# OnnDeploy — makes an onn / Google TV box launch AbleSign on every reboot.
#
# Point it at a box, press Deploy, and it: installs its own copy of adb, finds
# the device over USB or the network, removes every streaming app, and sets the
# box to come up in AbleSign after any reboot or power cut. AbleSign pulls its
# own content from your AbleSign cloud account, so there is no URL to enter.
# Errors are diagnosed and repaired automatically where that is possible, and
# reported in plain language where it is not.
#
# Run via OnnDeploy.bat (which sets the execution policy for this process only).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'
$script:Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Tools   = Join-Path $Root 'platform-tools'
# Anything downloaded lands here, not beside the script: re-extracting the repo
# ZIP gives a brand-new folder, and nobody should pay for the download twice.
$script:Store   = Join-Path $env:LOCALAPPDATA 'OnnDeploy'
$script:AdbMemo = Join-Path $Store 'adb-path.txt'
$script:Adb     = $null
$script:Serial  = $null
$script:Cancel  = $false

# Packages stripped from a wall display. Removed per-user (-k, --user 0), which
# is reversible and needs no root; the system image is untouched.
$script:Bloat = @(
  'com.netflix.ninja','com.amazon.amazonvideo.livingroom','com.disney.disneyplus',
  'com.wbd.stream','com.hbo.hbonow','com.hulu.livingroomplus','com.spotify.tv.android',
  'com.google.android.play.games','com.google.android.videos','com.google.android.youtube.tv',
  'com.google.android.youtube.tvmusic','com.google.android.youtube.tvunplugged',
  'com.peacocktv.peacockandroid','com.cbs.ott','tv.pluto.android','com.tubitv',
  'com.apple.atve.androidtv.appletv','com.espn.score_center','com.instagram.airwave',
  'com.google.android.katniss','com.google.android.backdrop','com.android.dreams.basic'
)
$script:Gtv    = 'com.google.android.apps.tv.launcherx'
$script:Wizard = 'com.google.android.tungsten.setupwraith'
$script:Proj   = 'com.spocky.projengmenu'
# Launch-On-Boot (ITVlab, MIT-licensed, free on Play + F-Droid): its entire job
# is starting a chosen app at boot, which is the paid part of every launcher.
$script:Lob    = 'news.androidtv.launchonboot'
# Older project, so some TVs' Play Store no longer lists it - the releases page
# is the sideload fallback, downloaded on the PC and pushed with Install APK.
$script:LobApkPage = 'https://github.com/ITVlab/Launch-On-Boot/releases/latest'
$script:Fully  = 'de.ozerov.fully'
$script:FullyApkUrl = 'https://www.fully-kiosk.com/files/2026/08/Fully-Kiosk-Browser-v1.61.1.apk'

# ---------------------------------------------------------------- UI ---------
$form               = New-Object Windows.Forms.Form
$form.Text          = 'onn Wall Display Deployer  (all onn / Google TV devices)'
$form.Size          = New-Object Drawing.Size(860, 660)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object Drawing.Size(760, 560)

function New-Label($text, $x, $y, $w, $bold) {
  $l = New-Object Windows.Forms.Label
  $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y)
  $l.Size = New-Object Drawing.Size($w, 20)
  if ($bold) { $l.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold) }
  $form.Controls.Add($l); return $l
}

$null = New-Label '1. Device' 20 15 200 $true
$lblDev = New-Label 'Searching for devices...' 20 38 480 $false

$cboDev = New-Object Windows.Forms.ComboBox
$cboDev.Location = New-Object Drawing.Point(20, 60)
$cboDev.Size = New-Object Drawing.Size(480, 24)
$cboDev.DropDownStyle = 'DropDownList'
$form.Controls.Add($cboDev)

$btnScan = New-Object Windows.Forms.Button
$btnScan.Text = 'Rescan'; $btnScan.Location = New-Object Drawing.Point(510, 59)
$btnScan.Size = New-Object Drawing.Size(90, 26)
$form.Controls.Add($btnScan)

$null = New-Label 'or enter the box IP (Settings > Network on the TV):' 20 95 400 $false
$txtIp = New-Object Windows.Forms.TextBox
$txtIp.Location = New-Object Drawing.Point(20, 116); $txtIp.Size = New-Object Drawing.Size(200, 24)
$form.Controls.Add($txtIp)
$btnConnect = New-Object Windows.Forms.Button
$btnConnect.Text = 'Connect'; $btnConnect.Location = New-Object Drawing.Point(228, 115)
$btnConnect.Size = New-Object Drawing.Size(90, 26)
$form.Controls.Add($btnConnect)

$null = New-Label '2. Player' 20 155 200 $true
$null = New-Label 'AbleSign gets its content from your AbleSign cloud account - nothing to enter here.' 20 178 620 $false
$rbAble = New-Object Windows.Forms.RadioButton
$rbAble.Text = 'AbleSign  (free routes tried first: own boot receiver, then Launch-On-Boot)'
$rbAble.Location = New-Object Drawing.Point(20, 202); $rbAble.Size = New-Object Drawing.Size(420, 22)
$rbAble.Checked = $true
$form.Controls.Add($rbAble)
$rbFully = New-Object Windows.Forms.RadioButton
$rbFully.Text = 'Fully Kiosk  (kiosk/launcher mode needs a paid PLUS license)'
$rbFully.Location = New-Object Drawing.Point(20, 224); $rbFully.Size = New-Object Drawing.Size(400, 22)
$form.Controls.Add($rbFully)

$chkWipe = New-Object Windows.Forms.CheckBox
$chkWipe.Text = 'Remove all streaming apps'; $chkWipe.Checked = $true
$chkWipe.Location = New-Object Drawing.Point(440, 202); $chkWipe.Size = New-Object Drawing.Size(220, 22)
$form.Controls.Add($chkWipe)
$chkExcl = New-Object Windows.Forms.CheckBox
$chkExcl.Text = 'Disable the Google TV home screen'; $chkExcl.Checked = $true
$chkExcl.Location = New-Object Drawing.Point(440, 224); $chkExcl.Size = New-Object Drawing.Size(260, 22)
$form.Controls.Add($chkExcl)

