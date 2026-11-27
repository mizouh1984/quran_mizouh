# 📖 قارئ القرآن - mizouh المتميز (`v3.0.0`)

[![GitHub release](https://img.shields.io/github/v/release/mizouh1984/quran_mizouh?label=Version&color=2ea44f)](https://github.com/mizouh1984/quran_mizouh/releases)
[![GitHub downloads](https://img.shields.io/github/downloads/mizouh1984/quran_mizouh/total?label=Downloads&color=0366d6)](https://github.com/mizouh1984/quran_mizouh/releases)
[![GitHub last commit](https://img.shields.io/github/last-commit/mizouh1984/quran_mizouh?label=Updated&color=informational)](https://github.com/mizouh1984/quran_mizouh/commits/main)
[![Enigma2](https://img.shields.io/badge/Enigma2-Plugin-blueviolet)](#الأنظمة-المدعومة)


بلوجن احترافي لتلاوة القرآن الكريم وتصفح المصحف الشريف على أجهزة **Enigma2** مع دعم **التحديث التلقائي الجماعي** وتحديث قائمة القراء عن بُعد عبر GitHub.

---

## ✨ أبرز المميزات

* **تلاوة متصلة لـ 31 قارئاً:** روايتا **حفص عن عاصم** (بما فيهم الشيخ أحمد بن علي العجمي) و**ورش عن نافع**.
* **المصحف الشريف (604 صفحة):** عرض صفحات المصحف بدقة واضحة بدون تظليل مع تقليب تلقائي متزامن مع التلاوة.
* **وضع الاستماع الصوتي فقط:** إظهار أو إخفاء المصحف بالزر الأصفر.
* **التفسير والبحث والتحميل:** التفسير الميسر، الجلالين، البغوي، الترجمات (الإنجليزية والفرنسية)، البحث المتقدم، والتحميل للاستماع بدون إنترنت.
* **تحديث تلقائي عن بُعد:** إشعار وتحميل التحديثات الجديدة من GitHub مباشرة عند فتح البلوجن.

---

## 🖥️ الأنظمة المدعومة

متوافق مع صور Enigma2 الشائعة على معالجات ARM وMIPS (مثل Vu+ وDreambox وNovaler وغيرها):
* OpenATV / OpenPLi / OpenBH / EGAMI / Pure2 / VTi

---

## ⚡ التثبيت السريع بسطر واحد (Telnet / SSH)

نفّذ الأمر التالي مباشرة عبر Telnet أو SSH على الرسيفر:

```sh
wget -q --no-check-certificate "[https://raw.githubusercontent.com/mizouh1984/quran_mizouh/main/install_quran_mizouh_allinone.sh](https://raw.githubusercontent.com/mizouh1984/quran_mizouh/main/install_quran_mizouh_allinone.sh)" -O - | /bin/sh
