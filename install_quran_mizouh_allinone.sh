#!/bin/sh
# =========================================================================
# قارئ القرآن - mizouh المتميز (الإصدار v3.1.0) - ملف تثبيت شامل (All-in-One)
# مستودع التحديث التلقائي: https://github.com/mizouh1984/quran_mizouh
# متوافق مع OpenATV / OpenPLi / OpenBH / Egami / Pure2 / VTi / DreamOS
# =========================================================================

PLUGIN_DIR="/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh"
echo ">>> جارٍ تثبيت قارئ القرآن - mizouh المتميز (الإصدار v3.1.0)..."
rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR/locale"

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/plugin.py"
# -*- coding: utf-8 -*-
"""
قارئ القرآن - mizouh المتميز (Quran Reader - mizouh Al-Mutamayiz)
Enigma2 FullHD (1920x1080) Plugin v3.1.0
Fixes & Upgrades:
  1. Instant Pre-Fetched Mushaf Page Turning + Studio Timing Ratios + 1.2s Anticipation Lead (zero late turns!)
  2. True 3-State Play / Pause / Resume / Stop on Green & Red & Media Remote Keys
  3. 100% Reliable Blue Button Hafs <-> Warsh Switching (no keymap collision + built-in Warsh list + reset index)
  4. Full MENU Screen with 4 Live-Switchable FullHD Skins + Built-in GitHub OTA Updater
"""

import os
import re
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
from Components.config import config, ConfigSubsection, ConfigSelection, ConfigInteger, ConfigYesNo, getConfigListEntry
from enigma import eServiceReference, ePicLoad, eTimer, iPlayableService
from Components.ServiceEventTracker import ServiceEventTracker

from .version import PLUGIN_VERSION, GITHUB_USER, GITHUB_REPO
from .skins import SKIN_CHOICES, build_main_skin, build_menu_skin
from .quran_api import QuranAPI, SURAHS_LIST
from .offline_manager import OfflineManager
from .updater import PluginAutoUpdater
from .locale_loader import LocaleLoader

