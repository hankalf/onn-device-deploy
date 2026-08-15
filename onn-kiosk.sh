#!/usr/bin/env bash
# Provision an Android TV / Google TV box (onn and similar) as a dedicated
# wall-display kiosk over ADB: strip the streaming bloat, install the signage
# player, grant it the permissions Google TV hides, keep the screen awake, and
# (optionally) make the player the launcher so a power cycle boots straight
# into the board.
#
# One-time prep on each device (Android will not allow silent takeover):
#   1. Settings → System → About → click "Android TV OS build" 7 times
#   2. Settings → System → Developer options → enable USB debugging
#      (on these boxes that enables ADB over the network, port 5555)
#   3. Note the box's IP: Settings → Network & Internet
#   4. First connection pops an "Allow USB debugging?" prompt on the TV —
#      tick "Always allow" and accept.
#
# Usage:
#   ./onn-kiosk.sh <ip> [options]
#
# Options:
#   --apk <file>     Install this signage-player APK directly (fastest).
#   --store <pkg>    Open this package's Play Store page on the TV instead
#                    (install it with the remote, then re-run the script).
#   --pkg <pkg>      Signage player package name, if you already know it.
#                    Otherwise the script auto-detects anything matching
#                    "able|fully|signage|kiosk" after install.
#   --set-home       Make the signage player the launcher (Home button and
#                    every boot land in it). Undo: --restore-home.
#   --restore-home   Put the Google TV launcher back.
#   --debloat        Remove streaming apps for the current user (reversible).
#   --rebloat        Reinstall everything --debloat removed.
#   --no-reboot      Skip the final reboot.
#   --dry-run        Print every adb command instead of running it.
#
# Typical full run:
#   ./onn-kiosk.sh 192.168.1.57 --debloat --apk ablesign.apk --set-home
#
# Everything here is reversible without a factory reset: --rebloat and
# --restore-home undo the two invasive steps.

set -u

IP="${1:-}"
if [ -z "$IP" ] || [[ "$IP" == --* ]]; then
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
shift

APK="" STORE_PKG="" PKG="" SET_HOME=0 RESTORE_HOME=0 DEBLOAT=0 REBLOAT=0 REBOOT=1 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --store) STORE_PKG="$2"; shift 2 ;;
    --pkg) PKG="$2"; shift 2 ;;
    --set-home) SET_HOME=1; shift ;;
    --restore-home) RESTORE_HOME=1; shift ;;
    --debloat) DEBLOAT=1; shift ;;
    --rebloat) REBLOAT=1; shift ;;
    --no-reboot) REBOOT=0; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SERIAL="$IP:5555"
# Dry-run prints to stderr so the commands survive the script's own
# stdout redirects to /dev/null.
run() {
  if [ "$DRY" = 1 ]; then echo "DRY: adb -s $SERIAL $*" >&2; else adb -s "$SERIAL" "$@"; fi
}
shell() { run shell "$@"; }
# Like shell, but quiet on real runs — in dry-run the command still prints.
shell_q() {
  if [ "$DRY" = 1 ]; then run shell "$@"; else adb -s "$SERIAL" shell "$@" >/dev/null 2>&1; fi
}

# adb missing is the most common first-run failure — say so plainly instead of
# letting it masquerade as an unreachable device.
if ! command -v adb >/dev/null 2>&1; then
  echo "adb is not installed (or not on PATH)."
  echo
  echo "Install Android platform-tools and re-run:"
  echo "  https://developer.android.com/tools/releases/platform-tools"
  echo "  - Windows: unzip, then run this script from Git Bash with the"
  echo "    unzipped folder on PATH (or cd into it)."
  echo "  - macOS:   brew install android-platform-tools"
  echo "  - Linux:   apt install adb   (or your distro's equivalent)"
  exit 1
fi

echo "== Connecting to $SERIAL"
CONNECT_OUT=$(adb connect "$SERIAL" 2>&1)
if ! adb -s "$SERIAL" shell true >/dev/null 2>&1 && [ "$DRY" = 0 ]; then
  echo "Cannot reach the device."
  echo "   adb connect said: $CONNECT_OUT"
  echo "   adb devices sees:"
  adb devices | sed 's/^/     /'
  echo
  STATE=$(adb devices | awk -v s="$SERIAL" '$1==s {print $2}')
  case "$STATE" in
    unauthorized)
      echo "-> The 'Allow USB debugging?' prompt is on the TV right now."
      echo "   Accept it (tick 'Always allow'), then re-run." ;;
    offline)
      echo "-> Stale session. Run: adb disconnect $SERIAL   then re-run." ;;
    *)
      echo "-> Nothing answered on $SERIAL. Check, in order:"
      echo "   1. USB debugging is ON (Settings -> System -> Developer options)."
      echo "   2. The IP is current (Settings -> Network & Internet on the box)."
      echo "   3. Your PC and the box are on the SAME network - business Wi-Fi"
      echo "      often blocks device-to-device traffic (AP isolation). If so,"
      echo "      join both to a phone hotspot, provision, then switch back." ;;
  esac
  exit 1
