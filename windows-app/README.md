# onn Wall Display Deployer (Windows app)

A point-and-click Windows app with one job: make an **onn / Google TV box**
(HD stick, 4K, 4K Plus, 4K Pro — any Android TV device) **come up in AbleSign
after every reboot and power cut**, with nobody touching a remote. It also
strips the streaming apps, and diagnoses and repairs errors on its own.

**There is no URL to enter.** AbleSign pulls whatever screen your AbleSign
cloud account assigns to that device — this app only handles the device side:
getting AbleSign to start, every time.

No install needed on the PC. It finds an `adb` you already have — beside the
app, on your PATH, in an Android Studio SDK, Chocolatey/Scoop, or a
`platform-tools` folder in Downloads/Desktop/`C:\` — and only downloads one if
there genuinely isn't one, keeping it in `%LOCALAPPDATA%\OnnDeploy` so it never
downloads twice even after you re-extract this ZIP.

---

## Before you begin — one-time checklist

### On the PC (2 minutes)

1. Download this repo as a ZIP (green **Code** button → Download ZIP) and
   extract it anywhere, e.g. the Desktop.
2. That's it. Windows 10/11 has PowerShell built in, and the app sorts out
   `adb` itself — reusing one you already have, or downloading it once if you
   don't. (If your network blocks downloads, grab
   [platform-tools](https://developer.android.com/tools/releases/platform-tools)
   yourself and unzip it anywhere obvious — next to the app, or in Downloads,
   Desktop, or `C:\platform-tools` — and it will be found.)

### On each TV box (5 minutes, once per box)

1. **Finish Google TV's first-run setup** if the box is new (language, Wi-Fi —
   a Google account is fine to skip if it offers).
2. **Install AbleSign** from the Play Store on the box, open it once, and pair
   it with your AbleSign account so it shows your screen.
3. **Unlock Developer options:** Settings → System → About → click
   **Android TV OS build** 7 times ("You are now a developer").
4. **Enable debugging:** Settings → System → Developer options →
   **USB debugging** → On. On these boxes this enables debugging **over the
   network** — the USB port itself is power/OTG only and cannot talk to a PC,
   which is why the app connects by IP.
5. **Note the box's IP address:** Settings → Network & Internet → (your
   network). Better: give the box a **DHCP reservation** in your router (or a
   static IP on the box) so the address never changes.
6. Make sure the **PC and the box are on the same network**. Business Wi-Fi
   often has "AP/client isolation" that blocks device-to-device traffic — if
   the app can't connect and everything else is right, join both to a phone
   hotspot for the deploy, then put the box back on the normal network.

### Have ready

- The box's IP address.
- AbleSign already paired to your cloud account and showing the right screen
  when you open it manually — the app makes it *launch*, it doesn't configure
  what it plays.
- The TV remote, for two small prompts (below).

---

## The Requirements screen

Press **Requirements** any time, and it appears automatically every time you
press **DEPLOY** — so a box that was just factory reset can't get halfway
through before you discover a missing step. It lists the order to do things on
a fresh box, including which choice to make about the Google account (sign in
for the Play Store route; skip it only if you'll sideload APKs and want
device-owner mode).

## Deploying

1. Double-click **`OnnDeploy.bat`**.
2. Enter the box's IP → **Connect**. **Watch the TV:** the first connection
   pops *"Allow USB debugging?"* — accept it with the remote, tick **Always
   allow**. Press Connect again if it timed out waiting.
3. Leave **AbleSign** selected, press **DEPLOY**.
4. The app strips the streaming apps and sets up the **first free boot route**:
   AbleSign's own boot receiver. Then it reboots.
5. Press **Verify boot (reboot + report)**. It waits for the box and names what
   actually came up:
   - **AbleSign** → done, that box is finished and it cost nothing.
   - **anything else** → it records that route as failed for this box and
     immediately sets up the next free route, **Launch-On-Boot**, in the same
     press. If that app isn't on the box it opens its Store page on the TV and
     its [releases page](https://github.com/ITVlab/Launch-On-Boot/releases/latest)
     in your browser (it's an older app some boxes no longer list) — install it,
     press **DEPLOY**, then choose **AbleSign** inside it with the remote.
6. Press **Verify boot** again. Repeat until it reports AbleSign. Finally, pull
   the power and plug it back in to confirm it survives a real outage.

Each failed route is remembered per box, so **Auto** never spends another
reboot on something that has already been proved not to work here — and
**Check only** prints that memory. Once a box is set up, later deploys are
fully automatic.

**Undo (back to stock):** the app's *Undo* button restores the Google TV home
and reinstalls the removed apps. **Check only** reports the device's state
without changing anything.

## Every option in the app

| Control | What it does |
|---|---|
| **Device list / Rescan** | Finds boxes on USB **and** network. onn sticks only answer over the network — the list says so when nothing is found. |
| **IP + Connect** | Connects over the network; retries stale sessions and explains `unauthorized` (the prompt is on the TV). |
| **AbleSign** | The default. Content comes from the AbleSign cloud — nothing to configure here. How it's made to start at boot is the **Boot method** setting below. |
| **Fully Kiosk** | Alternative, for showing a plain URL instead. Kiosk/launcher mode needs a paid PLUS license per device; the app warns first, and asks for the URL only if you pick this. |
| **Remove all streaming apps** | Strips 22 packages (Netflix, YouTube, Disney+, Apple TV, ESPN, Instagram, assistant, screensavers…), reversibly. |
| **Disable the Google TV home screen** | Removes the Live/Apps rows so nothing competes for boot — only after the replacement verifies. |
| **Boot method** | Which way AbleSign is made to start. **Auto** (default) tries the free routes cheapest-first and remembers per box which ones have already failed, so it never wastes a reboot repeating one. Pick a specific route to override it: *AbleSign's own boot receiver*, *Launch-On-Boot* (free), or *Projectivy* (its boot-launch is Premium, $7.49 one-time, all devices). |
| **Try device-owner** | Strongest possible kiosk lock. Only works on a box where the Google account was skipped at setup, so it's off by default. |
| **DEPLOY** | Shows Requirements, then runs the whole sequence and reboots to prove it. |
| **Undo** | Back to stock: home restored, apps reinstalled. |
| **Check only** | Full state report, changes nothing. |
| **Requirements** | The pre-flight checklist on demand. |
| **Screenshot** | Grabs what's on the TV right now and opens it — useful for "is it blank or is it not launching?". |
| **Install APK…** | Sideload any APK (AbleSign, Projectivy, Fully) without the Play Store. |
| **Reboot box** | Power-cycle test without walking to the TV. |
| **Verify boot (reboot + report)** | The one that closes the loop: reboots, waits for the box, then names the app that actually came up. If it isn't AbleSign, it marks that route failed for this box and **moves on to the next free route in the same press** — no going back to DEPLOY to try again. |
| **Open AbleSign install page on TV** | Jumps the TV straight to the Play Store page. |

## What actually costs money (read this first)

Making a *non-launcher* app start at boot is the one thing Android walls off,
and every workaround has a price except one:

| Route | Cost | Notes |
|---|---|---|
| **AbleSign's own boot receiver** | **Free** | Only if AbleSign ships one — the app checks and tells you. Nothing else needed. |
| **[Launch-On-Boot](https://github.com/ITVlab/Launch-On-Boot)** | **Free** (MIT) | A tiny open-source app whose *only* job is starting a chosen app at boot — exactly the feature the launchers charge for. The app opens its Store page on the TV, and its [releases page](https://github.com/ITVlab/Launch-On-Boot/releases/latest) in your browser as a sideload fallback, since some boxes no longer list this older app. Then it clears the Doze/background limits that silently stop boot receivers. |
| **Projectivy Premium** | $7.49 one-time | Its "launch app at startup" is Premium. One purchase covers **every device on the same Google account**. |
| **Fully Kiosk PLUS** | Paid **per device** | Kiosk/launcher mode is licensed per box — the expensive option at scale. |
| **Amazon Signage Stick** | Hardware only | Boots into its signage player natively. No launcher tricks, no add-on licence. |

The app tries the free routes **first** and only mentions the paid ones if both
fail.

## Does AbleSign need Projectivy?

Only if AbleSign can't start itself — and the app now checks rather than
assuming. An Android app can start at boot in exactly two ways:

1. **Be the home app** — AbleSign declares no launcher activity, so it can't.
2. **Register a BOOT_COMPLETED receiver** — the app checks for one, enables it
   if it ships dormant, and clears the Doze / background / app-standby limits
   that silently stop boot receivers from firing.

Having that receiver isn't the same as it firing — Android has tightened
`BOOT_COMPLETED` a lot, and on some firmware it simply doesn't. So the app
doesn't *assume* the receiver worked: **Verify boot** checks, and if AbleSign
didn't come up it moves to free Launch-On-Boot on its own. Only when both free
routes have actually failed on that box does it say the remaining options cost
money — $7.49 once (Projectivy Premium) or per device (Fully Kiosk PLUS).

## If it still doesn't auto-launch

Press **Check only**. It prints the box's boot-route memory — which methods
have been tried here and which one is currently set up — plus the lines that
matter:

- **`news.androidtv.launchonboot` in the app list, but AbleSign still doesn't
  come up** → the app is installed but hasn't been *told* what to start. Open
  it on the TV and choose AbleSign; that choice lives in its private storage,
  so no PC tool can write it.
- **`com.spocky.projengmenu` missing from the app list** → Projectivy isn't
  installed (a factory reset wipes it). Set **Boot method** to Projectivy and
  press **DEPLOY**; it opens the Play Store page on the TV, then finishes on
  the next press.
- **home resolves to `...launcherx...`** → the boot takeover didn't hold.
  Press **DEPLOY** with *Disable the Google TV home screen* ticked. (This only
  applies to the launcher-hosted routes; the free routes leave home alone.)
- **home resolves to `...projengmenu...` but AbleSign never appears** → the
  only remaining step, and no PC tool can do it: on the TV,
  **Projectivy → Settings → General → launch app at startup → AbleSign**.

**Verify boot** distinguishes all of these for you in one press — and acts on
them instead of just reporting.

## Everything it repairs on its own

- `adb`: finds an existing one in ~10 usual places, checks it actually runs,
  and downloads platform-tools only if there is none; stale/offline sessions
  and unauthorized prompts
- A box left with **no working home screen** — repaired before anything else, every run
- **Play Store builds** of Fully Kiosk, whose launcher capability Google strips out
- Launcher activities that ship **disabled** behind an in-app toggle
- `set-home-activity` being ignored on Android 10+ — claims the **HOME role** instead
- The **setup wizard** outranking third-party launchers once the stock home is gone
- Display sleep, screensaver, and battery throttling of the player

## What the app handles by itself

- Locates `adb` (downloading it only as a last resort); finds devices over USB
  **and** network
- Reconnects stale sessions; explains `unauthorized` / unreachable states
- Repairs a box left with no working home screen (before doing anything else)
- Removes 20+ streaming/bloat apps (reversibly)
- Makes Projectivy the home app using the modern RoleManager path **and** the
  legacy one; disables the Google TV home and the setup wizard when they
  outrank it; verifies what the system actually resolves and rolls back if it
  can't win
- Enables Projectivy's accessibility service — the hidden requirement for its
  "launch app at startup" feature
- Disables display sleep and the screensaver

## Why not Fully Kiosk?

Its kiosk/launcher mode sits behind a paid PLUS license per device. The option
is still in the app if you buy licenses; AbleSign + Projectivy is free end to
end.
