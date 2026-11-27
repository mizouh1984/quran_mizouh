#!/bin/sh
# =========================================================================
# قارئ القرآن - mizouh المتميز (الإصدار v3.3.0) - ملف تثبيت شامل (All-in-One)
# مستودع التحديث التلقائي: https://github.com/mizouh1984/quran_mizouh
# متوافق مع OpenATV / OpenPLi / OpenBH / EGAMI / Pure2 / VTi / DreamOS
# =========================================================================

PLUGIN_DIR="/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh"
MIN_FREE_KB=5120

# Flash Space Guard: require at least 5 MB free on / BEFORE touching existing files
FREE_KB=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt "$MIN_FREE_KB" ] 2>/dev/null; then
    echo ">>> [ERROR] المساحة الحرة على الفلاش أقل من 5 MB (${FREE_KB} KB)!"
    echo ">>> تم إيقاف التثبيت حمايةً للرسيفر دون حذف النسخة الحالية."
    exit 1
fi

echo ">>> جارٍ تثبيت قارئ القرآن - mizouh المتميز (الإصدار v3.3.0)..."
rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR/locale"

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/plugin.py"
# -*- coding: utf-8 -*-
"""
قارئ القرآن - mizouh المتميز (Quran Reader - mizouh Al-Mutamayiz)
Enigma2 FullHD (1920x1080) Plugin v3.3.0
Performance & Feature Architecture:
  1. Zero-Lag Async Surah Switching: 0ms UI freeze — all HTTP & JSON I/O offloaded to background workers
  2. Instant Mushaf Page Display: Built-in 114-Surah page map + fast ePicLoad scaler + lazy text mode + dedup prefetch
  3. Persistent Auto-Resume (last_reciter, last_surah, last_ayah) saved on navigation & exit
  4. Background Offline Audio + Surah Text/Tafsir Download via REC / TEXT keys & top MENU action
  5. Full MENU Screen with 4 Live-Switchable FullHD Skins + GitHub OTA Auto-Updater + Official plugin.png Icon
"""

import os
import re
import time
import threading
from Plugins.Plugin import PluginDescriptor
from Screens.Screen import Screen
from Screens.MessageBox import MessageBox
from Screens.Standby import TryQuitMainloop
from Screens.VirtualKeyBoard import VirtualKeyBoard
from Components.ActionMap import ActionMap
from Components.Label import Label
from Components.Pixmap import Pixmap
from Components.MenuList import MenuList
from Components.ScrollLabel import ScrollLabel
from Components.ConfigList import ConfigListScreen
from Components.config import (
    config,
    configfile,
    ConfigSubsection,
    ConfigSelection,
    ConfigInteger,
    ConfigText,
    ConfigYesNo,
    ConfigNothing,
    getConfigListEntry,
)
from enigma import eServiceReference, ePicLoad, eTimer, iPlayableService
from Components.ServiceEventTracker import ServiceEventTracker

from .version import PLUGIN_VERSION, GITHUB_USER, GITHUB_REPO
from .skins import SKIN_CHOICES, build_main_skin, build_menu_skin
from .quran_api import QuranAPI, SURAHS_LIST
from .offline_manager import OfflineManager
from .updater import PluginAutoUpdater
from .locale_loader import LocaleLoader

# Persistent Enigma2 Plugin Configuration (including Auto-Resume state)
config.plugins.quranmizouh = ConfigSubsection()
config.plugins.quranmizouh.skin_theme = ConfigSelection(default="emerald_gold", choices=SKIN_CHOICES)
config.plugins.quranmizouh.language = ConfigSelection(default="ar", choices=[("ar", "العربية"), ("en", "English"), ("fr", "Français")])
config.plugins.quranmizouh.riwaya = ConfigSelection(default="hafs", choices=[("hafs", "حفص عن عاصم"), ("warsh", "ورش عن نافع")])
config.plugins.quranmizouh.show_mushaf = ConfigYesNo(default=True)
config.plugins.quranmizouh.mushaf_mode = ConfigSelection(default="image", choices=[("image", "صورة المصحف الحقيقية"), ("text", "المصحف النصي")])
config.plugins.quranmizouh.auto_update = ConfigYesNo(default=True)
config.plugins.quranmizouh.last_reciter = ConfigText(default="", fixed_size=False)
config.plugins.quranmizouh.last_surah = ConfigInteger(default=1, limits=(1, 114))
config.plugins.quranmizouh.last_ayah = ConfigInteger(default=1, limits=(1, 286))
config.plugins.quranmizouh.tafsir_edition = ConfigSelection(
    default="ar.muyassar",
    choices=[
        ("ar.muyassar", "التفسير الميسر"),
        ("ar.jalalayn", "تفسير الجلالين"),
        ("ar.baghawi", "تفسير البغوي"),
        ("en.sahih", "Sahih International (EN)"),
        ("fr.hamidullah", "Hamidullah (FR)"),
    ],
)
config.plugins.quranmizouh.font_size = ConfigInteger(default=32, limits=(22, 46))
config.plugins.quranmizouh.storage_path = ConfigSelection(
    default="/media/hdd/QuranMizouh",
    choices=[
        ("/media/hdd/QuranMizouh", "/media/hdd/QuranMizouh"),
        ("/media/usb/QuranMizouh", "/media/usb/QuranMizouh"),
        ("/tmp/QuranMizouh", "/tmp/QuranMizouh"),
    ],
)

MUSHAF_W = 576
MUSHAF_H = 824
PAGE_TURN_LEAD_SEC = 1.2

DIACRITICS_RE = re.compile(r"[\u064B-\u065F\u0670\u06D6-\u06ED\s]+")


def strip_diacritics(text):
    return DIACRITICS_RE.sub("", text or "")


