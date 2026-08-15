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
#   --list           Show installed non-system apps and every launcher-capable
#                    app, then exit. Run this first when unsure of anything.
#   --apk <file>     Install this signage-player APK directly (fastest).
#   --store <pkg>    Open this package's Play Store page on the TV instead
#                    (install it with the remote, then re-run the script).
#   --pkg <pkg>      Signage player package name. Strongly recommended —
#                    auto-detection is a fallback, not a guarantee.
#   --set-home       Make the signage player the launcher, if it is
#                    launcher-capable (the script checks and says so if not).
#                    Undo: --restore-home.
#   --restore-home   Put the Google TV launcher back.
#   --debloat        Remove streaming apps for the current user (reversible).
#   --minimal        Deeper strip on top of --debloat: assistant/search,
#                    screensavers, accessibility extras. Still reversible.
#   --kill-launcher  Disable the Google TV home (its Live/Apps/recommendation
#                    rows included). REFUSES to run unless another
#                    launcher-capable app is present to take over boot.
#                    Undo: --restore-launcher.
#   --restore-launcher  Re-enable the Google TV home.
#   --rebloat        Reinstall everything --debloat/--minimal removed.
#   --no-reboot      Skip the final reboot.
#   --dry-run        Print every adb command instead of running it.
#
# Typical full run:
#   ./onn-kiosk.sh 192.168.1.57 --list                      # look around first
#   ./onn-kiosk.sh 192.168.1.57 --debloat --minimal --pkg <player> --set-home
#
# Everything here is reversible without a factory reset: --rebloat,
# --restore-home and --restore-launcher undo the invasive steps.

set -u

IP="${1:-}"
if [ -z "$IP" ] || [[ "$IP" == --* ]]; then
  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
shift

APK="" STORE_PKG="" PKG="" SET_HOME=0 RESTORE_HOME=0 DEBLOAT=0 MINIMAL=0
KILL_LAUNCHER=0 RESTORE_LAUNCHER=0 REBLOAT=0 REBOOT=1 DRY=0 LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --apk) APK="$2"; shift 2 ;;
    --store) STORE_PKG="$2"; shift 2 ;;
    --pkg) PKG="$2"; shift 2 ;;
    --set-home) SET_HOME=1; shift ;;
    --restore-home) RESTORE_HOME=1; shift ;;
    --debloat) DEBLOAT=1; shift ;;
    --minimal) MINIMAL=1; shift ;;
    --kill-launcher) KILL_LAUNCHER=1; shift ;;
    --restore-launcher) RESTORE_LAUNCHER=1; shift ;;
    --rebloat) REBLOAT=1; shift ;;
    --no-reboot) REBOOT=0; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SERIAL="$IP:5555"
GTV_LAUNCHER="com.google.android.apps.tv.launcherx"

# Dry-run prints to stderr so the commands survive stdout redirects.
run() {
  if [ "$DRY" = 1 ]; then echo "DRY: adb -s $SERIAL $*" >&2; else adb -s "$SERIAL" "$@"; fi
}
shell() { run shell "$@"; }
shell_q() {
  if [ "$DRY" = 1 ]; then run shell "$@"; else adb -s "$SERIAL" shell "$@" >/dev/null 2>&1; fi
}
# Read-only queries that must run for real even in --dry-run.
qshell() { adb -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }

# The expected Windows setup is this script dropped into the unzipped
# platform-tools folder, and Git Bash does not search the current directory
# for commands — so look next to the script (and in the cwd) before giving up.
if ! command -v adb >/dev/null 2>&1; then
  HERE="$(cd "$(dirname "$0")" && pwd)"
  for d in "$HERE" "$PWD"; do
    if [ -x "$d/adb" ] || [ -f "$d/adb.exe" ]; then
      PATH="$d:$PATH"
      break
    fi
  done
fi
if ! command -v adb >/dev/null 2>&1; then
  echo "adb is not installed (or not on PATH)."
  echo
  echo "Install Android platform-tools and re-run:"
  echo "  https://developer.android.com/tools/releases/platform-tools"
  echo "  - Windows: unzip, then put this script in the unzipped"
  echo "    platform-tools folder and run it from Git Bash there."
  echo "  - macOS:   brew install android-platform-tools"
  echo "  - Linux:   apt install adb   (or your distro's equivalent)"
  exit 1
fi

echo "== Connecting to $SERIAL"
CONNECT_OUT=$(adb connect "$SERIAL" 2>&1)
if ! adb -s "$SERIAL" shell true >/dev/null 2>&1; then
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
echo "   model: $(qshell getprop ro.product.model)"

# Every app that can act as the HOME screen, one component per line.
home_capable() {
  qshell cmd package query-activities --brief -a android.intent.action.MAIN \
    -c android.intent.category.HOME | grep '/' | sed 's/^[[:space:]]*//'
}

if [ "$LIST" = 1 ]; then
  echo
  echo "== Installed non-system apps (candidates for --pkg)"
  qshell pm list packages -3 | sed 's/^package:/   /'
  echo
  echo "== Launcher-capable apps (candidates for --set-home / boot target)"
  home_capable | sed 's/^/   /'
  echo
  echo "Re-run with --pkg <package> to provision the right app."
  exit 0
fi

