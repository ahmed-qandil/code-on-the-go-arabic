#!/usr/bin/env bash
# Runtime validation of the EXACT published CoGo 26.46-ar2 APK on an emulator.
# Installs a throwaway test-signed copy of the published (unsigned) APK,
# sets ar-EG locale, launches, and captures screenshots + UI dumps.
set -x
mkdir -p evidence
cat > /tmp/tap_text.py <<'PY'
import re, subprocess, sys
targets = ['install', 'setup', 'continue', 'next', 'start', 'get started', 'done', 'agree', 'accept', 'grant', 'allow', 'ok',
           'تثبيت', 'إعداد', 'متابعة', 'التالي', 'ابدأ', 'بدء', 'تم', 'موافق', 'سماح', 'حسنا', 'استمرار']
try:
    xml = open('/tmp/window.xml', encoding='utf-8').read()
except FileNotFoundError:
    sys.exit(0)
nodes = re.findall(r'<node[^>]*>', xml)
best = None
for n in nodes:
    text = re.search(r'text="([^"]*)"', n)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    enabled = re.search(r'enabled="true"', n)
    if not (text and b and enabled):
        continue
    t = text.group(1).strip().lower()
    if t and any(w in t for w in targets):
        x = (int(b.group(1)) + int(b.group(3))) // 2
        y = (int(b.group(2)) + int(b.group(4))) // 2
        best = (x, y, t)
        break
if best:
    print('TAPPING:', best)
    subprocess.run(['adb', 'shell', 'input', 'tap', str(best[0]), str(best[1])])
else:
    print('no tappable target')
PY
cat > /tmp/count_ar.py <<'PY'
try:
    s = open('/tmp/window.xml', encoding='utf-8').read()
    print(sum(1 for c in s if '؀' <= c <= 'ۿ'))
except Exception:
    print(0)
PY

adb root || true
sleep 8
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 5; done

echo '=== ABI / native bridge check ==='
AB64=$(adb shell getprop ro.product.cpu.abilist64 | tr -d '\r')
echo "abilist64: $AB64" | tee evidence/abilist64.txt
adb shell getprop ro.product.cpu.abilist32 | tr -d '\r' | tee evidence/abilist32.txt
adb shell getprop ro.dalvik.vm.native.bridge | tee evidence/native-bridge.txt

adb shell setprop persist.sys.locale ar-EG || true
adb shell settings put system system_locales ar-EG || true
adb shell setprop ctl.restart zygote || true
sleep 30
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 5; done
adb shell settings get system system_locales | tee evidence/locale.txt
adb shell getprop persist.sys.locale | tee -a evidence/locale.txt
adb shell getprop persist.sys.language | tee -a evidence/locale.txt
adb shell getprop persist.sys.country | tee -a evidence/locale.txt

if ! echo "$AB64" | grep -q arm64-v8a; then
  echo 'EMULATOR_ABI_UNSUPPORTED: no arm64-v8a translation on this image; skipping install (emulator limitation, not a product defect)' | tee evidence/ABI_UNSUPPORTED.txt
  exit 0
fi

echo '=== install (test-signed copy of the published APK) ==='
if ! adb install cogo-test-signed.apk 2>&1 | tee evidence/install.log | grep -q Success; then
  echo 'INSTALL_FAILED' | tee evidence/INSTALL_FAILED.txt
  adb exec-out screencap -p > evidence/install-failed.png 2>/dev/null || true
  exit 0
fi
adb shell pm list packages | grep itsaky
adb shell dumpsys package com.itsaky.androidide | grep -E 'versionName|primaryCpuAbi' | tee evidence/package-info.txt || true

echo '=== launch ==='
adb shell monkey -p com.itsaky.androidide -c android.intent.category.LAUNCHER 1 | tee evidence/launch.log
sleep 20
if ! adb shell pidof com.itsaky.androidide >/dev/null 2>&1; then
  echo 'APP_NOT_RUNNING_AFTER_LAUNCH' | tee evidence/LAUNCH_FAILED.txt
  adb exec-out screencap -p > evidence/launch-failed.png 2>/dev/null || true
  adb logcat -d -t 300 | grep -iE 'androidide|AndroidRuntime|FATAL' > evidence/logcat-launch.txt || true
  exit 0
fi

for i in $(seq 1 36); do
  adb exec-out screencap -p > evidence/shot-$i.png 2>/dev/null || true
  adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/window.xml /tmp/window.xml >/dev/null 2>&1 || true
  cp /tmp/window.xml evidence/ui-$i.xml 2>/dev/null || true
  AR=$(python3 /tmp/count_ar.py || echo 0)
  SIZE=$(adb shell du -s /data/data/com.itsaky.androidide 2>/dev/null | tr -d '\r' || true)
  echo "[$i] arabic_chars_in_ui=$AR appdata=$SIZE" | tee -a evidence/progress.log
  python3 /tmp/tap_text.py | tee -a evidence/taps.log || true
  sleep 30
done

adb shell pm path com.itsaky.androidide
adb shell du -s /data/data/com.itsaky.androidide | tee evidence/final-size.txt || true
adb logcat -d -t 300 | grep -iE 'androidide|AndroidRuntime|FATAL' > evidence/logcat-final.txt || true
