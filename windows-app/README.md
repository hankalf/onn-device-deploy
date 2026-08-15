# onn Wall Display Deployer (Windows app)

A point-and-click Windows app with one job: make an **onn / Google TV box**
(HD stick, 4K, 4K Plus, 4K Pro — any Android TV device) **come up in AbleSign
after every reboot and power cut**, with nobody touching a remote. It also
strips the streaming apps, and diagnoses and repairs errors on its own.

**There is no URL to enter.** AbleSign pulls whatever screen your AbleSign
cloud account assigns to that device — this app only handles the device side:
getting AbleSign to start, every time.

No install needed on the PC — it even fetches its own copy of `adb` on first
run.

---

## Before you begin — one-time checklist

### On the PC (2 minutes)

1. Download this repo as a ZIP (green **Code** button → Download ZIP) and
   extract it anywhere, e.g. the Desktop.
2. That's it. Windows 10/11 has PowerShell built in, and the app downloads
   `adb` by itself on first run. (If your network blocks downloads, grab
   [platform-tools](https://developer.android.com/tools/releases/platform-tools)
   yourself and unzip it into the `windows-app` folder so `platform-tools\adb.exe`
   sits next to the app.)

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
4. The app runs the whole sequence, narrating each step. Two interactions may
   come up on the first deploy:
   - If **Projectivy Launcher** (the free launcher that starts AbleSign at
     boot) isn't installed yet, the app opens its Play Store page on the TV —
     install it with the remote, then press **DEPLOY** again.
   - At the end, one setting only the remote can set:
     **Projectivy → Settings → General → launch app at startup → AbleSign.**
5. The box reboots. Within ~60–90 seconds it lands in AbleSign, showing
   whatever your AbleSign account assigns it — no remote touched. Pull the
   power and plug it back in to confirm it does the same after an outage.

Every later deploy of the same box (or another box that already has Projectivy
and AbleSign) is fully automatic.

**Undo (back to stock):** the app's *Undo* button restores the Google TV home
and reinstalls the removed apps. **Check only** reports the device's state
without changing anything.

## Every option in the app

| Control | What it does |
|---|---|
| **Device list / Rescan** | Finds boxes on USB **and** network. onn sticks only answer over the network — the list says so when nothing is found. |
| **IP + Connect** | Connects over the network; retries stale sessions and explains `unauthorized` (the prompt is on the TV). |
| **AbleSign** | The default. Hosts it with Projectivy so it starts on every boot, and enables the accessibility service that unlocks that feature. Content comes from the AbleSign cloud — nothing to configure here. |
| **Fully Kiosk** | Alternative, for showing a plain URL instead. Kiosk/launcher mode needs a paid PLUS license per device; the app warns first, and asks for the URL only if you pick this. |
| **Remove all streaming apps** | Strips 22 packages (Netflix, YouTube, Disney+, Apple TV, ESPN, Instagram, assistant, screensavers…), reversibly. |
| **Disable the Google TV home screen** | Removes the Live/Apps rows so nothing competes for boot — only after the replacement verifies. |
| **Try device-owner** | Strongest possible kiosk lock. Only works on a box where the Google account was skipped at setup, so it's off by default. |
| **DEPLOY** | Shows Requirements, then runs the whole sequence and reboots to prove it. |
| **Undo** | Back to stock: home restored, apps reinstalled. |
| **Check only** | Full state report, changes nothing. |
| **Requirements** | The pre-flight checklist on demand. |
| **Screenshot** | Grabs what's on the TV right now and opens it — useful for "is it blank or is it not launching?". |
| **Install APK…** | Sideload any APK (AbleSign, Projectivy, Fully) without the Play Store. |
| **Reboot box** | Power-cycle test without walking to the TV. |
| **Open AbleSign install page on TV** | Jumps the TV straight to the Play Store page. |

## Everything it repairs on its own

- Missing `adb` (downloads platform-tools), stale/offline sessions, unauthorized prompts
- A box left with **no working home screen** — repaired before anything else, every run
- **Play Store builds** of Fully Kiosk, whose launcher capability Google strips out
- Launcher activities that ship **disabled** behind an in-app toggle
- `set-home-activity` being ignored on Android 10+ — claims the **HOME role** instead
- The **setup wizard** outranking third-party launchers once the stock home is gone
- Display sleep, screensaver, and battery throttling of the player

## What the app handles by itself

- Downloads/locates `adb`; finds devices over USB **and** network
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