# ---------------------------------------------------------------------------
# Streaming apps a wall display has no use for. Removed per-user with data
# kept (-k), which is fully reversible — nothing is erased from the system
# image (that would need root). Core Google TV plumbing (Play services, Play
# Store, WebView, the stock launcher) is deliberately NOT on this list: the
# signage player needs WebView to render the board and Play for updates, and
# the stock launcher stays as the fallback unless --kill-launcher.
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

# Deeper strip for dedicated kiosks: voice/search, screensavers, accessibility
# extras. Safe to remove on a wall display; restore with --rebloat.
MINIMAL_EXTRA=(
  com.google.android.katniss
  com.google.android.backdrop
  com.android.dreams.basic
  com.google.android.marvin.talkback
  com.google.android.tv.remote.service
)

if [ "$REBLOAT" = 1 ]; then
  echo "== Reinstalling previously removed apps"
  for p in "${BLOAT[@]}" "${MINIMAL_EXTRA[@]}"; do
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

if [ "$MINIMAL" = 1 ]; then
  echo "== Deeper strip: assistant, screensavers, extras (reversible with --rebloat)"
  for p in "${MINIMAL_EXTRA[@]}"; do
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
# Identify the signage player. Auto-detection deliberately skips system
# packages (com.android.*, com.google.*) — a previous version matched the word
# "disabled" inside a system overlay's name and provisioned that instead.
# ---------------------------------------------------------------------------
if [ -z "$PKG" ]; then
  CANDIDATES=$(qshell pm list packages -3 | sed 's/^package://' \
    | grep -iE 'ablesign|fully|signage|kiosk|projectivy' || true)
  COUNT=$(printf '%s' "$CANDIDATES" | grep -c . || true)
  if [ "$COUNT" = 1 ]; then
    PKG="$CANDIDATES"
  elif [ "$COUNT" = 0 ]; then
    echo "Could not find a signage player among the installed (non-system) apps:"
    qshell pm list packages -3 | sed 's/^package:/   /'
    echo "Install one (--apk / --store), or name it with --pkg <package>."
    exit 1
  else
    echo "More than one candidate — pick one and re-run with --pkg:"
    printf '%s\n' "$CANDIDATES" | sed 's/^/   /'
    exit 1
  fi
fi
echo "== Signage player: $PKG"
if [ "$DRY" = 0 ] && ! qshell pm list packages | grep -q "^package:$PKG$"; then
  echo "   WARNING: $PKG is not installed on this device."
  exit 1
fi

echo "== Granting the permissions Google TV hides in missing menus"
shell_q appops set --user 0 "$PKG" SYSTEM_ALERT_WINDOW allow \
  && echo "   display over other apps: allowed"
shell_q dumpsys deviceidle whitelist "+$PKG" \
  && echo "   battery optimization: exempt"

echo "== Display never sleeps"
shell settings put secure sleep_timeout -1
shell settings put secure screensaver_enabled 0
shell settings put global stay_on_while_plugged_in 3

if [ "$SET_HOME" = 1 ]; then
  # set-home-activity only works on apps that declare a HOME activity. Resolve
  # the exact component and say so plainly when the app has none.
  HOME_COMP=$(home_capable | grep "^$PKG/" | head -1 || true)
  if [ -n "$HOME_COMP" ]; then
    echo "== Making $HOME_COMP the launcher (Home + every boot land in it)"
    shell cmd package set-home-activity "$HOME_COMP"
  else
    echo "== $PKG is NOT launcher-capable — cannot be set as home."
    echo "   Launcher-capable apps on this device:"
    home_capable | sed 's/^/     /'
    echo
    echo "   Your options, best first:"
    echo "   1. Enable the player's own start-on-boot setting (in its app"
    echo "      settings or web dashboard). The overlay permission it needs"
    echo "      was just granted, so it may simply work now."
    echo "   2. Install Projectivy Launcher (free, in the TV Play Store),"
    echo "      re-run with --pkg for your player plus --set-home-projectivy"
    echo "      style flow: set Projectivy as home, then in its settings pick"
    echo "      'App to launch on startup' -> your player."
    echo "   3. Use Fully Kiosk Browser as the player instead - it IS"
    echo "      launcher-capable, so --set-home works directly."
  fi
fi

if [ "$RESTORE_HOME" = 1 ]; then
  echo "== Restoring the Google TV launcher"
  shell cmd package set-home-activity "$GTV_LAUNCHER"
fi

if [ "$KILL_LAUNCHER" = 1 ]; then
  # Refuse to remove the only working home — that's a black screen at boot.
  OTHER_HOME=$(home_capable | grep -v "^$GTV_LAUNCHER/" \
    | grep -viE 'settings|setupwraith|frameworkpackagestubs' | head -1 || true)
  if [ -z "$OTHER_HOME" ] && [ "$DRY" = 0 ]; then
    echo "== NOT disabling the Google TV home: no other launcher-capable app"
    echo "   exists to take over boot. Install one first (e.g. Projectivy"
    echo "   Launcher or Fully Kiosk), then re-run --kill-launcher."
  else
    echo "== Disabling the Google TV home (Live/Apps rows included)"
    echo "   Boot will land in: ${OTHER_HOME:-<dry-run>}"
    shell pm disable-user --user 0 "$GTV_LAUNCHER"
  fi
fi

if [ "$RESTORE_LAUNCHER" = 1 ]; then
  echo "== Re-enabling the Google TV home"
  shell pm enable --user 0 "$GTV_LAUNCHER"
  shell cmd package set-home-activity "$GTV_LAUNCHER"
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
