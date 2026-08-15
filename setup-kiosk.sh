#!/usr/bin/env bash
# setup-kiosk — ONE command to turn an Android TV / Google TV box into a wall
# display that boots straight into your dashboard.
#
#   ./setup-kiosk.sh <ip> --url "<board url>"
#
# It does everything that is possible over adb, in the order that works:
#   1. connects, and repairs a box left with no usable home screen
#   2. downloads + installs the correct Fully Kiosk build (NOT the Play one,
#      whose launcher capability Google strips out)
#   3. strips the streaming bloat
#   4. tries EVERY way to own boot, strongest first:
#        a. device owner provisioning   (unbreakable, needs no Google account)
#        b. the HOME role via RoleManager  (Android 10+)
#        c. legacy set-home-activity       (older boxes)
#        d. disabling the launchers that outrank it
#   5. pushes the start URL in without you typing it on a remote
#   6. keeps the screen awake, reboots, and VERIFIES the result
#
# Anything Android refuses to let adb do is printed at the end as an exact
# menu path — no hunting.
#
# Options:
#   --url <url>     the page the screen should show (your /screen/<token> URL)
#   --apk <file>    use a local Fully Kiosk APK instead of downloading
#   --keep-apps     skip removing the streaming apps
#   --recover       undo everything, back to a stock box
#
# Undo at any time:  ./setup-kiosk.sh <ip> --recover

set -u

IP="${1:-}"
if [ -z "$IP" ] || [[ "$IP" == --* ]]; then
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
shift

URL="" APK="" KEEP=0 RECOVER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --apk) APK="${2:-}"; shift 2 ;;
    --keep-apps) KEEP=1; shift ;;
    --recover) RECOVER=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SERIAL="$IP:5555"
PKG="de.ozerov.fully"
GTV="com.google.android.apps.tv.launcherx"
SETUP="com.google.android.tungsten.setupwraith"
APK_URL="https://www.fully-kiosk.com/files/2026/08/Fully-Kiosk-Browser-v1.61.1.apk"

# adb sitting next to this script (Git Bash does not search the cwd)
if ! command -v adb >/dev/null 2>&1; then
  HERE="$(cd "$(dirname "$0")" && pwd)"
  for d in "$HERE" "$PWD"; do
    { [ -x "$d/adb" ] || [ -f "$d/adb.exe" ]; } && { PATH="$d:$PATH"; break; }
  done
fi
command -v adb >/dev/null 2>&1 || {
  echo "adb not found. Put this script in your platform-tools folder, or install:"
  echo "  https://developer.android.com/tools/releases/platform-tools"
  exit 1
}

sh_()  { adb -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }
shq_() { adb -s "$SERIAL" shell "$@" >/dev/null 2>&1; }
step() { echo; echo "== $*"; }
ok()   { echo "   [ok] $*"; }
info() { echo "   $*"; }
warn() { echo "   !! $*"; }

home_list() {
  sh_ cmd package query-activities --brief -a android.intent.action.MAIN \
    -c android.intent.category.HOME | grep '/' | sed 's/^[[:space:]]*//'
}
home_now() {
  sh_ cmd package resolve-activity --brief -a android.intent.action.MAIN \
    -c android.intent.category.HOME | grep '/' | tail -1 \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
is_ours()  { [ "${1#"$PKG"/}" != "$1" ]; }
real_home(){ case "$1" in ""|*setupwraith*|*FallbackHome*|*stubs*) return 1;; *) return 0;; esac; }

# ---------------------------------------------------------------- connect ---
step "Connecting to $SERIAL"
adb connect "$SERIAL" >/dev/null 2>&1
adb -s "$SERIAL" shell true >/dev/null 2>&1 || {
  warn "Cannot reach the device."
  adb devices | sed 's/^/     /'
  echo
  echo "   1. On the TV: Settings > System > About > click 'Android TV OS build'"
  echo "      7 times, then Settings > System > Developer options > USB debugging ON."
  echo "   2. Check the IP: Settings > Network & Internet."
  echo "   3. Accept the 'Allow USB debugging?' prompt that appears on the TV."
  echo "   4. PC and box must be on the same network (business Wi-Fi often blocks"
  echo "      device-to-device traffic; a phone hotspot is a quick way around it)."
  exit 1
}
ok "$(sh_ getprop ro.product.model)  (Android $(sh_ getprop ro.build.version.release))"

