#!/usr/bin/env bash
# kiosk-doctor — diagnose and fix "my TV box won't boot into the kiosk app".
#
# Everything learned the hard way on a real onn box, in one pass:
#   * repairs a device left with no usable home screen (ALWAYS, first thing)
#   * reports the full launcher/home state in plain language
#   * detects Play Store builds whose launcher capability is stripped out
#   * finds and enables launcher components apps ship DISABLED (Fully Kiosk
#     hides its home activity behind an in-app toggle, which is invisible to
#     `set-home-activity` until enabled)
#   * sets the kiosk app as home and VERIFIES it actually resolved
#   * only then, optionally, disables the stock launcher
#
# Usage:
#   ./kiosk-doctor.sh <ip>                 # diagnose only, change nothing
#   ./kiosk-doctor.sh <ip> --fix <pkg>     # diagnose, then make <pkg> the home app
#   ./kiosk-doctor.sh <ip> --fix <pkg> --exclusive
#                                          # ...and disable the stock launcher,
#                                          #    but ONLY after <pkg> verifies
#   ./kiosk-doctor.sh <ip> --recover       # undo everything, back to stock
#
# Example:
#   ./kiosk-doctor.sh 192.168.13.132 --fix de.ozerov.fully --exclusive
#
# Safe by construction: it never disables the stock launcher until the
# replacement is confirmed resolving as home, and --recover always works
# because adb stays reachable no matter which launcher is active.

set -u

IP="${1:-}"
if [ -z "$IP" ] || [[ "$IP" == --* ]]; then
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
shift

FIX_PKG="" EXCLUSIVE=0 RECOVER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fix) FIX_PKG="${2:-}"; shift 2 ;;
    --exclusive) EXCLUSIVE=1; shift ;;
    --recover) RECOVER=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SERIAL="$IP:5555"
GTV="com.google.android.apps.tv.launcherx"

# adb next to the script (Git Bash doesn't search the cwd).
if ! command -v adb >/dev/null 2>&1; then
  HERE="$(cd "$(dirname "$0")" && pwd)"
  for d in "$HERE" "$PWD"; do
    { [ -x "$d/adb" ] || [ -f "$d/adb.exe" ]; } && { PATH="$d:$PATH"; break; }
  done
fi
command -v adb >/dev/null 2>&1 || {
  echo "adb not found. Install platform-tools and run this from that folder:"
  echo "  https://developer.android.com/tools/releases/platform-tools"
  exit 1
}

sh_()  { adb -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }
shq_() { adb -s "$SERIAL" shell "$@" >/dev/null 2>&1; }

echo "== Connecting to $SERIAL"
adb connect "$SERIAL" >/dev/null 2>&1
adb -s "$SERIAL" shell true >/dev/null 2>&1 || {
  echo "Cannot reach the device."
  adb devices | sed 's/^/   /'
  echo "Check: USB debugging on, IP correct, same network, and accept the"
  echo "'Allow USB debugging?' prompt on the TV."
  exit 1
}
echo "   $(sh_ getprop ro.product.model)  (Android $(sh_ getprop ro.build.version.release))"