$btnGo = New-Object Windows.Forms.Button
$btnGo.Text = 'DEPLOY'
$btnGo.Location = New-Object Drawing.Point(20, 280); $btnGo.Size = New-Object Drawing.Size(200, 40)
$btnGo.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$btnGo.BackColor = [Drawing.Color]::FromArgb(29, 78, 216); $btnGo.ForeColor = 'White'
$btnGo.FlatStyle = 'Flat'
$form.Controls.Add($btnGo)

$btnUndo = New-Object Windows.Forms.Button
$btnUndo.Text = 'Undo (back to stock)'
$btnUndo.Location = New-Object Drawing.Point(232, 280); $btnUndo.Size = New-Object Drawing.Size(160, 40)
$form.Controls.Add($btnUndo)

$btnCheck = New-Object Windows.Forms.Button
$btnCheck.Text = 'Check only'
$btnCheck.Location = New-Object Drawing.Point(404, 280); $btnCheck.Size = New-Object Drawing.Size(110, 40)
$form.Controls.Add($btnCheck)

$btnReq = New-Object Windows.Forms.Button
$btnReq.Text = 'Requirements'
$btnReq.Location = New-Object Drawing.Point(526, 280); $btnReq.Size = New-Object Drawing.Size(120, 40)
$form.Controls.Add($btnReq)

# Utility row - the smaller tools built up over this project
$btnShot = New-Object Windows.Forms.Button
$btnShot.Text = 'Screenshot'; $btnShot.Location = New-Object Drawing.Point(20, 326)
$btnShot.Size = New-Object Drawing.Size(95, 26); $form.Controls.Add($btnShot)
$btnApk = New-Object Windows.Forms.Button
$btnApk.Text = 'Install APK...'; $btnApk.Location = New-Object Drawing.Point(121, 326)
$btnApk.Size = New-Object Drawing.Size(100, 26); $form.Controls.Add($btnApk)
$btnReboot = New-Object Windows.Forms.Button
$btnReboot.Text = 'Reboot box'; $btnReboot.Location = New-Object Drawing.Point(227, 326)
$btnReboot.Size = New-Object Drawing.Size(95, 26); $form.Controls.Add($btnReboot)
$btnVerify = New-Object Windows.Forms.Button
$btnVerify.Text = 'Verify boot (reboot + report)'
$btnVerify.Location = New-Object Drawing.Point(544, 326)
$btnVerify.Size = New-Object Drawing.Size(180, 26); $form.Controls.Add($btnVerify)

$btnPlayAble = New-Object Windows.Forms.Button
$btnPlayAble.Text = 'AbleSign install page'
$btnPlayAble.Location = New-Object Drawing.Point(328, 326)
$btnPlayAble.Size = New-Object Drawing.Size(150, 26); $form.Controls.Add($btnPlayAble)

$chkForceProj = New-Object Windows.Forms.CheckBox
$chkForceProj.Text = 'Force Projectivy route (its boot-launch is Premium, $7.49 one-time)'
$chkForceProj.Location = New-Object Drawing.Point(20, 248); $chkForceProj.Size = New-Object Drawing.Size(400, 22)
$form.Controls.Add($chkForceProj)

$chkOwner = New-Object Windows.Forms.CheckBox
$chkOwner.Text = 'Try device-owner (fresh box, no Google account)'
$chkOwner.Location = New-Object Drawing.Point(430, 248); $chkOwner.Size = New-Object Drawing.Size(400, 22)
$form.Controls.Add($chkOwner)

$log = New-Object Windows.Forms.RichTextBox
$log.Location = New-Object Drawing.Point(20, 362)
$log.Size = New-Object Drawing.Size(800, 240)
$log.ReadOnly = $true; $log.BackColor = [Drawing.Color]::FromArgb(24,24,27)
$log.ForeColor = [Drawing.Color]::Gainsboro
$log.Font = New-Object Drawing.Font('Consolas', 9)
$log.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($log)

function Say($text, $color = 'Gainsboro') {
  $log.SelectionColor = [Drawing.Color]::FromName($color)
  $log.AppendText("$text`r`n")
  $log.ScrollToCaret()
  [Windows.Forms.Application]::DoEvents()
}
function Step($t) { Say "" ; Say "== $t" 'White' }
function Ok($t)   { Say "   [ok] $t" 'LightGreen' }
function Warn($t) { Say "   !! $t" 'Gold' }
function Fail($t) { Say "   XX $t" 'Salmon' }
function Info($t) { Say "   $t" }

# --------------------------------------------------------- requirements gate -
$script:ReqText = @'
GOAL: this box comes up in AbleSign after every reboot and power cut,
with nobody touching a remote. AbleSign shows whatever screen your
AbleSign cloud account assigns it - there is no URL to enter here.

BEFORE YOU DEPLOY - one-time steps on the box. On a FRESH / RESET box do
them in this order:

 1. Go through Google TV first-run setup (language, Wi-Fi).
      - SIGN IN with a Google account if you will install AbleSign /
        Projectivy from the Play Store (the normal route).
      - SKIP the account only if you plan to sideload APKs with the
        "Install APK..." button; skipping also unlocks device-owner
        mode for Fully Kiosk (the strongest kiosk lock).

 2. Play Store: install ABLESIGN, open it once, pair it to your
    AbleSign account so it shows the right screen.
    (The "Open AbleSign install page on TV" button below can jump the
    TV straight there once the box is connected.)

 3. Unlock Developer options:
    Settings > System > About > click "Android TV OS build" 7 times.

 4. Settings > System > Developer options > USB DEBUGGING = ON.
    (onn boxes only expose adb over the NETWORK - the USB port is
    power/OTG only, so this app connects by IP.)

 5. Settings > Network & Internet: note the box IP. Strongly
    recommended: give the box a DHCP RESERVATION in your router -
    its IP changing mid-work cost us hours in testing.

 6. PC and box must be on the SAME network. Business Wi-Fi often has
    AP/client isolation that silently blocks this - if Connect times
    out with everything else right, put both on a phone hotspot for
    the deploy, then move the box back.

 7. Keep the TV REMOTE nearby. Two prompts need it:
      - "Allow USB debugging?" on first connect (tick Always allow)
      - first deploy only: Projectivy > Settings > General >
        launch app at startup > AbleSign