# Persistent Enigma2 Plugin Configuration
config.plugins.quranmizouh = ConfigSubsection()
config.plugins.quranmizouh.skin_theme = ConfigSelection(default="emerald_gold", choices=SKIN_CHOICES)
config.plugins.quranmizouh.language = ConfigSelection(default="ar", choices=[("ar", "العربية"), ("en", "English"), ("fr", "Français")])
config.plugins.quranmizouh.riwaya = ConfigSelection(default="hafs", choices=[("hafs", "حفص عن عاصم"), ("warsh", "ورش عن نافع")])
config.plugins.quranmizouh.show_mushaf = ConfigYesNo(default=True)
config.plugins.quranmizouh.mushaf_mode = ConfigSelection(default="image", choices=[("image", "صورة المصحف الحقيقية"), ("text", "المصحف النصي")])
config.plugins.quranmizouh.auto_update = ConfigYesNo(default=True)
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

        self.riwaya = (restore_state or {}).get("riwaya") or config.plugins.quranmizouh.riwaya.value
        self.show_mushaf = config.plugins.quranmizouh.show_mushaf.value
        self.mushaf_mode = config.plugins.quranmizouh.mushaf_mode.value
        self.active_pane = "surahs"
        self.current_surah = (restore_state or {}).get("surah", 1)
        self.current_ayah = (restore_state or {}).get("ayah", 1)
        self.current_page = 1
        self.ayahs_data = []
        self.tafsirs_data = []
        self.ayah_page_map = {}
        self.exact_timings = []
        self.ref_ratio_timings = []
        self.ayah_weight_ranges = []

        # Explicit 3-state playback machine: "stopped" | "playing" | "paused"
        self.play_state = (restore_state or {}).get("play_state", "stopped")
        self.last_pos_sec = (restore_state or {}).get("last_pos_sec", 0.0)
        self.pending_resume_sec = None
        self.pending_update_info = None
        self.pending_decoded_page = None
        self._closing_for_skin_reload = False

        self.reciters = self.api.get_reciters_by_riwaya(self.riwaya)
        restored_rec_id = (restore_state or {}).get("reciter_id")
        self.current_reciter = next((r for r in self.reciters if r["id"] == restored_rec_id), self.reciters[0])

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
        self["status_bar"] = Label(f"v{PLUGIN_VERSION} · MENU للسكينات والتحديث")

        # Fast 250ms timer for accurate, instant page-turning & Tafsir updates
        self.sync_timer = eTimer()
        self.sync_timer.callback.append(self.sync_page_from_playback)

        # Main-thread trigger when async Mushaf page image finishes downloading
        self.page_ready_timer = eTimer()
        self.page_ready_timer.callback.append(self._decode_ready_page)

        # Main-thread trigger for GitHub OTA update result
        self.update_ui_timer = eTimer()
        self.update_ui_timer.callback.append(self._handle_update_check_result)

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
        self.picload.setPara((MUSHAF_W, MUSHAF_H, 1, 1, False, 1, "#FAF6EC"))
        self.populate_lists()
        self.load_surah_content(self.current_surah)
        self.update_display_mode()
        self._refresh_playback_labels()
        if self.play_state == "playing":
            self.sync_timer.start(250, False)
        if config.plugins.quranmizouh.auto_update.value:
            self.start_background_update_check()

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

    def update_display_mode(self):
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
            self.render_mushaf_page_image(self.current_page)
        else:
            self["mushaf_page"].hide()
            self["mushaf_text"].show()

    def _prefetch_upcoming_pages(self, start_page):
        """Pre-downloads the next 3 Mushaf pages in background so page turning is INSTANT (<50ms)."""
        pages = [p for p in (start_page, start_page + 1, start_page + 2, start_page + 3) if 1 <= p <= 604]
        def _worker():
            for p in pages:
                self.offline.get_or_download_mushaf_page(p)
        threading.Thread(target=_worker, daemon=True).start()

    def render_mushaf_page_image(self, page_num):
        # Fast path: already cached on disk -> decode immediately (<50ms!)
        cached_path = self.offline.get_cached_mushaf_page(page_num)
        if cached_path:
            self.picload.startDecode(cached_path)
            self._prefetch_upcoming_pages(page_num + 1)
            return

        # Slow path: download asynchronously so main thread NEVER freezes or lags behind audio!
        def _dl_worker():
            path = self.offline.get_or_download_mushaf_page(page_num)
            if path and page_num == self.current_page:
                self.pending_decoded_page = path
                self.page_ready_timer.start(10, True)
            self._prefetch_upcoming_pages(page_num + 1)

        threading.Thread(target=_dl_worker, daemon=True).start()

    def _decode_ready_page(self):
        path = self.pending_decoded_page
        self.pending_decoded_page = None
        if path and os.path.exists(path):
            self.picload.startDecode(path)

    def _compute_ayah_weight_ranges(self):
        self.ayah_weight_ranges = []
        if not self.ayahs_data:
            return
        # Calibrated lightweight character weights (fallback only if studio ratios unavailable)
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
        surah_meta = SURAHS_LIST[surah_number - 1]
        self["surah_banner"].setText(f"سورة {surah_meta['name_ar']}  ·  الآية {self.current_ayah}")
        self["status_bar"].setText("جارٍ تحميل المصحف والتفسير...")
        self.ayahs_data, self.tafsirs_data = self.api.fetch_surah_and_tafsir(
            surah_number,
            config.plugins.quranmizouh.tafsir_edition.value,
            self.offline,
        )
        self.ayah_page_map = {a["num"]: a.get("page", 1) for a in self.ayahs_data}
        self._compute_ayah_weight_ranges()
        mushaf_str = " ۝ ".join([f"{a['text']} ({a['num']})" for a in self.ayahs_data])
        self["mushaf_text"].setText(mushaf_str)
        self.update_active_ui(force_page_reload=True)
        self._prefetch_upcoming_pages(self.current_page)
        self["status_bar"].setText(f"v{PLUGIN_VERSION} · صفحة {self.current_page}")

    def update_active_ui(self, force_page_reload=False, override_page=None):
        if not self.ayahs_data:
            return
        idx = max(0, min(len(self.ayahs_data) - 1, self.current_ayah - 1))
        ayah = self.ayahs_data[idx]
        tafsir = self.tafsirs_data[idx] if idx < len(self.tafsirs_data) else {"text": ""}
        new_page = override_page if override_page is not None else ayah.get("page", 1)
        page_changed = force_page_reload or (new_page != self.current_page)
        self.current_page = new_page

        surah_meta = SURAHS_LIST[self.current_surah - 1]
        self["surah_banner"].setText(f"سورة {surah_meta['name_ar']}  ·  آية {ayah['num']}  ·  صفحة {self.current_page}")
        self["active_ayah_label"].setText(f"{ayah['text']} ۝{ayah['num']}")
        self["tafsir_text"].setText(f"التفسير:\n{tafsir['text']}")
        if self.show_mushaf and self.mushaf_mode == "image" and page_changed:
            self.render_mushaf_page_image(self.current_page)

    def play_continuous_surah(self, resume_sec=None):
        self.sync_timer.stop()
        self.exact_timings = []
        self.ref_ratio_timings = []

        local_mp3 = self.offline.get_local_mp3(self.current_reciter["id"], self.current_surah)
        if local_mp3 and os.path.exists(local_mp3):
            url = local_mp3
            source_label = f"تشغيل محلي · {self.current_reciter['name_ar']}"
        else:
            q_url, timings = self.api.fetch_continuous_surah_stream(self.current_reciter, self.current_surah)
            url = q_url or self.api.build_audio_url(self.current_reciter, self.current_surah)
            self.exact_timings = timings
            if not timings:
                # Fetch studio Murattal timing ratios for accurate page turning on Al-Ajmy, Maher, Warsh, etc.!
                self.ref_ratio_timings = self.api.fetch_reference_ratios(self.current_surah)
            riwaya_short = "حفص" if self.riwaya == "hafs" else "ورش"
            source_label = f"{riwaya_short} · {self.current_reciter['name_ar']}"

        sref = eServiceReference(4097, 0, url)
        sref.setName(f"سورة {SURAHS_LIST[self.current_surah - 1]['name_ar']} - {self.current_reciter['name_ar']}")
        self.session.nav.stopService()
        self.session.nav.playService(sref)
        self.play_state = "playing"
        self.pending_resume_sec = resume_sec
        if resume_sec is None:
            self.current_ayah = 1
            self.last_pos_sec = 0.0
        self.update_active_ui()
        self._refresh_playback_labels()
        self["status_bar"].setText(source_label)
        self.sync_timer.start(250, False)

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

        # Apply deferred resume seek if we recovered from a dropped paused stream
        if self.pending_resume_sec is not None and pos_sec >= 0.1:
            target = self.pending_resume_sec
            self.pending_resume_sec = None
            seek.seekTo(int(target * 90000))
            return

        self.last_pos_sec = pos_sec
        matched_ayah = None
        lead_page = None

        if self.exact_timings:
            # Exact millisecond timing for current Ayah + 1.2s anticipation for page turn!
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
            self.update_active_ui(override_page=lead_page)
        elif lead_page is not None and lead_page != self.current_page:
            self.update_active_ui(override_page=lead_page)

    def _seek_to_ayah(self, target_ayah):
        self.current_ayah = target_ayah
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
                self.sync_timer.start(250, False)
                self._refresh_playback_labels()
                self["status_bar"].setText(f"مستمر · {self.current_reciter['name_ar']}")
                return
            # Fallback if GStreamer stream timed out while paused: resume at exact saved second
            self.play_continuous_surah(resume_sec=self.last_pos_sec)
            return
        self.play_continuous_surah()

    def toggle_play_pause(self):
        """True 3-state Green button: Playing -> Pause -> Resume (NEVER restarts from 00:00!)."""
        if self.play_state == "playing":
            self.pause_recitation()
        elif self.play_state == "paused":
            self.resume_or_play()
        else:
            self.play_continuous_surah()

    def stop_recitation(self):
        self.sync_timer.stop()
        self.session.nav.stopService()
        self.play_state = "stopped"
        self.last_pos_sec = 0.0
        self._refresh_playback_labels()
        self["status_bar"].setText("تم الإيقاف الكلي")

    def toggle_mushaf_display(self):
        self.show_mushaf = not self.show_mushaf
        config.plugins.quranmizouh.show_mushaf.value = self.show_mushaf
        config.plugins.quranmizouh.show_mushaf.save()
        self.update_display_mode()

    def toggle_riwaya(self):
        """Reliably switches Hafs <-> Warsh, updates reciter list to index 0, and plays immediately!"""
        next_riwaya = "warsh" if self.riwaya == "hafs" else "hafs"
        next_reciters = self.api.get_reciters_by_riwaya(next_riwaya)
        if not next_reciters:
            self["status_bar"].setText("تعذر تحميل قائمة القراء لهذه الرواية")
            return
        self.riwaya = next_riwaya
        config.plugins.quranmizouh.riwaya.value = self.riwaya
        config.plugins.quranmizouh.riwaya.save()
        self.reciters = next_reciters
        self.current_reciter = self.reciters[0]
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
                riwaya_title = "رواية حفص عن عاصم" if self.riwaya == "hafs" else "رواية ورش عن نافع"
                self["riwaya_label"].setText(f"{riwaya_title}  ·  {self.current_reciter['name_ar']}")
                self.play_continuous_surah()
        else:
            sel = self["surah_list"].getCurrent()
            if sel:
                self.current_surah = sel[1]["number"]
                self.current_ayah = 1
                self.load_surah_content(self.current_surah)
                self.play_continuous_surah()

    def open_search(self):
        self.session.openWithCallback(self.execute_search, VirtualKeyBoard, title="البحث المتقدم في القرآن الكريم", text="")

    def execute_search(self, keyword):
        if not keyword:
            return
        results = self.api.search_verses(keyword)
        if not results:
            self.session.open(MessageBox, "لم يتم العثور على نتائج مطابقة.", MessageBox.TYPE_INFO, timeout=4)
            return
        first = results[0]
        self.current_surah = first["surah"]
        self.current_ayah = first["ayah"]
        self.load_surah_content(self.current_surah)
        self.play_continuous_surah()
        self._seek_to_ayah(first["ayah"])

    def open_menu_screen(self):
        """Opens the themed MENU screen with 4 Skins & GitHub OTA Updater."""
        self.session.openWithCallback(self._on_menu_closed, QuranMizouhMenuScreen, self.updater)

    def _on_menu_closed(self, action=None):
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
            new_riwaya = config.plugins.quranmizouh.riwaya.value
            if new_riwaya != self.riwaya:
                self.riwaya = new_riwaya
                self.populate_lists(keep_current=False)

            if new_skin != self.skin_theme:
                # Seamlessly reopen main screen with the newly selected FullHD Skin!
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
                self.sync_timer.stop()
                self.update_ui_timer.stop()
                self.page_ready_timer.stop()
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

    def exit_plugin(self):
        self.sync_timer.stop()
        self.update_ui_timer.stop()
        self.page_ready_timer.stop()
        if not self._closing_for_skin_reload:
            self.session.nav.stopService()
            if self.prev_service:
                self.session.nav.playService(self.prev_service)
        self.close()