# --- helpers ---------------------------------------------------------------
home_list() {
  sh_ cmd package query-activities --brief -a android.intent.action.MAIN \
    -c android.intent.category.HOME | grep '/' | sed 's/^[[:space:]]*//'
}
home_now() {
  # Strip the indentation adb prints, or every string comparison below silently
  # fails to match and a successful change looks like a failure.
  sh_ cmd package resolve-activity --brief -a android.intent.action.MAIN \
    -c android.intent.category.HOME | grep '/' | tail -1 \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
installed() { sh_ pm list packages | grep -q "^package:$1$"; }
# A home that is a real launcher, not the recovery/settings fallbacks.
usable_home() {
  case "$1" in
    ""|*setupwraith*|*FallbackHome*|*frameworkpackagestubs*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- 0. SAFETY: never leave the box without a working home -----------------
CUR=$(home_now)
if ! usable_home "$CUR"; then
  echo
  echo "!! No usable home screen right now (home resolves to: ${CUR:-nothing})."
  echo "   Re-enabling the stock launcher so the box is usable again."
  shq_ pm enable --user 0 "$GTV"
  shq_ cmd package set-home-activity "$GTV/.home.HomeActivity"
  sleep 1
  CUR=$(home_now)
  echo "   home is now: $CUR"
fi

if [ "$RECOVER" = 1 ]; then
  echo
  echo "== Recovering to stock"
  shq_ pm enable --user 0 "$GTV"
  shq_ cmd package set-home-activity "$GTV/.home.HomeActivity"
  sleep 1
  echo "   home is now: $(home_now)"
  echo "   (streaming apps: re-add with onn-kiosk.sh --rebloat)"
  adb -s "$SERIAL" reboot
  exit 0
fi

# --- 1. Report -------------------------------------------------------------
echo
echo "== Current state"
echo "   home resolves to : $CUR"
echo "   stock launcher   : $(sh_ pm list packages -d | grep -q "^package:$GTV$" \
                              && echo 'DISABLED' || echo 'enabled')"
echo "   launcher-capable apps:"
home_list | sed 's/^/     /'

if [ -z "$FIX_PKG" ]; then
  echo
  echo "Diagnosis only — nothing changed. To make an app the home screen:"
  echo "   $0 $IP --fix <package>            (e.g. de.ozerov.fully)"
  echo "   $0 $IP --fix <package> --exclusive   (also disables the stock launcher)"
  exit 0
fi

# --- 2. Sanity-check the target -------------------------------------------
echo
echo "== Target: $FIX_PKG"
if ! installed "$FIX_PKG"; then
  echo "   NOT INSTALLED. Install it first, then re-run."
  exit 1
fi
VER=$(sh_ dumpsys package "$FIX_PKG" | grep -m1 versionName | sed 's/.*=//')
echo "   version: $VER"
case "$VER" in
  *-play*)
    echo
    echo "!! This is a PLAY STORE build. Google forbids Play apps from replacing"
    echo "   the home screen, so its launcher capability is compiled out and no"
    echo "   amount of adb will make it the launcher."
    echo "   Fix: uninstall it and install the vendor's own APK, e.g."
    echo "     adb uninstall $FIX_PKG"
    echo "     # Fully Kiosk: https://www.fully-kiosk.com/  (Download APK)"
    echo "     adb install <that.apk>"
    exit 1 ;;
esac

# --- 3. Make it launcher-capable if the component ships disabled -----------
TARGET_HOME=$(home_list | grep "^$FIX_PKG/" | head -1 || true)
if [ -z "$TARGET_HOME" ]; then
  echo "   not currently launcher-capable — looking for a disabled home component"
  # Apps like Fully Kiosk ship their launcher activity as a DISABLED alias that
  # an in-app toggle enables. Enumerate the package's components and try the
  # plausible ones; enabling an activity is harmless if it turns out wrong.
  CANDIDATES=$(sh_ dumpsys package "$FIX_PKG" \
    | grep -oE "$FIX_PKG/[A-Za-z0-9_.\$]+" | sort -u \
    | grep -iE 'home|launch|kiosk|main' || true)
  for c in $CANDIDATES; do
    shq_ pm enable "$c"
    if home_list | grep -q "^$FIX_PKG/"; then
      echo "   enabled hidden launcher component: $c"
      break
    fi
  done
  TARGET_HOME=$(home_list | grep "^$FIX_PKG/" | head -1 || true)
fi

if [ -z "$TARGET_HOME" ]; then
  echo
  echo "!! $FIX_PKG declares no usable home activity, even after trying to"
  echo "   enable hidden components. It cannot be the launcher on this device."
  echo
  echo "   Options:"
  echo "   1. Open the app on the TV and turn ON its own 'set as home app' /"
  echo "      'kiosk mode' / 'launcher' setting, then re-run this script."
  echo "      (Fully Kiosk: Settings -> Device Management.)"
  echo "   2. Use a launcher that CAN host it: install Projectivy Launcher,"
  echo "      make that home, and set its 'launch app at startup' to your app."
  echo "   3. Use a device built for signage (Amazon Signage Stick) which boots"
  echo "      into its player with none of this."
  exit 1
fi
echo "   launcher activity: $TARGET_HOME"

# --- 4. Set home and VERIFY ------------------------------------------------
echo
echo "== Setting home to $TARGET_HOME"
shq_ cmd package set-home-activity "$TARGET_HOME"
sleep 1
NOW=$(home_now)
echo "   home is now: $NOW"

case "$NOW" in
  "$FIX_PKG"/*) echo "   verified." ;;
  *)
    echo "   NOT verified — the system still prefers $NOW."
    if [ "$EXCLUSIVE" = 0 ]; then
      echo "   Re-run with --exclusive to disable the stock launcher so there is"
      echo "   no competition."
      exit 1
    fi ;;
esac

# --- 5. Optionally remove the competition ---------------------------------
if [ "$EXCLUSIVE" = 1 ]; then
  echo
  echo "== Disabling the stock launcher (Live/Apps rows included)"
  shq_ pm disable-user --user 0 "$GTV"
  sleep 1
  NOW=$(home_now)
  echo "   home is now: $NOW"
  if ! usable_home "$NOW" || [ "${NOW#"$FIX_PKG"/}" = "$NOW" ]; then
    echo "   That is not $FIX_PKG — rolling back so the box stays usable."
    shq_ pm enable --user 0 "$GTV"
    shq_ cmd package set-home-activity "$GTV/.home.HomeActivity"
    echo "   restored: $(home_now)"
    exit 1
  fi
  echo "   verified — $FIX_PKG is the only home app."
fi

# --- 6. Kiosk hygiene ------------------------------------------------------
echo
echo "== Display never sleeps"
shq_ settings put secure sleep_timeout -1
shq_ settings put secure screensaver_enabled 0
shq_ settings put global stay_on_while_plugged_in 3
shq_ appops set --user 0 "$FIX_PKG" SYSTEM_ALERT_WINDOW allow
shq_ dumpsys deviceidle whitelist "+$FIX_PKG"

echo
echo "== Rebooting to prove the boot path"
adb -s "$SERIAL" reboot
echo
echo "Expect: boot -> $FIX_PKG within ~60-90s, with no remote touched."
echo "If the app comes up blank, its start URL isn't set yet — Fully Kiosk:"
echo "  enable Settings -> Remote Administration, then from this PC open"
echo "  http://$IP:2323 and paste the screen URL there."
echo
echo "Undo everything:  $0 $IP --recover"