After deploy the box reboots and lands in AbleSign in about a minute,
and every later reboot or power cycle does the same on its own.
'@

function Show-Requirements([switch]$GateDeploy) {
  $dlg = New-Object Windows.Forms.Form
  $dlg.Text = 'Before you deploy - requirements'
  $dlg.Size = New-Object Drawing.Size(640, 620)
  $dlg.StartPosition = 'CenterParent'
  $dlg.FormBorderStyle = 'FixedDialog'
  $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false

  $tb = New-Object Windows.Forms.TextBox
  $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'
  $tb.Font = New-Object Drawing.Font('Consolas', 9)
  $tb.Location = New-Object Drawing.Point(12, 12)
  $tb.Size = New-Object Drawing.Size(600, 510)
  $tb.Text = $script:ReqText
  $dlg.Controls.Add($tb)

  $okBtn = New-Object Windows.Forms.Button
  $okBtn.Text = $(if ($GateDeploy) { 'All done - DEPLOY' } else { 'Close' })
  $okBtn.Location = New-Object Drawing.Point(12, 534); $okBtn.Size = New-Object Drawing.Size(160, 32)
  $okBtn.DialogResult = [Windows.Forms.DialogResult]::OK
  $dlg.Controls.Add($okBtn)
  if ($GateDeploy) {
    $noBtn = New-Object Windows.Forms.Button
    $noBtn.Text = 'Not yet'
    $noBtn.Location = New-Object Drawing.Point(180, 534); $noBtn.Size = New-Object Drawing.Size(100, 32)
    $noBtn.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($noBtn)
    $dlg.CancelButton = $noBtn
  }
  $dlg.AcceptButton = $okBtn
  # De-select the text so the dialog opens without everything highlighted
  $dlg.Add_Shown({ $okBtn.Focus() })
  return ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK)
}

# ------------------------------------------------------------ adb plumbing ---
function Test-Adb([string]$path) {
  # Present is not the same as working: a half-extracted or 32-bit-blocked
  # adb.exe would fail every later command with a confusing error instead.
  if (-not $path -or -not (Test-Path $path)) { return $false }
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $path; $psi.Arguments = 'version'
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd(); $p.StandardError.ReadToEnd() | Out-Null
    $p.WaitForExit()
    return ($p.ExitCode -eq 0 -and $out -match 'Android Debug Bridge')
  } catch { return $false }
}

function Find-Adb {
  # Every place adb realistically already sits on a Windows PC, cheapest first.
  $repoRoot = Split-Path -Parent $Root
  $c = @()
  if (Test-Path $AdbMemo) {                       # what worked last time
    try { $c += (Get-Content $AdbMemo -TotalCount 1).Trim() } catch { }
  }
  $c += (Join-Path $Tools 'adb.exe')              # unzipped beside this app
  $c += (Join-Path $Store 'platform-tools\adb.exe')   # fetched by an earlier run
  if ($repoRoot) { $c += (Join-Path $repoRoot 'platform-tools\adb.exe') }
  $onPath = Get-Command adb.exe -ErrorAction SilentlyContinue
  if ($onPath) { $c += $onPath.Source }           # PATH, Scoop/Choco shims
  $c += @(
    "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",   # Android Studio
    "$env:ProgramFiles\Android\android-sdk\platform-tools\adb.exe",
    "${env:ProgramFiles(x86)}\Android\android-sdk\platform-tools\adb.exe",
    "$env:ProgramData\chocolatey\lib\adb\tools\platform-tools\adb.exe",
    "$env:USERPROFILE\scoop\apps\adb\current\adb.exe",
    "$env:USERPROFILE\Downloads\platform-tools\adb.exe",      # manual grab
    "$env:USERPROFILE\Desktop\platform-tools\adb.exe",
    'C:\platform-tools\adb.exe',
    'C:\adb\adb.exe'
  )
  foreach ($p in ($c | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Adb $p) { return $p }
  }
  return $null
}

function Ensure-Adb {
  if ($script:Adb -and (Test-Path $script:Adb)) { return $true }  # settled already

  $found = Find-Adb
  if ($found) {
    $script:Adb = $found
    Remember-Adb $found
    Ok "using the adb already on this PC: $found"
    return $true
  }

  Step 'No adb on this PC - fetching it once'
  $dest = Join-Path $Store 'platform-tools\adb.exe'
  try {
    if (-not (Test-Path $Store)) { New-Item -ItemType Directory -Path $Store -Force | Out-Null }
    $zip = Join-Path $env:TEMP 'platform-tools.zip'
    Info 'downloading from Google...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
      -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $Store -Force
    Remove-Item $zip -Force
    if (Test-Adb $dest) {
      $script:Adb = $dest
      Remember-Adb $dest
      Ok "adb installed to $dest (kept, so this never downloads again)"
      return $true
    }
    Fail 'the download finished but adb.exe would not run.'
  } catch {
    Fail "could not download adb: $($_.Exception.Message)"
  }
  Info 'Fix: download platform-tools manually and unzip it beside this app,'
  Info 'so that platform-tools\adb.exe sits next to OnnDeploy.bat:'
  Info '  https://developer.android.com/tools/releases/platform-tools'
  return $false
}