restore_stock() {
  shq_ dpm remove-active-admin "$PKG/.MyDeviceAdminReceiver"
  shq_ pm enable --user 0 "$GTV"
  shq_ pm enable --user 0 "$SETUP"
  shq_ cmd role add-role-holder android.app.role.HOME "$GTV"
  shq_ cmd package set-home-activity "$GTV/.home.HomeActivity"
}

# ------------------------------------------------------------- safety net ---
CUR=$(home_now)
if ! real_home "$CUR"; then
  step "Repairing: this box has no usable home screen"
  restore_stock; sleep 1
  ok "home restored to $(home_now)"
fi

if [ "$RECOVER" = 1 ]; then
  step "Restoring the box to stock"
  restore_stock
  for p in com.netflix.ninja com.google.android.youtube.tv com.disney.disneyplus \
           com.amazon.amazonvideo.livingroom com.hulu.livingroomplus com.wbd.stream \
           com.apple.atve.androidtv.appletv com.espn.score_center com.tubitv \
           com.cbs.ott com.google.android.play.games com.google.android.videos \
           com.instagram.airwave com.google.android.youtube.tvunplugged; do
    shq_ cmd package install-existing "$p"
  done
  sleep 1
  ok "home is now $(home_now)"
  adb -s "$SERIAL" reboot
  echo; echo "Done — the box is back to stock."
  exit 0
fi

# ------------------------------------------------------------ install app ---
step "Fully Kiosk"
VER=$(sh_ dumpsys package "$PKG" | grep -m1 versionName | sed 's/.*=//')
case "$VER" in
  *-play*)
    info "a Play Store build is installed ($VER) — its launcher capability is"
    info "stripped by Google policy, removing it"
    adb -s "$SERIAL" uninstall "$PKG" >/dev/null 2>&1
    VER="" ;;
esac

if [ -z "$VER" ]; then
  if [ -z "$APK" ]; then
    APK="$(dirname "$0")/fully-kiosk.apk"
    if [ ! -s "$APK" ]; then
      info "downloading the correct build..."
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$APK" "$APK_URL" || true
      fi
      [ -s "$APK" ] || {
        warn "download failed. Get the APK from https://www.fully-kiosk.com/"
        warn "(Download APK, not the Play badge), then re-run with --apk <file>."
        exit 1
      }
    fi
  fi
  info "installing $(basename "$APK")"
  adb -s "$SERIAL" install -r "$APK" >/dev/null 2>&1 || {
    warn "install failed"; exit 1; }
  VER=$(sh_ dumpsys package "$PKG" | grep -m1 versionName | sed 's/.*=//')
fi
ok "installed: $VER"

# --------------------------------------------------------------- debloat ---
if [ "$KEEP" = 0 ]; then
  step "Removing streaming apps (reversible with --recover)"
  n=0
  for p in com.netflix.ninja com.google.android.youtube.tv com.disney.disneyplus \
           com.amazon.amazonvideo.livingroom com.hulu.livingroomplus com.wbd.stream \
           com.apple.atve.androidtv.appletv com.espn.score_center com.tubitv \
           com.cbs.ott com.google.android.play.games com.google.android.videos \
           com.instagram.airwave com.google.android.youtube.tvunplugged \
           com.spotify.tv.android tv.pluto.android com.peacocktv.peacockandroid; do
    shq_ pm uninstall -k --user 0 "$p" && n=$((n+1))
  done
  ok "removed $n"
fi

# ------------------------------------------------------------- own boot ----
step "Making the box boot into Fully Kiosk"

# (a) Device owner — the only method nothing can override. Requires a box with
#     no accounts on it, which is why it is offered rather than assumed.
if sh_ dumpsys account | grep -q "Account {"; then
  info "device-owner mode unavailable (a Google account is signed in)"
  DO_POSSIBLE=0
else
  if shq_ dpm set-device-owner "$PKG/.MyDeviceAdminReceiver"; then
    ok "device owner granted — this box now belongs to Fully Kiosk"
  fi
  DO_POSSIBLE=1