class QuranMizouhMainScreen(Screen):
    def __init__(self, session, restore_state=None):
        self.skin_theme = config.plugins.quranmizouh.skin_theme.value
        self.skin = build_main_skin(self.skin_theme)
        Screen.__init__(self, session)

        self.session = session
        self.prev_service = (restore_state or {}).get("prev_service") or self.session.nav.getCurrentlyPlayingServiceReference()
        self.api = QuranAPI()
        self.offline = OfflineManager(config.plugins.quranmizouh.storage_path.value)
        self.updater = PluginAutoUpdater()
        self.locale = LocaleLoader(config.plugins.quranmizouh.language.value)
        self.picload = ePicLoad()

        # Restore persistent Auto-Resume listening position (last_reciter, last_surah, last_ayah)
        saved_reciter_id = (restore_state or {}).get("reciter_id") or (config.plugins.quranmizouh.last_reciter.value or "").strip()
        saved_surah = (restore_state or {}).get("surah") or int(config.plugins.quranmizouh.last_surah.value or 1)
        saved_ayah = (restore_state or {}).get("ayah") or int(config.plugins.quranmizouh.last_ayah.value or 1)
        saved_riwaya = (restore_state or {}).get("riwaya") or config.plugins.quranmizouh.riwaya.value

        matched_global = self.api.find_reciter_by_id(saved_reciter_id) if saved_reciter_id else None
        if matched_global and not restore_state:
            saved_riwaya = matched_global.get("riwaya") or saved_riwaya

        self.riwaya = saved_riwaya
        self.show_mushaf = config.plugins.quranmizouh.show_mushaf.value
        self.mushaf_mode = config.plugins.quranmizouh.mushaf_mode.value
        self.active_pane = "surahs"
        self.current_surah = max(1, min(114, saved_surah))
        self.current_ayah = max(1, saved_ayah)
        self.current_page = SURAHS_LIST[self.current_surah - 1].get("page", 1)
        self.ayahs_data = []
        self.tafsirs_data = []
        self.ayah_page_map = {}
        self.exact_timings = []
        self.ref_ratio_timings = []
        self.ayah_weight_ranges = []

        # Generation counters cancel stale background threads immediately during fast remote navigation
        self._surah_load_gen = 0
        self._play_gen = 0
        self._page_req_gen = 0
        self._last_decoded_page_num = None
        self._mushaf_text_loaded_surah = None
        self._pending_surah_payload = None
        self._pending_timings_payload = None
        self._pending_decoded_page = None
        self._pending_decoded_page_num = None
        self._pending_search_results = None

        # Explicit 3-state playback machine: "stopped" | "playing" | "paused"
        self.play_state = (restore_state or {}).get("play_state", "stopped")
        self.last_pos_sec = (restore_state or {}).get("last_pos_sec", 0.0)
        self.pending_resume_sec = None
        self.pending_resume_ayah = self.current_ayah if (self.current_ayah > 1 and not restore_state) else None
        self.pending_update_info = None
        self.pending_download_status = None
        self.is_downloading_offline = False
        self._closing_for_skin_reload = False

        self.reciters = self.api.get_reciters_by_riwaya(self.riwaya)
        self.current_reciter = next((r for r in self.reciters if r["id"] == saved_reciter_id), self.reciters[0])

        self["header_title"] = Label(f"قارئ القرآن - mizouh المتميز   v{PLUGIN_VERSION}")
        self["riwaya_label"] = Label("")
        self["reciter_title"] = Label("")
        self["surah_title"] = Label(self.locale.t("surahs"))
        self["reciter_list"] = MenuList([])
        self["surah_list"] = MenuList([])
        self["surah_banner"] = Label("")
        self["mushaf_page"] = Pixmap()
        self["mushaf_text"] = ScrollLabel("")
        self["active_ayah_label"] = Label("")
        self["audio_only_status"] = Label("")
        self["tafsir_text"] = ScrollLabel("")
        self["key_red"] = Label("إيقاف كلي")
        self["key_green"] = Label("تشغيل / إيقاف مؤقت")
        self["key_yellow"] = Label("إظهار / إخفاء المصحف")
        self["key_blue"] = Label("")
        self["status_bar"] = Label(f"v{PLUGIN_VERSION} · REC/TEXT للتحميل · MENU للقائمة")

        # Fast 300ms timer for smooth page-turning & Tafsir sync (lightweight CPU footprint)
        self.sync_timer = eTimer()
        self.sync_timer.callback.append(self.sync_page_from_playback)

        # Main-thread handoff timers (keep GUI 100% responsive with zero main-thread blocking!)
        self.page_ready_timer = eTimer()
        self.page_ready_timer.callback.append(self._decode_ready_page)

        self.surah_ready_timer = eTimer()
        self.surah_ready_timer.callback.append(self._apply_loaded_surah_payload)

        self.timings_ready_timer = eTimer()
        self.timings_ready_timer.callback.append(self._apply_loaded_timings_payload)

        self.search_ready_timer = eTimer()
        self.search_ready_timer.callback.append(self._apply_search_results)

        self.update_ui_timer = eTimer()
        self.update_ui_timer.callback.append(self._handle_update_check_result)

        self.download_ui_timer = eTimer()
        self.download_ui_timer.callback.append(self._handle_download_status_update)

        self.__event_tracker = ServiceEventTracker(screen=self, eventmap={
            iPlayableService.evEOF: self.on_surah_finished,
        })

        # Dedicated high-priority ColorActions & MediaPlayerActions (ZERO EPGSelectActions collision on Blue!)
        self["color_actions"] = ActionMap(
            ["ColorActions", "MediaPlayerActions", "InfobarSeekActions"],
            {
                "red": self.stop_recitation,
                "green": self.toggle_play_pause,
                "yellow": self.toggle_mushaf_display,
                "blue": self.toggle_riwaya,
                "play": self.resume_or_play,
                "pause": self.pause_recitation,
                "playpause": self.toggle_play_pause,
                "pauseService": self.toggle_play_pause,
                "unPauseService": self.resume_or_play,
                "stop": self.stop_recitation,
            },
            -2,
        )

        # Background offline download mapped to REC and TEXT remote buttons
        self["download_actions"] = ActionMap(
            ["InfobarInstantRecord", "InfobarTeletextActions"],
            {
                "instantRecord": self.start_background_download,
                "startTeletext": self.start_background_download,
            },
            -2,
        )

        self["nav_actions"] = ActionMap(
            ["OkCancelActions", "DirectionActions", "MenuActions", "ChannelSelectBaseActions"],
            {
                "cancel": self.exit_plugin,
                "ok": self.on_ok,
                "up": self.move_up,
                "down": self.move_down,
                "left": self.switch_pane_reciters,
                "right": self.switch_pane_surahs,
                "menu": self.open_menu_screen,
                "nextBouquet": self.next_ayah_seek,
                "prevBouquet": self.prev_ayah_seek,
            },
            -1,
        )

        # Separate lower-priority map strictly for INFO key search (never intercepts Blue!)
        self["info_actions"] = ActionMap(
            ["EPGSelectActions"],
            {
                "info": self.open_search,
            },
            0,
        )

        self.picload.PictureData.get().append(self.on_mushaf_decoded)
        self.onLayoutFinish.append(self.initialize_ui)

    def initialize_ui(self):
        # Fast scaler flag (0) drastically speeds up Mushaf PNG/JPG decoding on MIPS/ARM Enigma2 boxes!
        self.picload.setPara((MUSHAF_W, MUSHAF_H, 1, 1, False, 0, "#FAF6EC"))
        self.populate_lists(keep_current=True)
        self.update_display_mode(trigger_image=False)
        self.load_surah_content(self.current_surah)
        self._refresh_playback_labels()
        surah_name = SURAHS_LIST[self.current_surah - 1]["name_ar"]
        if self.current_surah > 1 or self.current_ayah > 1:
            self["status_bar"].setText(f"استئناف: سورة {surah_name} · آية {self.current_ayah}")
        if self.play_state == "playing":
            self.sync_timer.start(300, False)
        if config.plugins.quranmizouh.auto_update.value:
            self.start_background_update_check()

    def save_playback_position(self, flush_disk=False):
        """Persists last_reciter, last_surah, last_ayah & riwaya without blocking UI flash I/O."""
        try:
            config.plugins.quranmizouh.riwaya.value = self.riwaya
            config.plugins.quranmizouh.last_reciter.value = str(self.current_reciter.get("id", ""))
            config.plugins.quranmizouh.last_surah.value = max(1, min(114, int(self.current_surah)))
            config.plugins.quranmizouh.last_ayah.value = max(1, min(286, int(self.current_ayah)))
            config.plugins.quranmizouh.riwaya.save()
            config.plugins.quranmizouh.last_reciter.save()
            config.plugins.quranmizouh.last_surah.save()
            config.plugins.quranmizouh.last_ayah.save()
            if flush_disk:
                configfile.save()
        except Exception:
            pass

    def _refresh_playback_labels(self):
        if self.play_state == "playing":
            self["key_green"].setText("إيقاف مؤقت")
        elif self.play_state == "paused":
            self["key_green"].setText("استمرار التلاوة")
        else:
            self["key_green"].setText("تشغيل التلاوة")

        if self.riwaya == "hafs":
            self["key_blue"].setText("تحويل إلى ورش")
        else:
            self["key_blue"].setText("تحويل إلى حفص")

    def start_background_download(self):
        """Downloads active Surah audio MP3 + Surah text & Tafsir in background thread without freezing TV."""
        if self.is_downloading_offline:
            self["status_bar"].setText("جارٍ التحميل في الخلفية بالفعل...")
            return

        reciter = dict(self.current_reciter)
        surah_num = int(self.current_surah)
        surah_name = SURAHS_LIST[surah_num - 1]["name_ar"]
        tafsir_ed = config.plugins.quranmizouh.tafsir_edition.value

        existing_mp3 = self.offline.get_local_mp3(reciter["id"], surah_num)
        if existing_mp3 and os.path.exists(existing_mp3) and os.path.getsize(existing_mp3) > 8192:
            self["status_bar"].setText(f"✔ سورة {surah_name} محفوظة مسبقاً بدون إنترنت")
            return

        self.is_downloading_offline = True
        self["status_bar"].setText(f"⬇ جارٍ تحميل سورة {surah_name} في الخلفية...")

        def _dl_worker():
            try:
                self.api.fetch_surah_and_tafsir(surah_num, tafsir_ed, self.offline)
                q_url, _ = self.api.fetch_continuous_surah_stream(reciter, surah_num)
                mp3_url = q_url or self.api.build_audio_url(reciter, surah_num)
                saved_path = self.offline.download_surah(reciter["id"], surah_num, mp3_url)
                if saved_path:
                    self.pending_download_status = f"✔ تم حفظ سورة {surah_name} والتفسير بدون إنترنت"
                else:
                    self.pending_download_status = f"✖ تعذر تحميل سورة {surah_name} (تحقق من المساحة أو الإنترنت)"
            except Exception:
                self.pending_download_status = f"✖ خطأ أثناء تحميل سورة {surah_name}"
            finally:
                self.is_downloading_offline = False
                self.download_ui_timer.start(50, True)

        threading.Thread(target=_dl_worker, daemon=True).start()

    def _handle_download_status_update(self):
        msg = self.pending_download_status
        self.pending_download_status = None
        if msg:
            self["status_bar"].setText(msg)

    def start_background_update_check(self):
        def _worker():
            feed_updated = self.updater.sync_reciters_feed()
            update_info = self.updater.check_for_update()
            self.pending_update_info = {
                "feed_updated": feed_updated,
                "update": update_info,
            }
            self.update_ui_timer.start(150, True)

        threading.Thread(target=_worker, daemon=True).start()

    def _handle_update_check_result(self):
        result = self.pending_update_info
        self.pending_update_info = None
        if not result:
            return
        if result.get("feed_updated"):
            self.api.reload_catalog()
            self.populate_lists(keep_current=True)
        update_info = result.get("update")
        if not update_info:
            return

        new_ver = update_info.get("version", "")
        changelog = update_info.get("changelog_ar") or update_info.get("changelog_en") or ""
        force_auto = bool(update_info.get("force_auto_update", False))

        if force_auto and config.plugins.quranmizouh.auto_update.value:
            self["status_bar"].setText(f"جارٍ التحديث التلقائي إلى v{new_ver}...")
            self.apply_ota_update(update_info)
        else:
            msg = (
                f"يتوفر تحديث جديد لبلوجن قارئ القرآن - mizouh المتميز\n"
                f"الإصدار الحالي: v{PLUGIN_VERSION}  ←  الإصدار الجديد: v{new_ver}\n\n"
                f"{changelog}\n\n"
                f"هل تريد التحديث الآن وإعادة تشغيل الواجهة؟"
            )
            self.session.openWithCallback(
                lambda confirmed: self.apply_ota_update(update_info) if confirmed else None,
                MessageBox,
                msg,
                MessageBox.TYPE_YESNO,
            )

    def apply_ota_update(self, update_info):
        self.save_playback_position(flush_disk=True)
        ok, message = self.updater.download_and_install_update(update_info)
        if ok:
            self.session.openWithCallback(
                lambda _res=None: self.session.open(TryQuitMainloop, 3),
                MessageBox,
                f"{message}\nجارٍ إعادة تشغيل Enigma2 لتفعيل الإصدار v{update_info.get('version', '')}...",
                MessageBox.TYPE_INFO,
                timeout=3,
            )
        else:
            self["status_bar"].setText("تعذر التحديث التلقائي")
            self.session.open(MessageBox, message, MessageBox.TYPE_ERROR, timeout=5)

    def on_mushaf_decoded(self, picInfo=None):
        ptr = self.picload.getData()
        if ptr is not None:
            self["mushaf_page"].instance.setPixmap(ptr)

    def populate_lists(self, keep_current=False):
        self.reciters = self.api.get_reciters_by_riwaya(self.riwaya)
        if not self.reciters:
            return
        if not keep_current or self.current_reciter["id"] not in [r["id"] for r in self.reciters]:
            self.current_reciter = self.reciters[0]

        riwaya_title = "رواية حفص عن عاصم" if self.riwaya == "hafs" else "رواية ورش عن نافع"
        self["reciter_title"].setText(f"قراء {riwaya_title} ({len(self.reciters)})")
        self["reciter_list"].setList([(r["name_ar"], r) for r in self.reciters])
        idx_rec = next((i for i, r in enumerate(self.reciters) if r["id"] == self.current_reciter["id"]), 0)
        try:
            self["reciter_list"].moveToIndex(idx_rec)
        except Exception:
            pass

        self["surah_list"].setList([(f"{s['number']:03d} - سورة {s['name_ar']}", s) for s in SURAHS_LIST])
        try:
            self["surah_list"].moveToIndex(max(0, self.current_surah - 1))
        except Exception:
            pass

        self["riwaya_label"].setText(f"{riwaya_title}  ·  {self.current_reciter['name_ar']}")
        self._refresh_playback_labels()

    def _populate_text_mushaf_lazy(self):
        """Populates heavy ScrollLabel only when user actually switches to text mode (0ms cost in image mode!)."""
        if self._mushaf_text_loaded_surah == self.current_surah:
            return
        if not self.ayahs_data:
            return
        mushaf_str = " ۝ ".join([f"{a['text']} ({a['num']})" for a in self.ayahs_data])
        self["mushaf_text"].setText(mushaf_str)
        self._mushaf_text_loaded_surah = self.current_surah

    def update_display_mode(self, trigger_image=True):
        if not self.show_mushaf:
            self["mushaf_page"].hide()
            self["mushaf_text"].hide()
            self["active_ayah_label"].hide()
            self["tafsir_text"].hide()
            self["audio_only_status"].show()
            surah_meta = SURAHS_LIST[self.current_surah - 1]
            riwaya_title = "حفص عن عاصم" if self.riwaya == "hafs" else "ورش عن نافع"
            self["audio_only_status"].setText(
                f"وضع الاستماع الصوتي (بدون إظهار المصحف)\n\nسورة {surah_meta['name_ar']}\nالقارئ: {self.current_reciter['name_ar']} ({riwaya_title})"
            )
            return

        self["audio_only_status"].hide()
        self["active_ayah_label"].show()
        self["tafsir_text"].show()

        if self.mushaf_mode == "image":
            self["mushaf_text"].hide()
            self["mushaf_page"].show()
            if trigger_image:
                self.render_mushaf_page_image(self.current_page)
        else:
            self["mushaf_page"].hide()
            self["mushaf_text"].show()
            self._populate_text_mushaf_lazy()

    def _prefetch_upcoming_pages(self, start_page, expected_gen):
        """Lightweight single-thread sequential prefetch for next 2 pages AFTER active page renders."""
        pages = [p for p in (start_page, start_page + 1) if 1 <= p <= 604]
        if not pages:
            return

        def _worker():
            time.sleep(0.25)
            for p in pages:
                if expected_gen != self._page_req_gen:
                    return
                if not self.offline.get_cached_mushaf_page(p):
                    self.offline.get_or_download_mushaf_page(p)

        threading.Thread(target=_worker, daemon=True).start()

    def render_mushaf_page_image(self, page_num, force=False):
        """Instant local-cache decode (<20ms) or non-blocking priority download for active Mushaf page."""
        if not self.show_mushaf or self.mushaf_mode != "image":
            return
        if not force and self._last_decoded_page_num == page_num:
            return

        self._page_req_gen += 1
        req_gen = self._page_req_gen

        cached_path = self.offline.get_cached_mushaf_page(page_num)
        if cached_path:
            self._last_decoded_page_num = page_num
            self.picload.startDecode(cached_path)
            self._prefetch_upcoming_pages(page_num + 1, req_gen)
            return

        def _dl_worker():
            path = self.offline.get_or_download_mushaf_page(page_num)
            if path and req_gen == self._page_req_gen and page_num == self.current_page:
                self._pending_decoded_page = path
                self._pending_decoded_page_num = page_num
                self.page_ready_timer.start(10, True)
                self._prefetch_upcoming_pages(page_num + 1, req_gen)

        threading.Thread(target=_dl_worker, daemon=True).start()

    def _decode_ready_page(self):
        path = self._pending_decoded_page
        page_num = self._pending_decoded_page_num
        self._pending_decoded_page = None
        self._pending_decoded_page_num = None
        if path and os.path.exists(path) and page_num == self.current_page:
            self._last_decoded_page_num = page_num
            self.picload.startDecode(path)

    def _compute_ayah_weight_ranges(self):
        self.ayah_weight_ranges = []
        if not self.ayahs_data:
            return
        intro = 14.0 if (self.current_surah != 1 and self.current_surah != 9) else 0.0
        weights = [max(8.0, float(len(strip_diacritics(a.get("text", "")))) + 2.5) for a in self.ayahs_data]
        total = intro + sum(weights)
        if total <= 0:
            return
        acc = intro
        for a, w in zip(self.ayahs_data, weights):
            s_r = acc / total
            acc += w
            e_r = acc / total
            self.ayah_weight_ranges.append((a["num"], s_r, e_r))

    def load_surah_content(self, surah_number):
        """
        100% NON-BLOCKING Surah loader:
        - Immediately renders the Surah's exact Madinah Mushaf start page (0ms delay!)
        - Uses instant RAM cache if already visited, or loads JSON/Tafsir in a background thread
        """
        self._surah_load_gen += 1
        load_gen = self._surah_load_gen
        surah_meta = SURAHS_LIST[surah_number - 1]
        tafsir_ed = config.plugins.quranmizouh.tafsir_edition.value

        # Step 1: Immediate Mushaf page flip using built-in 114-Surah page map (zero API wait!)
        known_start_page = surah_meta.get("page", 1)
        if self.current_ayah <= 1:
            self.current_page = known_start_page
            if self.show_mushaf and self.mushaf_mode == "image":
                self.render_mushaf_page_image(self.current_page)

        self["surah_banner"].setText(f"سورة {surah_meta['name_ar']}  ·  آية {self.current_ayah}  ·  صفحة {self.current_page}")

        # Step 2: Check instant RAM cache first (0ms hit when switching between Surahs!)
        mem_hit = self.api.get_cached_surah_mem(surah_number, tafsir_ed)
        if mem_hit is not None:
            self._finish_surah_load(surah_number, mem_hit[0], mem_hit[1])
            return

        self["active_ayah_label"].setText("جارٍ تحميل نص السورة والتفسير...")

        # Step 3: Fetch disk cache or network JSON asynchronously in background thread
        def _surah_worker():
            ayahs, tafsirs = self.api.fetch_surah_and_tafsir(surah_number, tafsir_ed, self.offline)
            if load_gen == self._surah_load_gen:
                self._pending_surah_payload = (load_gen, surah_number, ayahs, tafsirs)
                self.surah_ready_timer.start(10, True)

        threading.Thread(target=_surah_worker, daemon=True).start()

    def _apply_loaded_surah_payload(self):
        payload = self._pending_surah_payload
        self._pending_surah_payload = None
        if not payload:
            return
        load_gen, surah_number, ayahs, tafsirs = payload
        if load_gen != self._surah_load_gen or surah_number != self.current_surah:
            return
        self._finish_surah_load(surah_number, ayahs, tafsirs)

    def _finish_surah_load(self, surah_number, ayahs, tafsirs):
        self.ayahs_data = ayahs
        self.tafsirs_data = tafsirs
        if self.ayahs_data and self.current_ayah > len(self.ayahs_data):
            self.current_ayah = 1
        self.ayah_page_map = {a["num"]: a.get("page", 1) for a in self.ayahs_data}
        self._compute_ayah_weight_ranges()
        self._mushaf_text_loaded_surah = None
        if self.show_mushaf and self.mushaf_mode == "text":
            self._populate_text_mushaf_lazy()
        self.update_active_ui(force_page_reload=False)
        self["status_bar"].setText(f"v{PLUGIN_VERSION} · صفحة {self.current_page} · آية {self.current_ayah}")

    def update_active_ui(self, force_page_reload=False, override_page=None):
        if not self.ayahs_data:
            return
        idx = max(0, min(len(self.ayahs_data) - 1, self.current_ayah - 1))
        ayah = self.ayahs_data[idx]
        tafsir = self.tafsirs_data[idx] if idx < len(self.tafsirs_data) else {"text": ""}
        new_page = override_page if override_page is not None else ayah.get("page", self.current_page)
        page_changed = force_page_reload or (new_page != self.current_page) or (self._last_decoded_page_num != new_page)
        self.current_page = new_page

        surah_meta = SURAHS_LIST[self.current_surah - 1]
        self["surah_banner"].setText(f"سورة {surah_meta['name_ar']}  ·  آية {ayah['num']}  ·  صفحة {self.current_page}")
        self["active_ayah_label"].setText(f"{ayah['text']} ۝{ayah['num']}")
        self["tafsir_text"].setText(f"التفسير:\n{tafsir['text']}")
        if self.show_mushaf and self.mushaf_mode == "image" and page_changed:
            self.render_mushaf_page_image(self.current_page, force=force_page_reload)

    def play_continuous_surah(self, resume_sec=None, resume_ayah=None):
        """
        Starts full-Surah playback INSTANTLY (<10ms) with ZERO blocking API calls!
        Exact verse timings & reference ratios load silently in a background thread.
        """
        self.sync_timer.stop()
        self._play_gen += 1
        play_gen = self._play_gen
        self.exact_timings = []
        self.ref_ratio_timings = []

        reciter = dict(self.current_reciter)
        surah_num = int(self.current_surah)
        local_mp3 = self.offline.get_local_mp3(reciter["id"], surah_num)

        if local_mp3 and os.path.exists(local_mp3) and os.path.getsize(local_mp3) > 8192:
            url = local_mp3
            is_local = True
            source_label = f"تشغيل محلي · {reciter['name_ar']}"
        else:
            url = self.api.build_audio_url(reciter, surah_num)
            is_local = False
            riwaya_short = "حفص" if self.riwaya == "hafs" else "ورش"
            source_label = f"{riwaya_short} · {reciter['name_ar']}"

        # Play audio immediately — zero waiting for api.quran.com!
        sref = eServiceReference(4097, 0, url)
        sref.setName(f"سورة {SURAHS_LIST[surah_num - 1]['name_ar']} - {reciter['name_ar']}")
        self.session.nav.stopService()
        self.session.nav.playService(sref)
        self.play_state = "playing"
        self.pending_resume_sec = resume_sec
        self.pending_resume_ayah = resume_ayah
        if resume_sec is None and resume_ayah is None:
            self.current_ayah = 1
            self.last_pos_sec = 0.0
        elif resume_ayah is not None:
            self.current_ayah = resume_ayah

        self.save_playback_position(flush_disk=False)
        self.update_active_ui()
        self._refresh_playback_labels()
        self["status_bar"].setText(source_label)
        self.sync_timer.start(300, False)

        # Load exact or reference timing ratios in background thread for pinpoint page turns
        def _timings_worker():
            exact = []
            ratios = []
            if not is_local and reciter.get("quran_com_id", 0):
                _q_url, exact = self.api.fetch_continuous_surah_stream(reciter, surah_num)
            if not exact:
                ratios = self.api.fetch_reference_ratios(surah_num)
            if play_gen == self._play_gen:
                self._pending_timings_payload = (play_gen, exact, ratios)
                self.timings_ready_timer.start(20, True)

        threading.Thread(target=_timings_worker, daemon=True).start()

    def _apply_loaded_timings_payload(self):
        payload = self._pending_timings_payload
        self._pending_timings_payload = None
        if not payload:
            return
        play_gen, exact, ratios = payload
        if play_gen != self._play_gen:
            return
        self.exact_timings = exact or []
        self.ref_ratio_timings = ratios or []

    def sync_page_from_playback(self):
        if self.play_state != "playing":
            return
        service = self.session.nav.getCurrentService()
        seek = service and service.seek()
        if not seek:
            return
        pos_tuple = seek.getPlayPosition()
        if not pos_tuple or pos_tuple[0] != 0:
            return
        pos_sec = pos_tuple[1] / 90000.0

        if self.pending_resume_sec is not None and pos_sec >= 0.1:
            target = self.pending_resume_sec
            self.pending_resume_sec = None
            seek.seekTo(int(target * 90000))
            return

        if self.pending_resume_ayah is not None and pos_sec >= 0.1:
            target_a = self.pending_resume_ayah
            self.pending_resume_ayah = None
            self._seek_to_ayah(target_a)
            return

        self.last_pos_sec = pos_sec
        matched_ayah = None
        lead_page = None

        if self.exact_timings:
            for item in self.exact_timings:
                if item["start"] <= pos_sec < item["end"]:
                    matched_ayah = item["ayah"]
                    break
            lead_sec = pos_sec + PAGE_TURN_LEAD_SEC
            for item in self.exact_timings:
                if item["start"] <= lead_sec < item["end"]:
                    upcoming_page = self.ayah_page_map.get(item["ayah"])
                    if upcoming_page and upcoming_page > self.current_page:
                        lead_page = upcoming_page
                    break
        else:
            len_tuple = seek.getLength()
            if len_tuple and len_tuple[0] == 0 and len_tuple[1] > 0:
                total_sec = len_tuple[1] / 90000.0
                progress = pos_sec / total_sec
                lead_progress = min(1.0, (pos_sec + PAGE_TURN_LEAD_SEC) / total_sec)
                ratios = self.ref_ratio_timings if self.ref_ratio_timings else self.ayah_weight_ranges
                for a_num, s_r, e_r in ratios:
                    if s_r <= progress <= e_r:
                        matched_ayah = a_num
                        break
                for a_num, s_r, e_r in ratios:
                    if s_r <= lead_progress <= e_r:
                        upcoming_page = self.ayah_page_map.get(a_num)
                        if upcoming_page and upcoming_page > self.current_page:
                            lead_page = upcoming_page
                        break

        if matched_ayah is not None and matched_ayah != self.current_ayah:
            self.current_ayah = matched_ayah
            self.save_playback_position(flush_disk=False)
            self.update_active_ui(override_page=lead_page)
        elif lead_page is not None and lead_page != self.current_page:
            self.update_active_ui(override_page=lead_page)

    def _seek_to_ayah(self, target_ayah):
        self.current_ayah = target_ayah
        self.save_playback_position(flush_disk=False)
        self.update_active_ui()
        service = self.session.nav.getCurrentService()
        seek = service and service.seek()
        if not seek:
            return
        target_sec = None
        if self.exact_timings:
            for item in self.exact_timings:
                if item["ayah"] == target_ayah:
                    target_sec = item["start"]
                    break
        else:
            len_tuple = seek.getLength()
            if len_tuple and len_tuple[0] == 0 and len_tuple[1] > 0:
                total_sec = len_tuple[1] / 90000.0
                ratios = self.ref_ratio_timings if self.ref_ratio_timings else self.ayah_weight_ranges
                for a_num, s_r, _e_r in ratios:
                    if a_num == target_ayah:
                        target_sec = s_r * total_sec
                        break
        if target_sec is not None:
            seek.seekTo(int(target_sec * 90000))

    def on_surah_finished(self):
        if self.play_state != "playing":
            return
        if self.current_surah < 114:
            self.current_surah += 1
            self.current_ayah = 1
            try:
                self["surah_list"].moveToIndex(self.current_surah - 1)
            except Exception:
                pass
            self.save_playback_position(flush_disk=False)
            self.load_surah_content(self.current_surah)
            self.play_continuous_surah()

    def next_ayah_seek(self):
        if self.current_ayah < len(self.ayahs_data):
            self._seek_to_ayah(self.current_ayah + 1)

    def prev_ayah_seek(self):
        if self.current_ayah > 1:
            self._seek_to_ayah(self.current_ayah - 1)

    def pause_recitation(self):
        if self.play_state != "playing":
            return
        service = self.session.nav.getCurrentService()
        pauseable = service and service.pause()
        if pauseable:
            pauseable.pause()
            self.play_state = "paused"
            self.sync_timer.stop()
            self.save_playback_position(flush_disk=False)
            self._refresh_playback_labels()
            self["status_bar"].setText("إيقاف مؤقت — اضغط الأخضر للاستمرار")

    def resume_or_play(self):
        if self.play_state == "playing":
            return
        if self.play_state == "paused":
            service = self.session.nav.getCurrentService()
            pauseable = service and service.pause()
            if pauseable:
                pauseable.unpause()
                self.play_state = "playing"
                self.sync_timer.start(300, False)
                self._refresh_playback_labels()
                self["status_bar"].setText(f"مستمر · {self.current_reciter['name_ar']}")
                return
            self.play_continuous_surah(resume_sec=self.last_pos_sec)
            return
        resume_a = self.pending_resume_ayah or (self.current_ayah if self.current_ayah > 1 else None)
        self.play_continuous_surah(resume_ayah=resume_a)

    def toggle_play_pause(self):
        if self.play_state == "playing":
            self.pause_recitation()
        elif self.play_state == "paused":
            self.resume_or_play()
        else:
            self.resume_or_play()

    def stop_recitation(self):
        self.sync_timer.stop()
        self.session.nav.stopService()
        self.play_state = "stopped"
        self.last_pos_sec = 0.0
        self.save_playback_position(flush_disk=False)
        self._refresh_playback_labels()
        self["status_bar"].setText("تم الإيقاف الكلي")

    def toggle_mushaf_display(self):
        self.show_mushaf = not self.show_mushaf
        config.plugins.quranmizouh.show_mushaf.value = self.show_mushaf
        config.plugins.quranmizouh.show_mushaf.save()
        self.update_display_mode()

    def toggle_riwaya(self):
        """Reliably switches Hafs <-> Warsh, updates reciter list to index 0, saves position, and plays immediately!"""
        next_riwaya = "warsh" if self.riwaya == "hafs" else "hafs"
        next_reciters = self.api.get_reciters_by_riwaya(next_riwaya)
        if not next_reciters:
            self["status_bar"].setText("تعذر تحميل قائمة القراء لهذه الرواية")
            return
        self.riwaya = next_riwaya
        self.reciters = next_reciters
        self.current_reciter = self.reciters[0]
        self.save_playback_position(flush_disk=False)
        self.populate_lists(keep_current=False)
        riwaya_title = "حفص عن عاصم" if self.riwaya == "hafs" else "ورش عن نافع"
        self["status_bar"].setText(f"تم التحويل إلى {riwaya_title} · {self.current_reciter['name_ar']}")
        self.play_continuous_surah()

    def switch_pane_reciters(self):
        self.active_pane = "reciters"

    def switch_pane_surahs(self):
        self.active_pane = "surahs"

    def move_up(self):
        if self.active_pane == "reciters":
            self["reciter_list"].up()
        else:
            self["surah_list"].up()

    def move_down(self):
        if self.active_pane == "reciters":
            self["reciter_list"].down()
        else:
            self["surah_list"].down()

    def on_ok(self):
        if self.active_pane == "reciters":
            sel = self["reciter_list"].getCurrent()
            if sel:
                self.current_reciter = sel[1]
                self.save_playback_position(flush_disk=False)
                riwaya_title = "رواية حفص عن عاصم" if self.riwaya == "hafs" else "رواية ورش عن نافع"
                self["riwaya_label"].setText(f"{riwaya_title}  ·  {self.current_reciter['name_ar']}")
                self.play_continuous_surah()
        else:
            sel = self["surah_list"].getCurrent()
            if sel:
                self.current_surah = sel[1]["number"]
                self.current_ayah = 1
                self.pending_resume_ayah = None
                self.save_playback_position(flush_disk=False)
                self.load_surah_content(self.current_surah)
                self.play_continuous_surah()

    def open_search(self):
        self.session.openWithCallback(self.execute_search, VirtualKeyBoard, title="البحث المتقدم في القرآن الكريم", text="")

    def execute_search(self, keyword):
        if not keyword:
            return
        self["status_bar"].setText(f"جارٍ البحث عن: {keyword}...")

        def _search_worker():
            results = self.api.search_verses(keyword)
            self._pending_search_results = results
            self.search_ready_timer.start(20, True)

        threading.Thread(target=_search_worker, daemon=True).start()

    def _apply_search_results(self):
        results = self._pending_search_results
        self._pending_search_results = None
        if not results:
            self["status_bar"].setText("لم يتم العثور على نتائج مطابقة")
            self.session.open(MessageBox, "لم يتم العثور على نتائج مطابقة.", MessageBox.TYPE_INFO, timeout=4)
            return
        first = results[0]
        self.current_surah = first["surah"]
        self.current_ayah = first["ayah"]
        try:
            self["surah_list"].moveToIndex(max(0, self.current_surah - 1))
        except Exception:
            pass
        self.save_playback_position(flush_disk=False)
        self.load_surah_content(self.current_surah)
        self.play_continuous_surah(resume_ayah=first["ayah"])

    def open_menu_screen(self):
        """Opens the themed MENU screen with Background Download, 4 Skins & GitHub OTA Updater."""
        surah_name = SURAHS_LIST[self.current_surah - 1]["name_ar"]
        self.session.openWithCallback(
            self._on_menu_closed,
            QuranMizouhMenuScreen,
            self.updater,
            surah_name,
        )

    def _on_menu_closed(self, action=None):
        if action == "download_offline":
            self.start_background_download()
            return
        if action == "update_plugin":
            self.check_update_now()
            return
        if action == "update_reciters":
            ok = self.updater.sync_reciters_feed()
            self.api.reload_catalog()
            self.populate_lists(keep_current=True)
            msg = "تم تحديث قائمة القراء من GitHub بنجاح!" if ok else "تعذر الاتصال بـ GitHub، القائمة المحلية تعمل بشكل طبيعي."
            self.session.open(MessageBox, msg, MessageBox.TYPE_INFO, timeout=4)
            return
        if action == "saved":
            new_skin = config.plugins.quranmizouh.skin_theme.value
            self.show_mushaf = config.plugins.quranmizouh.show_mushaf.value
            self.mushaf_mode = config.plugins.quranmizouh.mushaf_mode.value
            self.offline = OfflineManager(config.plugins.quranmizouh.storage_path.value)
            new_riwaya = config.plugins.quranmizouh.riwaya.value
            if new_riwaya != self.riwaya:
                self.riwaya = new_riwaya
                self.populate_lists(keep_current=False)
            self.save_playback_position(flush_disk=True)

            if new_skin != self.skin_theme:
                state = {
                    "prev_service": self.prev_service,
                    "riwaya": self.riwaya,
                    "reciter_id": self.current_reciter["id"],
                    "surah": self.current_surah,
                    "ayah": self.current_ayah,
                    "play_state": self.play_state,
                    "last_pos_sec": self.last_pos_sec,
                }
                self._closing_for_skin_reload = True
                self._stop_all_timers()
                self.close()
                self.session.open(QuranMizouhMainScreen, restore_state=state)
                return

            self.update_display_mode()

    def check_update_now(self):
        self["status_bar"].setText("جارٍ فحص التحديثات من GitHub...")
        self.updater.sync_reciters_feed()
        self.api.reload_catalog()
        self.populate_lists(keep_current=True)
        update_info = self.updater.check_for_update()
        if update_info:
            self.apply_ota_update(update_info)
        else:
            self["status_bar"].setText(f"v{PLUGIN_VERSION} · محدث لأحدث إصدار")
            self.session.open(
                MessageBox,
                f"البلوجن محدث بالفعل لأحدث إصدار (v{PLUGIN_VERSION})\nالمستودع: {GITHUB_USER}/{GITHUB_REPO}",
                MessageBox.TYPE_INFO,
                timeout=4,
            )

    def _stop_all_timers(self):
        for t in (
            self.sync_timer,
            self.page_ready_timer,
            self.surah_ready_timer,
            self.timings_ready_timer,
            self.search_ready_timer,
            self.update_ui_timer,
            self.download_ui_timer,
        ):
            try:
                t.stop()
            except Exception:
                pass

    def exit_plugin(self):
        self._stop_all_timers()
        self.save_playback_position(flush_disk=True)
        if not self._closing_for_skin_reload:
            self.session.nav.stopService()
            if self.prev_service:
                self.session.nav.playService(self.prev_service)
        self.close()


