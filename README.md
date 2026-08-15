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

## Boot problems: run kiosk-doctor first

`kiosk-doctor.sh` handles the whole "it won't boot into my kiosk app" mess in
one pass — diagnosing, fixing, and refusing to leave the box unusable:

```bash
./kiosk-doctor.sh <ip>                                   # report only
./kiosk-doctor.sh <ip> --fix de.ozerov.fully             # make it the home app
./kiosk-doctor.sh <ip> --fix de.ozerov.fully --exclusive # ...and disable the stock launcher
./kiosk-doctor.sh <ip> --recover                         # undo, back to stock
```

It knows the traps this repo was built around:

| Trap | What the doctor does |
|---|---|
| Device left with **no working home screen** | Detects it and re-enables the stock launcher **before anything else**, every run |
| **Play Store build** of the kiosk app (launcher capability stripped by Play policy) | Reads `versionName`, spots the `-play` suffix, tells you to install the vendor APK |
| App ships its **launcher activity disabled** behind an in-app toggle | Enumerates the package's components and enables the hidden one; if it can't, names the exact setting to flip |
| `set-home-activity` silently not taking on Android 10+ | Claims `android.app.role.HOME` via RoleManager (the modern path) and keeps the legacy call as a fallback |
| The **TV setup wizard** outranking third-party launchers (priority 1 vs 0) once the stock launcher is gone | Detects it grabbing home and disables it too |
| Disabling the stock launcher leaving nothing behind | Only disables **after** the replacement verifies, and **rolls back automatically** if home lands anywhere wrong |

## Making the board come up at boot

This is the part that bites. Most **signage players declare no launcher
activity** — AbleSign does not — so they can never own boot themselves, and
their own "start on boot" settings are unreliable on Google TV.

### Recommended: Fully Kiosk Browser as the player

If the screen just shows a web page (a dashboard URL), Fully Kiosk is both the
player *and* launcher-capable — one app, no launcher chaining, no accessibility
service:

```bash
# APK from https://www.fully-kiosk.com/ (see the warning below)
./onn-kiosk.sh <ip> --apk fully-kiosk.apk --pkg de.ozerov.fully --set-home
```

> **Install the APK from fully-kiosk.com, NOT the Play Store version.** Play
> policy forbids apps from replacing the home app, so the Play build ships with
> the launcher capability stripped — `--set-home` then has nothing to point at
> and boot keeps landing on the Google TV home. A `versionName` ending in
> `-play` (`adb shell dumpsys package de.ozerov.fully | grep versionName`) is
> the tell; the script now flags it for you. Fix: `adb uninstall
> de.ozerov.fully`, then install the downloaded APK.

**One setting must be flipped on the TV first:** Fully Kiosk only registers as
a home app once **Kiosk Mode** is enabled (Settings -> Kiosk Mode). That is an
in-app preference, so adb cannot set it — without it the app is invisible to
Android as a launcher and `--set-home` has nothing to bind to.

Then set its **Start URL**. Rather than typing a long URL with a remote, turn on
**Settings -> Remote Administration** on the TV and paste it from your PC at
`http://<ip>:2323`. Also enable **Keep Screen On** and **Web Auto Reload**.

Boot chain: power on -> Fully Kiosk (it is the launcher) -> page. Done.

### Alternative: a real launcher starts your player

If you must keep a signage player that cannot be a launcher, hand boot to
Projectivy Launcher and have it start the player:

```bash
# 1. install Projectivy (free) — opens its Store page on the TV
./onn-kiosk.sh <ip> --store com.spocky.projengmenu
#    ...install it with the remote, and WAIT for it to finish...

# 2. hand boot to Projectivy, keeping the player as the permissions target
./onn-kiosk.sh <ip> --pkg tv.ablesign.app \
                    --home-pkg com.spocky.projengmenu --set-home

# 3. on the TV, once: Projectivy settings -> General -> launch app at startup
```

`--home-pkg` also enables Projectivy's **accessibility service**, which is how
it implements launch-at-startup. Its first-run wizard normally grants that and
is trivially skipped with a remote — without it, the startup option is missing
or does nothing. That single detail is the usual reason this route "silently
fails".

`--set-home` verifies what the system actually resolves as home afterwards, and
says to add `--kill-launcher` if the Google TV home is somehow still winning.

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