function Remember-Adb([string]$path) {
  # So the next run skips the search entirely - including after the repo ZIP is
  # re-downloaded into a fresh folder.
  try {
    if (-not (Test-Path $Store)) { New-Item -ItemType Directory -Path $Store -Force | Out-Null }
    Set-Content -Path $AdbMemo -Value $path -Encoding ASCII
  } catch { }
}

function Adb {
  param([string[]]$Arguments, [switch]$NoSerial)
  $a = @()
  if (-not $NoSerial -and $script:Serial) { $a += @('-s', $script:Serial) }
  $a += $Arguments
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $script:Adb
  $psi.Arguments = ($a | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return (($out + $err) -replace "`r", '')
}
function Sh([string]$cmd) { return (Adb @('shell', $cmd)) }

# --------------------------------------------------------------- discovery ---
function Get-Devices {
  $out = Adb @('devices') -NoSerial
  $list = @()
  foreach ($line in ($out -split "`n")) {
    if ($line -match '^(\S+)\s+(device|unauthorized|offline)\s*$') {
      $list += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
    }
  }
  return $list
}

function Refresh-Devices {
  $cboDev.Items.Clear()
  $devs = Get-Devices
  foreach ($d in $devs) {
    $kind = if ($d.Serial -match ':\d+$') { 'network' } else { 'USB' }
    $cboDev.Items.Add("$($d.Serial)   [$kind - $($d.State)]") | Out-Null
  }
  if ($cboDev.Items.Count -gt 0) {
    $cboDev.SelectedIndex = 0
    $lblDev.Text = "$($cboDev.Items.Count) device(s) found."
    $lblDev.ForeColor = [Drawing.Color]::DarkGreen
  } else {
    $lblDev.Text = 'No device. onn sticks do NOT support USB adb - enter the IP below.'
    $lblDev.ForeColor = [Drawing.Color]::Firebrick
  }
}

function Select-Device {
  if ($cboDev.SelectedItem) {
    $script:Serial = ($cboDev.SelectedItem -split '\s')[0]
    return $true
  }
  Fail 'No device selected.'
  return $false
}

# ------------------------------------------------------- self-healing checks -
# Each returns $true when the device is usable, repairing what it can first.
function Repair-Connection {
  Step 'Checking the connection'
  $devs = Get-Devices | Where-Object { $_.Serial -eq $script:Serial }
  if (-not $devs) {
    if ($script:Serial -match ':\d+$') {
      Info 'not connected - reconnecting'
      Adb @('connect', $script:Serial) -NoSerial | Out-Null
      Start-Sleep 2
      $devs = Get-Devices | Where-Object { $_.Serial -eq $script:Serial }
    }
  }
  if (-not $devs) { Fail 'Device not reachable.'; Show-ConnectHelp; return $false }

  if ($devs[0].State -eq 'offline') {
    Info 'stale session - reconnecting'
    Adb @('disconnect', $script:Serial) -NoSerial | Out-Null
    Adb @('connect', $script:Serial) -NoSerial | Out-Null
    Start-Sleep 2
    $devs = Get-Devices | Where-Object { $_.Serial -eq $script:Serial }
  }
  if ($devs[0].State -eq 'unauthorized') {
    Warn 'The TV is showing an "Allow USB debugging?" prompt right now.'
    Info 'Accept it with the remote (tick "Always allow"), then press Deploy again.'
    return $false
  }
  $model = (Sh 'getprop ro.product.model').Trim()
  $rel   = (Sh 'getprop ro.build.version.release').Trim()
  Ok "$model  (Android $rel)"
  return $true
}

function Show-ConnectHelp {
  Info ''
  Info 'On the TV, one time:'
  Info '  1. Settings > System > About > click "Android TV OS build" 7 times'
  Info '  2. Settings > System > Developer options > USB debugging = ON'
  Info '  3. Settings > Network & Internet > note the IP address'
  Info '  4. Type that IP above and press Connect; accept the prompt on the TV'
  Info ''
  Info 'Note: onn sticks do not expose adb over their USB port (it is power/OTG'
  Info 'only). Network is the supported route. PC and box must be on the same'
  Info 'network - business Wi-Fi often blocks device-to-device traffic, and a'
  Info 'phone hotspot is a quick way around that.'
}

function Home-List { (Sh 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME') -split "`n" | Where-Object { $_ -match '/' } | ForEach-Object { $_.Trim() } }
function Home-Now  { (((Sh 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME') -split "`n" | Where-Object { $_ -match '/' }) | Select-Object -Last 1).Trim() }
function Is-RealHome($h) { return -not ($h -eq '' -or $h -match 'setupwraith|FallbackHome|stubs') }
function Pkg-Installed($p) { return ((Sh "pm list packages $p") -match "package:$([regex]::Escape($p))(\s|$)") }

function Restore-Stock {
  Sh "dpm remove-active-admin $Fully/.MyDeviceAdminReceiver" | Out-Null
  Sh "pm enable --user 0 $Gtv" | Out-Null
  Sh "pm enable --user 0 $Wizard" | Out-Null
  Sh "cmd role add-role-holder android.app.role.HOME $Gtv" | Out-Null
  Sh "cmd package set-home-activity $Gtv/.home.HomeActivity" | Out-Null
}

function Repair-Home {
  # A box whose home resolves to the recovery activity is unusable; fix that
  # before doing anything else, on every run.
  $h = Home-Now
  if (-not (Is-RealHome $h)) {
    Warn "no usable home screen (resolves to '$h') - repairing"
    Restore-Stock; Start-Sleep 1
    Ok "home restored to $(Home-Now)"
  }
}

# -------------------------------------------------------------- deployment ---
function Install-Fully {
  Step 'Fully Kiosk'
  $ver = ''
  if (Pkg-Installed $Fully) {
    $m = (Sh "dumpsys package $Fully") -split "`n" | Where-Object { $_ -match 'versionName=' } | Select-Object -First 1
    if ($m -match 'versionName=(.+)$') { $ver = $Matches[1].Trim() }
  }
  if ($ver -match '-play') {
    Warn "a Play Store build is installed ($ver)"
    Info 'Google forbids Play apps from replacing the home screen, so that build'
    Info 'cannot auto-launch. Replacing it with the full version.'
    Adb @('uninstall', $Fully) | Out-Null
    $ver = ''
  }
  if ($ver -eq '') {
    $apk = Join-Path $Root 'fully-kiosk.apk'
    if (-not (Test-Path $apk)) {
      Info 'downloading the correct build...'
      try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest $FullyApkUrl -OutFile $apk -UseBasicParsing
      } catch {
        Fail "download failed: $($_.Exception.Message)"
        Info 'Fix: download the APK from https://www.fully-kiosk.com/ (Download APK,'
        Info 'not the Play badge) and save it beside this app as fully-kiosk.apk'
        return $false
      }
    }
    Info 'installing...'
    $r = Adb @('install', '-r', $apk)
    if ($r -notmatch 'Success') { Fail "install failed: $r"; return $false }
    $m = (Sh "dumpsys package $Fully") -split "`n" | Where-Object { $_ -match 'versionName=' } | Select-Object -First 1
    if ($m -match 'versionName=(.+)$') { $ver = $Matches[1].Trim() }
  }
  Ok "installed: $ver"
  return $true
}

function Remove-Bloat {
  Step 'Removing streaming apps'
  $n = 0
  foreach ($p in $Bloat) {
    $r = Sh "pm uninstall -k --user 0 $p"
    if ($r -match 'Success') { $n++ }
  }
  Ok "removed $n"
}

function Claim-Home($pkg, $component) {
  # Android 10+ assigns home through RoleManager; set-home-activity is the
  # legacy path and is silently ignored on modern Google TV. Do both.
  Sh "cmd role add-role-holder android.app.role.HOME $pkg" | Out-Null
  Sh "cmd package set-home-activity $component" | Out-Null
  Start-Sleep 1
}

function Set-BootTarget($pkg) {
  Step "Making the box boot into $pkg"

  $target = Home-List | Where-Object { $_ -like "$pkg/*" } | Select-Object -First 1
  if (-not $target) {
    # Some apps ship the launcher activity disabled behind an in-app toggle.
    foreach ($c in @("$pkg/.LauncherReplacement", "$pkg/.MainActivity", "$pkg/.HomeActivity")) {
      Sh "pm enable $c" | Out-Null
      $target = Home-List | Where-Object { $_ -like "$pkg/*" } | Select-Object -First 1
      if ($target) { Info "enabled hidden launcher component: $c"; break }
    }
  }
  if (-not $target) {
    Fail "$pkg is not offering itself as a launcher."
    if ($pkg -eq $Fully) {
      Info 'One switch lives inside the app and no PC tool can write it:'
      Info '   On the TV:  Fully Kiosk > Settings > Kiosk Mode > ENABLE'
      Info '               (accept "set as Home App" when it asks)'
      Info 'Then press Deploy again - everything else is already done.'
    }
    return $false
  }
  Ok "launcher activity: $target"

  Claim-Home $pkg $target
  if ((Home-Now) -notlike "$pkg/*" -and $chkExcl.Checked) {
    Info 'the Google TV home still wins - disabling it'
    Sh "pm disable-user --user 0 $Gtv" | Out-Null
    Claim-Home $pkg $target
  }
  $now = Home-Now
  if ($now -notlike "$pkg/*" -and $now -match 'setupwraith') {
    Info 'the setup wizard outranks it (priority 1 vs 0) - disabling that too'
    Sh "pm disable-user --user 0 $Wizard" | Out-Null
    Claim-Home $pkg $target
  }

  $now = Home-Now
  if ($now -like "$pkg/*") { Ok "home is now $now"; return $true }

  Fail "could not take over home (it resolves to $now) - rolling back"
  Restore-Stock
  Info 'The reliable route on a stubborn box is device-owner provisioning,'
  Info 'which needs a box with no Google account:'
  Info '   1. Factory reset the stick'
  Info '   2. SKIP the Google account during setup'
  Info '   3. Re-enable USB debugging and run this app again'
  return $false
}

# Try to make an app start itself at boot with no launcher involved. Only two
# mechanisms exist on Android: a HOME activity (checked elsewhere) or a
# BOOT_COMPLETED receiver. This enables a dormant receiver, clears the battery
# restrictions that silently kill one, and reports honestly if neither exists.
function Try-StandaloneAutostart($pkg) {
  Step "Can $pkg start itself at boot (no launcher)?"

  $rx = (Sh 'cmd package query-receivers --brief -a android.intent.action.BOOT_COMPLETED') -split "`n" |
        Where-Object { $_ -match [regex]::Escape($pkg) } | ForEach-Object { $_.Trim() }

  if (-not $rx) {
    # It may exist but be disabled - hunt the package's own components.
    $cand = ((Sh "dumpsys package $pkg") | Select-String -Pattern "$([regex]::Escape($pkg))/[A-Za-z0-9_.`$]+" -AllMatches |
             ForEach-Object { $_.Matches.Value } | Sort-Object -Unique |
             Where-Object { $_ -match 'boot|start|receiv' })
    foreach ($c in $cand) {
      Sh "pm enable $c" | Out-Null
      $rx = (Sh 'cmd package query-receivers --brief -a android.intent.action.BOOT_COMPLETED') -split "`n" |
            Where-Object { $_ -match [regex]::Escape($pkg) } | ForEach-Object { $_.Trim() }
      if ($rx) { Info "enabled dormant boot receiver: $c"; break }
    }
  }

  if (-not $rx) {
    Warn "$pkg has no boot receiver and no launcher activity."
    Info 'Those are the only two ways an Android app can start itself at boot,'
    Info 'so it genuinely cannot do it alone - that is an app limitation, not a'
    Info 'device or tooling one. Something else has to start it. Your options:'
    Info '  * Launch-On-Boot - FREE, MIT-licensed, does only this one job.'
    Info '  * Projectivy Premium - $7.49 ONCE, covers every box on the same'
    Info '    Google account. Cheapest for a fleet.'
    Info '  * Fully Kiosk PLUS - licensed PER DEVICE, so pricier at scale.'
    Info '  * A device built for signage (Amazon Signage Stick) - boots into its'
    Info '    player natively, no launcher tricks and no add-on licence.'
    return $false
  }

  Ok "boot receiver found: $($rx -join ', ')"
  Info 'clearing the restrictions that silently stop boot receivers...'
  Sh "dumpsys deviceidle whitelist +$pkg" | Out-Null       # ignore Doze
  Sh "cmd appops set $pkg RUN_IN_BACKGROUND allow" | Out-Null
  Sh "cmd appops set $pkg RUN_ANY_IN_BACKGROUND allow" | Out-Null
  Sh "cmd appops set --user 0 $pkg SYSTEM_ALERT_WINDOW allow" | Out-Null
  Sh "am set-inactive $pkg false" | Out-Null               # out of app-standby
  Sh "pm set-app-links --package $pkg 0 all" | Out-Null    # harmless if absent
  Ok 'battery, background and overlay restrictions cleared'
  Info 'Press "Verify boot" after this to see whether it actually comes up.'
  return $true
}

function Set-StartUrl($url) {
  if (-not $url) { return }
  Step 'Start URL'
  $ip = ($script:Serial -split ':')[0]
  try {
    $enc = [Uri]::EscapeDataString($url)
    Invoke-WebRequest "http://$ip`:2323/?cmd=setStringSetting&key=startURL&value=$enc&password=" `
      -TimeoutSec 5 -UseBasicParsing | Out-Null
    Ok "pushed into the app: $url"
    return
  } catch { }
  Sh "am start -n $Fully/.MainActivity -d `"$url`"" | Out-Null
  Warn 'could not push the URL in (Remote Administration is off in the app).'
  Info 'It is showing now but will NOT persist. To save it without a remote:'
  Info "   TV: Fully Kiosk > Settings > Remote Administration > enable"
  Info "   PC: open http://$ip`:2323 and paste the URL into Start URL"
}

function Harden {
  Step 'Keeping the screen alive'
  Sh 'settings put secure sleep_timeout -1' | Out-Null
  Sh 'settings put secure screensaver_enabled 0' | Out-Null
  Sh 'settings put global stay_on_while_plugged_in 3' | Out-Null
  Ok 'display sleep and screensaver disabled'
}

# ------------------------------------------------------------------ actions --
function Do-Check {
  $log.Clear()
  if (-not (Ensure-Adb)) { return }
  if (-not (Select-Device)) { return }
  if (-not (Repair-Connection)) { return }
  Repair-Home
  Step 'Current state'
  Info "home resolves to : $(Home-Now)"
  $disabled = Sh 'pm list packages -d'
  Info ("Google TV home   : " + $(if ($disabled -match [regex]::Escape($Gtv)) { 'DISABLED' } else { 'enabled' }))
  Info 'launcher-capable apps:'
  foreach ($h in (Home-List)) { Info "   $h" }
  Info ''
  Info 'installed (non-system) apps:'
  foreach ($p in ((Sh 'pm list packages -3') -split "`n" | Where-Object { $_ -match 'package:' })) {
    Info ("   " + ($p -replace 'package:', '').Trim())
  }
  Step 'Nothing was changed.'
}

function Do-Deploy {
  if (-not (Show-Requirements -GateDeploy)) { return }
  $log.Clear()
  $btnGo.Enabled = $false
  try {
    if (-not (Ensure-Adb)) { return }
    if (-not (Select-Device)) { return }
    if (-not (Repair-Connection)) { return }
    Repair-Home

    if ($chkWipe.Checked) { Remove-Bloat }

    if ($rbFully.Checked) {
      Warn 'Note: Fully Kiosk keeps Kiosk Mode / launcher replacement behind a'
      Warn 'paid PLUS license (per device). Without one it will not stay set as'
      Warn 'the home app. The AbleSign option is free end to end.'
      if (-not (Install-Fully)) { return }
      if ($chkOwner.Checked) {
        Step 'Device owner (the strongest kiosk lock)'
        if ((Sh 'dumpsys account') -match 'Account \{') {
          Warn 'unavailable: a Google account is signed in on the box.'
          Info 'It only works on a box where the account was SKIPPED during setup.'
        } else {
          $r = Sh "dpm set-device-owner $Fully/.MyDeviceAdminReceiver"
          if ($r -match 'Success') { Ok 'Fully Kiosk is now the device owner' }
          else { Warn "not granted: $($r.Trim())" }
        }
      }
      if (-not (Set-BootTarget $Fully)) { return }
      $u = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Fully Kiosk needs a page to show. Paste the URL (leave blank to set it on the TV later).',
        'Start URL', '')
      if ($u) { Set-StartUrl $u }
    } else {
      # AbleSign declares no launcher activity, so it cannot own boot itself.
      # Projectivy can, and starts a chosen app at boot via its accessibility
      # service - which this app can enable, unlike the in-app toggle.
      Step 'AbleSign'
      if (-not (Pkg-Installed 'tv.ablesign.app')) {
        Fail 'AbleSign is not installed on this box.'
        Info 'Opening its Play Store page on the TV - install it with the'
        Info 'remote, open it once to pair it, then press Deploy again.'
        Sh 'am start -a android.intent.action.VIEW -d market://details?id=tv.ablesign.app' | Out-Null
        return
      }
      Ok 'AbleSign present'

      # Prefer AbleSign standing on its own - no second app to configure.
      $solo = Try-StandaloneAutostart 'tv.ablesign.app'
      if ($solo -and -not $chkForceProj.Checked) {
        Harden
        Step 'Rebooting to test AbleSign on its own'
        Adb @('reboot') | Out-Null
        Say ''
        Say 'AbleSign has a boot receiver and its restrictions are cleared, so it' 'LightGreen'
        Say 'may now start on its own. Press "Verify boot" in ~90s to find out.' 'LightGreen'
        Say 'If it does NOT come up, tick "Force the Projectivy route" and deploy' 'Gold'
        Say 'again - that route always works, at the cost of one setting on the TV.' 'Gold'
        return
      }

      # Free route first: a tiny open-source helper whose only job is this.
      if (Pkg-Installed $Lob) {
        Step 'Launch-On-Boot (free) is installed - using it'
        Sh "dumpsys deviceidle whitelist +$Lob" | Out-Null
        Sh "cmd appops set $Lob RUN_IN_BACKGROUND allow" | Out-Null
        Sh "cmd appops set $Lob RUN_ANY_IN_BACKGROUND allow" | Out-Null
        Sh "am set-inactive $Lob false" | Out-Null
        Ok 'its boot restrictions are cleared'
        Sh "monkey -p $Lob -c android.intent.category.LAUNCHER 1" | Out-Null
        Warn 'ONE step on the TV, with the remote (first time only):'
        Info '   Launch-On-Boot is now open - choose ABLESIGN in it.'
        Info 'Then press "Verify boot" here to confirm. Total cost: $0.'
        Harden
        return
      }
      if (-not $chkForceProj.Checked) {
        Step 'Free option available'
        Info 'Launch-On-Boot is a small MIT-licensed app whose only job is'
        Info 'starting a chosen app at boot - the exact feature Projectivy'
        Info 'and Fully Kiosk charge for. It is free on the Play Store.'
        Info 'Opening its page on the TV - install it, then press DEPLOY again.'
        Sh "am start -a android.intent.action.VIEW -d market://details?id=$Lob" | Out-Null
        Info ''
        Warn 'It is an older app, so some boxes no longer list it in the Store.'
        Info 'If the TV shows "not found", use the releases page opening in your'
        Info 'browser now: download the .apk, then press "Install APK..." here.'
        try { Start-Process $LobApkPage -ErrorAction Stop | Out-Null } catch {
          Info "  $LobApkPage"
        }
        Info ''
        Info 'Prefer the paid launcher instead? Tick "Force Projectivy route".'
        return
      }
      if (-not (Pkg-Installed $Proj)) {
        Warn 'Projectivy Launcher is needed to start AbleSign at boot.'
        Warn 'HEADS UP: Projectivy is free, but its "launch app at startup"'
        Warn 'feature is PREMIUM - $7.49 one-time, and that one purchase covers'
        Warn 'every device signed in with the same Google account (unlike Fully'
        Warn 'Kiosk, which licenses per device).'
        Info 'Opening its Play Store page on the TV - install it with the remote,'
        Info 'then press Deploy again.'
        Sh "am start -a android.intent.action.VIEW -d market://details?id=$Proj" | Out-Null
        return
      }
      if (-not (Set-BootTarget $Proj)) { return }
      Step 'Letting Projectivy start AbleSign at boot'
      $svc = ((Sh 'cmd package query-services --brief -a android.accessibilityservice.AccessibilityService') -split "`n" |
              Where-Object { $_ -match [regex]::Escape($Proj) } | Select-Object -First 1)
      if ($svc) {
        $svc = $svc.Trim()
        $cur = (Sh 'settings get secure enabled_accessibility_services').Trim()
        if ($cur -notmatch [regex]::Escape($svc)) {
          $merged = if ($cur -and $cur -ne 'null') { "$cur`:$svc" } else { $svc }
          Sh "settings put secure enabled_accessibility_services $merged" | Out-Null
          Sh 'settings put secure accessibility_enabled 1' | Out-Null
        }
        Ok 'accessibility enabled (this is what unlocks launch-at-startup)'
      }
      Warn 'ONE step left on the TV, with the remote (first deploy only):'
      Info '   Projectivy > Settings > General > launch app at startup > AbleSign'
      Info 'That option is part of Projectivy PREMIUM ($7.49 one-time, bought'
      Info 'inside the app; it then covers every box on the same Google account).'
      Info 'After that: every reboot goes straight into AbleSign, which shows'
      Info 'whatever screen you assigned it in the AbleSign dashboard.'
    }

    Harden
    Step 'Rebooting to prove it'
    Adb @('reboot') | Out-Null
    Say ''
    Say 'Rebooting. Press "Verify boot (reboot + report)" in ~90s and it will' 'LightGreen'
    Say 'tell you exactly what came up on the TV - no walking over to check.' 'LightGreen'
  } catch {
    Fail "unexpected error: $($_.Exception.Message)"
  } finally {
    $btnGo.Enabled = $true
  }
}

function Do-Undo {
  $log.Clear()
  if (-not (Ensure-Adb)) { return }
  if (-not (Select-Device)) { return }
  if (-not (Repair-Connection)) { return }
  Step 'Restoring the box to stock'
  Restore-Stock
  foreach ($p in $Bloat) { Sh "cmd package install-existing $p" | Out-Null }
  Start-Sleep 1
  Ok "home is now $(Home-Now)"
  Adb @('reboot') | Out-Null
  Step 'Done - the box is back to stock.'
}

# ------------------------------------------------------------------ wiring ---
$btnScan.Add_Click({ if (Ensure-Adb) { Refresh-Devices } })
$btnConnect.Add_Click({
  if (-not (Ensure-Adb)) { return }
  $ip = $txtIp.Text.Trim()
  if (-not $ip) { return }
  if ($ip -notmatch ':\d+$') { $ip = "$ip`:5555" }
  $log.Clear(); Step "Connecting to $ip"
  $r = Adb @('connect', $ip) -NoSerial
  Info $r.Trim()
  Refresh-Devices
  for ($i = 0; $i -lt $cboDev.Items.Count; $i++) {
    if ($cboDev.Items[$i] -like "$ip*") { $cboDev.SelectedIndex = $i }
  }
  if ($r -match 'connected') { Ok 'connected' } else { Show-ConnectHelp }
})
function Do-Screenshot {
  if (-not (Ensure-Adb)) { return }
  if (-not (Select-Device)) { return }
  if (-not (Repair-Connection)) { return }
  Step 'Screenshot'
  Sh 'screencap -p /sdcard/onndeploy-screen.png' | Out-Null
  $file = Join-Path $Root ("screen-{0:yyyyMMdd-HHmmss}.png" -f (Get-Date))
  Adb @('pull', '/sdcard/onndeploy-screen.png', $file) | Out-Null
  Sh 'rm /sdcard/onndeploy-screen.png' | Out-Null
  if (Test-Path $file) { Ok "saved: $file"; Invoke-Item $file }
  else { Fail 'could not capture (some DRM/boot screens refuse capture)' }
}

function Do-InstallApk {
  if (-not (Ensure-Adb)) { return }
  if (-not (Select-Device)) { return }
  $fd = New-Object Windows.Forms.OpenFileDialog
  $fd.Filter = 'Android app (*.apk)|*.apk'
  $fd.Title = 'Choose an APK to install on the box'
  if ($fd.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }
  if (-not (Repair-Connection)) { return }
  Step ("Installing " + (Split-Path -Leaf $fd.FileName))
  $r = Adb @('install', '-r', $fd.FileName)
  if ($r -match 'Success') { Ok 'installed' } else { Fail $r.Trim() }
}

function Do-VerifyBoot {
  if (-not (Ensure-Adb)) { return }
  if (-not (Select-Device)) { return }
  if (-not (Repair-Connection)) { return }
  $log.Clear()
  Step 'Reboot test - this takes about 90 seconds'
  Info 'rebooting the box...'
  Adb @('reboot') | Out-Null
  Start-Sleep 12

  # Wait for the box to answer again, then let the boot settle before judging.
  $back = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep 3
    if ($script:Serial -match ':\d+$') { Adb @('connect', $script:Serial) -NoSerial | Out-Null }
    if ((Sh 'echo up').Trim() -eq 'up') { $back = $true; break }
    Info "   ...waiting ($((($i+1)*3)+12)s)"
  }
  if (-not $back) {
    Fail 'the box did not come back on the network within ~2 minutes.'
    Info 'If it is showing a picture, its IP probably changed - check'
    Info 'Settings > Network on the TV, or set a DHCP reservation.'
    return
  }
  Ok 'box is back - letting the boot settle'
  Start-Sleep 25

  $top = ((Sh 'dumpsys activity activities') -split "`n" |
          Where-Object { $_ -match 'topResumedActivity|mResumedActivity' } |
          Select-Object -First 1)
  Step 'What actually came up'
  if ($top -match '([A-Za-z0-9_.]+)/([A-Za-z0-9_.$]+)') {
    $pkg = $Matches[1]
    Info "on screen: $pkg"
    switch -Wildcard ($pkg) {
      '*ablesign*' { Ok 'AbleSign launched by itself - this box is done.'; return }
      '*projengmenu*' {
        Warn 'Projectivy came up, but it did not start AbleSign.'
        Info 'That last hop is a setting inside Projectivy that no PC tool can'
        Info 'write. On the TV, once:'
        Info '   Projectivy > Settings > General > launch app at startup > AbleSign'
        Info 'Then press this button again to confirm.'
        return
      }
      '*launcherx*' {
        Warn 'The Google TV home came up - the boot takeover did not hold.'
        Info 'Press DEPLOY (it will install/repair what is missing), then verify again.'
        return
      }
      default { Warn "Something else owns the screen: $pkg" }
    }
  } else {
    Warn 'could not read what is on screen'
  }
  Info ''
  Info 'Tip: press Screenshot to see exactly what the TV is showing.'
}

$btnVerify.Add_Click({ Do-VerifyBoot })
$btnReq.Add_Click({ [void](Show-Requirements) })
$btnShot.Add_Click({ Do-Screenshot })
$btnApk.Add_Click({ Do-InstallApk })
$btnReboot.Add_Click({
  if ((Ensure-Adb) -and (Select-Device) -and (Repair-Connection)) {
    Step 'Rebooting'; Adb @('reboot') | Out-Null; Ok 'reboot sent'
  }
})
$btnPlayAble.Add_Click({
  if ((Ensure-Adb) -and (Select-Device) -and (Repair-Connection)) {
    Step 'Opening the AbleSign Play Store page on the TV'
    Sh 'am start -a android.intent.action.VIEW -d market://details?id=tv.ablesign.app' | Out-Null
    Ok 'sent - install it with the remote, open it once to pair'
  }
})
$btnGo.Add_Click({ Do-Deploy })
$btnUndo.Add_Click({ Do-Undo })
$btnCheck.Add_Click({ Do-Check })

$form.Add_Shown({
  Say 'Onn Wall Display Deployer' 'White'
  Say 'Works on every onn / Google TV box (HD stick, 4K, 4K Plus, 4K Pro).'
  Say 'Pick the device (or enter its IP), then press DEPLOY. The app strips the'
  Say 'streaming apps and makes AbleSign come up after every reboot or power'
  Say 'cut. Content comes from your AbleSign cloud account - nothing to enter.'
  if (Ensure-Adb) { Refresh-Devices }
})

[void]$form.ShowDialog()