class QuranMizouhMenuScreen(ConfigListScreen, Screen):
    """Dedicated MENU Screen: Offline Surah Download + 4 Live FullHD Skins + GitHub OTA Updates."""

    def __init__(self, session, updater=None, current_surah_name="الفاتحة"):
        self.skin = build_menu_skin(config.plugins.quranmizouh.skin_theme.value)
        Screen.__init__(self, session)
        self.updater = updater
        self._download_entry = getConfigListEntry(
            f"⬇ تحميل سورة ({current_surah_name}) للاستماع بدون إنترنت",
            ConfigNothing(),
        )

        entries = [
            self._download_entry,
            getConfigListEntry("مظهر الواجهة (السكين / Skin)", config.plugins.quranmizouh.skin_theme),
            getConfigListEntry("التحديث التلقائي الدوري عبر GitHub", config.plugins.quranmizouh.auto_update),
            getConfigListEntry("الرواية الافتراضية (حفص / ورش)", config.plugins.quranmizouh.riwaya),
            getConfigListEntry("إظهار المصحف الشريف أثناء التلاوة", config.plugins.quranmizouh.show_mushaf),
            getConfigListEntry("نمط المصحف (صورة حقيقية / نص)", config.plugins.quranmizouh.mushaf_mode),
            getConfigListEntry("مصدر التفسير / الترجمة", config.plugins.quranmizouh.tafsir_edition),
            getConfigListEntry("لغة الواجهة / Language", config.plugins.quranmizouh.language),
            getConfigListEntry("حجم الخط القرآني", config.plugins.quranmizouh.font_size),
            getConfigListEntry("مجلد التحميل بدون إنترنت", config.plugins.quranmizouh.storage_path),
        ]
        ConfigListScreen.__init__(self, entries)

        self["menu_title"] = Label(f"قائمة قارئ القرآن - mizouh المتميز   ·   الإصدار v{PLUGIN_VERSION}")
        self["repo_info"] = Label(f"مستودع التحديثات: github.com/{GITHUB_USER}/{GITHUB_REPO}")
        self["update_status"] = Label("OK على الخيار الأول للتحميل بدون إنترنت · الأخضر لتطبيق السكين · الأصفر للتحديث من GitHub")
        self["btn_red"] = Label("إغلاق")
        self["btn_green"] = Label("حفظ وتطبيق السكين")
        self["btn_yellow"] = Label("تحديث البلوجن من GitHub")
        self["btn_blue"] = Label("تحديث القراء فقط")

        self["actions"] = ActionMap(["SetupActions", "ColorActions"], {
            "save": self.save_settings,
            "ok": self.on_ok_pressed,
            "green": self.save_settings,
            "yellow": self.trigger_plugin_update,
            "blue": self.trigger_reciters_update,
            "red": lambda: self.close(None),
            "cancel": lambda: self.close(None),
        }, -2)

    def on_ok_pressed(self):
        cur = self["config"].getCurrent()
        if cur is self._download_entry:
            self.close("download_offline")
            return
        self.save_settings()

    def save_settings(self):
        for item in self["config"].list:
            if hasattr(item[1], "save"):
                item[1].save()
        configfile.save()
        self.close("saved")

    def trigger_plugin_update(self):
        self.close("update_plugin")

    def trigger_reciters_update(self):
        self.close("update_reciters")