fi
[ "$DRY" = 0 ] && echo "   model: $(adb -s "$SERIAL" shell getprop ro.product.model | tr -d '\r')"

# ---------------------------------------------------------------------------
# Streaming apps a wall display has no use for. Removed per-user with data
# kept (-k), which is fully reversible — nothing is erased from the system
# image (that would need root). Core Google TV plumbing (Play services, Play
# Store, WebView, the stock launcher) is deliberately NOT on this list: the
# signage player needs WebView to render the board and Play for updates, and
# the stock launcher stays as the fallback if the player is ever removed.
# ---------------------------------------------------------------------------
BLOAT=(
  com.netflix.ninja
  com.amazon.amazonvideo.livingroom
  com.disney.disneyplus
  com.wbd.stream
  com.hbo.hbonow
  com.hulu.livingroomplus
  com.spotify.tv.android
  com.google.android.play.games
  com.google.android.videos
  com.google.android.youtube.tv
  com.google.android.youtube.tvmusic
  com.peacocktv.peacockandroid
  com.cbs.ott
  tv.pluto.android
  com.tubitv
)

if [ "$REBLOAT" = 1 ]; then
  echo "== Reinstalling previously removed apps"
  for p in "${BLOAT[@]}"; do
    shell_q cmd package install-existing "$p" && echo "   restored $p"
  done
fi

if [ "$DEBLOAT" = 1 ]; then
  echo "== Removing streaming apps for this user (reversible with --rebloat)"
  for p in "${BLOAT[@]}"; do
    if shell_q pm uninstall -k --user 0 "$p"; then
      echo "   removed  $p"
    fi
  done
fi

if [ -n "$APK" ]; then
  echo "== Installing $APK"
  run install -r "$APK"
fi

if [ -n "$STORE_PKG" ]; then
  echo "== Opening the Play Store page on the TV — install it with the remote,"
  echo "   then re-run this script without --store to finish provisioning."
  shell_q am start -a android.intent.action.VIEW -d "market://details?id=$STORE_PKG"
  exit 0
fi

# ---------------------------------------------------------------------------
# Find the signage player if not named explicitly.
# ---------------------------------------------------------------------------
if [ -z "$PKG" ]; then
  if [ "$DRY" = 1 ]; then
    PKG="<signage-player>"
  else
    PKG=$(adb -s "$SERIAL" shell pm list packages | tr -d '\r' | sed 's/^package://' \
          | grep -iE 'able|fully|signage|kiosk' | grep -v 'com.google' | head -1)
    if [ -z "$PKG" ]; then
      echo "Could not find a signage player on the device. Install one first"
      echo "(--apk file.apk, or --store <package> to open its Play Store page),"
      echo "or name it with --pkg <package>."
      exit 1
    fi
  fi
fi
echo "== Signage player: ${PKG:-<dry-run>}"

echo "== Granting the permissions Google TV hides in missing menus"
# "Display over other apps" — required for the player's own launch-on-boot.
shell_q appops set --user 0 "$PKG" SYSTEM_ALERT_WINDOW allow \
  && echo "   display over other apps: allowed"
# Let it ignore battery/App-standby throttling so long-running playback isn't killed.
shell_q dumpsys deviceidle whitelist "+$PKG" \
  && echo "   battery optimization: exempt"

echo "== Display never sleeps"
shell settings put secure sleep_timeout -1        # "Turn off display" → Never
shell settings put secure screensaver_enabled 0   # no ambient mode
shell settings put global stay_on_while_plugged_in 3

if [ "$SET_HOME" = 1 ]; then
  echo "== Making $PKG the launcher (Home + every boot land in it)"
  shell cmd package set-home-activity "$PKG"
fi
if [ "$RESTORE_HOME" = 1 ]; then
  echo "== Restoring the Google TV launcher"
  shell cmd package set-home-activity com.google.android.apps.tv.launcherx
fi

if [ "$REBOOT" = 1 ]; then
  echo "== Rebooting to prove the boot path"
  run reboot
  echo "   The board should be on screen within ~60–90s of the box coming back."
else
  echo "== Done (reboot skipped)"
fi

echo
echo "Register/check this screen in Admin → Screen Fleet — it should show"
echo "'online now' once the player has loaded its display URL."
