#!/usr/bin/env bash
# Runtime validation of the EXACT published CoGo 26.46-ar2 APK on an emulator.
# Installs a throwaway test-signed copy of the published (unsigned) APK,
# sets ar-EG locale, launches, and captures screenshots + UI dumps.
#
# Test-device-only settings (no product change, published artifact untouched):
#  - S153.txt sentinel in emulator Downloads (documented emulator opt-in gate).
#  - appops/pm pre-grants of the permissions the app itself declares, because
#    scoped storage would hide the sentinel and the onboarding grant buttons
#    only open system Settings screens.
#  - Direct root start of the non-exported OnboardingActivity to bypass the
#    x86 launcher gate (ordinary launcher launch fails on x86 emulators by
#    product design + a cold-start flag race; documented separately).
#
# Bounded observation: 3-min base after onboarding entry, extended only while
# the app data dir is measurably growing (active extraction), 6-min hard cap.
# Early exit on: FATAL EXCEPTION, error dialog, or static screen with no
# progress. No retries inside the run.
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

echo '=== test-device pre-grants (permissions the app itself declares) ==='
adb shell mkdir -p /sdcard/Download || true
adb shell touch /sdcard/Download/S153.txt || true
adb shell pm grant com.itsaky.androidide android.permission.POST_NOTIFICATIONS || true
adb shell appops set com.itsaky.androidide MANAGE_EXTERNAL_STORAGE allow || true
adb shell appops set com.itsaky.androidide REQUEST_INSTALL_PACKAGES allow || true
adb shell appops set com.itsaky.androidide SYSTEM_ALERT_WINDOW allow || true
adb shell appops get com.itsaky.androidide MANAGE_EXTERNAL_STORAGE | tee evidence/appops.txt || true
adb shell appops get com.itsaky.androidide REQUEST_INSTALL_PACKAGES | tee -a evidence/appops.txt || true
adb shell appops get com.itsaky.androidide SYSTEM_ALERT_WINDOW | tee -a evidence/appops.txt || true
adb shell dumpsys package com.itsaky.androidide | grep -E 'POST_NOTIFICATIONS|READ_EXTERNAL|WRITE_EXTERNAL' | tee evidence/permissions.txt || true