def main(session, **kwargs):
    session.open(QuranMizouhMainScreen)


def Plugins(**kwargs):
    return [
        PluginDescriptor(
            name="قارئ القرآن - mizouh",
            description=f"قارئ القرآن - mizouh المتميز v{PLUGIN_VERSION} - تلاوة متصلة وسريعة (حفص وورش) مع المصحف الحقيقي و4 سكينات",
            where=[PluginDescriptor.WHERE_PLUGINMENU, PluginDescriptor.WHERE_EXTENSIONSMENU],
            icon="plugin.png",
            fnc=main,
        )
    ]

QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/skins.py"
# -*- coding: utf-8 -*-
"""
4 distinct handcrafted FullHD (1920x1080) Enigma2 Skins for قارئ القرآن - mizouh المتميز
Switchable live from the MENU screen without restarting Enigma2!
"""

SKIN_CHOICES = [
    ("emerald_gold", "الزمردي الذهبي (الأصلي)"),
    ("royal_blue", "الأزرق الملكي الليلي"),
    ("warm_walnut", "الكلاسيكي الدافئ (خشبي ذهبي)"),
    ("oled_black", "الأسود الفاحم OLED (تباين عالٍ)"),
]

SKIN_PALETTES = {
    "emerald_gold": {
        "bg": "#090E0D",
        "bar": "#101917",
        "panel": "#0D1513",
        "sidebar": "#111A18",
        "card": "#121D1A",
        "accent": "#C9A24D",
        "title": "#E5C878",
        "sub": "#A8BDB6",
        "text": "#EAECEB",
        "ayah": "#FFF3C8",
        "tafsir": "#C6D4CF",
        "divider": "#243531",
        "mushaf_frame": "#F5EFE1",
    },
    "royal_blue": {
        "bg": "#060D1A",
        "bar": "#0C1930",
        "panel": "#091428",
        "sidebar": "#0D1B34",
        "card": "#122444",
        "accent": "#38BDF8",
        "title": "#F5D061",
        "sub": "#9CC2E6",
        "text": "#F1F5F9",
        "ayah": "#FEF08A",
        "tafsir": "#CBD5E1",
        "divider": "#1E3A5F",
        "mushaf_frame": "#F4EFE4",
    },
    "warm_walnut": {
        "bg": "#15100A",
        "bar": "#221910",
        "panel": "#1C150E",
        "sidebar": "#241B12",
        "card": "#2C2116",
        "accent": "#DFB356",
        "title": "#F6DC96",
        "sub": "#C8B69A",
        "text": "#F7F1E5",
        "ayah": "#FFF4D1",
        "tafsir": "#DECDB3",
        "divider": "#403121",
        "mushaf_frame": "#F7F0DF",
    },
    "oled_black": {
        "bg": "#000000",
        "bar": "#0B0B0B",
        "panel": "#060606",
        "sidebar": "#0A0A0A",
        "card": "#121212",
        "accent": "#FACC15",
        "title": "#FDE047",
        "sub": "#D4D4D4",
        "text": "#FFFFFF",
        "ayah": "#FEF9C3",
        "tafsir": "#E5E5E5",
        "divider": "#262626",
        "mushaf_frame": "#FAF6EC",
    },
}


def get_palette(theme_key):
    return SKIN_PALETTES.get(theme_key, SKIN_PALETTES["emerald_gold"])


def build_main_skin(theme_key="emerald_gold"):
    p = get_palette(theme_key)
    return f"""
    <screen name="QuranMizouhMainScreen" position="0,0" size="1920,1080" title="قارئ القرآن - mizouh المتميز" flags="wfNoBorder" backgroundColor="{p['bg']}">
        <!-- Header Bar -->
        <eLabel position="0,0" size="1920,88" backgroundColor="{p['bar']}" zPosition="-1" />
        <eLabel position="0,88" size="1920,3" backgroundColor="{p['accent']}" zPosition="0" />
        <widget name="header_title" position="64,20" size="860,48" font="Regular;34" foregroundColor="{p['title']}" backgroundColor="{p['bar']}" halign="right" transparent="1" />
        <widget name="riwaya_label" position="940,24" size="916,42" font="Regular;25" foregroundColor="{p['sub']}" backgroundColor="{p['bar']}" halign="left" transparent="1" />

        <!-- Right Sidebar: 31+ Reciters & All 114 Surahs -->
        <eLabel position="1352,106" size="504,840" backgroundColor="{p['sidebar']}" zPosition="-1" />
        <widget name="reciter_title" position="1372,118" size="464,36" font="Regular;24" foregroundColor="{p['accent']}" backgroundColor="{p['sidebar']}" halign="right" transparent="1" />
        <widget name="reciter_list" position="1372,160" size="464,260" itemHeight="40" font="Regular;22" foregroundColor="{p['text']}" backgroundColor="{p['sidebar']}" scrollbarMode="showOnDemand" />
        <eLabel position="1372,430" size="464,2" backgroundColor="{p['divider']}" />
        <widget name="surah_title" position="1372,442" size="464,36" font="Regular;24" foregroundColor="{p['accent']}" backgroundColor="{p['sidebar']}" halign="right" transparent="1" />
        <widget name="surah_list" position="1372,484" size="464,448" itemHeight="40" font="Regular;22" foregroundColor="{p['text']}" backgroundColor="{p['sidebar']}" scrollbarMode="showOnDemand" />

        <!-- Center Pure Real Printed Mushaf Page (576x824, ZERO overlay bars or boxes) -->
        <eLabel position="708,106" size="600,840" backgroundColor="{p['mushaf_frame']}" zPosition="-1" />
        <widget name="mushaf_page" position="720,114" size="576,824" alphatest="blend" zPosition="1" />

        <!-- Interactive Text Mushaf Fallback -->
        <widget name="mushaf_text" position="714,122" size="588,808" font="Regular;30" foregroundColor="{p['text']}" backgroundColor="{p['panel']}" halign="right" zPosition="4" />

        <!-- Audio-Only Sanctuary View -->
        <widget name="audio_only_status" position="80,260" size="1220,300" font="Regular;38" foregroundColor="{p['title']}" backgroundColor="{p['panel']}" halign="center" valign="center" transparent="1" zPosition="5" />

        <!-- Left Pane: Surah Header + Ayah Text + Companion Tafsir -->
        <eLabel position="64,106" size="618,840" backgroundColor="{p['panel']}" zPosition="-1" />
        <widget name="surah_banner" position="84,124" size="578,48" font="Regular;28" foregroundColor="{p['title']}" backgroundColor="{p['panel']}" halign="center" transparent="1" />
        <widget name="active_ayah_label" position="84,186" size="578,225" font="Regular;26" foregroundColor="{p['ayah']}" backgroundColor="{p['card']}" halign="right" valign="center" />
        <eLabel position="84,424" size="578,2" backgroundColor="{p['accent']}" />
        <widget name="tafsir_text" position="84,440" size="578,490" font="Regular;23" foregroundColor="{p['tafsir']}" backgroundColor="{p['panel']}" halign="right" transparent="1" />

        <!-- Bottom Remote Control Color Key Bar -->
        <eLabel position="0,964" size="1920,116" backgroundColor="{p['bar']}" zPosition="-1" />
        <eLabel position="0,962" size="1920,2" backgroundColor="{p['divider']}" />

        <eLabel position="1828,996" size="22,22" backgroundColor="#DC2626" />
        <widget name="key_red" position="1560,988" size="256,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <eLabel position="1520,996" size="22,22" backgroundColor="#16A34A" />
        <widget name="key_green" position="1226,988" size="282,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <eLabel position="1186,996" size="22,22" backgroundColor="#EAB308" />
        <widget name="key_yellow" position="880,988" size="294,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <eLabel position="840,996" size="22,22" backgroundColor="#2563EB" />
        <widget name="key_blue" position="560,988" size="268,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <widget name="status_bar" position="64,988" size="476,38" font="Regular;21" foregroundColor="{p['title']}" halign="left" transparent="1" />
    </screen>
    """


def build_menu_skin(theme_key="emerald_gold"):
    p = get_palette(theme_key)
    return f"""
    <screen name="QuranMizouhMenuScreen" position="center,center" size="1340,840" title="قائمة الإعدادات والسكينات والتحديث" flags="wfNoBorder" backgroundColor="{p['bg']}">
        <eLabel position="0,0" size="1340,92" backgroundColor="{p['bar']}" zPosition="-1" />
        <eLabel position="0,92" size="1340,3" backgroundColor="{p['accent']}" zPosition="0" />
        <widget name="menu_title" position="40,18" size="1260,42" font="Regular;32" foregroundColor="{p['title']}" backgroundColor="{p['bar']}" halign="center" transparent="1" />
        <widget name="repo_info" position="40,58" size="1260,30" font="Regular;20" foregroundColor="{p['sub']}" backgroundColor="{p['bar']}" halign="center" transparent="1" />

        <widget name="config" position="45,116" size="1250,560" itemHeight="50" font="Regular;25" foregroundColor="{p['text']}" backgroundColor="{p['panel']}" scrollbarMode="showOnDemand" />

        <eLabel position="45,690" size="1250,2" backgroundColor="{p['divider']}" />
        <widget name="update_status" position="45,704" size="1250,38" font="Regular;22" foregroundColor="{p['ayah']}" halign="center" transparent="1" />

        <!-- Menu Bottom Color Actions -->
        <eLabel position="0,754" size="1340,86" backgroundColor="{p['bar']}" zPosition="-1" />

        <eLabel position="1268,784" size="20,20" backgroundColor="#DC2626" />
        <widget name="btn_red" position="1060,776" size="198,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <eLabel position="1018,784" size="20,20" backgroundColor="#16A34A" />
        <widget name="btn_green" position="730,776" size="278,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <eLabel position="688,784" size="20,20" backgroundColor="#EAB308" />
        <widget name="btn_yellow" position="390,776" size="288,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <eLabel position="348,784" size="20,20" backgroundColor="#2563EB" />
        <widget name="btn_blue" position="40,776" size="298,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />
    </screen>
    """

QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/updater.py"
# -*- coding: utf-8 -*-
"""
GitHub OTA Auto-Updater for قارئ القرآن - mizouh المتميز
Checks version.json & reciters_feed.json hosted on the owner's GitHub repository,
guards flash free space (>= 5 MB), enforces strict 755 dir / 644 file permissions,
and pushes automatic mass updates to all customer Enigma2 receivers at once.
"""

import json
import os
import ssl
import tarfile
import time
import urllib.request

from .version import (
    PLUGIN_VERSION,
    VERSION_MANIFEST_URL,
    RECITERS_FEED_URL,
    PACKAGE_TAR_URL,
)

PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
CATALOG_FILE = os.path.join(PLUGIN_DIR, "reciters_feed.json")
MIN_FLASH_FREE_BYTES = 5 * 1024 * 1024  # 5 MB Flash Space Guard


def _parse_version(ver_str):
    parts = []
    for token in str(ver_str or "0").strip().lstrip("vV").split("."):
        try:
            parts.append(int(token))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def _ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _has_enough_flash_space(path="/", min_bytes=MIN_FLASH_FREE_BYTES):
    try:
        st = os.statvfs(path)
        free_bytes = st.f_bavail * st.f_frsize
        return free_bytes >= min_bytes, free_bytes
    except Exception:
        return True, min_bytes


def _apply_safe_permissions(target_dir):
    """Applies strict 755 for directories and 644 for files (never blanket chmod -R 755)."""
    try:
        os.chmod(target_dir, 0o755)
    except OSError:
        pass
    for root, dirs, files in os.walk(target_dir):
        try:
            os.chmod(root, 0o755)
        except OSError:
            pass
        for d_name in dirs:
            try:
                os.chmod(os.path.join(root, d_name), 0o755)
            except OSError:
                pass
        for f_name in files:
            try:
                os.chmod(os.path.join(root, f_name), 0o644)
            except OSError:
                pass


class PluginAutoUpdater:
    """Checks GitHub for plugin OTA updates and periodic reciter feed updates."""

    def _fetch_bytes(self, url, timeout=10):
        sep = "&" if "?" in url else "?"
        bust_url = f"{url}{sep}t={int(time.time())}"
        req = urllib.request.Request(
            bust_url,
            headers={"User-Agent": f"QuranMizouh-Updater/{PLUGIN_VERSION}"},
        )
        with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as resp:
            return resp.read()

    def check_for_update(self):
        """Returns remote manifest dict if remote GitHub version > local PLUGIN_VERSION, else None."""
        try:
            raw = self._fetch_bytes(VERSION_MANIFEST_URL, timeout=8)
            manifest = json.loads(raw.decode("utf-8"))
            remote_ver = str(manifest.get("version", "")).strip()
            if remote_ver and _parse_version(remote_ver) > _parse_version(PLUGIN_VERSION):
                return manifest
        except Exception:
            pass
        return None

    def sync_reciters_feed(self):
        """Silently downloads updated reciters_feed.json from GitHub if valid."""
        try:
            raw = self._fetch_bytes(RECITERS_FEED_URL, timeout=8)
            data = json.loads(raw.decode("utf-8"))
            reciters = data.get("reciters", [])
            if isinstance(reciters, list) and len(reciters) >= 5:
                tmp_path = CATALOG_FILE + ".part"
                with open(tmp_path, "w", encoding="utf-8") as f:
                    json.dump(data, f, ensure_ascii=False, indent=2)
                os.replace(tmp_path, CATALOG_FILE)
                try:
                    os.chmod(CATALOG_FILE, 0o644)
                except OSError:
                    pass
                return True
        except Exception:
            pass
        return False

    def download_and_install_update(self, manifest):
        """
        Verifies >= 5 MB free flash space on /, downloads tar.gz from GitHub into .part,
        extracts cleanly into QuranMizouh, and applies 755/644 permissions.
        """
        enough_space, free_bytes = _has_enough_flash_space("/")
        if not enough_space:
            free_mb = round(free_bytes / (1024.0 * 1024.0), 2)
            return False, f"المساحة الحرة على الفلاش ({free_mb} MB) أقل من 5 MB — تم إلغاء التحديث حمايةً للرسيفر."

        pkg_url = manifest.get("package_url") or PACKAGE_TAR_URL
        tmp_part = "/tmp/quran_mizouh_ota.tar.gz.part"
        tmp_tar = "/tmp/quran_mizouh_ota.tar.gz"
        try:
            data = self._fetch_bytes(pkg_url, timeout=25)
            if not data or len(data) < 2048:
                return False, "ملف التحديث المستلم من GitHub غير مكتمل."

            with open(tmp_part, "wb") as f:
                f.write(data)
            os.replace(tmp_part, tmp_tar)

            with tarfile.open(tmp_tar, "r:gz") as tar:
                members = [
                    m for m in tar.getmembers()
                    if m.name.startswith("usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/")
                    and ".." not in m.name
                ]
                tar.extractall(path="/", members=members)

            _apply_safe_permissions(PLUGIN_DIR)
            return True, "تم تثبيت التحديث الجديد بنجاح من GitHub!"
        except Exception as err:
            return False, f"فشل تحميل التحديث من GitHub: {err}"
        finally:
            for p in (tmp_part, tmp_tar):
                try:
                    if os.path.exists(p):
                        os.remove(p)
                except OSError:
                    pass

QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/version.py"
# -*- coding: utf-8 -*-
# الإصدار الرسمي وإعدادات مستودع التحديث التلقائي عبر GitHub

PLUGIN_VERSION = "3.3.0"
GITHUB_USER = "mizouh1984"
GITHUB_REPO = "quran_mizouh"
GITHUB_BRANCH = "main"
GITHUB_RAW_BASE = "https://raw.githubusercontent.com/mizouh1984/quran_mizouh/main"
VERSION_MANIFEST_URL = f"{GITHUB_RAW_BASE}/version.json"
RECITERS_FEED_URL = f"{GITHUB_RAW_BASE}/reciters_feed.json"
PACKAGE_TAR_URL = f"{GITHUB_RAW_BASE}/enigma2-plugin-extensions-quranmizouh.tar.gz"
INSTALLER_SH_URL = f"{GITHUB_RAW_BASE}/install_quran_mizouh_allinone.sh"

QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/quran_api.py"
# -*- coding: utf-8 -*-
import json
import os
import urllib.request
import urllib.parse

from .version import PLUGIN_VERSION

PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
CATALOG_FILE = os.path.join(PLUGIN_DIR, "reciters_feed.json")

SURAHS_LIST = [
    {"number": 1, "name_ar": "الفاتحة", "ayahs": 7, "page": 1},
    {"number": 2, "name_ar": "البقرة", "ayahs": 286, "page": 2},
    {"number": 3, "name_ar": "آل عمران", "ayahs": 200, "page": 50},
    {"number": 4, "name_ar": "النساء", "ayahs": 176, "page": 77},
    {"number": 5, "name_ar": "المائدة", "ayahs": 120, "page": 106},
    {"number": 6, "name_ar": "الأنعام", "ayahs": 165, "page": 128},
    {"number": 7, "name_ar": "الأعراف", "ayahs": 206, "page": 151},
    {"number": 8, "name_ar": "الأنفال", "ayahs": 75, "page": 177},
    {"number": 9, "name_ar": "التوبة", "ayahs": 129, "page": 187},
    {"number": 10, "name_ar": "يونس", "ayahs": 109, "page": 208},
    {"number": 11, "name_ar": "هود", "ayahs": 123, "page": 221},
    {"number": 12, "name_ar": "يوسف", "ayahs": 111, "page": 235},
    {"number": 13, "name_ar": "الرعد", "ayahs": 43, "page": 249},
    {"number": 14, "name_ar": "إبراهيم", "ayahs": 52, "page": 255},
    {"number": 15, "name_ar": "الحجر", "ayahs": 99, "page": 262},
    {"number": 16, "name_ar": "النحل", "ayahs": 128, "page": 267},
    {"number": 17, "name_ar": "الإسراء", "ayahs": 111, "page": 282},
    {"number": 18, "name_ar": "الكهف", "ayahs": 110, "page": 293},
    {"number": 19, "name_ar": "مريم", "ayahs": 98, "page": 305},
    {"number": 20, "name_ar": "طه", "ayahs": 135, "page": 312},
    {"number": 21, "name_ar": "الأنبياء", "ayahs": 112, "page": 322},
    {"number": 22, "name_ar": "الحج", "ayahs": 78, "page": 332},
    {"number": 23, "name_ar": "المؤمنون", "ayahs": 118, "page": 342},
    {"number": 24, "name_ar": "النور", "ayahs": 64, "page": 350},
    {"number": 25, "name_ar": "الفرقان", "ayahs": 77, "page": 359},
    {"number": 26, "name_ar": "الشعراء", "ayahs": 227, "page": 367},
    {"number": 27, "name_ar": "النمل", "ayahs": 93, "page": 377},
    {"number": 28, "name_ar": "القصص", "ayahs": 88, "page": 385},
    {"number": 29, "name_ar": "العنكبوت", "ayahs": 69, "page": 396},
    {"number": 30, "name_ar": "الروم", "ayahs": 60, "page": 404},
    {"number": 31, "name_ar": "لقمان", "ayahs": 34, "page": 411},
    {"number": 32, "name_ar": "السجدة", "ayahs": 30, "page": 415},
    {"number": 33, "name_ar": "الأحزاب", "ayahs": 73, "page": 418},
    {"number": 34, "name_ar": "سبأ", "ayahs": 54, "page": 428},
    {"number": 35, "name_ar": "فاطر", "ayahs": 45, "page": 434},
    {"number": 36, "name_ar": "يس", "ayahs": 83, "page": 440},
    {"number": 37, "name_ar": "الصافات", "ayahs": 182, "page": 446},
    {"number": 38, "name_ar": "ص", "ayahs": 88, "page": 453},
    {"number": 39, "name_ar": "الزمر", "ayahs": 75, "page": 458},
    {"number": 40, "name_ar": "غافر", "ayahs": 85, "page": 467},
    {"number": 41, "name_ar": "فصلت", "ayahs": 54, "page": 477},
    {"number": 42, "name_ar": "الشورى", "ayahs": 53, "page": 483},
    {"number": 43, "name_ar": "الزخرف", "ayahs": 89, "page": 489},
    {"number": 44, "name_ar": "الدخان", "ayahs": 59, "page": 496},
    {"number": 45, "name_ar": "الجاثية", "ayahs": 37, "page": 499},
    {"number": 46, "name_ar": "الأحقاف", "ayahs": 35, "page": 502},
    {"number": 47, "name_ar": "محمد", "ayahs": 38, "page": 507},
    {"number": 48, "name_ar": "الفتح", "ayahs": 29, "page": 511},
    {"number": 49, "name_ar": "الحجرات", "ayahs": 18, "page": 515},
    {"number": 50, "name_ar": "ق", "ayahs": 45, "page": 518},
    {"number": 51, "name_ar": "الذاريات", "ayahs": 60, "page": 520},
    {"number": 52, "name_ar": "الطور", "ayahs": 49, "page": 523},
    {"number": 53, "name_ar": "النجم", "ayahs": 62, "page": 526},
    {"number": 54, "name_ar": "القمر", "ayahs": 55, "page": 528},
    {"number": 55, "name_ar": "الرحمن", "ayahs": 78, "page": 531},
    {"number": 56, "name_ar": "الواقعة", "ayahs": 96, "page": 534},
    {"number": 57, "name_ar": "الحديد", "ayahs": 29, "page": 537},
    {"number": 58, "name_ar": "المجادلة", "ayahs": 22, "page": 542},
    {"number": 59, "name_ar": "الحشر", "ayahs": 24, "page": 545},
    {"number": 60, "name_ar": "الممتحنة", "ayahs": 13, "page": 549},
    {"number": 61, "name_ar": "الصف", "ayahs": 14, "page": 551},
    {"number": 62, "name_ar": "الجمعة", "ayahs": 11, "page": 553},
    {"number": 63, "name_ar": "المنافقون", "ayahs": 11, "page": 554},
    {"number": 64, "name_ar": "التغابن", "ayahs": 18, "page": 556},
    {"number": 65, "name_ar": "الطلاق", "ayahs": 12, "page": 558},
    {"number": 66, "name_ar": "التحريم", "ayahs": 12, "page": 560},
    {"number": 67, "name_ar": "الملك", "ayahs": 30, "page": 562},
    {"number": 68, "name_ar": "القلم", "ayahs": 52, "page": 564},
    {"number": 69, "name_ar": "الحاقة", "ayahs": 52, "page": 566},
    {"number": 70, "name_ar": "المعارج", "ayahs": 44, "page": 568},
    {"number": 71, "name_ar": "نوح", "ayahs": 28, "page": 570},
    {"number": 72, "name_ar": "الجن", "ayahs": 28, "page": 572},
    {"number": 73, "name_ar": "المزمل", "ayahs": 20, "page": 574},
    {"number": 74, "name_ar": "المدثر", "ayahs": 56, "page": 575},
    {"number": 75, "name_ar": "القيامة", "ayahs": 40, "page": 577},
    {"number": 76, "name_ar": "الإنسان", "ayahs": 31, "page": 578},
    {"number": 77, "name_ar": "المرسلات", "ayahs": 50, "page": 580},
    {"number": 78, "name_ar": "النبأ", "ayahs": 40, "page": 582},
    {"number": 79, "name_ar": "النازعات", "ayahs": 46, "page": 583},
    {"number": 80, "name_ar": "عبس", "ayahs": 42, "page": 585},
    {"number": 81, "name_ar": "التكوير", "ayahs": 29, "page": 586},
    {"number": 82, "name_ar": "الانفطار", "ayahs": 19, "page": 587},
    {"number": 83, "name_ar": "المطففين", "ayahs": 36, "page": 587},
    {"number": 84, "name_ar": "الانشقاق", "ayahs": 25, "page": 589},
    {"number": 85, "name_ar": "البروج", "ayahs": 22, "page": 590},
    {"number": 86, "name_ar": "الطارق", "ayahs": 17, "page": 591},
    {"number": 87, "name_ar": "الأعلى", "ayahs": 19, "page": 591},
    {"number": 88, "name_ar": "الغاشية", "ayahs": 26, "page": 592},
    {"number": 89, "name_ar": "الفجر", "ayahs": 30, "page": 593},
    {"number": 90, "name_ar": "البلد", "ayahs": 20, "page": 594},
    {"number": 91, "name_ar": "الشمس", "ayahs": 15, "page": 595},
    {"number": 92, "name_ar": "الليل", "ayahs": 21, "page": 595},
    {"number": 93, "name_ar": "الضحى", "ayahs": 11, "page": 596},
    {"number": 94, "name_ar": "الشرح", "ayahs": 8, "page": 596},
    {"number": 95, "name_ar": "التين", "ayahs": 8, "page": 597},
    {"number": 96, "name_ar": "العلق", "ayahs": 19, "page": 597},
    {"number": 97, "name_ar": "القدر", "ayahs": 5, "page": 598},
    {"number": 98, "name_ar": "البينة", "ayahs": 8, "page": 598},
    {"number": 99, "name_ar": "الزلزلة", "ayahs": 8, "page": 599},
    {"number": 100, "name_ar": "العاديات", "ayahs": 11, "page": 599},
    {"number": 101, "name_ar": "القارعة", "ayahs": 11, "page": 600},
    {"number": 102, "name_ar": "التكاثر", "ayahs": 8, "page": 600},
    {"number": 103, "name_ar": "العصر", "ayahs": 3, "page": 601},
    {"number": 104, "name_ar": "الهمزة", "ayahs": 9, "page": 601},
    {"number": 105, "name_ar": "الفيل", "ayahs": 5, "page": 601},
    {"number": 106, "name_ar": "قريش", "ayahs": 4, "page": 602},
    {"number": 107, "name_ar": "الماعون", "ayahs": 7, "page": 602},
    {"number": 108, "name_ar": "الكوثر", "ayahs": 3, "page": 602},
    {"number": 109, "name_ar": "الكافرون", "ayahs": 6, "page": 603},
    {"number": 110, "name_ar": "النصر", "ayahs": 3, "page": 603},
    {"number": 111, "name_ar": "المسد", "ayahs": 5, "page": 603},
    {"number": 112, "name_ar": "الإخلاص", "ayahs": 4, "page": 604},
    {"number": 113, "name_ar": "الفلق", "ayahs": 5, "page": 604},
    {"number": 114, "name_ar": "الناس", "ayahs": 6, "page": 604},
]