class QuranMizouhMenuScreen(ConfigListScreen, Screen):
    """Dedicated MENU Screen: Switch between 4 FullHD Skins + Run GitHub OTA Updates + Settings."""

    def __init__(self, session, updater=None):
        self.skin = build_menu_skin(config.plugins.quranmizouh.skin_theme.value)
        Screen.__init__(self, session)
        self.updater = updater

        entries = [
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
        self["update_status"] = Label("غيّر السكين بالأسهم يمين/يسار ثم اضغط الأخضر للتطبيق الفوري — أو الأصفر للتحديث من GitHub")
        self["btn_red"] = Label("إغلاق")
        self["btn_green"] = Label("حفظ وتطبيق السكين")
        self["btn_yellow"] = Label("تحديث البلوجن من GitHub")
        self["btn_blue"] = Label("تحديث القراء فقط")

        self["actions"] = ActionMap(["SetupActions", "ColorActions"], {
            "save": self.save_settings,
            "ok": self.save_settings,
            "green": self.save_settings,
            "yellow": self.trigger_plugin_update,
            "blue": self.trigger_reciters_update,
            "red": lambda: self.close(None),
            "cancel": lambda: self.close(None),
        }, -2)

    def save_settings(self):
        for item in self["config"].list:
            item[1].save()
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
            name=f"قارئ القرآن - mizouh المتميز v{PLUGIN_VERSION}",
            description=f"إصدار v{PLUGIN_VERSION} - تلاوة متصلة لـ 31+ قارئاً (حفص وورش) مع 4 سكينات والمصحف الحقيقي والتحديث عبر GitHub",
            where=[PluginDescriptor.WHERE_PLUGINMENU, PluginDescriptor.WHERE_EXTENSIONSMENU],
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
    <screen name="QuranMizouhMenuScreen" position="center,center" size="1320,820" title="قائمة الإعدادات والسكينات والتحديث" flags="wfNoBorder" backgroundColor="{p['bg']}">
        <eLabel position="0,0" size="1320,92" backgroundColor="{p['bar']}" zPosition="-1" />
        <eLabel position="0,92" size="1320,3" backgroundColor="{p['accent']}" zPosition="0" />
        <widget name="menu_title" position="40,18" size="1240,42" font="Regular;32" foregroundColor="{p['title']}" backgroundColor="{p['bar']}" halign="center" transparent="1" />
        <widget name="repo_info" position="40,58" size="1240,30" font="Regular;20" foregroundColor="{p['sub']}" backgroundColor="{p['bar']}" halign="center" transparent="1" />

        <widget name="config" position="45,116" size="1230,540" itemHeight="50" font="Regular;25" foregroundColor="{p['text']}" backgroundColor="{p['panel']}" scrollbarMode="showOnDemand" />

        <eLabel position="45,672" size="1230,2" backgroundColor="{p['divider']}" />
        <widget name="update_status" position="45,686" size="1230,38" font="Regular;22" foregroundColor="{p['ayah']}" halign="center" transparent="1" />

        <!-- Menu Bottom Color Actions -->
        <eLabel position="0,736" size="1320,84" backgroundColor="{p['bar']}" zPosition="-1" />

        <eLabel position="1248,766" size="20,20" backgroundColor="#DC2626" />
        <widget name="btn_red" position="1040,758" size="198,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <eLabel position="998,766" size="20,20" backgroundColor="#16A34A" />
        <widget name="btn_green" position="720,758" size="268,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <eLabel position="678,766" size="20,20" backgroundColor="#EAB308" />
        <widget name="btn_yellow" position="380,758" size="288,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />

        <eLabel position="338,766" size="20,20" backgroundColor="#2563EB" />
        <widget name="btn_blue" position="40,758" size="288,38" font="Regular;22" foregroundColor="{p['text']}" halign="right" transparent="1" />
    </screen>
    """

QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/updater.py"
# -*- coding: utf-8 -*-
"""
GitHub OTA Auto-Updater for قارئ القرآن - mizouh المتميز
Checks version.json & reciters_feed.json hosted on the owner's GitHub repository
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
                tmp_path = CATALOG_FILE + ".tmp"
                with open(tmp_path, "w", encoding="utf-8") as f:
                    json.dump(data, f, ensure_ascii=False, indent=2)
                os.replace(tmp_path, CATALOG_FILE)
                return True
        except Exception:
            pass
        return False

    def download_and_install_update(self, manifest):
        """Downloads tar.gz package from GitHub and extracts cleanly over /usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh."""
        pkg_url = manifest.get("package_url") or PACKAGE_TAR_URL
        tmp_tar = "/tmp/quran_mizouh_ota.tar.gz"
        try:
            data = self._fetch_bytes(pkg_url, timeout=25)
            with open(tmp_tar, "wb") as f:
                f.write(data)

            with tarfile.open(tmp_tar, "r:gz") as tar:
                members = [
                    m for m in tar.getmembers()
                    if m.name.startswith("usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/")
                ]
                tar.extractall(path="/", members=members)

            os.system(f"chmod -R 755 {PLUGIN_DIR}")
            try:
                os.remove(tmp_tar)
            except OSError:
                pass
            return True, "تم تثبيت التحديث الجديد بنجاح من GitHub!"
        except Exception as err:
            return False, f"فشل تحميل التحديث من GitHub: {err}"

QURAN_MIZOUH_EOF

cat << 'QURAN_MIZOUH_EOF' > "/usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh/version.py"
# -*- coding: utf-8 -*-
# الإصدار الرسمي وإعدادات مستودع التحديث التلقائي عبر GitHub

PLUGIN_VERSION = "3.1.0"
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
    {"number": 1, "name_ar": "الفاتحة", "ayahs": 7},
    {"number": 2, "name_ar": "البقرة", "ayahs": 286},
    {"number": 3, "name_ar": "آل عمران", "ayahs": 200},
    {"number": 4, "name_ar": "النساء", "ayahs": 176},
    {"number": 5, "name_ar": "المائدة", "ayahs": 120},
    {"number": 6, "name_ar": "الأنعام", "ayahs": 165},
    {"number": 7, "name_ar": "الأعراف", "ayahs": 206},
    {"number": 8, "name_ar": "الأنفال", "ayahs": 75},
    {"number": 9, "name_ar": "التوبة", "ayahs": 129},
    {"number": 10, "name_ar": "يونس", "ayahs": 109},
    {"number": 11, "name_ar": "هود", "ayahs": 123},
    {"number": 12, "name_ar": "يوسف", "ayahs": 111},
    {"number": 13, "name_ar": "الرعد", "ayahs": 43},
    {"number": 14, "name_ar": "إبراهيم", "ayahs": 52},
    {"number": 15, "name_ar": "الحجر", "ayahs": 99},
    {"number": 16, "name_ar": "النحل", "ayahs": 128},
    {"number": 17, "name_ar": "الإسراء", "ayahs": 111},
    {"number": 18, "name_ar": "الكهف", "ayahs": 110},
    {"number": 19, "name_ar": "مريم", "ayahs": 98},
    {"number": 20, "name_ar": "طه", "ayahs": 135},
    {"number": 21, "name_ar": "الأنبياء", "ayahs": 112},
    {"number": 22, "name_ar": "الحج", "ayahs": 78},
    {"number": 23, "name_ar": "المؤمنون", "ayahs": 118},
    {"number": 24, "name_ar": "النور", "ayahs": 64},
    {"number": 25, "name_ar": "الفرقان", "ayahs": 77},
    {"number": 26, "name_ar": "الشعراء", "ayahs": 227},
    {"number": 27, "name_ar": "النمل", "ayahs": 93},
    {"number": 28, "name_ar": "القصص", "ayahs": 88},
    {"number": 29, "name_ar": "العنكبوت", "ayahs": 69},
    {"number": 30, "name_ar": "الروم", "ayahs": 60},
    {"number": 31, "name_ar": "لقمان", "ayahs": 34},
    {"number": 32, "name_ar": "السجدة", "ayahs": 30},
    {"number": 33, "name_ar": "الأحزاب", "ayahs": 73},
    {"number": 34, "name_ar": "سبأ", "ayahs": 54},
    {"number": 35, "name_ar": "فاطر", "ayahs": 45},
    {"number": 36, "name_ar": "يس", "ayahs": 83},
    {"number": 37, "name_ar": "الصافات", "ayahs": 182},
    {"number": 38, "name_ar": "ص", "ayahs": 88},
    {"number": 39, "name_ar": "الزمر", "ayahs": 75},
    {"number": 40, "name_ar": "غافر", "ayahs": 85},
    {"number": 41, "name_ar": "فصلت", "ayahs": 54},
    {"number": 42, "name_ar": "الشورى", "ayahs": 53},
    {"number": 43, "name_ar": "الزخرف", "ayahs": 89},
    {"number": 44, "name_ar": "الدخان", "ayahs": 59},
    {"number": 45, "name_ar": "الجاثية", "ayahs": 37},
    {"number": 46, "name_ar": "الأحقاف", "ayahs": 35},
    {"number": 47, "name_ar": "محمد", "ayahs": 38},
    {"number": 48, "name_ar": "الفتح", "ayahs": 29},
    {"number": 49, "name_ar": "الحجرات", "ayahs": 18},
    {"number": 50, "name_ar": "ق", "ayahs": 45},
    {"number": 51, "name_ar": "الذاريات", "ayahs": 60},
    {"number": 52, "name_ar": "الطور", "ayahs": 49},
    {"number": 53, "name_ar": "النجم", "ayahs": 62},
    {"number": 54, "name_ar": "القمر", "ayahs": 55},
    {"number": 55, "name_ar": "الرحمن", "ayahs": 78},
    {"number": 56, "name_ar": "الواقعة", "ayahs": 96},
    {"number": 57, "name_ar": "الحديد", "ayahs": 29},
    {"number": 58, "name_ar": "المجادلة", "ayahs": 22},
    {"number": 59, "name_ar": "الحشر", "ayahs": 24},
    {"number": 60, "name_ar": "الممتحنة", "ayahs": 13},
    {"number": 61, "name_ar": "الصف", "ayahs": 14},
    {"number": 62, "name_ar": "الجمعة", "ayahs": 11},
    {"number": 63, "name_ar": "المنافقون", "ayahs": 11},
    {"number": 64, "name_ar": "التغابن", "ayahs": 18},
    {"number": 65, "name_ar": "الطلاق", "ayahs": 12},
    {"number": 66, "name_ar": "التحريم", "ayahs": 12},
    {"number": 67, "name_ar": "الملك", "ayahs": 30},
    {"number": 68, "name_ar": "القلم", "ayahs": 52},
    {"number": 69, "name_ar": "الحاقة", "ayahs": 52},
    {"number": 70, "name_ar": "المعارج", "ayahs": 44},
    {"number": 71, "name_ar": "نوح", "ayahs": 28},
    {"number": 72, "name_ar": "الجن", "ayahs": 28},
    {"number": 73, "name_ar": "المزمل", "ayahs": 20},
    {"number": 74, "name_ar": "المدثر", "ayahs": 56},
    {"number": 75, "name_ar": "القيامة", "ayahs": 40},
    {"number": 76, "name_ar": "الإنسان", "ayahs": 31},
    {"number": 77, "name_ar": "المرسلات", "ayahs": 50},
    {"number": 78, "name_ar": "النبأ", "ayahs": 40},
    {"number": 79, "name_ar": "النازعات", "ayahs": 46},
    {"number": 80, "name_ar": "عبس", "ayahs": 42},
    {"number": 81, "name_ar": "التكوير", "ayahs": 29},
    {"number": 82, "name_ar": "الانفطار", "ayahs": 19},
    {"number": 83, "name_ar": "المطففين", "ayahs": 36},
    {"number": 84, "name_ar": "الانشقاق", "ayahs": 25},
    {"number": 85, "name_ar": "البروج", "ayahs": 22},
    {"number": 86, "name_ar": "الطارق", "ayahs": 17},
    {"number": 87, "name_ar": "الأعلى", "ayahs": 19},
    {"number": 88, "name_ar": "الغاشية", "ayahs": 26},
    {"number": 89, "name_ar": "الفجر", "ayahs": 30},
    {"number": 90, "name_ar": "البلد", "ayahs": 20},
    {"number": 91, "name_ar": "الشمس", "ayahs": 15},
    {"number": 92, "name_ar": "الليل", "ayahs": 21},
    {"number": 93, "name_ar": "الضحى", "ayahs": 11},
    {"number": 94, "name_ar": "الشرح", "ayahs": 8},
    {"number": 95, "name_ar": "التين", "ayahs": 8},
    {"number": 96, "name_ar": "العلق", "ayahs": 19},
    {"number": 97, "name_ar": "القدر", "ayahs": 5},
    {"number": 98, "name_ar": "البينة", "ayahs": 8},
    {"number": 99, "name_ar": "الزلزلة", "ayahs": 8},
    {"number": 100, "name_ar": "العاديات", "ayahs": 11},
    {"number": 101, "name_ar": "القارعة", "ayahs": 11},
    {"number": 102, "name_ar": "التكاثر", "ayahs": 8},
    {"number": 103, "name_ar": "العصر", "ayahs": 3},
    {"number": 104, "name_ar": "الهمزة", "ayahs": 9},
    {"number": 105, "name_ar": "الفيل", "ayahs": 5},
    {"number": 106, "name_ar": "قريش", "ayahs": 4},
    {"number": 107, "name_ar": "الماعون", "ayahs": 7},
    {"number": 108, "name_ar": "الكوثر", "ayahs": 3},
    {"number": 109, "name_ar": "الكافرون", "ayahs": 6},
    {"number": 110, "name_ar": "النصر", "ayahs": 3},
    {"number": 111, "name_ar": "المسد", "ayahs": 5},
    {"number": 112, "name_ar": "الإخلاص", "ayahs": 4},
    {"number": 113, "name_ar": "الفلق", "ayahs": 5},
    {"number": 114, "name_ar": "الناس", "ayahs": 6},
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

        # Ensure both hafs and warsh exist; merge built-in fallback if needed
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

    def get_reciters_by_riwaya(self, riwaya="hafs"):
        target = str(riwaya or "hafs").strip().lower()
        return [r for r in self.reciters if str(r.get("riwaya", "")).strip().lower() == target]

    def build_audio_url(self, reciter, surah_number):
        base = reciter["server"].rstrip("/")
        return f"{base}/{surah_number:03d}.mp3"

    def fetch_continuous_surah_stream(self, reciter, surah_number):
        """Returns (continuous_mp3_url, ayah_timings) for zero-delay recitation & exact page turning."""
        qid = reciter.get("quran_com_id", 0)
        if not qid:
            return None, []
        url = f"https://api.quran.com/api/v4/chapter_recitations/{qid}/{surah_number}?segments=true"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
            with urllib.request.urlopen(req, timeout=8) as resp:
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
            with urllib.request.urlopen(req, timeout=7) as resp:
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
        if offline_mgr:
            cached = offline_mgr.load_surah_json(surah_number, tafsir_edition)
            if cached:
                return cached["ayahs"], cached["tafsirs"]

        url = f"https://api.alquran.cloud/v1/surah/{surah_number}/editions/quran-uthmani,{tafsir_edition}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
                q_ayahs = [{"num": a["numberInSurah"], "text": a["text"], "page": a.get("page", 1)} for a in payload["data"][0]["ayahs"]]
                t_ayahs = [{"num": a["numberInSurah"], "text": a["text"]} for a in payload["data"][1]["ayahs"]]
                if offline_mgr:
                    offline_mgr.save_surah_json(surah_number, tafsir_edition, q_ayahs, t_ayahs)
                return q_ayahs, t_ayahs
        except Exception:
            return [{"num": 1, "text": "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ", "page": 1}], [{"num": 1, "text": "تحقق من اتصال الإنترنت أو شغّل السور المحفوظة محلياً."}]

    def search_verses(self, keyword):
        encoded = urllib.parse.quote(keyword)
        url = f"https://api.alquran.cloud/v1/search/{encoded}/all/ar"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
            with urllib.request.urlopen(req, timeout=10) as resp:
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
import urllib.request

from .version import PLUGIN_VERSION


class OfflineManager:
    """Manages local HDD/USB storage for offline Quran audio, pre-fetched Mushaf page images, and Tafsir JSON."""

    def __init__(self, base_dir="/media/hdd/QuranMizouh"):
        self.base_dir = base_dir
        self.audio_dir = os.path.join(base_dir, "audio")
        self.text_dir = os.path.join(base_dir, "text")
        self.pages_dir = os.path.join(base_dir, "mushaf_pages")
        self._ensure_dirs()

    def _ensure_dirs(self):
        for path in (self.base_dir, self.audio_dir, self.text_dir, self.pages_dir):
            try:
                os.makedirs(path, exist_ok=True)
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
        target = os.path.join(self.pages_dir, f"page_{page_number:03d}.jpg")
        tmp = f"{target}.part"
        mirrors = [
            f"https://www.mp3quran.net/api/quran_pages_arabic/{page_number:03d}.jpg",
            f"https://quran.ksu.edu.sa/png_big/{page_number}.png",
        ]
        for url in mirrors:
            try:
                req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
                with urllib.request.urlopen(req, timeout=12) as resp, open(tmp, "wb") as out:
                    out.write(resp.read())
                if os.path.getsize(tmp) > 2048:
                    os.replace(tmp, target)
                    return target
            except Exception:
                continue
        return None

    def get_local_mp3(self, reciter_id, surah_number):
        return os.path.join(self.audio_dir, f"{reciter_id}_{surah_number:03d}.mp3")

    def download_surah(self, reciter_id, surah_number, url):
        self._ensure_dirs()
        target = self.get_local_mp3(reciter_id, surah_number)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": f"QuranMizouh-Enigma2/{PLUGIN_VERSION}"})
            with urllib.request.urlopen(req, timeout=30) as resp, open(target, "wb") as out:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    out.write(chunk)
            return target
        except Exception:
            return None

    def save_surah_json(self, surah_number, tafsir_edition, ayahs, tafsirs):
        self._ensure_dirs()
        path = os.path.join(self.text_dir, f"surah_{surah_number:03d}_{tafsir_edition}.json")
        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"ayahs": ayahs, "tafsirs": tafsirs}, f, ensure_ascii=False)
        except OSError:
            pass

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
  "version": "3.1.0",
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

chmod -R 755 "$PLUGIN_DIR"
echo ">>> تم تثبيت قارئ القرآن - mizouh المتميز v3.1.0 بنجاح!"
echo ">>> جارٍ إعادة تشغيل واجهة Enigma2..."
sleep 2
killall -9 enigma2 2>/dev/null || systemctl restart enigma2 2>/dev/null
exit 0