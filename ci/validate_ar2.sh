#!/usr/bin/env bash
# Runtime validation of the EXACT published CoGo 26.46-ar2 APK on an emulator.
# Installs a throwaway test-signed copy of the published (unsigned) APK,
# sets ar-EG locale, launches, and captures screenshots + UI dumps.
#
# This run also enables the product's OWN documented emulator opt-in
# (SplashActivity.kt: on x86-primary devices the app exits unless the
# sentinel file Downloads/S153.txt exists). This is a test-device setting
# only: the published APK, its sources, and the release are untouched.
# Because scoped storage on API 34 hides foreign files from apps without
# all-files access, we pre-grant MANAGE_EXTERNAL_STORAGE (a permission the
# app itself declares in its manifest) via appops on the emulator.
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

echo '=== emulator opt-in (documented product gate, test-device setting only) ==='
adb shell mkdir -p /sdcard/Download || true
adb shell touch /sdcard/Download/S153.txt || true
adb shell appops set com.itsaky.androidide MANAGE_EXTERNAL_STORAGE allow || true
adb shell appops get com.itsaky.androidide MANAGE_EXTERNAL_STORAGE | tee evidence/appops.txt || true
adb shell ls -l /sdcard/Download/ | tee evidence/downloads.txt || true

echo '=== launch (explicit am start -W, continuous unfiltered logcat) ==='
adb logcat -c || true
adb logcat > evidence/logcat-full.txt 2>&1 &
LOGCAT_PID=$!
adb shell am start -W -n "com.itsaky.androidide/$ACT" 2>&1 | tee evidence/am-start.log

tap_if_present() {
  # $1 = resource-id fragment or exact visible text; taps center of first match
  local pat="$1" node b x1y1 x2y2 x1 y1 x2 y2 cx cy
  [ -s /tmp/window.xml ] || return 1
  node=$(grep -o '<node[^>]*resource-id="[^"]*'"$pat"'"[^>]*>' /tmp/window.xml | head -1)
  [ -z "$node" ] && node=$(grep -o '<node[^>]*text="'"$pat"'"[^>]*>' /tmp/window.xml | head -1)
  [ -z "$node" ] && return 1
  b=$(echo "$node" | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1)
  [ -z "$b" ] && return 1
  x1y1=$(echo "$b" | grep -oE '[0-9]+,[0-9]+' | head -1)
  x2y2=$(echo "$b" | grep -oE '[0-9]+,[0-9]+' | tail -1)
  x1=${x1y1%,*}; y1=${x1y1#*,}; x2=${x2y2%,*}; y2=${x2y2#*,}
  cx=$(( (x1 + x2) / 2 )); cy=$(( (y1 + y2) / 2 ))
  adb shell input tap "$cx" "$cy" || return 1
  echo "TAP [$pat] at $cx,$cy" | tee -a evidence/taps.log
  sleep 3
  return 0
}

echo '=== observe up to 12 min, drive onboarding (skip/next/done/allow) ==='
MAIN_HITS=0
for i in $(seq 1 36); do
  PID=$(adb shell pidof com.itsaky.androidide | tr -d '\r')
  FOCUS=$(adb shell dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity' | tr -d '\r' || true)
  echo "[$((i*20))s] pid=$PID focus=$FOCUS" | tee -a evidence/observe.log
  adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/window.xml /tmp/window.xml >/dev/null 2>&1 || true
  if [ -s /tmp/window.xml ]; then
    if [ $((i % 3)) -eq 0 ]; then cp /tmp/window.xml evidence/ui-$i.xml; fi
    tap_if_present 'id/skip' || tap_if_present 'id/next' || tap_if_present 'id/done' \
      || tap_if_present 'permission_allow_button' \
      || tap_if_present 'التالي' || tap_if_present 'تم' || tap_if_present 'تخطي' \
      || tap_if_present 'تخطى' || tap_if_present 'السماح' || tap_if_present 'ابدأ' \
      || tap_if_present 'Next' || tap_if_present 'Done' || tap_if_present 'Skip' \
      || tap_if_present 'Allow' || true
  fi
  if [ $((i % 3)) -eq 0 ]; then
    adb exec-out screencap -p > evidence/launch-$i.png 2>/dev/null || true
  fi
  if echo "$FOCUS" | grep -qE 'itsaky.*(MainActivity|EditorActivity)'; then
    MAIN_HITS=$((MAIN_HITS + 1))
  else
    MAIN_HITS=0
  fi
  if [ "$MAIN_HITS" -ge 3 ]; then
    echo "REACHED_MAIN_ACTIVITY at ~$((i*20))s" | tee -a evidence/observe.log
    break
  fi
  sleep 20
done

adb exec-out screencap -p > evidence/launch-final.png 2>/dev/null || true
adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
adb pull /sdcard/window.xml evidence/ui-final.xml >/dev/null 2>&1 || true
kill $LOGCAT_PID 2>/dev/null || true

echo '=== crash / state evidence ==='
adb shell ls /data/tombstones/ 2>/dev/null | tee evidence/tombstones-list.txt || true
LATEST=$(adb shell ls -t /data/tombstones/ 2>/dev/null | head -1 | tr -d '\r')
if [ -n "$LATEST" ]; then
  adb shell cat "/data/tombstones/$LATEST" > evidence/tombstone-latest.txt 2>/dev/null || true
fi
adb shell dumpsys dropbox --print 2>/dev/null | grep -B2 -A40 -iE 'crash|anr|itsaky' | head -200 > evidence/dropbox.txt || true
adb shell pidof com.itsaky.androidide | tee evidence/final-pid.txt || true
adb shell du -s /data/data/com.itsaky.androidide 2>/dev/null | tee evidence/final-size.txt || true
adb shell dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity' | tee evidence/final-focus.txt || true