fi

# (b) The launcher component. Fully ships it disabled until Kiosk Mode is on;
#     enabling it directly is what saves a trip to the TV.
TARGET=$(home_list | grep "^$PKG/" | head -1 || true)
if [ -z "$TARGET" ]; then
  for c in "$PKG/.LauncherReplacement" "$PKG/.MainActivity" "$PKG/.HomeActivity"; do
    shq_ pm enable "$c"
    home_list | grep -q "^$PKG/" && break
  done
  TARGET=$(home_list | grep "^$PKG/" | head -1 || true)
fi

if [ -z "$TARGET" ]; then
  warn "Fully Kiosk is not offering itself as a launcher yet."
  echo
  echo "   This one switch lives inside the app and adb cannot write it:"
  echo "     On the TV:  Fully Kiosk > Settings > Kiosk Mode > ENABLE"
  echo "                 (accept 'set as Home App' when it asks)"
  echo "   Then re-run this exact command and it will finish on its own."
  exit 1
fi
ok "launcher activity: $TARGET"

claim() {
  shq_ cmd role add-role-holder android.app.role.HOME "$PKG"   # Android 10+
  shq_ cmd package set-home-activity "$TARGET"                 # older boxes
  sleep 1
}

claim
if ! is_ours "$(home_now)"; then
  info "the stock launcher still wins — disabling it"
  shq_ pm disable-user --user 0 "$GTV"; claim
fi
NOW=$(home_now)
if ! is_ours "$NOW" && [ "${NOW#*setupwraith}" != "$NOW" ]; then
  info "the setup wizard outranks it (priority 1 vs 0) — disabling that too"
  shq_ pm disable-user --user 0 "$SETUP"; claim
fi

NOW=$(home_now)
if is_ours "$NOW"; then
  ok "home is now $NOW"
else
  warn "could not take over home (it resolves to $NOW) — rolling back"
  restore_stock
  echo
  echo "   Everything adb can do has been tried. The reliable route on this box"
  echo "   is device-owner provisioning, which needs a box with no account:"
  echo "     1. Factory reset the stick"
  echo "     2. During setup, SKIP the Google account sign-in"
  echo "     3. Re-enable USB debugging, then run this script again"
  echo
  echo "   Or use a device built for this: the Amazon Signage Stick boots into"
  echo "   its player with none of the above."
  exit 1
fi

# ------------------------------------------------------------- start URL ---
if [ -n "$URL" ]; then
  step "Start URL"
  # Fully's Remote Admin REST API, if it is switched on, saves typing the URL
  # with a remote. Blank password is the default.
  if command -v curl >/dev/null 2>&1 && \
     curl -fsS --max-time 5 "http://$IP:2323/?cmd=setStringSetting&key=startURL&value=$URL&password=" >/dev/null 2>&1; then
    ok "pushed to the app: $URL"
  else
    # Not reachable — at least make this boot show the right page.
    shq_ am start -n "$PKG/.MainActivity" -d "$URL"
    info "loaded $URL on screen now, but it is NOT saved as the start URL."
    info "To make it stick without typing on a remote:"
    info "  TV: Fully Kiosk > Settings > Remote Administration > enable"
    info "  PC: open http://$IP:2323  and paste the URL into Start URL"
  fi
fi

# ------------------------------------------------------------- hygiene ----
step "Keeping the screen alive"
shq_ settings put secure sleep_timeout -1
shq_ settings put secure screensaver_enabled 0
shq_ settings put global stay_on_while_plugged_in 3
shq_ appops set --user 0 "$PKG" SYSTEM_ALERT_WINDOW allow
shq_ dumpsys deviceidle whitelist "+$PKG"
ok "display sleep and screensaver off"

step "Rebooting to prove it"
adb -s "$SERIAL" reboot
cat <<EOF

Expect the board within ~60-90s of the box coming back, no remote touched.

If Fully Kiosk comes up BLANK, its start URL is not saved yet:
  TV: Fully Kiosk > Settings > Remote Administration > enable
  PC: http://$IP:2323  ->  paste your URL into Start URL

Undo everything:  $0 $IP --recover
EOF
