# onn-device-deploy

Turn a cheap Android TV / Google TV box (onn Full HD, onn 4K, and similar) into
a dedicated wall-display kiosk with one command: strip the streaming bloat,
install a signage player (AbleSign, Fully Kiosk, …), grant the permissions
Google TV hides behind missing menus, keep the display awake, and optionally
make the player the launcher — so a power cycle boots straight back onto the
dashboard with nobody touching a remote.

Built for driving [worker-dashboard](https://github.com/hankalf/worker-dashboard)
wall screens, but nothing in it is specific to that app — it kiosks any web
signage player.

## What it does

| Step | How |
|---|---|
| Remove streaming apps (Netflix, YouTube, Disney+, …) | `pm uninstall -k --user 0` — per-user, **reversible**, nothing erased from the system image |
| Install the signage player | `adb install` from an APK, or opens its Play Store page on the TV |
| "Display over other apps" (needed for launch-on-boot, missing from many onn settings menus) | granted directly via `appops` |
| Exempt the player from battery/app-standby throttling | `deviceidle whitelist` |
| Display never sleeps | `sleep_timeout -1`, screensaver off, stay-on |
| Boot straight into the player *(optional)* | makes it the launcher via `cmd package set-home-activity` |

Everything is reversible without a factory reset: `--rebloat` restores the
removed apps, `--restore-home` puts the Google TV launcher back.

## One-time prep on each device

Android does not allow silent takeover of a fresh device — three clicks on the
TV first:

1. **Settings → System → About** → click **Android TV OS build** 7 times
   ("You are now a developer").
2. **Settings → System → Developer options** → enable **USB debugging**
   (on these boxes that enables ADB over the network).
3. Note the IP under **Settings → Network & Internet**.

The first connection pops *"Allow USB debugging?"* on the TV — tick **Always
allow** and accept.

## Usage

Needs `adb` on your PC ([platform-tools](https://developer.android.com/tools/releases/platform-tools)).

```bash
# See every option
./onn-kiosk.sh

# ALWAYS start here: see what's installed and what can act as launcher
./onn-kiosk.sh 192.168.1.57 --list

# Full provisioning, naming the player explicitly (recommended)
./onn-kiosk.sh 192.168.1.57 --debloat --pkg <player-package> --set-home

# Bare-minimum kiosk: deeper strip + disable the Google TV home entirely
# (only allowed once another launcher-capable app can take over boot)
./onn-kiosk.sh 192.168.1.57 --debloat --minimal --pkg <player> --kill-launcher

# Rehearse without touching the device
./onn-kiosk.sh 192.168.1.57 --debloat --set-home --dry-run

# Undo everything
./onn-kiosk.sh 192.168.1.57 --rebloat --restore-home --restore-launcher
```

Auto-detection only considers **non-system** apps matching
`ablesign|fully|signage|kiosk|projectivy`, and stops to ask when more than one
matches — but `--pkg` is always the safer choice. Use `--list` to find the
right name.

## If the player can't be the launcher

Most signage players — AbleSign included — declare no launcher activity, so
they can never own boot themselves. `--set-home` detects this and says so.
The reliable fix is to hand boot to a real launcher and let *it* start the
player:

```bash
# 1. install Projectivy Launcher (free) — opens its Store page on the TV
./onn-kiosk.sh <ip> --store com.spocky.projengmenu
#    ...install it with the remote, and WAIT for it to finish...

# 2. hand boot to Projectivy, keeping the player as the permissions target
./onn-kiosk.sh <ip> --pkg tv.ablesign.app \
                    --home-pkg com.spocky.projengmenu --set-home

# 3. on the TV, once: Projectivy settings -> launch at startup -> AbleSign
```

The script verifies what the system actually resolves as home afterwards, and
tells you to add `--kill-launcher` if the Google TV home is somehow still
winning.

**Why step 3 needs step 2's accessibility grant:** Projectivy implements
"launch app at startup" through an accessibility service, which is normally
granted by its first-run wizard — trivially skipped with a TV remote, and
without it the startup option does nothing. `--home-pkg` enables that service
over ADB (appending to the existing list, never replacing it), so the option
actually works when you set it.

Other options: enable the player's own start-on-boot (the overlay permission
it needs is granted by this script, which is usually the missing piece), or
use **Fully Kiosk Browser** as the player — it is launcher-capable, so
`--set-home` works on it directly.

## Notes

- **`--set-home` makes the player the launcher**: the Home button and every
  boot land in it. For a dedicated wall stick that is exactly right — and it
  sidesteps the launch-on-boot permission entirely on firmware that refuses to
  honor it. The stock launcher stays installed as a fallback.
- **What is deliberately kept**: Play services, Play Store, WebView, and the
  stock launcher. The signage player renders the dashboard in WebView and
  updates through Play — removing those breaks the kiosk.
- **Without root you cannot erase system apps** — `--debloat` removes them for
  the user, which stops them running and taking updates. That is the same
  thing "debloat" tools do.
- **onn Full HD (100133520) caveat**: it outputs 1080p max. On a 4K panel the
  TV upscales and text goes soft — no software fixes that. Put HD sticks on
  1080p TVs and use 4K devices on 4K panels.
- Provision several boxes by looping:
  `for ip in 192.168.1.57 192.168.1.58; do ./onn-kiosk.sh $ip --debloat --set-home; done`

## Only ever run this on devices you own

It is a provisioning tool for your own hardware fleet. ADB over the network
should live on a trusted LAN; turn Developer options back off if a device
leaves kiosk duty.