# Built-in fallback reciters (guarantees BOTH Hafs & Warsh always load reliably!)
BUILTIN_RECITERS = [
    {"id": "afasy-hafs", "name_ar": "مشاري راشد العفاسي", "name_en": "Mishary Rashid Alafasy", "riwaya": "hafs", "server": "https://server8.mp3quran.net/afs/", "quran_com_id": 7},
    {"id": "ajmy-hafs", "name_ar": "أحمد بن علي العجمي", "name_en": "Ahmad bin Ali Al-Ajmy", "riwaya": "hafs", "server": "https://server10.mp3quran.net/ajm/", "quran_com_id": 0},
    {"id": "abdulbasit-hafs", "name_ar": "عبد الباسط عبد الصمد (مرتل)", "name_en": "Abdul Basit (Murattal)", "riwaya": "hafs", "server": "https://server7.mp3quran.net/basit/", "quran_com_id": 2},
    {"id": "abdulbasit-mujawwad", "name_ar": "عبد الباسط عبد الصمد (مجود)", "name_en": "Abdul Basit (Mujawwad)", "riwaya": "hafs", "server": "https://server7.mp3quran.net/basit/Almusshaf-Al-Mojawwad/", "quran_com_id": 1},
    {"id": "husary-hafs", "name_ar": "محمود خليل الحصري (مرتل)", "name_en": "Al-Husary (Murattal)", "riwaya": "hafs", "server": "https://server13.mp3quran.net/husr/", "quran_com_id": 6},
    {"id": "husary-muallim", "name_ar": "محمود خليل الحصري (المعلم)", "name_en": "Al-Husary (Muallim)", "riwaya": "hafs", "server": "https://server13.mp3quran.net/husr/", "quran_com_id": 12},
    {"id": "minshawi-hafs", "name_ar": "محمد صديق المنشاوي (مرتل)", "name_en": "Al-Minshawi (Murattal)", "riwaya": "hafs", "server": "https://server10.mp3quran.net/minsh/", "quran_com_id": 9},
    {"id": "minshawi-mujawwad", "name_ar": "محمد صديق المنشاوي (مجود)", "name_en": "Al-Minshawi (Mujawwad)", "riwaya": "hafs", "server": "https://server10.mp3quran.net/minsh/Almusshaf-Al-Mojawwad/", "quran_com_id": 8},
    {"id": "sudais-hafs", "name_ar": "عبد الرحمن السديس", "name_en": "Abdul Rahman Al-Sudais", "riwaya": "hafs", "server": "https://server11.mp3quran.net/sds/", "quran_com_id": 3},
    {"id": "shuraim-hafs", "name_ar": "سعود الشريم", "name_en": "Saud Al-Shuraim", "riwaya": "hafs", "server": "https://server7.mp3quran.net/shur/", "quran_com_id": 10},
    {"id": "shatri-hafs", "name_ar": "أبو بكر الشاطري", "name_en": "Abu Bakr Al-Shatri", "riwaya": "hafs", "server": "https://server11.mp3quran.net/shatri/", "quran_com_id": 4},
    {"id": "rifai-hafs", "name_ar": "هاني الرفاعي", "name_en": "Hani Ar-Rifai", "riwaya": "hafs", "server": "https://server8.mp3quran.net/hani/", "quran_com_id": 5},
    {"id": "maher-hafs", "name_ar": "ماهر المعيقلي", "name_en": "Maher Al-Muaiqly", "riwaya": "hafs", "server": "https://server12.mp3quran.net/maher/", "quran_com_id": 0},
    {"id": "ghamdi-hafs", "name_ar": "سعد الغامدي", "name_en": "Saad Al-Ghamdi", "riwaya": "hafs", "server": "https://server7.mp3quran.net/s_gmd/", "quran_com_id": 0},
    {"id": "dosari-hafs", "name_ar": "ياسر الدوسري", "name_en": "Yasser Al-Dosari", "riwaya": "hafs", "server": "https://server11.mp3quran.net/yasser/", "quran_com_id": 0},
    {"id": "qatami-hafs", "name_ar": "ناصر القطامي", "name_en": "Nasser Al-Qatami", "riwaya": "hafs", "server": "https://server6.mp3quran.net/qtm/", "quran_com_id": 0},
    {"id": "fares-hafs", "name_ar": "فارس عباد", "name_en": "Fares Abbad", "riwaya": "hafs", "server": "https://server8.mp3quran.net/frs_a/", "quran_com_id": 0},
    {"id": "idris-hafs", "name_ar": "إدريس أبكر", "name_en": "Idris Abkar", "riwaya": "hafs", "server": "https://server6.mp3quran.net/abkr/", "quran_com_id": 0},
    {"id": "ayyub-hafs", "name_ar": "محمد أيوب", "name_en": "Muhammad Ayyub", "riwaya": "hafs", "server": "https://server8.mp3quran.net/ayyub/", "quran_com_id": 0},
    {"id": "hudhaify-hafs", "name_ar": "علي الحذيفي", "name_en": "Ali Al-Hudhaify", "riwaya": "hafs", "server": "https://server9.mp3quran.net/hthfi/", "quran_com_id": 0},
    {"id": "jaleel-hafs", "name_ar": "خالد الجليل", "name_en": "Khalid Al-Jaleel", "riwaya": "hafs", "server": "https://server10.mp3quran.net/jleel/", "quran_com_id": 0},
    {"id": "qazabri-warsh", "name_ar": "عمر القزابري", "name_en": "Omar Al-Qazabri", "riwaya": "warsh", "server": "https://server9.mp3quran.net/omar_warsh/", "quran_com_id": 0},
    {"id": "yassin-warsh", "name_ar": "ياسين الجزائري", "name_en": "Yassin Al-Jazaery", "riwaya": "warsh", "server": "https://server11.mp3quran.net/qari/", "quran_com_id": 0},
    {"id": "kouchi-warsh", "name_ar": "العيون الكوشي", "name_en": "Laayoun El-Kouchi", "riwaya": "warsh", "server": "https://server11.mp3quran.net/koshi/", "quran_com_id": 0},
    {"id": "abdulbasit-warsh", "name_ar": "عبد الباسط عبد الصمد (ورش)", "name_en": "Abdul Basit (Warsh)", "riwaya": "warsh", "server": "https://server10.mp3quran.net/basit_warsh/", "quran_com_id": 0},
    {"id": "husary-warsh", "name_ar": "محمود خليل الحصري (ورش)", "name_en": "Al-Husary (Warsh)", "riwaya": "warsh", "server": "https://server13.mp3quran.net/husr/Rewayat-Warsh-A-n-Nafi/", "quran_com_id": 0},
    {"id": "belalya-warsh", "name_ar": "رشيد بلعالية", "name_en": "Rachid Belalya", "riwaya": "warsh", "server": "https://server6.mp3quran.net/bl3/Rewayat-Warsh-A-n-Nafi/", "quran_com_id": 0},
    {"id": "ibrahim-dosari-warsh", "name_ar": "إبراهيم الدوسري (ورش)", "name_en": "Ibrahim Al-Dosari (Warsh)", "riwaya": "warsh", "server": "https://server10.mp3quran.net/ibrahim_dosri/Rewayat-Warsh-A-n-Nafi/", "quran_com_id": 0},
    {"id": "hsain-warsh", "name_ar": "عبد الحميد احساين (ورش)", "name_en": "Abdelhamid Hssain (Warsh)", "riwaya": "warsh", "server": "https://server12.mp3quran.net/hsn/", "quran_com_id": 0},
    {"id": "daif-warsh", "name_ar": "محمد السيد ضيف (ورش)", "name_en": "Mohamed Sayed Daif (Warsh)", "riwaya": "warsh", "server": "https://server11.mp3quran.net/m_daif/", "quran_com_id": 0},
    {"id": "souilass-warsh", "name_ar": "يونس اسويلص (ورش)", "name_en": "Younes Souilass (Warsh)", "riwaya": "warsh", "server": "https://server16.mp3quran.net/souilass/Rewayat-Warsh-A-n-Nafi/", "quran_com_id": 0},
]