echo '=== resolve launchable activity ==='
AAPT=$(ls -d $ANDROID_HOME/build-tools/*/aapt | sort -V | tail -1)
$AAPT dump badging cogo-test-signed.apk | grep -E 'launchable-activity|package:' | tee evidence/badging.txt
ACT=$(grep "launchable-activity" evidence/badging.txt | sed "s/.*name='\([^']*\)'.*/\1/")
echo "resolved activity: $ACT" | tee evidence/activity.txt

echo '=== gate check: ordinary launcher entry (documents the ordinary-launch failure) ==='
adb logcat -c || true
adb logcat > evidence/logcat-full.txt 2>&1 &
LOGCAT_PID=$!
adb shell am start -W -n "com.itsaky.androidide/$ACT" 2>&1 | tee evidence/am-start-splash.log
sleep 8
adb shell pidof com.itsaky.androidide | tee evidence/splash-pid.txt || true
adb exec-out screencap -p > evidence/splash-8s.png 2>/dev/null || true

echo '=== direct root start of OnboardingActivity (test-only bypass path) ==='
adb shell am start -W -n 'com.itsaky.androidide/.activities.OnboardingActivity' 2>&1 | tee evidence/am-start.log
sleep 5

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

dump_ui() {
  adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/window.xml /tmp/window.xml >/dev/null 2>&1 || true
}

data_kb() { adb shell du -s /data/data/com.itsaky.androidide 2>/dev/null | awk '{print $1}' | tr -d '\r'; }

echo '=== bounded observation: 3-min base, 6-min hard cap, early exits ==='
LAST_HASH=''
STATIC=0
INSTALL_TAP_ITER=0
PREV_KB=$(data_kb)
GROWING=0
for i in $(seq 1 24); do
  PID=$(adb shell pidof com.itsaky.androidide | tr -d '\r')
  FOCUS=$(adb shell dumpsys activity activities 2>/dev/null | grep -E 'topResumedActivity' | tr -d '\r' || true)
  dump_ui
  HASH=$(md5sum /tmp/window.xml 2>/dev/null | cut -d' ' -f1)
  KB=$(data_kb)
  DELTA=$(( ${KB:-0} - ${PREV_KB:-0} ))
  [ "$DELTA" -gt 1024 ] && GROWING=1 || GROWING=0
  PREV_KB=$KB
  # stage tracking: first meaningful text node on screen
  STAGE=$(grep -oE 'text="[^"]{3,}"' /tmp/window.xml 2>/dev/null | head -3 | tr '\n' ' ')
  echo "[$((i*15))s] pid=$PID kb=$KB(+$DELTA) growing=$GROWING stage=[$STAGE] focus=$FOCUS" | tee -a evidence/observe.log

  # save periodic + on-stage-change UI dumps and screenshots
  if [ "$HASH" != "$LAST_HASH" ]; then
    cp /tmp/window.xml "evidence/ui-stage-$i.xml" 2>/dev/null || true
    adb exec-out screencap -p > "evidence/stage-$i.png" 2>/dev/null || true
    LAST_HASH="$HASH"
    STATIC=0
  else
    STATIC=$((STATIC + 1))
  fi

  # early exit: fatal crash
  if grep -q 'FATAL EXCEPTION' evidence/logcat-full.txt 2>/dev/null; then
    echo "EARLY_EXIT: FATAL EXCEPTION detected at ~$((i*15))s" | tee -a evidence/observe.log
    adb exec-out screencap -p > evidence/exit-fatal.png 2>/dev/null || true
    break
  fi
  # early exit: error dialog on screen
  if grep -qE 'text="(خطأ|فشل|تعذر|Error|Failed|Unable)"' /tmp/window.xml 2>/dev/null; then
    echo "EARLY_EXIT: error dialog text at ~$((i*15))s" | tee -a evidence/observe.log
    adb exec-out screencap -p > evidence/exit-error.png 2>/dev/null || true
    sleep 10
    break
  fi
  # early exit: install tapped, give it 60s to show progress/exception
  if [ "$INSTALL_TAP_ITER" -gt 0 ] && [ "$i" -ge $((INSTALL_TAP_ITER + 4)) ]; then
    echo "EARLY_EXIT: 60s after install tap, no further wait" | tee -a evidence/observe.log
    break
  fi
  # early exit: static screen with no growth (only after 3-min base unless install tapped)
  if [ "$STATIC" -ge 6 ] && [ "$GROWING" -eq 0 ] && [ "$i" -ge 12 ]; then
    echo "EARLY_EXIT: static screen, no extraction growth, past 3-min base" | tee -a evidence/observe.log
    break
  fi

  # drive onboarding: advance, grant, finish
  tap_if_present 'id/skip' || tap_if_present 'id/next' || tap_if_present 'id/done' \
    || tap_if_present 'permission_allow_button' \
    || tap_if_present 'إنهاء التثبيت' || tap_if_present 'id/finish_installation_button' \
    || tap_if_present 'التالي' || tap_if_present 'تم' || tap_if_present 'السماح' \
    || tap_if_present 'Next' || tap_if_present 'Done' || tap_if_present 'Allow' || true

  # one documented tap on the tools-install control when the setup screen shows it
  if [ "$INSTALL_TAP_ITER" -eq 0 ]; then
    if tap_if_present 'id/install_button' || tap_if_present 'تثبيت' || tap_if_present 'Install'; then
      INSTALL_TAP_ITER=$i
      echo "INSTALL_TAPPED at ~$((i*15))s" | tee -a evidence/taps.log
    fi
  fi

  sleep 15
done

adb exec-out screencap -p > evidence/launch-final.png 2>/dev/null || true
dump_ui
cp /tmp/window.xml evidence/ui-final.xml 2>/dev/null || true
kill $LOGCAT_PID 2>/dev/null || true

echo '=== crash / state evidence ==='
grep -c 'FATAL EXCEPTION' evidence/logcat-full.txt 2>/dev/null | tee evidence/fatal-count.txt || true
grep -n -A30 'FATAL EXCEPTION' evidence/logcat-full.txt 2>/dev/null | head -60 > evidence/fatal-excerpt.txt || true
adb shell ls /data/tombstones/ 2>/dev/null | tee evidence/tombstones-list.txt || true
adb shell dumpsys dropbox --print 2>/dev/null | grep -B2 -A40 -iE 'crash|anr|itsaky' | head -200 > evidence/dropbox.txt || true
adb shell pidof com.itsaky.androidide | tee evidence/final-pid.txt || true
adb shell du -s /data/data/com.itsaky.androidide 2>/dev/null | tee evidence/final-size.txt || true
adb shell dumpsys activity activities 2>/dev/null | grep -E 'topResumedActivity' | tee evidence/final-focus.txt || true
