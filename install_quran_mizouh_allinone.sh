# -*- coding: utf-8 -*-
"""
قارئ القرآن - mizouh المتميز (Quran Reader - mizouh Al-Mutamayiz)
Enigma2 FullHD (1920x1080) Plugin v3.2.0
Features:
  1. Auto-Resume Last Reciter, Surah & Ayah across sessions
  2. Background Offline MP3 Downloader (REC / TEXT key or inside MENU)
  3. Instant Pre-Fetched Mushaf Page Turning + Studio Timing Ratios + 1.2s Anticipation Lead
  4. True 3-State Play / Pause / Resume / Stop on Green & Red & Media Remote Keys
  5. 100% Reliable Blue Button Hafs <-> Warsh Switching + 4 Live Skins + GitHub OTA Updater
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
from Components.config import (
    config,
    ConfigSubsection,
    ConfigSelection,
    ConfigInteger,
    ConfigYesNo,
    ConfigText,
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
# Persistent Last Session State (Reciter, Surah, Ayah)
config.plugins.quranmizouh.last_reciter = ConfigText(default="afasy-hafs", fixed_size=False)
config.plugins.quranmizouh.last_surah = ConfigInteger(default=1, limits=(1, 114))
config.plugins.quranmizouh.last_ayah = ConfigInteger(default=1, limits=(1, 286))

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
        self.current_surah = (restore_state or {}).get("surah") or config.plugins.quranmizouh.last_surah.value
        self.current_ayah = (restore_state or {}).get("ayah") or config.plugins.quranmizouh.last_ayah.value
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
        self.pending_download_notice = None
        self._downloading_surah_key = None
        self._closing_for_skin_reload = False

        self.reciters = self.api.get_reciters_by_riwaya(self.riwaya)
        restored_rec_id = (restore_state or {}).get("reciter_id") or config.plugins.quranmizouh.last_reciter.value
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
        self["status_bar"] = Label(f"v{PLUGIN_VERSION} · MENU للإعدادات والتحميل")

        # Fast 250ms timer for accurate, instant page-turning & Tafsir updates
        self.sync_timer = eTimer()
        self.sync_timer.callback.append(self.sync_page_from_playback)

        # Main-thread trigger when async Mushaf page image finishes downloading
        self.page_ready_timer = eTimer()
        self.page_ready_timer.callback.append(self._decode_ready_page)

        # Main-thread trigger for GitHub OTA update result
        self.update_ui_timer = eTimer()
        self.update_ui_timer.callback.append(self._handle_update_check_result)

        # Main-thread trigger when background Surah MP3 download completes
        self.download_ui_timer = eTimer()
        self.download_ui_timer.callback.append(self._handle_download_result)

        self.__event_tracker = ServiceEventTracker(screen=self, eventmap={
            iPlayableService.evEOF: self.on_surah_finished,
        })

        # Dedicated high-priority ColorActions & MediaPlayerActions
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
                "record": self.download_current_surah_offline,
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

        # Separate lower-priority map strictly for INFO & TEXT keys (never intercepts Blue!)
        self["info_actions"] = ActionMap(
            ["EPGSelectActions", "TeletextActions"],
            {
                "info": self.open_search,
                "startTeletext": self.download_current_surah_offline,
            },
            0,
        )

        self.picload.PictureData.get().append(self.on_mushaf_decoded)
        self.onLayoutFinish.append(self.initialize_ui)

    def _save_last_session_state(self):
        try:
            config.plugins.quranmizouh.riwaya.value = self.riwaya
            config.plugins.quranmizouh.last_reciter.value = self.current_reciter["id"]
            config.plugins.quranmizouh.last_surah.value = max(1, min(114, int(self.current_surah)))
            config.plugins.quranmizouh.last_ayah.value = max(1, min(286, int(self.current_ayah)))
            config.plugins.quranmizouh.riwaya.save()
            config.plugins.quranmizouh.last_reciter.save()
            config.plugins.quranmizouh.last_surah.save()
            config.plugins.quranmizouh.last_ayah.save()
        except Exception:
            pass

    def initialize_ui(self):
        self.picload.setPara((MUSHAF_W, MUSHAF_H, 1, 1, False, 1, "#FAF6EC"))
        self.populate_lists(keep_current=True)
        self.load_surah_content(self.current_surah, preserve_ayah=True)
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

    # ------------------------------------------------------------------
    # Background Offline Surah MP3 Downloader
    # ------------------------------------------------------------------
    def download_current_surah_offline(self):
        reciter = dict(self.current_reciter)
        surah_num = int(self.current_surah)
        surah_name = SURAHS_LIST[surah_num - 1]["name_ar"]
        task_key = f"{reciter['id']}_{surah_num:03d}"

        local_mp3 = self.offline.get_local_mp3(reciter["id"], surah_num)
        if os.path.exists(local_mp3) and os.path.getsize(local_mp3) > 8192:
            self["status_bar"].setText(f"محفوظة مسبقاً · سورة {surah_name}")
            self.session.open(
                MessageBox,
                f"سورة {surah_name} بصوت {reciter['name_ar']} محفوظة مسبقاً على الجهاز!\nالمسار: {local_mp3}",
                MessageBox.TYPE_INFO,
                timeout=4,
            )
            return

        if self._downloading_surah_key == task_key:
            self["status_bar"].setText(f"جارٍ تحميل سورة {surah_name} بالفعل...")
            return

        self._downloading_surah_key = task_key
        self["status_bar"].setText(f"جارٍ تحميل سورة {surah_name} بدون إنترنت...")

        def _dl_worker():
            # Also cache Surah text & Tafsir alongside audio for 100% offline playback
            self.api.fetch_surah_and_tafsir(
                surah_num,
                config.plugins.quranmizouh.tafsir_edition.value,
                self.offline,
            )
            url = self.api.build_audio_url(reciter, surah_num)
            saved_path = self.offline.download_surah(reciter["id"], surah_num, url)
            ok = bool(saved_path and os.path.exists(saved_path) and os.path.getsize(saved_path) > 8192)
            if not ok and saved_path and os.path.exists(saved_path):
                try:
                    os.remove(saved_path)
                except OSError:
                    pass
            self._downloading_surah_key = None
            self.pending_download_notice = {
                "ok": ok,
                "surah_name": surah_name,
                "reciter_name": reciter["name_ar"],
                "path": saved_path or "",
            }
            self.download_ui_timer.start(50, True)

        threading.Thread(target=_dl_worker, daemon=True).start()

    def _handle_download_result(self):
        info = self.pending_download_notice
        self.pending_download_notice = None
        if not info:
            return
        if info["ok"]:
            self["status_bar"].setText(f"تم الحفظ بدون إنترنت · سورة {info['surah_name']}")
            self.session.open(
                MessageBox,
                f"تم تحميل سورة {info['surah_name']} بصوت {info['reciter_name']} بنجاح!\nيمكنك الآن الاستماع إليها في أي وقت بدون إنترنت.",
                MessageBox.TYPE_INFO,
                timeout=4,
            )
        else:
            self["status_bar"].setText("تعذر تحميل السورة — تحقق من التخزين أو الشبكة")
            self.session.open(
                MessageBox,
                f"تعذر تحميل سورة {info['surah_name']}.\nتأكد من اتصال الإنترنت ووجود مساحة كافية في:\n{config.plugins.quranmizouh.storage_path.value}",
                MessageBox.TYPE_ERROR,
                timeout=5,
            )

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
                Message
