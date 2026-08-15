# onn Wall Display Deployer (Windows app)

A point-and-click Windows app that turns any **onn / Google TV box** (HD stick,
4K, 4K Plus, 4K Pro — any Android TV device, really) into a dedicated wall
display: it removes the streaming apps and makes **AbleSign come up on every
reboot**, with all errors diagnosed and auto-repaired where possible.

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
- Your AbleSign account already showing the right screen when AbleSign opens.
- The TV remote, for two small prompts (below).

---

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
5. The box reboots. Within ~60–90 seconds it should land in AbleSign showing
   your screen — no remote touched.

Every later deploy of the same box (or another box that already has Projectivy
and AbleSign) is fully automatic.

**Undo (back to stock):** the app's *Undo* button restores the Google TV home
and reinstalls the removed apps. **Check only** reports the device's state
without changing anything.

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
