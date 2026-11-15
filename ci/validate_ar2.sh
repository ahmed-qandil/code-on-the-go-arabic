#!/usr/bin/env bash
# Runtime validation of the EXACT published CoGo 26.46-ar2 APK on an emulator.
# Installs a throwaway test-signed copy of the published (unsigned) APK,
# sets ar-EG locale, launches, and captures screenshots + UI dumps.
set -x
mkdir -p evidence

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

echo '=== resolve launchable activity ==='
AAPT=$(ls -d $ANDROID_HOME/build-tools/*/aapt | sort -V | tail -1)
$AAPT dump badging cogo-test-signed.apk | grep -E 'launchable-activity|package:' | tee evidence/badging.txt
ACT=$(grep "launchable-activity" evidence/badging.txt | sed "s/.*name='\([^']*\)'.*/\1/")
echo "resolved activity: $ACT" | tee evidence/activity.txt

echo '=== launch (explicit am start -W, continuous unfiltered logcat) ==='
adb logcat -c || true
adb logcat > evidence/logcat-full.txt 2>&1 &
LOGCAT_PID=$!
adb shell am start -W -n "com.itsaky.androidide/$ACT" 2>&1 | tee evidence/am-start.log

for i in $(seq 1 18); do
  PID=$(adb shell pidof com.itsaky.androidide | tr -d '\r')
  FOCUS=$(adb shell dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity' | tr -d '\r' || true)
  echo "[$((i*10))s] pid=$PID focus=$FOCUS" | tee -a evidence/observe.log
  if [ $((i % 3)) -eq 0 ]; then
    adb exec-out screencap -p > evidence/launch-$i.png 2>/dev/null || true
  fi
  sleep 10
done

adb exec-out screencap -p > evidence/launch-final.png 2>/dev/null || true
kill $LOGCAT_PID 2>/dev/null || true

echo '=== crash evidence ==='
adb shell ls /data/tombstones/ 2>/dev/null | tee evidence/tombstones-list.txt || true
LATEST=$(adb shell ls -t /data/tombstones/ 2>/dev/null | head -1 | tr -d '\r')
if [ -n "$LATEST" ]; then
  adb shell cat "/data/tombstones/$LATEST" > evidence/tombstone-latest.txt 2>/dev/null || true
fi
adb shell dumpsys dropbox --print 2>/dev/null | grep -B2 -A40 -iE 'crash|anr|itsaky' | head -200 > evidence/dropbox.txt || true
adb shell pidof com.itsaky.androidide | tee evidence/final-pid.txt || true
adb shell du -s /data/data/com.itsaky.androidide | tee evidence/final-size.txt || true