class QuranAPI:
    def __init__(self):
        self.reciters = []
        self._ref_ratios_cache = {}
        self._timings_cache = {}
        self._surah_mem_cache = {}
        self._surah_mem_order = []
        self.reload_catalog()

    def reload_catalog(self):
        loaded = []
        if os.path.exists(CATALOG_FILE):
            try:
                with open(CATALOG_FILE, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    loaded = data.get("reciters", [])
            except Exception:
                loaded = []

        has_hafs = any(r.get("riwaya") == "hafs" for r in loaded)
        has_warsh = any(r.get("riwaya") == "warsh" for r in loaded)
        if has_hafs and has_warsh:
            self.reciters = loaded
        else:
            existing_ids = {r.get("id") for r in loaded}
            merged = list(loaded)
            for item in BUILTIN_RECITERS:
                if item["id"] not in existing_ids:
                    merged.append(item)
            self.reciters = merged

    def find_reciter_by_id(self, reciter_id):
        if not reciter_id:
            return None
        for r in self.reciters:
            if r.get("id") == reciter_id:
                return r
        return None

    def get_reciters_by_riwaya(self, riwaya="hafs"):
        target = str(riwaya or "hafs").strip().lower()
        return [r for r in self.reciters if str(r.get("riwaya", "")).strip().lower() == target]

    def build_audio_url(self, reciter, surah_number):
        base = reciter["server"].rstrip("/")
        return f"{base}/{surah_number:03d}.mp3"

    def get_cached_surah_mem(self, surah_number, tafsir_edition="ar.muyassar"):
        return self._surah_mem_cache.get((int(surah_number), str(tafsir_edition)))

    def _put_surah_mem(self, surah_number, tafsir_edition, ayahs, tafsirs):
        key = (int(surah_number), str(tafsir_edition))
        if key not in self._surah_mem_cache:
            self._surah_mem_order.append(key)
            if len(self._surah_mem_order) > 24:
                oldest = self._surah_mem_order.pop(0)
                self._surah_mem_cache.pop(oldest, None)
        self._surah_mem_cache[key] = (ayahs, tafsirs)

    def fetch_continuous_surah_stream(self, reciter, surah_number):
        """Returns (continuous_mp3_url, ayah_timings) with RAM caching for instant repeat switches."""
        qid = reciter.get("quran_com_id", 0)
        if not qid:
            return None, []
        cache_key = (int(qid), int(surah_number))
        if cache_key in self._timings_cache:
            return self._timings_cache[cache_key]
        url = f"https://api.quran.com/api/v4/chapter_recitations/{qid}/{surah_number}?segments=true"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
                af = payload.get("audio_file", {})
                audio_url = af.get("audio_url")
                raw_ts = af.get("timestamps", [])
                timings = []
                for ts in raw_ts:
                    parts = str(ts.get("verse_key", "0:0")).split(":")
                    if len(parts) != 2:
                        continue
                    timings.append({
                        "ayah": int(parts[1]),
                        "start": float(ts.get("timestamp_from", 0)) / 1000.0,
                        "end": float(ts.get("timestamp_to", 0)) / 1000.0,
                    })
                if audio_url and timings:
                    self._timings_cache[cache_key] = (audio_url, timings)
                    return audio_url, timings
        except Exception:
            pass
        return None, []

    def fetch_reference_ratios(self, surah_number):
        """
        Fetches normalized [0.0..1.0] studio Murattal timing proportions for any Surah so non-segmented
        reciters (Ahmad Al-Ajmy, Maher, Warsh reciters, etc.) turn Mushaf pages right on time!
        """
        if surah_number in self._ref_ratios_cache:
            return self._ref_ratios_cache[surah_number]
        url = f"https://api.quran.com/api/v4/chapter_recitations/7/{surah_number}?segments=true"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
                raw_ts = payload.get("audio_file", {}).get("timestamps", [])
                if not raw_ts:
                    return []
                total_ms = float(raw_ts[-1].get("timestamp_to", 0))
                if total_ms <= 0:
                    return []
                ratios = []
                for ts in raw_ts:
                    parts = str(ts.get("verse_key", "0:0")).split(":")
                    if len(parts) != 2:
                        continue
                    ratios.append((
                        int(parts[1]),
                        float(ts.get("timestamp_from", 0)) / total_ms,
                        float(ts.get("timestamp_to", 0)) / total_ms,
                    ))
                self._ref_ratios_cache[surah_number] = ratios
                return ratios
        except Exception:
            return []

    def fetch_surah_and_tafsir(self, surah_number, tafsir_edition="ar.muyassar", offline_mgr=None):
        mem = self.get_cached_surah_mem(surah_number, tafsir_edition)
        if mem is not None:
            return mem

        if offline_mgr:
            cached = offline_mgr.load_surah_json(surah_number, tafsir_edition)
            if cached:
                self._put_surah_mem(surah_number, tafsir_edition, cached["ayahs"], cached["tafsirs"])
                return cached["ayahs"], cached["tafsirs"]

        url = f"https://api.alquran.cloud/v1/surah/{surah_number}/editions/quran-uthmani,{tafsir_edition}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
            with urllib.request.urlopen(req, timeout=7) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
                q_ayahs = [{"num": a["numberInSurah"], "text": a["text"], "page": a.get("page", 1)} for a in payload["data"][0]["ayahs"]]
                t_ayahs = [{"num": a["numberInSurah"], "text": a["text"]} for a in payload["data"][1]["ayahs"]]
                self._put_surah_mem(surah_number, tafsir_edition, q_ayahs, t_ayahs)
                if offline_mgr:
                    offline_mgr.save_surah_json(surah_number, tafsir_edition, q_ayahs, t_ayahs)
                return q_ayahs, t_ayahs
        except Exception:
            fallback_page = SURAHS_LIST[max(0, min(113, int(surah_number) - 1))].get("page", 1)
            return [{"num": 1, "text": "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ", "page": fallback_page}], [{"num": 1, "text": "تحقق من اتصال الإنترنت أو شغّل السور المحفوظة محلياً."}]

    def search_verses(self, keyword):
        encoded = urllib.parse.quote(keyword)
        url = f"https://api.alquran.cloud/v1/search/{encoded}/all/ar"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
            with urllib.request.urlopen(req, timeout=8) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
                matches = payload.get("data", {}).get("matches", [])
                return [
                    {
                        "surah": m["surah"]["number"],
                        "surah_name": m["surah"]["name"],
                        "ayah": m["numberInSurah"],
                        "text": m["text"],
                    }
                    for m in matches[:40]
                ]
        except Exception:
            return []

QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/offline_manager.py"
# -*- coding: utf-8 -*-
import json
import os
import threading
import urllib.request

from .version import PLUGIN_VERSION


class OfflineManager:
    """
    Manages local HDD/USB storage for offline Quran audio, deduplicated Mushaf page images, and Tafsir JSON.
    Uses atomic .part temporary files + size validation + os.replace() to prevent corrupted/truncated files.
    """

    def __init__(self, base_dir="/media/hdd/QuranMizouh"):
        self.base_dir = base_dir
        self.audio_dir = os.path.join(base_dir, "audio")
        self.text_dir = os.path.join(base_dir, "text")
        self.pages_dir = os.path.join(base_dir, "mushaf_pages")
        self._page_lock = threading.Lock()
        self._inflight_pages = set()
        self._ensure_dirs()

    def _ensure_dirs(self):
        for path in (self.base_dir, self.audio_dir, self.text_dir, self.pages_dir):
            try:
                os.makedirs(path, exist_ok=True)
            except OSError:
                pass

    def _cleanup_part(self, part_path):
        try:
            if part_path and os.path.exists(part_path):
                os.remove(part_path)
        except OSError:
            pass

    def get_cached_mushaf_page(self, page_number):
        target = os.path.join(self.pages_dir, f"page_{page_number:03d}.jpg")
        if os.path.exists(target) and os.path.getsize(target) > 2048:
            return target
        return None

    def get_or_download_mushaf_page(self, page_number):
        self._ensure_dirs()
        cached = self.get_cached_mushaf_page(page_number)
        if cached:
            return cached

        with self._page_lock:
            if page_number in self._inflight_pages:
                return None
            self._inflight_pages.add(page_number)

        target = os.path.join(self.pages_dir, f"page_{page_number:03d}.jpg")
        tmp = f"{target}.part"
        mirrors = [
            f"https://www.mp3quran.net/api/quran_pages_arabic/{page_number:03d}.jpg",
            f"https://quran.ksu.edu.sa/png_big/{page_number}.png",
        ]
        try:
            for url in mirrors:
                try:
                    req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
                    with urllib.request.urlopen(req, timeout=7) as resp, open(tmp, "wb") as out:
                        out.write(resp.read())
                    if os.path.exists(tmp) and os.path.getsize(tmp) > 2048:
                        os.replace(tmp, target)
                        return target
                    self._cleanup_part(tmp)
                except Exception:
                    self._cleanup_part(tmp)
                    continue
            return None
        finally:
            with self._page_lock:
                self._inflight_pages.discard(page_number)

    def get_local_mp3(self, reciter_id, surah_number):
        return os.path.join(self.audio_dir, f"{reciter_id}_{surah_number:03d}.mp3")

    def download_surah(self, reciter_id, surah_number, url):
        """Safely downloads audio MP3 into a .part file, validates size, and atomically replaces target."""
        self._ensure_dirs()
        target = self.get_local_mp3(reciter_id, surah_number)
        tmp = f"{target}.part"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
            with urllib.request.urlopen(req, timeout=45) as resp:
                expected_len = int(resp.headers.get("Content-Length") or 0)
                downloaded = 0
                with open(tmp, "wb") as out:
                    while True:
                        chunk = resp.read(65536)
                        if not chunk:
                            break
                        out.write(chunk)
                        downloaded += len(chunk)

            # Verify downloaded file is valid and complete before promoting
            actual_size = os.path.getsize(tmp) if os.path.exists(tmp) else 0
            if actual_size < 8192:
                self._cleanup_part(tmp)
                return None
            if expected_len > 0 and actual_size < int(expected_len * 0.98):
                self._cleanup_part(tmp)
                return None

            os.replace(tmp, target)
            return target
        except Exception:
            self._cleanup_part(tmp)
            return None

    def save_surah_json(self, surah_number, tafsir_edition, ayahs, tafsirs):
        self._ensure_dirs()
        path = os.path.join(self.text_dir, f"surah_{surah_number:03d}_{tafsir_edition}.json")
        tmp = f"{path}.part"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"ayahs": ayahs, "tafsirs": tafsirs}, f, ensure_ascii=False)
            os.replace(tmp, path)
        except OSError:
            self._cleanup_part(tmp)

    def load_surah_json(self, surah_number, tafsir_edition):
        path = os.path.join(self.text_dir, f"surah_{surah_number:03d}_{tafsir_edition}.json")
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return None
        return None

QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/locale_loader.py"
# -*- coding: utf-8 -*-
import json
import os

PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))


class LocaleLoader:
    def __init__(self, lang="ar"):
        self.lang = lang
        path = os.path.join(PLUGIN_DIR, "locale", "translations.json")
        self.strings = {}
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
                self.strings = data.get(lang, data.get("ar", {}))

    def t(self, key):
        return self.strings.get(key, key)

QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/reciters_feed.json"
{
  "plugin": "QuranMizouh",
  "version": "3.3.0",
  "updated_at": "2026-11-27",
  "reciters_count": 31,
  "reciters": [
    {
      "id": "afasy-hafs",
      "name_ar": "مشاري راشد العفاسي",
      "name_en": "Mishary Rashid Alafasy",
      "name_fr": "Mishary Rashid Alafasy",
      "riwaya": "hafs",
      "country": "الكويت",
      "server": "https://server8.mp3quran.net/afs/",
      "quran_com_id": 7,
      "bitrate": "128 kbps"
    },
    {
      "id": "ajmy-hafs",
      "name_ar": "أحمد بن علي العجمي",
      "name_en": "Ahmad bin Ali Al-Ajmy",
      "name_fr": "Ahmad bin Ali Al-Ajmy",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server10.mp3quran.net/ajm/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "abdulbasit-hafs",
      "name_ar": "عبد الباسط عبد الصمد (مرتل)",
      "name_en": "Abdul Basit (Murattal)",
      "name_fr": "Abdelbasset (Murattal)",
      "riwaya": "hafs",
      "country": "مصر",
      "server": "https://server7.mp3quran.net/basit/",
      "quran_com_id": 2,
      "bitrate": "128 kbps"
    },
    {
      "id": "abdulbasit-mujawwad",
      "name_ar": "عبد الباسط عبد الصمد (مجود)",
      "name_en": "Abdul Basit (Mujawwad)",
      "name_fr": "Abdelbasset (Mujawwad)",
      "riwaya": "hafs",
      "country": "مصر",
      "server": "https://server7.mp3quran.net/basit/Almusshaf-Al-Mojawwad/",
      "quran_com_id": 1,
      "bitrate": "128 kbps"
    },
    {
      "id": "husary-hafs",
      "name_ar": "محمود خليل الحصري (مرتل)",
      "name_en": "Al-Husary (Murattal)",
      "name_fr": "Al-Hussary (Murattal)",
      "riwaya": "hafs",
      "country": "مصر",
      "server": "https://server13.mp3quran.net/husr/",
      "quran_com_id": 6,
      "bitrate": "128 kbps"
    },
    {
      "id": "husary-muallim",
      "name_ar": "محمود خليل الحصري (المعلم)",
      "name_en": "Al-Husary (Muallim)",
      "name_fr": "Al-Hussary (Muallim)",
      "riwaya": "hafs",
      "country": "مصر",
      "server": "https://server13.mp3quran.net/husr/",
      "quran_com_id": 12,
      "bitrate": "128 kbps"
    },
    {
      "id": "minshawi-hafs",
      "name_ar": "محمد صديق المنشاوي (مرتل)",
      "name_en": "Al-Minshawi (Murattal)",
      "name_fr": "El-Minshawi (Murattal)",
      "riwaya": "hafs",
      "country": "مصر",
      "server": "https://server10.mp3quran.net/minsh/",
      "quran_com_id": 9,
      "bitrate": "128 kbps"
    },
    {
      "id": "minshawi-mujawwad",
      "name_ar": "محمد صديق المنشاوي (مجود)",
      "name_en": "Al-Minshawi (Mujawwad)",
      "name_fr": "El-Minshawi (Mujawwad)",
      "riwaya": "hafs",
      "country": "مصر",
      "server": "https://server10.mp3quran.net/minsh/Almusshaf-Al-Mojawwad/",
      "quran_com_id": 8,
      "bitrate": "128 kbps"
    },
    {
      "id": "sudais-hafs",
      "name_ar": "عبد الرحمن السديس",
      "name_en": "Abdul Rahman Al-Sudais",
      "name_fr": "Abderrahmane Al-Soudais",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server11.mp3quran.net/sds/",
      "quran_com_id": 3,
      "bitrate": "128 kbps"
    },
    {
      "id": "shuraim-hafs",
      "name_ar": "سعود الشريم",
      "name_en": "Saud Al-Shuraim",
      "name_fr": "Saoud Al-Shuraim",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server7.mp3quran.net/shur/",
      "quran_com_id": 10,
      "bitrate": "128 kbps"
    },
    {
      "id": "shatri-hafs",
      "name_ar": "أبو بكر الشاطري",
      "name_en": "Abu Bakr Al-Shatri",
      "name_fr": "Abou Bakr Al-Shatri",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server11.mp3quran.net/shatri/",
      "quran_com_id": 4,
      "bitrate": "128 kbps"
    },
    {
      "id": "rifai-hafs",
      "name_ar": "هاني الرفاعي",
      "name_en": "Hani Ar-Rifai",
      "name_fr": "Hani Ar-Rifai",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server8.mp3quran.net/hani/",
      "quran_com_id": 5,
      "bitrate": "128 kbps"
    },
    {
      "id": "maher-hafs",
      "name_ar": "ماهر المعيقلي",
      "name_en": "Maher Al-Muaiqly",
      "name_fr": "Maher Al-Muaiqly",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server12.mp3quran.net/maher/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "ghamdi-hafs",
      "name_ar": "سعد الغامدي",
      "name_en": "Saad Al-Ghamdi",
      "name_fr": "Saad Al-Ghamdi",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server7.mp3quran.net/s_gmd/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "dosari-hafs",
      "name_ar": "ياسر الدوسري",
      "name_en": "Yasser Al-Dosari",
      "name_fr": "Yasser Al-Dosari",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server11.mp3quran.net/yasser/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "qatami-hafs",
      "name_ar": "ناصر القطامي",
      "name_en": "Nasser Al-Qatami",
      "name_fr": "Nasser Al-Qatami",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server6.mp3quran.net/qtm/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "fares-hafs",
      "name_ar": "فارس عباد",
      "name_en": "Fares Abbad",
      "name_fr": "Fares Abbad",
      "riwaya": "hafs",
      "country": "اليمن",
      "server": "https://server8.mp3quran.net/frs_a/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "idris-hafs",
      "name_ar": "إدريس أبكر",
      "name_en": "Idris Abkar",
      "name_fr": "Idris Abkar",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server6.mp3quran.net/abkr/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "ayyub-hafs",
      "name_ar": "محمد أيوب",
      "name_en": "Muhammad Ayyub",
      "name_fr": "Muhammad Ayyub",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server8.mp3quran.net/ayyub/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "hudhaify-hafs",
      "name_ar": "علي الحذيفي",
      "name_en": "Ali Al-Hudhaify",
      "name_fr": "Ali Al-Houdhaifi",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server9.mp3quran.net/hthfi/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "jaleel-hafs",
      "name_ar": "خالد الجليل",
      "name_en": "Khalid Al-Jaleel",
      "name_fr": "Khalid Al-Jaleel",
      "riwaya": "hafs",
      "country": "السعودية",
      "server": "https://server10.mp3quran.net/jleel/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "qazabri-warsh",
      "name_ar": "عمر القزابري",
      "name_en": "Omar Al-Qazabri",
      "name_fr": "Omar Al-Qazabri",
      "riwaya": "warsh",
      "country": "المغرب",
      "server": "https://server9.mp3quran.net/omar_warsh/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "yassin-warsh",
      "name_ar": "ياسين الجزائري",
      "name_en": "Yassin Al-Jazaery",
      "name_fr": "Yassin Al-Jazaery",
      "riwaya": "warsh",
      "country": "الجزائر",
      "server": "https://server11.mp3quran.net/qari/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "kouchi-warsh",
      "name_ar": "العيون الكوشي",
      "name_en": "Laayoun El-Kouchi",
      "name_fr": "Laayoun El-Kouchi",
      "riwaya": "warsh",
      "country": "المغرب",
      "server": "https://server11.mp3quran.net/koshi/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "abdulbasit-warsh",
      "name_ar": "عبد الباسط عبد الصمد (ورش)",
      "name_en": "Abdul Basit (Warsh)",
      "name_fr": "Abdelbasset (Warsh)",
      "riwaya": "warsh",
      "country": "مصر",
      "server": "https://server10.mp3quran.net/basit_warsh/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "husary-warsh",
      "name_ar": "محمود خليل الحصري (ورش)",
      "name_en": "Al-Husary (Warsh)",
      "name_fr": "Al-Hussary (Warsh)",
      "riwaya": "warsh",
      "country": "مصر",
      "server": "https://server13.mp3quran.net/husr/Rewayat-Warsh-A-n-Nafi/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "belalya-warsh",
      "name_ar": "رشيد بلعالية",
      "name_en": "Rachid Belalya",
      "name_fr": "Rachid Belalya",
      "riwaya": "warsh",
      "country": "الجزائر",
      "server": "https://server6.mp3quran.net/bl3/Rewayat-Warsh-A-n-Nafi/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "ibrahim-dosari-warsh",
      "name_ar": "إبراهيم الدوسري (ورش)",
      "name_en": "Ibrahim Al-Dosari (Warsh)",
      "name_fr": "Ibrahim Al-Dosari (Warsh)",
      "riwaya": "warsh",
      "country": "السعودية",
      "server": "https://server10.mp3quran.net/ibrahim_dosri/Rewayat-Warsh-A-n-Nafi/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "hsain-warsh",
      "name_ar": "عبد الحميد احساين (ورش)",
      "name_en": "Abdelhamid Hssain (Warsh)",
      "name_fr": "Abdelhamid Hssain (Warsh)",
      "riwaya": "warsh",
      "country": "المغرب",
      "server": "https://server12.mp3quran.net/hsn/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "daif-warsh",
      "name_ar": "محمد السيد ضيف (ورش)",
      "name_en": "Mohamed Sayed Daif (Warsh)",
      "name_fr": "Mohamed Sayed Daif (Warsh)",
      "riwaya": "warsh",
      "country": "مصر",
      "server": "https://server11.mp3quran.net/m_daif/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    },
    {
      "id": "souilass-warsh",
      "name_ar": "يونس اسويلص (ورش)",
      "name_en": "Younes Souilass (Warsh)",
      "name_fr": "Younes Souilass (Warsh)",
      "riwaya": "warsh",
      "country": "المغرب",
      "server": "https://server16.mp3quran.net/souilass/Rewayat-Warsh-A-n-Nafi/",
      "quran_com_id": 0,
      "bitrate": "128 kbps"
    }
  ]
}
QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/locale/translations.json"
{
  "ar": {
    "reciters": "القراء",
    "surahs": "سور القرآن الكريم (114)",
    "key_red": "إيقاف كلي",
    "key_green": "تشغيل / إيقاف مؤقت",
    "key_yellow": "إظهار / إخفاء المصحف",
    "key_blue": "تبديل حفص / ورش"
  },
  "en": {
    "reciters": "Reciters",
    "surahs": "Holy Quran Surahs (114)",
    "key_red": "Stop",
    "key_green": "Play / Pause",
    "key_yellow": "Show / Hide Mushaf",
    "key_blue": "Switch Hafs / Warsh"
  },
  "fr": {
    "reciters": "Récitateurs",
    "surahs": "Sourates du Coran (114)",
    "key_red": "Arrêter",
    "key_green": "Lecture / Pause",
    "key_yellow": "Afficher / Masquer Mushaf",
    "key_blue": "Changer Hafs / Warsh"
  }
}
QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/__init__.py"
# -*- coding: utf-8 -*-
# قارئ القرآن - mizouh المتميز (Enigma2 Plugin)
# Compatible with Python 3 (OpenATV 7.x, OpenPLi 9.x, OpenBH, Egami, VTi, DreamOS)

from .version import PLUGIN_VERSION, GITHUB_RAW_BASE

__version__ = PLUGIN_VERSION
__author__ = "mizouh"
__plugin_name__ = "قارئ القرآن - mizouh المتميز"

QURAN_MIZOUH_EOF

# Official Plugin Icon (plugin.png)
cat << 'QURAN_ICON_B64' > /tmp/quran_mizouh_icon.b64
iVBORw0KGgoAAAANSUhEUgAAAPAAAABgCAYAAAAjM//RAAAQAElEQVR4AZS9B7wdVfX2/6w5t6T3
XkkIgUBClxJ6FUWRIiqWn4q994ItWH8IYgNEBaRJL9KRToAkQAgkhJCENNJ7Lze3nfl/nz3n3HuD
vu/n/87daz9rPWut3c7smTlzImb6fzw2v/6bEwr5xQkbZ/1y0vpZP5+0/rV2WTvjZ5Pa5SeT1k7/
yaTVSX4EIi9Zfjhp5UvINMv3J62c9v1Jy6dYvgtW5PlvT1palcnfnLS0Ikue+fqkjrLoqa9OKuTL
4JcnLXiiKl+ctOAxy+cnzX8MebQqn500/9HPTpr7sOVCEHnwwklzHvxUIfeD9//PpDnIbMu/Pj5p
dpt8dNKse6rykUmz7vrIpNeSfGjSa3cUMuOOD05Kcht427mTZiDTbzl30vRbzi7kZvDmsya9VJUb
3zfpJWRaVa5/76RpSc6YNOV65LqqnD5pyjWnT3r+mlML+RuITP7byZOSXA1efeKkZyxXgVcdP+kZ
yxXHT3rqimPb5U8TJz2FPJHkqElP/KGQx/5wxKTHLq/K4ZMeu+zwSY8mORREfttBLkNPUsQ49rHL
yWmTIyY9QVtP0GYhRR9P/eko+q5KMQ6P5ZkrJk4q5FgQuaqQyYy/Ta4+ftLkijzPHJP87cRJz7fJ
yazPO+VUuFMnTbuuKqejI9cX8hJYyBl8Bu0y/cb3TkpyM9gm75s045Z3yllwZ0167baqnI2O3HH2
pFl7yLmcK+dOmn1XR/ngpNn3FDIHnHvv+Sf8P27FFP7/awNvnvubE5751zeun/Hv7y0pq/xsGWnN
49lculh5XKwA0XPlF0dgywKXZxfn6IEvxRGbo+fKLk42eTn+HD7QVeHzXJW8uFjoiqKdnFzrcg66
46wLXfQlt4MeiHUxFvcV8Ert0y56jqQct0P7Ob5AlwU9By2BL3G20XP3gS7adxs57VuXefQcPty2
BV3Mx3FBm0p5cXGO7jEl2206Bl+gy4LudtxXVNuBdzs5Prkv+Jz2LUJPkuy4OIgVulIs/aFHRRe+
HN1iXbRlPYcPt4PPvPs2H+TKPJJbZ46yYItxB5ylIyfzxOSI9UKUzoucPEtHLojzeljE2gjbfQbt
uE9LRy7xxBXtx8VizEFsmNuj/Sz1GbSXEyNiRIzFc40KV/QbF1f7dFt5ioNLMXGxuTBH+46T20KC
ti1KcdnFbtvi9vMqR5wcR645izifRXtBjMVjaFU8O+feD+eWu//43uv1//PI/m9x3rgLpvzktbxV
zx40ZsCn9hraa68pr6/QlFnLNRX83T9f0u9usbwMvqzLb3lZv7t1ui6/DTHeDt7+ii6/fYZ+X5E/
3IGO/OGOV/XHO17TH+9E7npNf7hzpv5010z98e6Z4Czwdf3p7lkIeM/r+nOS2bri3tn6879mg2/o
in+9oSvvQ/71pq64bw7yJnZF7p+rK5GrLA/O018emK+rjA/N118enK+rwasfegtcgIAPL9BfkauR
vz66SH99ZKESWkf+9u/Fsvw94RL9/bG3dc1jSxDw8bf1d+TaJ5bqmieWKeGTYJus0HVPdZCnV+gf
T6/UP55ZpeufWYms0j+eXZ3wevCGZ9fo+snYk9fohslrdcNza3Tjc+Dza3VjkvW66YV3yJQNunnK
Rt2E3Dx1I/om3TwNnGbcrH++uEn/nLZZt7y4BX1LQuu3vrRFt768Tbe8tE23Td+mW5GEr2zH3qHb
Xink9hk723W426fjB+2/dToxtityK5iEdt225ZaXtqY+Ctyqf2L/k7HcjPzzxc2MbYtunmopxpnm
MJWxW6aAiOdm8TxvfmGDbuooz9uurMnz61mndbrpuXWsXRVZO+wbJ5tbqxueXcsaG9egr0bWyGt/
vT+Tp1frH0+v0vVPgU+tSvo/nlzJZ1iRJ1foOssTy/msl+uaxy183o+BSZbp7/9GHkP+vRR9qf4K
/s3yKPqjb3Nuva2rHynkr48s0StvbWYr5og0bmT3T735rw/nf/zpSc8k4v9S/R838KW/Pv8bUc6e
7dez68FBA964537/bp37g3t13g//leTy217W5WzU37Nhk7BJ/8CG/YPRm/T2V9mkMxDQGzUJG/RO
5K6ZbNKZabN6o/75HjYrkjbqva/rCuTP976hKzps1iv+NQd7jq5kw15535tsUOS+ubrygTd11QNz
C2GTpo0KXo38xRuVDWv860ML0mb96yPgwwuVNikb9W/eoBXxBv07ekI2a7FJvVEr8vjbfGhLdS1Y
3azXslGve3K5rkWue2q5vFn/UdmwaaNWNyybNp0gz65q26zppEkbdTUn21qEE4rNeiMnm0/AG59f
x8m4PsnNadNuYHOu101pw6KzWf+J+IT/Jyf7P9mwt6SNukm3TNuiW9kct7JJbn1xq259GWHj3AZ6
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
Eyr7iral808YrfnLtmryrNWKCKU/Lug15RZ1bdmm848aqfv+90LdftEH9M87HtR3P/keXXbRp/Xa
rNnq07ML33tv17LGekWXLso6c3506qSaLp1UQrLO9cq61KnU2XZ9wqxTDXG1+BH4wF9DXHSuk+pr
Zb1UaSfwr2rurKuuu1td6ms0ZdqL3PVP1WfPO0n/uPU+Xf+Nk3XPzz+q8981VF1at6rUUvyPD5iE
mIKefW2V5vOV4EMnj2G6XvgymBYTZDWgqCs6GudJ7vVjkbDkz9M2GejOhcVvO2MLG6W0aJIiFQkF
VTIWigiRj4hIekQFZUQ6YtLlWoTJXipZV8Ajygvs2qleN/z6U/rbpI9r8g3fVVYqSZWgCHZwugKB
5JxxzP6cDa0aMaSv0gFXxVBU1AqmzpTYsXsNVMZjTM4J8exLc/TI5Ne0au0GTbryXnlxXp+7FGzR
vU9M18YtO7h5lXXsofto2IAe8gVDHG41ImgPAaEUEQbiq8h36YNG6Yc84uX8triroUFbtu0kpjJZ
NJKUROSkfNC6fKBThJ1cVYRLthGuUljCXPN5O+95DeCNLZPAleuSb56nM44dpz9//0M68oARquEO
/Z5j9uPtfsZYaR2bmtiiplmUSLboKCIKO2FAhXxEgBQhQeWvGBHB2tKuP6eQgs8sg4sIZdwxMkmZ
QhHU5kJCVZaFIkLHThikxqZy2rwQkoLPuKw7fnC6fvnpU/W7r52n/t0767Kr79L3L7tdQwb052XR
Vj38zHSNGjtKv7/+AS1t7CLV1tJmmTu7kmS0XWKedVmoJssE0HJO27kigrWjp8jQc9Uo8Adxobqa
kjKCKYkrRaaoq9WK1m669u4nNWqf0fT9qtZu3qmxo0bq8pue1V9vfUyDuvfQ5V87V7/6zGm6+/un
i9ONvkTLSk8VLXw3Pu6gIYoIZZlA0X6GhDIhiQdxZsJHFfAR1BkCF0bbiMjKxG6HpyN2dVJQ34l5
QVQ2PecIsXDU6I5PWgqyZiVhJcYrherAFG+/ORNclPX9C0/TqCG9lLc2a+fOXdwJWyUWXukg05cx
J6A27N6lvNyskTwWmkqS4lJrSUt9o3ljAjI+MWWODv3gL3Xd3ZP1+Z/doPO/cbWOvuDX2tnQ6EQt
WrY29b9s1YbUpOe6Y0cDY2lWnx71ql4F3ZYT2vpI0akX03LeDz91mp6a9oY+8YNr9PXf3KqN/Hzh
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
REFUAwDF6gT2YzayAQAAAABJRU5ErkJggg==
QURAN_ICON_B64
if command -v base64 >/dev/null 2>&1; then
    base64 -d /tmp/quran_mizouh_icon.b64 > "$PLUGIN_DIR/plugin.png" 2>/dev/null
elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import base64; open('/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/plugin.png','wb').write(base64.b64decode(open('/tmp/quran_mizouh_icon.b64').read()))"
fi
rm -f /tmp/quran_mizouh_icon.b64

# Strict permissions: 755 for directories only, 644 for files
find "$PLUGIN_DIR" -type d -exec chmod 755 {} \;
find "$PLUGIN_DIR" -type f -exec chmod 644 {} \;

echo ">>> تم تثبيت قارئ القرآن - mizouh المتميز v3.3.0 بنجاح!"
echo ">>> جارٍ إعادة تشغيل واجهة Enigma2 بأمان..."
sleep 2
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet enigma2 2>/dev/null; then
    systemctl restart enigma2
elif command -v init >/dev/null 2>&1; then
    init 4 && sleep 2 && init 3
else
    killall -9 enigma2 2>/dev/null
fi
exit 0