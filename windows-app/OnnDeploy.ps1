# OnnDeploy — one-click wall-display provisioning for Android TV / Google TV boxes.
#
# Point it at a box, press Deploy, and it: installs its own copy of adb, finds
# the device over USB or the network, removes every streaming app, installs the
# signage player, makes the box boot straight into it, and verifies the result.
# Errors are diagnosed and repaired automatically where that is possible, and
# reported in plain language where it is not.
#
# Run via OnnDeploy.bat (which sets the execution policy for this process only).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'
$script:Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Tools   = Join-Path $Root 'platform-tools'
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

$null = New-Label '2. What the screen should show' 20 155 300 $true
$null = New-Label 'Dashboard URL (from Admin > Screen Fleet > Copy URL):' 20 178 420 $false
$txtUrl = New-Object Windows.Forms.TextBox
$txtUrl.Location = New-Object Drawing.Point(20, 199); $txtUrl.Size = New-Object Drawing.Size(580, 24)
$form.Controls.Add($txtUrl)

$null = New-Label '3. Player' 20 236 200 $true
$rbAble = New-Object Windows.Forms.RadioButton
$rbAble.Text = 'AbleSign  (free - recommended; auto-boots via Projectivy)'
$rbAble.Location = New-Object Drawing.Point(20, 258); $rbAble.Size = New-Object Drawing.Size(390, 22)
$rbAble.Checked = $true
$form.Controls.Add($rbAble)
$rbFully = New-Object Windows.Forms.RadioButton
$rbFully.Text = 'Fully Kiosk  (kiosk/launcher mode needs a paid PLUS license)'
$rbFully.Location = New-Object Drawing.Point(20, 280); $rbFully.Size = New-Object Drawing.Size(400, 22)
$form.Controls.Add($rbFully)

$chkWipe = New-Object Windows.Forms.CheckBox
$chkWipe.Text = 'Remove all streaming apps'; $chkWipe.Checked = $true
$chkWipe.Location = New-Object Drawing.Point(420, 258); $chkWipe.Size = New-Object Drawing.Size(220, 22)
$form.Controls.Add($chkWipe)
$chkExcl = New-Object Windows.Forms.CheckBox
$chkExcl.Text = 'Disable the Google TV home screen'; $chkExcl.Checked = $true
$chkExcl.Location = New-Object Drawing.Point(420, 280); $chkExcl.Size = New-Object Drawing.Size(260, 22)
$form.Controls.Add($chkExcl)

$btnGo = New-Object Windows.Forms.Button
$btnGo.Text = 'DEPLOY'
$btnGo.Location = New-Object Drawing.Point(20, 315); $btnGo.Size = New-Object Drawing.Size(200, 44)
$btnGo.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$btnGo.BackColor = [Drawing.Color]::FromArgb(29, 78, 216); $btnGo.ForeColor = 'White'
$btnGo.FlatStyle = 'Flat'
$form.Controls.Add($btnGo)

$btnUndo = New-Object Windows.Forms.Button
$btnUndo.Text = 'Undo (back to stock)'
$btnUndo.Location = New-Object Drawing.Point(232, 315); $btnUndo.Size = New-Object Drawing.Size(160, 44)
$form.Controls.Add($btnUndo)

$btnCheck = New-Object Windows.Forms.Button
$btnCheck.Text = 'Check only'
$btnCheck.Location = New-Object Drawing.Point(404, 315); $btnCheck.Size = New-Object Drawing.Size(110, 44)
$form.Controls.Add($btnCheck)

$log = New-Object Windows.Forms.RichTextBox
$log.Location = New-Object Drawing.Point(20, 372)
$log.Size = New-Object Drawing.Size(800, 230)
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

# ------------------------------------------------------------ adb plumbing ---
function Ensure-Adb {
  # Prefer a copy next to the app, then anything on PATH, then fetch Google's.
  $local = Join-Path $Tools 'adb.exe'
  if (Test-Path $local) { $script:Adb = $local; return $true }
  $onPath = Get-Command adb.exe -ErrorAction SilentlyContinue
  if ($onPath) { $script:Adb = $onPath.Source; return $true }

  Step 'Installing platform-tools (one time)'
  try {
    $zip = Join-Path $env:TEMP 'platform-tools.zip'
    Info 'downloading from Google...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
      -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $Root -Force
    Remove-Item $zip -Force
    if (Test-Path $local) { $script:Adb = $local; Ok 'adb installed'; return $true }
  } catch {
    Fail "could not download adb: $($_.Exception.Message)"
    Info 'Fix: download platform-tools manually and put adb.exe beside this app:'
    Info '  https://developer.android.com/tools/releases/platform-tools'
    return $false
  }
  return $false
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
  $log.Clear()
  $btnGo.Enabled = $false
  try {
    if (-not (Ensure-Adb)) { return }
    if (-not (Select-Device)) { return }
    if (-not (Repair-Connection)) { return }
    Repair-Home

    $url = $txtUrl.Text.Trim()
    if (-not $url) {
      Warn 'No dashboard URL given - the player will come up blank.'
    }

    if ($chkWipe.Checked) { Remove-Bloat }

    if ($rbFully.Checked) {
      Warn 'Note: Fully Kiosk keeps Kiosk Mode / launcher replacement behind a'
      Warn 'paid PLUS license (per device). Without one it will not stay set as'
      Warn 'the home app. The AbleSign option is free end to end.'
      if (-not (Install-Fully)) { return }
      if (-not (Set-BootTarget $Fully)) { return }
      Set-StartUrl $url
    } else {
      # AbleSign declares no launcher activity, so it cannot own boot itself.
      # Projectivy can, and starts a chosen app at boot via its accessibility
      # service - which this app can enable, unlike the in-app toggle.
      Step 'AbleSign'
      if (-not (Pkg-Installed 'tv.ablesign.app')) {
        Fail 'AbleSign is not installed on this box.'
        Info 'Install it from the Play Store on the TV, then press Deploy again.'
        return
      }
      Ok 'AbleSign present'
      if (-not (Pkg-Installed $Proj)) {
        Warn 'Projectivy Launcher is needed to start AbleSign at boot.'
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
      Info 'After that: every reboot goes straight into AbleSign, which shows'
      Info 'whatever screen you assigned it in the AbleSign dashboard.'
    }

    Harden
    Step 'Rebooting to prove it'
    Adb @('reboot') | Out-Null
    Say ''
    Say 'Expect the board within 60-90s of the box coming back, remote untouched.' 'LightGreen'
    Say 'Check Admin > Screen Fleet - the screen should show "online now".' 'LightGreen'
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
$btnGo.Add_Click({ Do-Deploy })
$btnUndo.Add_Click({ Do-Undo })
$btnCheck.Add_Click({ Do-Check })

$form.Add_Shown({
  Say 'Onn Wall Display Deployer' 'White'
  Say 'Works on every onn / Google TV box (HD stick, 4K, 4K Plus, 4K Pro).'
  Say 'Pick the device (or enter its IP), then press DEPLOY. The app removes'
  Say 'the streaming apps and sets AbleSign to come up on every reboot.'
  if (Ensure-Adb) { Refresh-Devices }
})

[void]$form.ShowDialog()
