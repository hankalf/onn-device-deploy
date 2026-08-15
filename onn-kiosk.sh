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
#   --home-pkg <pkg> Which app should own boot, when that is NOT the signage
#                    player (the usual case — most signage players declare no
#                    launcher activity). Point this at a real launcher such as
#                    Projectivy (com.spocky.projengmenu) and set that launcher's
#                    own "launch at startup" to your player.
#   --set-home       Make --home-pkg (or the signage player) the launcher, if it
#                    is launcher-capable — the script checks, sets it, and then
#                    verifies what the system actually resolves. Undo:
#                    --restore-home.
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

APK="" STORE_PKG="" PKG="" HOME_PKG="" SET_HOME=0 RESTORE_HOME=0 DEBLOAT=0 MINIMAL=0
KILL_LAUNCHER=0 RESTORE_LAUNCHER=0 REBLOAT=0 REBOOT=1 DRY=0 LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --apk) APK="$2"; shift 2 ;;
    --store) STORE_PKG="$2"; shift 2 ;;
    --pkg) PKG="$2"; shift 2 ;;
    --home-pkg) HOME_PKG="$2"; shift 2 ;;
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

# Enable a package's accessibility service. Projectivy needs this for its
# "launch app at startup" feature (it is granted by its first-run wizard, which
# is easy to skip with a remote — and without it the option does nothing).
enable_accessibility() {
  local pkg="$1"
  local svc
  svc=$(qshell cmd package query-services --brief \
          -a android.accessibilityservice.AccessibilityService \
        | grep "^ *$pkg/" | sed 's/^[[:space:]]*//' | head -1)
  if [ -z "$svc" ]; then
    echo "   $pkg declares no accessibility service (nothing to enable)"
    return 0
  fi
  local existing
  existing=$(qshell settings get secure enabled_accessibility_services)
  case "$existing" in
    *"$svc"*) echo "   accessibility already enabled for $pkg" ; return 0 ;;
  esac
  # Append rather than replace — clobbering the list would disable any other
  # accessibility service the device relies on.
  local merged="$svc"
  case "$existing" in
    ""|null) ;;
    *) merged="$existing:$svc" ;;
  esac
  shell_q settings put secure enabled_accessibility_services "$merged"
  shell_q settings put secure accessibility_enabled 1
  echo "   accessibility enabled: $svc"
}

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
  com.apple.atve.androidtv.appletv
  com.espn.score_center
  com.google.android.youtube.tvunplugged
  com.instagram.airwave
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
  # Which app should own boot: --home-pkg when given, else the signage player.
  # Signage players often declare no HOME activity, which is what --home-pkg
  # exists for: hand boot to a real launcher (Projectivy) and let it start the
  # player.
  TARGET="${HOME_PKG:-$PKG}"
  HOME_COMP=$(home_capable | grep "^$TARGET/" | head -1 || true)
  if [ -n "$HOME_COMP" ]; then
    echo "== Making $HOME_COMP the launcher (Home + every boot land in it)"
    shell cmd package set-home-activity "$HOME_COMP"
    # A launcher standing in for the player needs accessibility to be able to
    # start it at boot.
    if [ -n "$HOME_PKG" ]; then
      echo "   enabling $HOME_PKG's launch-at-startup capability"
      enable_accessibility "$HOME_PKG"
    fi
    if [ "$DRY" = 0 ]; then
      sleep 1
      NOW=$(qshell cmd package resolve-activity --brief -a android.intent.action.MAIN \
              -c android.intent.category.HOME | tail -1)
      echo "   home is now: $NOW"
      case "$NOW" in
        "$TARGET"/*) ;;
        *) echo "   WARNING: the system still resolves home elsewhere. Try"
           echo "   adding --kill-launcher to disable the Google TV home." ;;
      esac
      if [ -n "$HOME_PKG" ]; then
        echo
        echo "   ONE manual step left, on the TV with the remote:"
        echo "     $HOME_PKG settings -> General -> launch app at startup"
        echo "     -> $PKG"
      fi
    fi
  else
    echo "== $TARGET is NOT launcher-capable — cannot be set as home."
    # Play Store builds of Fully Kiosk have the launcher capability stripped
    # out (Play policy forbids replacing the home app), and the version string
    # is the only visible tell.
    TVER=$(qshell dumpsys package "$TARGET" | grep -m1 versionName | sed 's/.*=//')
    case "$TVER" in
      *-play*)
        echo "   Installed version is '$TVER' — a PLAY STORE build."
        echo "   Play policy strips the launcher capability from it. Install"
        echo "   the direct-download build instead:"
        echo "     adb uninstall $TARGET"
        echo "     # download the APK from the vendor's own site, then"
        echo "     $0 <ip> --apk <that.apk> --pkg $PKG --set-home"
        echo ;;
    esac
    echo "   Launcher-capable apps on this device:"
    home_capable | sed 's/^/     /'
    echo
    echo "   Your options, best first:"
    echo "   1. Install Projectivy Launcher (free, in the TV Play Store):"
    echo "        $0 <ip> --store com.spocky.projengmenu"
    echo "      then hand boot to it and let it start your player:"
    echo "        $0 <ip> --pkg $PKG --home-pkg com.spocky.projengmenu --set-home"
    echo "      finally, on the TV: Projectivy settings -> launch at startup"
    echo "      -> your player."
    echo "   2. Enable the player's own start-on-boot setting (app settings or"
    echo "      its web dashboard). The overlay permission it needs was just"
    echo "      granted, so it may work now."
    echo "   3. Use Fully Kiosk Browser as the player instead - it IS"
    echo "      launcher-capable, so --set-home works on it directly."
  fi
fi

if [ "$RESTORE_HOME" = 1 ]; then
  echo "== Restoring the Google TV launcher"
  shell cmd package set-home-activity "$GTV_LAUNCHER"
fi

if [ "$KILL_LAUNCHER" = 1 ]; then
  # Refuse to remove the only working home — that's a black screen at boot.
  if [ -n "$HOME_PKG" ]; then
    OTHER_HOME=$(home_capable | grep "^$HOME_PKG/" | head -1 || true)
  else
    OTHER_HOME=$(home_capable | grep -v "^$GTV_LAUNCHER/" \
      | grep -viE 'settings|setupwraith|frameworkpackagestubs' | head -1 || true)
  fi
  if [ -z "$OTHER_HOME" ] && [ "$DRY" = 0 ]; then
    echo "== NOT disabling the Google TV home: no other launcher-capable app"
    echo "   exists to take over boot. Install one first (e.g. Projectivy"
    echo "   Launcher or Fully Kiosk), then re-run --kill-launcher."
  else
    echo "== Disabling the Google TV home (Live/Apps rows included)"
    echo "   Boot will land in: ${OTHER_HOME:-<dry-run>}"
    shell pm disable-user --user 0 "$GTV_LAUNCHER"
    # Don't leave the boot target to fallback ordering — name it explicitly.
    [ -n "$OTHER_HOME" ] && shell cmd package set-home-activity "$OTHER_HOME"
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
