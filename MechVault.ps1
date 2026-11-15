#requires -version 5.1
param(
  [switch]$Minimized,
  [switch]$HideConsole,
  [string]$SelfTest = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing

if (-not ('MechVaultNative3' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MechVaultNative3 {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

  [StructLayout(LayoutKind.Sequential)] struct ACCENT { public int State; public int Flags; public uint Color; public int Anim; }
  [StructLayout(LayoutKind.Sequential)] struct WCAD { public int Attr; public IntPtr Data; public int Size; }
  [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr h, ref WCAD d);
  public static int Acrylic(IntPtr h, uint abgr) { return Accent(h, 4, abgr); }
  public static int Accent(IntPtr h, int state, uint abgr) {
    var a = new ACCENT { State = state, Flags = 2, Color = abgr };
    int sz = Marshal.SizeOf(a); IntPtr p = Marshal.AllocHGlobal(sz);
    try { Marshal.StructureToPtr(a, p, false); var d = new WCAD { Attr = 19, Data = p, Size = sz }; return SetWindowCompositionAttribute(h, ref d); }
    finally { Marshal.FreeHGlobal(p); }
  }
}
'@
}
if ($HideConsole) {
  $c = [MechVaultNative3]::GetConsoleWindow()
  if ($c -ne [IntPtr]::Zero) { [void][MechVaultNative3]::ShowWindow($c, 0) }
}

$script:IsTest = [bool]$SelfTest

if (-not $IsTest) {
  $created = $false
  $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\MechVault_SingleInstance', [ref]$created)
  if (-not $created) {
    [void][System.Windows.MessageBox]::Show("MechVault is already running.`nYou'll find it in the notification area, next to the clock.", 'MechVault')
    return
  }
}

$script:Here       = Split-Path -Parent $PSCommandPath
$script:AppDir     = if ($IsTest) { Join-Path $env:TEMP 'MechVaultTest3' } else { Join-Path $script:Here 'dati' }
$script:OldAppDir  = Join-Path $env:APPDATA 'MechVault'
if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
$script:LegacyFile = Join-Path $script:AppDir 'data.json'
$script:AccDir     = Join-Path $script:AppDir 'accounts'
$script:OldIndex   = Join-Path $script:AppDir 'accounts.json'
$script:ActiveFile = Join-Path $script:AppDir 'active.txt'
$script:LogFile    = Join-Path $script:AppDir 'errori.log'
$script:DataFile   = $null
$script:ActiveId   = $null
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'MechVault.lnk'
$script:IT  = [Globalization.CultureInfo]::GetCultureInfo('it-IT')
$script:INV = [Globalization.CultureInfo]::InvariantCulture
$script:Exiting      = $false
$script:GameRunning  = $false
$script:PendingCheck = $false
$script:Banner       = $null
$script:WarnOpen     = $false
$script:InDialog     = $false
$script:Pend         = @{ credits = $null; acoins = $null }
$script:Ignore       = @{ credits = $null; acoins = $null }
$script:OcrReady     = $false

$script:Lessons = @(
  "Una Crate Rush senza garantito non ha un tetto di spesa. Un obiettivo a crediti sì.",
  "Le casse sono progettate per farti perdere. Un obiettivo fisso no.",
  "Ogni giorno senza spendere avvicina il tuo prossimo obiettivo.",
  "Un'arma sicura vale più di dieci tentativi a vuoto.",
  "La voglia di aprire una cassa passa in 5 minuti. Il saldo vuoto resta.",
  "Le offerte a tempo esistono per farti decidere senza pensare. Pensa."
)

function Write-Log([string]$m) {
  for ($i = 0; $i -lt 3; $i++) {
    try { Add-Content -Path $script:LogFile -Value ("{0}  {1}" -f (Get-Date -Format 's'), $m) -Encoding UTF8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 150 }
  }
}

$script:LangDir  = Join-Path $script:Here 'lang'
$script:LangFile = Join-Path $script:AppDir 'lang.txt'
$script:Lang = 'it'
$script:Map = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)

function Load-Lang {
  $script:Lang = 'en'
  if ($script:IsTest) { if ($env:MECHVAULT_LANG) { $script:Lang = $env:MECHVAULT_LANG } }
  elseif (Test-Path $script:LangFile) { try { $l = ([IO.File]::ReadAllText($script:LangFile)).Trim(); if ($l) { $script:Lang = $l } } catch {} }
  $script:Map.Clear()
  $f = Join-Path $script:LangDir "$($script:Lang).json"
  if ($script:Lang -eq 'it' -or -not (Test-Path $f)) { $script:Lang = 'it'; return }
  try {
    $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($p in $j.strings) { if ($p[1]) { $script:Map[[string]$p[0]] = [string]$p[1] } }
    if ($j.culture) { $script:IT = [Globalization.CultureInfo]::GetCultureInfo([string]$j.culture) }
  } catch { Write-Log "Lingua $($script:Lang): $_"; $script:Lang = 'it' }
}

function T([string]$k) {
  $v = $script:Map[$k]
  if (-not $v) { $v = $k }
  if ($args.Count) { [string]::Format($v, [object[]]$args) } else { $v }
}

function Get-Languages {
  $list = @()
  foreach ($f in @(Get-ChildItem -Path $script:LangDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object { if ($_.BaseName -eq 'en') { 0 } else { 1 } }, Name)) {
    $name = $f.BaseName
    try { $n = ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).name; if ($n) { $name = $n } } catch {}
    $list += [pscustomobject]@{ code = $f.BaseName; name = $name }
  }
  $list += [pscustomobject]@{ code = 'it'; name = 'Italiano' }
  $list
}

$script:UiFile = Join-Path $script:AppDir 'ui.json'
function Get-UiPref([string]$k, $def) {
  try { if (Test-Path $script:UiFile) { $j = Read-JsonFile $script:UiFile; if ($null -ne $j.$k) { return $j.$k } } } catch {}
  $def
}
function Set-UiPref([string]$k, $v) {
  $h = [ordered]@{}
  try { if (Test-Path $script:UiFile) { (Read-JsonFile $script:UiFile).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } } } catch {}
  $h[$k] = $v
  [IO.File]::WriteAllText($script:UiFile, ($h | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}
function Get-LiquidGlass {
  if ($script:IsTest -and $env:MECHVAULT_GLASS -eq 'off') { return $false }
  [bool](Get-UiPref 'liquidGlass' $true)
}
function Set-LiquidGlass([bool]$on) {
  if ($on -eq $script:LiquidGlass) { return }
  try { Set-UiPref 'liquidGlass' $on } catch { Write-Log "ui.json: $_"; return }
  Restart-App
}

function Set-Language([string]$code) {
  if ($code -eq $script:Lang) { return }
  try { [IO.File]::WriteAllText($script:LangFile, $code) } catch { Write-Log "lang.txt: $_"; return }
  Restart-App
}

function Restart-App {
  Save-Data
  Hide-Banner
  if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
  try { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } catch {}
  Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -HideConsole" -WindowStyle Hidden
  $script:Exiting = $true
  $script:app.Shutdown()
}

$script:AppVersion = '1.1.9'
$script:UpdateBase = if ($env:MECHVAULT_UPDATE_BASE) { $env:MECHVAULT_UPDATE_BASE } else { 'https://mechvault.github.io' }
$script:UpdateFetch = @'
param($base, $cur)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$nc = [DateTime]::UtcNow.Ticks
$info = Invoke-RestMethod -Uri "$base/version.json?t=$nc" -UseBasicParsing -TimeoutSec 20
if (-not $info.version -or -not $info.sha256) { throw 'version.json without version or sha256' }
if (([version][string]$info.version) -le ([version]$cur)) { return @{ status = 'current'; version = [string]$info.version } }
$tmp = Join-Path $env:TEMP ('mvupd_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$zip = Join-Path $tmp 'MechVault.zip'
Invoke-WebRequest -Uri "$base/MechVault.zip?t=$nc" -OutFile $zip -UseBasicParsing -TimeoutSec 180
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($sha -ne ([string]$info.sha256).ToLower()) { Remove-Item $tmp -Recurse -Force; throw "SHA-256 mismatch: got $sha" }
Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'x') -Force
$src = Join-Path $tmp 'x\MechVault'
$ps1 = Join-Path $src 'MechVault.ps1'
if (-not (Test-Path $ps1)) { Remove-Item $tmp -Recurse -Force; throw 'MechVault.ps1 missing from the package' }
$err = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$null, [ref]$err)
if ($err) { Remove-Item $tmp -Recurse -Force; throw "package script has errors: $($err[0].Message)" }
@{ status = 'ready'; version = [string]$info.version; src = $src; tmp = $tmp }
'@

function Set-UpdateStatus([string]$t) { if ($script:ui -and $script:ui.UpdStatus) { $script:ui.UpdStatus.Text = $t } }

function Install-Update($r, [string]$dest = $script:Here) {
  $list = @()
  foreach ($f in 'MechVault.ps1', 'MechVaultReader.cs', 'MechVault Start.cmd', 'README.md') { $p = Join-Path $r.src $f; if (Test-Path -LiteralPath $p) { $list += @{ s = $p; d = Join-Path $dest $f } } }
  foreach ($sub in 'lang', 'calc') {
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $r.src $sub) -Filter '*.json' -File -ErrorAction SilentlyContinue)) { $list += @{ s = $f.FullName; d = Join-Path (Join-Path $dest $sub) $f.Name } }
  }
  try {
    foreach ($x in $list) { $dd = Split-Path $x.d; if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }; Copy-Item -LiteralPath $x.s -Destination ($x.d + '.new') -Force -ErrorAction Stop }
    foreach ($x in $list) { Move-Item -LiteralPath ($x.d + '.new') -Destination $x.d -Force -ErrorAction Stop }
  } catch {
    foreach ($x in $list) { Remove-Item -LiteralPath ($x.d + '.new') -Force -ErrorAction SilentlyContinue }
    throw
  } finally { Remove-Item -LiteralPath $r.tmp -Recurse -Force -ErrorAction SilentlyContinue }
  $list.Count
}

function Prompt-UpdateRestart {
  if (-not $script:UpdReady) { return }
  if ($script:GameRunning -or $script:InDialog) { $script:UpdPrompt = $true; return }
  $script:UpdPrompt = $false
  if (-not ($script:win -and $script:win.IsVisible)) {
    if ($script:Tray) { $script:Tray.ShowBalloonTip(6000, 'MechVault', (T 'Versione {0} installata. Si attiva al prossimo avvio di MechVault.' $script:UpdReady), [System.Windows.Forms.ToolTipIcon]::Info) }
    return
  }
  if ((Show-Msg (T 'MechVault {0} è installato. Riavviare adesso per usarlo?' $script:UpdReady) -YesNo) -eq 'Yes') { Restart-App }
}

function Start-UpdateCheck([switch]$Manual) {
  if ($script:IsTest -or $script:UpdJob) { return }
  if ($script:UpdReady) { Set-UpdateStatus (T 'Versione {0} installata. Si attiva al prossimo avvio di MechVault.' $script:UpdReady); if ($Manual) { Prompt-UpdateRestart }; return }
  if (-not $Manual -and -not [bool](Get-UiPref 'autoUpdate' $true)) { return }
  $ps = [powershell]::Create()
  [void]$ps.AddScript($script:UpdateFetch).AddArgument($script:UpdateBase).AddArgument($script:AppVersion)
  $script:UpdJob = @{ ps = $ps; h = $ps.BeginInvoke(); manual = [bool]$Manual }
  Set-UpdateStatus (T 'Controllo aggiornamenti…')
  $tm = New-Object System.Windows.Threading.DispatcherTimer
  $tm.Interval = [TimeSpan]::FromSeconds(1)
  $tm.Add_Tick({
    $j = $script:UpdJob
    if (-not $j -or -not $j.h.IsCompleted) { return }
    $this.Stop()
    $out = $null; $err = $null
    try { $out = @($j.ps.EndInvoke($j.h)) | Select-Object -Last 1 } catch { $err = $_.Exception.InnerException; if (-not $err) { $err = $_.Exception } }
    if (-not $err -and $j.ps.Streams.Error.Count) { $err = $j.ps.Streams.Error[0].Exception }
    $j.ps.Dispose(); $script:UpdJob = $null
    if ($err -or -not $out) {
      $msg = if ($err) { $err.Message } else { 'no answer' }
      Write-Log "Aggiornamento: $msg"
      Set-UpdateStatus (T 'Controllo non riuscito ({0}). Riprova più tardi.' $msg)
      return
    }
    if ($out.status -eq 'current') { Set-UpdateStatus (T 'Hai l''ultima versione ({0}).' $script:AppVersion); return }
    try {
      $n = Install-Update $out
      $script:UpdReady = $out.version
      Write-Log "Aggiornamento: installata la $($out.version) ($n file)"
      Set-UpdateStatus (T 'Versione {0} installata. Si attiva al prossimo avvio di MechVault.' $out.version)
      Prompt-UpdateRestart
    } catch {
      Write-Log "Aggiornamento: installazione non riuscita: $_"
      Set-UpdateStatus (T 'Installazione non riuscita: {0}' $_.Exception.Message)
    }
  })
  $tm.Start()
  $script:UpdTimer = $tm
}

function Fmt([double]$n) { $n.ToString('N0', $script:IT) }
function Short([double]$n) {
  $a = [math]::Abs($n)
  if ($a -ge 1e6) { return ($n / 1e6).ToString('0.##', $script:IT) + 'M' }
  if ($a -ge 1e4) { return ($n / 1e3).ToString('0.#', $script:IT) + 'k' }
  Fmt $n
}
function Signed([double]$n) { if ($n -gt 0) { '+' + (Fmt $n) } elseif ($n -lt 0) { '−' + (Fmt (-$n)) } else { '0' } }
function CurName([string]$c)  { if ($c -eq 'credits') { T 'crediti' } else { 'A-coin' } }
function CurColor([string]$c) { if ($c -eq 'credits') { '#64D2FF' } else { '#DA8FFF' } }
function CurColor2([string]$c) { if ($c -eq 'credits') { '#0A84FF' } else { '#BF5AF2' } }
function InitProp([string]$c) { if ($c -eq 'credits') { 'initCredits' } else { 'initAcoins' } }
function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }
function Now-Iso { (Get-Date).ToString('o') }
function New-Id { [guid]::NewGuid().ToString('N').Substring(0, 8) }
function Ago($t) {
  if (-not $t) { return (T 'mai') }
  $s = ((Get-Date) - [datetime]$t).TotalSeconds
  if ($s -lt 45) { return (T 'adesso') }
  if ($s -lt 3600) { return (T '{0} min fa' ([int][math]::Max(1.0, [math]::Round($s / 60)))) }
  if ($s -lt 86400) { return (T '{0} h fa' ([int][math]::Round($s / 3600))) }
  ([datetime]$t).ToString('d MMM HH:mm', $script:IT)
}

function Parse-Amount([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $s = ($s.Trim().ToLower() -replace '\s', '')
  $mult = 1.0
  if ($s.EndsWith('k')) { $mult = 1e3; $s = $s.TrimEnd('k') }
  elseif ($s.EndsWith('m')) { $mult = 1e6; $s = $s.TrimEnd('m') }
  if ($mult -gt 1) { $s = $s -replace ',', '.' } else { $s = $s -replace '[\.,]', '' }
  $v = 0.0
  if (-not [double]::TryParse($s, [Globalization.NumberStyles]::Float, $script:INV, [ref]$v)) { return $null }
  if ($v -lt 0) { return $null }
  [math]::Round($v * $mult)
}

function Parse-GameNumber([string]$t) {
  if (-not $t) { return $null }
  $t = ($t -replace '[Oo]', '0') -replace '[^0-9\.,KkMm]', ''
  if ($t -match '^(\d{1,4})(?:[\.,](\d{1,2}))?([KkMm])$') {
    $num = [double]::Parse(($matches[1] + '.' + $(if ($matches[2]) { $matches[2] } else { '0' })), $script:INV)
    $mult = if ($matches[3] -match '[Kk]') { 1e3 } else { 1e6 }
    return [math]::Round($num * $mult)
  }
  if ($t -match '^\d{1,3}([\.,]\d{3}){1,2}$') { return [double]($t -replace '[\.,]', '') }
  if ($t -match '^\d{1,7}$') { return [double]$t }
  $null
}

function New-Goal($name, $cur, $cost) {
  [pscustomobject]@{ id = (New-Id); name = $name; currency = $cur; cost = [double]$cost; done = $false; doneAt = $null }
}

function Get-DefaultData {
  [pscustomobject]@{
    version        = 3
    accountName    = 'Principale'
    createdAt      = (Now-Iso)
    credits        = 0.0
    acoins         = 0.0
    initCredits    = $false
    initAcoins     = $false
    events         = @()
    goals          = @()
    rateCredits    = 0.0
    rateAcoins     = 0.0
    missionCredits = 2000.0
    missionAcoins  = 0.0
    violations     = @()
    purchase       = $null
    cleanSince     = (Now-Iso)
    bestStreak     = 0
    processPattern = 'mech.?arena'
    autoRead       = $true
    showBanner     = $true
    autostart      = $true
    firstRun       = $true
    lastReadAt     = $null
  }
}

function Read-JsonFile([string]$path) {
  for ($i = 0; $i -lt 8; $i++) {
    try { return ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json) }
    catch { if ($i -eq 7) { throw }; Start-Sleep -Milliseconds 250 }
  }
}

function Load-Data([string]$path) {
  $def = Get-DefaultData
  if (Test-Path $path) {
    try {
      $d = Read-JsonFile $path
      foreach ($p in $def.PSObject.Properties) {
        if ($d.PSObject.Properties.Name -notcontains $p.Name) { $d | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
      }
      $d.events     = @($d.events     | Where-Object { $_ })
      $d.goals      = @($d.goals      | Where-Object { $_ })
      $d.violations = @($d.violations | Where-Object { $_ })
      foreach ($old in 'history', 'tolCredits', 'tolAcoins') { if ($d.PSObject.Properties.Name -contains $old) { $d.PSObject.Properties.Remove($old) } }
      if ($d.events.Count -eq 0) {
        foreach ($c in 'credits', 'acoins') {
          if ($d.(InitProp $c)) { $d.events += [pscustomobject]@{ t = (Now-Iso); cur = $c; delta = 0.0; bal = [double]$d.$c; kind = 'init'; note = 'saldo iniziale'; src = 'manuale' } }
        }
      }
      $d.version = 3
      return $d
    } catch {
      Write-Log "Account illeggibile ($path): $_"
      Copy-Item $path ("{0}.rotto-{1}" -f $path, (Get-Date -Format 'yyyyMMddHHmmss')) -ErrorAction SilentlyContinue
    }
  }
  $def
}

function Save-Data {
  if (-not $script:DataFile) { return }
  try {
    $json = $script:Data | ConvertTo-Json -Depth 8
    $tmp = "$($script:DataFile).tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -Force $tmp $script:DataFile
  } catch { Write-Log "Salvataggio fallito: $_" }
}

function Add-Event([string]$cur, [double]$delta, [double]$bal, [string]$kind, [string]$note, [string]$src) {
  $e = [pscustomobject]@{ t = (Now-Iso); cur = $cur; delta = $delta; bal = $bal; kind = $kind; note = $note; src = $src }
  $script:Data.events = @(@($script:Data.events) + $e | Select-Object -Last 3000)
}

function Get-Accounts {
  $list = @()
  foreach ($f in @(Get-ChildItem -Path $script:AccDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTime)) {
    $id = $f.BaseName
    if ($id -eq $script:ActiveId -and $script:Data) { $list += [pscustomobject]@{ id = $id; name = $script:Data.accountName }; continue }
    $name = $null
    try { $name = (Read-JsonFile $f.FullName).accountName } catch {}
    if (-not $name) { $name = T 'Account del {0}' ($f.CreationTime.ToString('d MMM', $script:IT)) }
    $list += [pscustomobject]@{ id = $id; name = $name }
  }
  $list
}

function Get-AccountName { if ($script:Data -and $script:Data.accountName) { $script:Data.accountName } else { '?' } }

function Set-ActiveId([string]$id) {
  $script:ActiveId = $id
  $script:DataFile = Join-Path $script:AccDir "$id.json"
  try { [IO.File]::WriteAllText($script:ActiveFile, $id) } catch { Write-Log "active.txt: $_" }
}

function Init-Accounts {
  if (-not (Test-Path $script:AccDir)) { New-Item -ItemType Directory -Path $script:AccDir -Force | Out-Null }
  if (-not $script:IsTest -and @(Get-ChildItem -Path $script:AccDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -eq 0 -and (Test-Path $script:OldAppDir)) {
    try {
      $oa = Join-Path $script:OldAppDir 'accounts'
      if (Test-Path $oa) { Copy-Item (Join-Path $oa '*.json') $script:AccDir -ErrorAction SilentlyContinue }
      foreach ($f in 'accounts.json', 'active.txt', 'data.json') {
        $src = Join-Path $script:OldAppDir $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $script:AppDir $f) }
      }
      Write-Log "Importati i dati da $($script:OldAppDir)"
    } catch { Write-Log "Import vecchi dati: $_" }
  }
  if (Test-Path $script:LegacyFile) { Move-Item $script:LegacyFile (Join-Path $script:AccDir "$(New-Id).json") -Force }
  if (Test-Path $script:OldIndex) {
    try {
      $idx = Read-JsonFile $script:OldIndex
      foreach ($a in @($idx.list)) {
        $p = Join-Path $script:AccDir "$($a.id).json"
        if (Test-Path $p) {
          $d = Load-Data $p
          if (-not $d.accountName -or $d.accountName -eq 'Principale') { $d.accountName = $a.name }
          [IO.File]::WriteAllText($p, ($d | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        }
      }
      if ($idx.active -and (Test-Path (Join-Path $script:AccDir "$($idx.active).json"))) { [IO.File]::WriteAllText($script:ActiveFile, [string]$idx.active) }
      Move-Item $script:OldIndex "$($script:OldIndex).old" -Force
    } catch { Write-Log "Migrazione accounts.json: $_" }
  }
  $files = @(Get-ChildItem -Path $script:AccDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
  if ($files.Count -eq 0) {
    Set-ActiveId (New-Id)
    $script:Data = Get-DefaultData
    Save-Data
    return
  }
  $active = $null
  if (Test-Path $script:ActiveFile) { try { $active = ([IO.File]::ReadAllText($script:ActiveFile)).Trim() } catch {} }
  if (-not $active -or -not (Test-Path (Join-Path $script:AccDir "$active.json"))) {
    $active = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).BaseName
  }
  Set-ActiveId $active
  $script:Data = Load-Data $script:DataFile
}

function Switch-Account([string]$id) {
  if (-not (Test-Path (Join-Path $script:AccDir "$id.json"))) { return }
  Save-Data
  Set-ActiveId $id
  $script:Data = Load-Data $script:DataFile
  $script:Pend = @{ credits = $null; acoins = $null }
  $script:Ignore = @{ credits = $null; acoins = $null }
  if ($script:win) { Refresh-UI }
}

function New-Account([string]$name) {
  $prev = $script:Data
  Save-Data
  $d = Get-DefaultData
  $d.accountName = $name
  $d.goals = @()
  $d.firstRun = $false
  if ($prev) { foreach ($k in 'processPattern', 'autoRead', 'showBanner', 'autostart', 'missionCredits', 'missionAcoins') { $d.$k = $prev.$k } }
  Set-ActiveId (New-Id)
  $script:Data = $d
  $script:Pend = @{ credits = $null; acoins = $null }
  $script:Ignore = @{ credits = $null; acoins = $null }
  Save-Data
  if ($script:win) { Refresh-UI }
}

function Rename-Account {
  $n = $script:ui.AccRename.Text.Trim()
  if (-not $n) { return }
  $script:Data.accountName = $n
  Save-Data
  $script:ui.AccRename.Text = ''
  Refresh-UI
}

function Remove-Account {
  $accs = @(Get-Accounts)
  if ($accs.Count -le 1) { [void](Show-Msg (T "È l'unico account: non si può eliminare.")); return }
  $name = Get-AccountName
  $r = (Show-Msg (T "Eliminare l'account «{0}» con tutti i suoi obiettivi e la cronologia?`n`nIl file viene spostato nel Cestino di Windows." $name) -YesNo -Danger)
  if ("$r" -ne 'Yes') { return }
  $old = $script:DataFile
  $next = ($accs | Where-Object { $_.id -ne $script:ActiveId } | Select-Object -First 1).id
  Set-ActiveId $next
  $script:Data = Load-Data $script:DataFile
  try {
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($old, 'OnlyErrorDialogs', 'SendToRecycleBin')
  } catch { Write-Log "Eliminazione account: $_" }
  Refresh-UI
}

function Get-AutoRateInfo([string]$cur) {
  $none = @{ v = 0.0; days = 0; freq = 0.0; perDay = 0.0 }
  $ev = @($script:Data.events | Where-Object { $_.cur -eq $cur })
  if (-not $ev.Count) { return $none }
  $today = (Get-Date).Date
  $winStart = $today.AddDays(-27)
  $fg = @($ev | Where-Object { $_.kind -eq 'gain' })
  if (-not $fg.Count) { return $none }
  $first = ([datetime]$fg[0].t).Date
  $start = if ($first -gt $winStart) { $first } else { $winStart }
  $gains = @($ev | Where-Object { $_.kind -eq 'gain' -and ([datetime]$_.t).Date -ge $start } | ForEach-Object { [double]$_.delta } | Sort-Object)
  $cap = [double]::MaxValue
  if ($gains.Count -ge 4) { $cap = 10 * [math]::Max(1.0, $gains[[int][math]::Floor(($gains.Count - 1) / 2)]) }
  $net = @{}; $bonus = 0; $mis = @{}
  $mBudget = if ($cur -eq 'credits') { [double]$script:Data.missionCredits } else { [double]$script:Data.missionAcoins }
  foreach ($e in $ev) {
    $t = ([datetime]$e.t).Date
    if ($t -lt $start) { continue }
    if ($e.kind -eq 'gain' -and ([double]$e.delta -gt $cap -or [double]$e.delta -gt $(if ($cur -eq 'credits') { 5000000 } else { 100000 }))) { $bonus++; continue }
    if (-not $net.ContainsKey($t) -and ($e.kind -eq 'gain' -or $e.kind -eq 'mission')) { $net[$t] = 0.0; $mis[$t] = 0.0 }
    if ($e.kind -eq 'gain') { $net[$t] += [double]$e.delta }
    elseif ($e.kind -eq 'mission') {
      $take = [math]::Min(-[double]$e.delta, [math]::Max(0.0, $mBudget - $mis[$t]))
      $mis[$t] += $take; $net[$t] -= $take
    }
  }
  $play = @($net.Keys | Where-Object { $net[$_] -ne 0 } | Sort-Object)
  if (-not $play.Count) { return $none }
  $full = @($play | Where-Object { $_ -lt $today })
  $use = $play
  if ($full.Count -ge 1 -and $net.ContainsKey($today)) {
    $avg = ($full | ForEach-Object { $net[$_] } | Measure-Object -Average).Average
    if ($net[$today] -lt $avg) { $use = $full }
  }
  $sw = 0.0; $sv = 0.0
  foreach ($d in $use) {
    $w = [math]::Pow(0.5, ($today - $d).TotalDays / 7.0)
    $sw += $w; $sv += $w * $net[$d]
  }
  $perDay = $sv / $sw
  if ($perDay -le 0) { return @{ v = 0.0; days = $use.Count; freq = 0.0; perDay = $perDay; bonus = $bonus; negative = $true } }
  $lastDay = if ($use -contains $today) { $today } else { $today.AddDays(-1) }
  $span = [math]::Max(1.0, ($lastDay - $start).TotalDays + 1)
  $freq = if ($span -ge 7) { [math]::Min(1.0, $use.Count / $span) } else { 1.0 }
  @{ v = $perDay * $freq; days = $use.Count; freq = $freq; perDay = $perDay; partial = ($use.Count -eq 1 -and $use[0] -eq $today); bonus = $bonus }
}
function Get-AutoRate([string]$cur) { (Get-AutoRateInfo $cur).v }

function Get-Rate([string]$cur) {
  $manual = if ($cur -eq 'credits') { [double]$script:Data.rateCredits } else { [double]$script:Data.rateAcoins }
  if ($manual -gt $(if ($cur -eq 'credits') { 2000000 } else { 50000 })) { $manual = 0 }
  if ($manual -gt 0) { return @{ v = $manual; src = (T 'impostato da te') } }
  $a = Get-AutoRateInfo $cur
  if ($a.v -gt 0) {
    $src = if ($a.partial) { T 'automatico · prima sessione' } elseif ($a.days -eq 1) { T 'automatico · 1 giorno giocato' } else { T 'automatico · {0} giorni giocati' $a.days }
    return @{ v = $a.v; src = $src }
  }
  if ($cur -eq 'acoins') { return @{ v = 150.0; src = (T 'stima iniziale') } }
  @{ v = 0; src = '' }
}

function Format-AutoRate([string]$cur) {
  $a = Get-AutoRateInfo $cur
  $name = CurName $cur
  if ($a.negative) { return (T '{0}: ultimamente spendi più di quanto guadagni, il ritmo è zero.' $name) }
  if ($a.v -le 0) { return (T '{0}: ancora nessun guadagno registrato.' $name) }
  $dd = if ($a.days -eq 1) { T '1 giorno di dati' } else { T '{0} giorni di dati' $a.days }
  $txt = T '{0}: ~{1} al giorno · {2} per giorno giocato · giochi {3} giorni su 7 · {4}' $name (Fmt $a.v) (Fmt $a.perDay) (([math]::Round($a.freq * 7, 1)).ToString('0.#', $script:IT)) $dd
  if ($a.bonus -gt 0) { $txt += T ' · esclusi {0} guadagni una tantum' $a.bonus }
  if ($a.partial) { $txt += T ' (solo oggi: si assesta nei prossimi giorni)' }
  $txt
}

function Get-Today([string]$cur) {
  $today = (Get-Date).Date
  $g = 0.0; $s = 0.0
  foreach ($e in @($script:Data.events)) {
    if ($e.cur -ne $cur -or ([datetime]$e.t) -lt $today) { continue }
    if ($e.kind -eq 'gain') { $g += [double]$e.delta } elseif ($e.kind -in 'spend', 'mission', 'purchase') { $s += [double]$e.delta }
  }
  @{ gain = $g; spend = $s }
}

function Get-MissionBudget([string]$cur) {
  $budget = if ($cur -eq 'credits') { [double]$script:Data.missionCredits } else { [double]$script:Data.missionAcoins }
  $today = (Get-Date).Date
  $used = 0.0
  foreach ($e in @($script:Data.events)) {
    if ($e.cur -eq $cur -and $e.kind -eq 'mission' -and ([datetime]$e.t) -ge $today) { $used += - [double]$e.delta }
  }
  @{ budget = $budget; used = $used; left = [math]::Max(0.0, $budget - $used) }
}

function Get-Streak {
  [int][math]::Max(0.0, [math]::Floor(((Get-Date) - [datetime]$script:Data.cleanSince).TotalDays))
}

function Get-GoalStats {
  $res = @()
  $cum = @{ credits = 0.0; acoins = 0.0 }
  $prevName = @{ credits = $null; acoins = $null }
  $rank = 0
  foreach ($g in @($script:Data.goals)) {
    if ($g.done) { continue }
    $rank++
    $cur  = $g.currency
    $bal  = [double]$script:Data.$cur
    $cost = [double]$g.cost
    $before = $cum[$cur]
    $cum[$cur] += $cost
    $have = [math]::Max(0.0, [math]::Min($cost, $bal - $before))
    $pct  = if ($cost -gt 0) { $have / $cost } else { 1.0 }
    $remaining = [math]::Max(0.0, $cum[$cur] - $bal)
    $rate = Get-Rate $cur
    $days = if ($remaining -le 0) { 0 } elseif ($rate.v -gt 0) { $remaining / $rate.v } else { -1 }
    $isFirst = ($null -eq $prevName[$cur])
    $auth = $script:Data.purchase
    $res += [pscustomobject]@{
      goal = $g; rank = $rank; pct = $pct; remaining = $remaining; days = $days
      isFirst = $isFirst; after = $prevName[$cur]
      canBuy = ($isFirst -and $bal -ge $cost -and [bool]$script:Data.(InitProp $cur))
      authorized = ($auth -and $auth.goalId -eq $g.id -and [datetime]$auth.until -gt (Get-Date))
    }
    $prevName[$cur] = $g.name
  }
  $res
}

function Eta-Days([double]$days) {
  if ($days -lt 0) { return '—' }
  if ($days -eq 0) { return (T 'ora') }
  $dd = [int][math]::Ceiling($days)
  if ($dd -eq 1) { T '1 giorno' } else { T '{0} giorni' $dd }
}
function Eta-Fine([double]$days) {
  if ($days -lt 0) { return '—' }
  if ($days -lt 1 / 24.0) { return (T 'meno di un''ora') }
  if ($days -lt 1) { $h = [int][math]::Round($days * 24); return $(if ($h -eq 1) { T '1 ora' } else { T '{0} ore' $h }) }
  Eta-Days $days
}
function Eta-Date([double]$days) {
  if ($days -lt 0) { return (T 'imposta il ritmo') }
  if ($days -eq 0) { return (T 'oggi') }
  (Get-Date).AddDays([math]::Ceiling($days)).ToString('ddd d MMM', $script:IT)
}

function Get-GoalLines {
  $lines = @()
  foreach ($s in @(Get-GoalStats)) {
    $lines += ('{0}.  {1}  —  {2}% · {3}' -f $s.rank, $s.goal.name, [math]::Floor($s.pct * 100),
      $(if ($s.remaining -le 0) { T 'pronto' } else { T 'mancano {0} {1}' (Short $s.remaining) (CurName $s.goal.currency) }))
  }
  if (-not $lines) { $lines = @((T 'Nessun obiettivo attivo.')) }
  $lines
}

function Get-DailySeries([string]$cur, [int]$days) {
  $ev = @($script:Data.events | Where-Object { $_.cur -eq $cur })
  $out = New-Object 'System.Collections.Generic.List[object]'
  $i = 0; $last = $null
  for ($k = $days - 1; $k -ge 0; $k--) {
    $end = (Get-Date).Date.AddDays(1 - $k)
    while ($i -lt $ev.Count -and [datetime]$ev[$i].t -lt $end) { $last = [double]$ev[$i].bal; $i++ }
    $out.Add($last)
  }
  , $out.ToArray()
}

function Set-Autostart([bool]$on) {
  if ($script:IsTest) { return }
  try {
    if ($on) {
      $ws = New-Object -ComObject WScript.Shell
      $s = $ws.CreateShortcut($script:StartupLnk)
      $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
      $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Minimized -HideConsole"
      $s.WorkingDirectory = $script:Here
      $s.WindowStyle = 7
      $s.Description = 'MechVault - resource planner for Mech Arena'
      $s.Save()
    } elseif (Test-Path $script:StartupLnk) {
      Remove-Item $script:StartupLnk -Force
    }
  } catch { Write-Log "Autostart: $_" }
}

function Init-Ocr {
  try {
    if (-not ('MechVaultReader' -as [type])) {
      Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $script:Here 'MechVaultReader.cs')
    }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
    $script:AsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $script:OcrEng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    $script:OcrReady = [bool]$script:OcrEng
    if (-not $script:OcrReady) { Write-Log 'OCR: nessuna lingua OCR installata' }
  } catch { Write-Log "OCR init: $_"; $script:OcrReady = $false }
}

function Await-Op($op, [type]$t) {
  $task = $script:AsTask.MakeGenericMethod($t).Invoke($null, @($op))
  [void]$task.Wait(5000)
  $task.Result
}

function Ocr-Bitmap($bmp) {
  $ms = New-Object IO.MemoryStream
  try {
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $ms.Position = 0
    $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms)
    $dec = Await-Op ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sb  = Await-Op ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $res = Await-Op ($script:OcrEng.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    if ($res) { $res.Text } else { '' }
  } finally { $ms.Dispose() }
}

function Get-GameProcess {
  $pat = $script:Data.processPattern
  try {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $pat }) |
      Sort-Object { $_.MainWindowHandle -eq [IntPtr]::Zero } | Select-Object -First 1
  } catch { $null }
}

function Read-GameBalances($proc) {
  $res = @{}
  if (-not $script:OcrReady -or -not $proc -or $proc.MainWindowHandle -eq [IntPtr]::Zero) { return $res }
  $bmp = [MechVaultReader]::Capture($proc.MainWindowHandle)
  if (-not $bmp) { return $res }
  try {
    foreach ($c in @(@('credits', 172.0, 206.0), @('acoins', 278.0, 322.0))) {
      $r = [MechVaultReader]::FindAmountRect($bmp, $c[1], $c[2])
      if ($r.IsEmpty) { continue }
      foreach ($sc in 2, 1, 3) {
        $pb = [MechVaultReader]::PrepForOcr($bmp, $r, $sc)
        try { $v = Parse-GameNumber (Ocr-Bitmap $pb) } finally { $pb.Dispose() }
        if ($null -ne $v -and $v -lt 1e9) { $res[$c[0]] = [double]$v; break }
      }
    }
  } catch { Write-Log "Lettura: $_" } finally { $bmp.Dispose() }
  $res
}

$script:XamlRes = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="T1" Color="#F5F5F7"/>
  <SolidColorBrush x:Key="T2" Color="#B8FFFFFF"/>
  <SolidColorBrush x:Key="T3" Color="#7AFFFFFF"/>
  <SolidColorBrush x:Key="T4" Color="#52FFFFFF"/>

  <LinearGradientBrush x:Key="GlassFill" StartPoint="0,0" EndPoint="0,1">
    <GradientStop Color="#2EFFFFFF" Offset="0"/><GradientStop Color="#0CFFFFFF" Offset="0.12"/><GradientStop Color="#05FFFFFF" Offset="0.55"/><GradientStop Color="#05FFFFFF" Offset="0.85"/><GradientStop Color="#14FFFFFF" Offset="1"/>
  </LinearGradientBrush>
  <LinearGradientBrush x:Key="GlassEdge" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="#D9FFFFFF" Offset="0"/><GradientStop Color="#40FFFFFF" Offset="0.22"/><GradientStop Color="#12FFFFFF" Offset="0.55"/><GradientStop Color="#8CFFFFFF" Offset="1"/>
  </LinearGradientBrush>
  <LinearGradientBrush x:Key="GlassFillStrong" StartPoint="0,0" EndPoint="0,1">
    <GradientStop Color="#40FFFFFF" Offset="0"/><GradientStop Color="#14FFFFFF" Offset="0.45"/><GradientStop Color="#0DFFFFFF" Offset="0.8"/><GradientStop Color="#24FFFFFF" Offset="1"/>
  </LinearGradientBrush>
  <LinearGradientBrush x:Key="GCred" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#9BE3FF"/><GradientStop Color="#0A84FF" Offset="1"/></LinearGradientBrush>
  <LinearGradientBrush x:Key="GAc" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#F0C4FF"/><GradientStop Color="#BF5AF2" Offset="1"/></LinearGradientBrush>
  <LinearGradientBrush x:Key="GSafe" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#8CF0A8"/><GradientStop Color="#30D158" Offset="1"/></LinearGradientBrush>
  <LinearGradientBrush x:Key="GWarn" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FFE98A"/><GradientStop Color="#FFB340" Offset="1"/></LinearGradientBrush>

  <Style TargetType="TextBox">
    <Setter Property="Background" Value="#14FFFFFF"/>
    <Setter Property="Foreground" Value="#F5F5F7"/>
    <Setter Property="BorderBrush" Value="#1FFFFFFF"/>
    <Setter Property="CaretBrush" Value="#F5F5F7"/>
    <Setter Property="SelectionBrush" Value="#8FFFFFFF"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="Padding" Value="14,0"/>
    <Setter Property="Height" Value="42"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="14">
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#33FFFFFF"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#73FFFFFF"/><Setter TargetName="b" Property="Background" Value="#1FFFFFFF"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="Button">
    <Setter Property="Background" Value="{StaticResource GlassFillStrong}"/>
    <Setter Property="Foreground" Value="#F5F5F7"/>
    <Setter Property="BorderBrush" Value="{StaticResource GlassEdge}"/>
    <Setter Property="Padding" Value="18,10"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="20" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.82"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.65"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.38"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="#EBF5F5F7"/>
    <Setter Property="BorderBrush" Value="#FFFFFFFF"/>
    <Setter Property="Foreground" Value="#1C1C1E"/>
  </Style>
  <Style x:Key="Safe" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="{StaticResource GSafe}"/>
    <Setter Property="BorderBrush" Value="#66FFFFFF"/>
    <Setter Property="Foreground" Value="#0B2A14"/>
  </Style>
  <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="#E6FF453A"/>
    <Setter Property="BorderBrush" Value="#66FFFFFF"/>
    <Setter Property="Foreground" Value="White"/>
  </Style>
  <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="#B8FFFFFF"/>
    <Setter Property="FontWeight" Value="Normal"/>
  </Style>
  <Style x:Key="IconBtn" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="#7AFFFFFF"/>
    <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
    <Setter Property="FontWeight" Value="Normal"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Padding" Value="10,9"/>
    <Setter Property="Margin" Value="2,0,0,0"/>
  </Style>
  <Style x:Key="Chrome" TargetType="Button">
    <Setter Property="Foreground" Value="#B8FFFFFF"/>
    <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
    <Setter Property="FontSize" Value="10"/>
    <Setter Property="Width" Value="40"/>
    <Setter Property="Height" Value="32"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="Transparent" CornerRadius="16"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1FFFFFFF"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="ChromeClose" TargetType="Button" BasedOn="{StaticResource Chrome}">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="Transparent" CornerRadius="16"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#CCFF453A"/><Setter Property="Foreground" Value="White"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Seg" TargetType="RadioButton">
    <Setter Property="Foreground" Value="#B8FFFFFF"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="16" Padding="18,7">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#0FFFFFFF"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource GlassFillStrong}"/>
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource GlassEdge}"/>
              <Setter Property="Foreground" Value="#F5F5F7"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Pill" TargetType="RadioButton">
    <Setter Property="Foreground" Value="#B8FFFFFF"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" Background="#0FFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" CornerRadius="20" Padding="16,10" Margin="0,0,6,0">
            <ContentPresenter VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="b" Property="Background" Value="#33FFFFFF"/>
              <Setter TargetName="b" Property="BorderBrush" Value="#66FFFFFF"/>
              <Setter Property="Foreground" Value="#F5F5F7"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Switch" TargetType="CheckBox">
    <Setter Property="Foreground" Value="#F5F5F7"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Margin" Value="0,6"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <DockPanel Background="Transparent" LastChildFill="True">
            <Border x:Name="track" DockPanel.Dock="Right" Width="46" Height="28" CornerRadius="14" Background="#29FFFFFF" Margin="16,0,0,0" VerticalAlignment="Center">
              <Ellipse x:Name="knob" Width="22" Height="22" Fill="#F5F5F7" HorizontalAlignment="Left" Margin="3,0"/>
            </Border>
            <ContentPresenter VerticalAlignment="Center"/>
          </DockPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="track" Property="Background" Value="#30D158"/>
              <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="ToolTip">
    <Setter Property="Background" Value="#F02C2C2E"/>
    <Setter Property="Foreground" Value="#F5F5F7"/>
    <Setter Property="BorderBrush" Value="#33FFFFFF"/>
    <Setter Property="Padding" Value="10,6"/>
  </Style>

  <Style TargetType="ScrollBar">
    <Setter Property="Width" Value="10"/>
    <Setter Property="MinWidth" Value="10"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb"><Border Background="#33FFFFFF" CornerRadius="4" Margin="2"/></ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Card" TargetType="Border">
    <Setter Property="Background" Value="{StaticResource GlassFill}"/>
    <Setter Property="BorderBrush" Value="{StaticResource GlassEdge}"/>
    <Setter Property="BorderThickness" Value="1.2"/>
    <Setter Property="CornerRadius" Value="26"/>
    <Setter Property="Padding" Value="26,22"/>
  </Style>
  <Style x:Key="Label" TargetType="TextBlock">
    <Setter Property="Foreground" Value="#7AFFFFFF"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="H1" TargetType="TextBlock">
    <Setter Property="FontSize" Value="30"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="#F5F5F7"/>
  </Style>
  <Style x:Key="Big" TargetType="TextBlock">
    <Setter Property="FontSize" Value="44"/>
    <Setter Property="FontWeight" Value="Light"/>
    <Setter Property="Foreground" Value="#F5F5F7"/>
  </Style>
</ResourceDictionary>
'@

$script:XamlMain = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MechVault" Width="1180" Height="820" MinWidth="1020" MinHeight="660"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="Transparent" Foreground="#F5F5F7" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="64" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Grid x:Name="Root">
    <Grid.Background>
      <RadialGradientBrush Center="0.5,0.45" GradientOrigin="0.5,0.45" RadiusX="0.75" RadiusY="0.8">
        <GradientStop Color="#00FFFFFF" Offset="0.6"/><GradientStop Color="#0FFFFFFF" Offset="0.92"/><GradientStop Color="#1FFFFFFF" Offset="1"/>
      </RadialGradientBrush>
    </Grid.Background>
    <Grid.RowDefinitions><RowDefinition Height="68"/><RowDefinition/></Grid.RowDefinitions>
    <Border x:Name="Sheen" Grid.RowSpan="2" VerticalAlignment="Top" Height="90" IsHitTestVisible="False">
      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#1AFFFFFF"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Border.Background>
    </Border>

    <Grid Margin="22,14,12,0">
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Border Width="32" Height="32" CornerRadius="10" Background="{StaticResource GlassFillStrong}" BorderBrush="{StaticResource GlassEdge}" BorderThickness="1" Margin="0,0,10,0">
          <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#F5F5F7" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock Text="MechVault" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
      </StackPanel>

      <Border Grid.Column="1" CornerRadius="20" Padding="4" Background="#0FFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" VerticalAlignment="Center" WindowChrome.IsHitTestVisibleInChrome="True">
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="NavHome" Style="{StaticResource Seg}" Content="Panoramica" GroupName="nav" IsChecked="True"/>
          <RadioButton x:Name="NavGoals" Style="{StaticResource Seg}" Content="Obiettivi" GroupName="nav"/>
          <RadioButton x:Name="NavActivity" Style="{StaticResource Seg}" Content="Attività" GroupName="nav"/>
          <RadioButton x:Name="NavTools" Style="{StaticResource Seg}" Content="Strumenti" GroupName="nav"/>
          <RadioButton x:Name="NavSettings" Style="{StaticResource Seg}" Content="Impostazioni" GroupName="nav"/>
        </StackPanel>
      </Border>

      <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Button x:Name="BtnAccount" Padding="12,6" Margin="0,0,10,0" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="Cambia account">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE77B;" FontFamily="Segoe MDL2 Assets" FontSize="12" Margin="0,1,8,0" Foreground="#B8FFFFFF"/>
            <TextBlock x:Name="AccName" Text="—" MaxWidth="150" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="9" Margin="8,3,0,0" Foreground="#7AFFFFFF"/>
          </StackPanel>
        </Button>
        <Button x:Name="BtnMin" Style="{StaticResource Chrome}" Content="&#xE921;" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <Button x:Name="BtnMax" Style="{StaticResource Chrome}" Content="&#xE922;" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <Button x:Name="BtnClose" Style="{StaticResource ChromeClose}" Content="&#xE8BB;" WindowChrome.IsHitTestVisibleInChrome="True"/>
      </StackPanel>
    </Grid>

    <ScrollViewer x:Name="PageHome" Grid.Row="1" VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="40,14,40,40" MaxWidth="1000">
        <DockPanel>
          <Border x:Name="StreakChip" DockPanel.Dock="Right" VerticalAlignment="Center" CornerRadius="18" Padding="14,8" Background="#1F30D158" BorderBrush="#4D30D158" BorderThickness="1">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" Foreground="#30D158" Margin="0,2,8,0" FontSize="12"/>
              <TextBlock x:Name="StreakChipTxt" Text="0 giorni puliti" Foreground="#B5F5C8" FontWeight="SemiBold"/>
            </StackPanel>
          </Border>
          <Border DockPanel.Dock="Right" CornerRadius="18" Padding="14,8" Background="#0FFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" Margin="0,0,10,0" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <Grid Width="10" Height="10" Margin="0,0,8,0" VerticalAlignment="Center">
                <Ellipse x:Name="StatusGlow" Fill="#4D30D158" Width="10" Height="10"/>
                <Ellipse x:Name="StatusDot" Fill="#30D158" Width="6" Height="6"/>
              </Grid>
              <TextBlock x:Name="StatusTitle" Text="Blocco attivo" Foreground="#B8FFFFFF" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <StackPanel>
            <TextBlock x:Name="Hello" Text="Ciao, pilota" Style="{StaticResource H1}"/>
            <TextBlock Foreground="#7AFFFFFF" Margin="0,4,0,0"><Run x:Name="DateTxt"/><Run Text="  ·  "/><Run x:Name="GameTxt"/><Run Text="  ·  "/><Run x:Name="ReadTxt"/></TextBlock>
          </StackPanel>
        </DockPanel>

        <Border x:Name="Notice" Margin="0,20,0,0" CornerRadius="18" Padding="18,12" Background="#0FFFFFFF" BorderBrush="#1AFFFFFF" BorderThickness="1">
          <DockPanel>
            <TextBlock x:Name="NoticeIcon" Text="&#xE946;" FontFamily="Segoe MDL2 Assets" Foreground="#B8FFFFFF" Margin="0,2,12,0" FontSize="13"/>
            <TextBlock x:Name="NoticeTxt" TextWrapping="Wrap" Foreground="#B8FFFFFF"/>
          </DockPanel>
        </Border>

        <Border Style="{StaticResource Card}" Margin="0,16,0,0" Padding="32,28" CornerRadius="30">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Grid Width="184" Height="184" Margin="0,0,36,0">
              <Ellipse Stroke="#17FFFFFF" StrokeThickness="12" Margin="6"/>
              <Path x:Name="RingPath" StrokeThickness="12" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stroke="{StaticResource GCred}">
                <Path.Effect><DropShadowEffect x:Name="RingGlow" Color="#64D2FF" BlurRadius="16" ShadowDepth="0" Opacity="0.45"/></Path.Effect>
              </Path>
              <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                <TextBlock x:Name="RingPct" Text="0%" FontSize="44" FontWeight="Light" HorizontalAlignment="Center"/>
                <TextBlock Text="completato" Foreground="#7AFFFFFF" FontSize="12" HorizontalAlignment="Center" Margin="0,-4,0,0"/>
              </StackPanel>
            </Grid>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
              <TextBlock x:Name="HeroLabel" Text="Prossimo obiettivo" Style="{StaticResource Label}"/>
              <TextBlock x:Name="HeroName" Text="—" FontSize="28" FontWeight="SemiBold" Margin="0,6,0,2" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="HeroCost" Foreground="#B8FFFFFF"/>
              <UniformGrid Columns="3" Margin="0,22,0,0">
                <StackPanel Margin="0,0,12,0">
                  <TextBlock Text="Mancano" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="HeroLeft" Text="—" FontSize="24" FontWeight="Light" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Margin="0,0,12,0">
                  <TextBlock Text="Tempo stimato" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="HeroEta" Text="—" FontSize="24" FontWeight="Light" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel>
                  <TextBlock Text="Pronto entro" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="HeroDate" Text="—" FontSize="24" FontWeight="Light" Margin="0,2,0,0"/>
                </StackPanel>
              </UniformGrid>
              <StackPanel Orientation="Horizontal" Margin="0,20,0,0">
                <Button x:Name="HeroBuy" Style="{StaticResource Safe}" Content="Compra ora" Visibility="Collapsed" Margin="0,0,12,0"/>
                <TextBlock x:Name="HeroHint" Foreground="#7AFFFFFF" VerticalAlignment="Center" TextWrapping="Wrap" FontSize="12"/>
              </StackPanel>
            </StackPanel>
          </Grid>
        </Border>

        <Grid Margin="0,16,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <DockPanel>
                <Border x:Name="CredTodayChip" DockPanel.Dock="Right" CornerRadius="12" Padding="10,4" Background="#14FFFFFF" VerticalAlignment="Center">
                  <TextBlock x:Name="CredToday" Text="oggi 0" Foreground="#B8FFFFFF" FontSize="12" FontWeight="SemiBold"/>
                </Border>
                <Ellipse Width="9" Height="9" Fill="#64D2FF" Margin="0,0,9,0" VerticalAlignment="Center"/>
                <TextBlock Text="Crediti" Foreground="#B8FFFFFF" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </DockPanel>
              <TextBlock x:Name="CredVal" Text="—" Style="{StaticResource Big}" Margin="0,12,0,0"/>
              <TextBlock x:Name="CredRate" Foreground="#7AFFFFFF" FontSize="12" TextWrapping="Wrap"/>
              <Canvas x:Name="SparkCred" Height="56" Margin="0,16,0,0" ClipToBounds="False"/>
            </StackPanel>
          </Border>
          <Border Grid.Column="2" Style="{StaticResource Card}">
            <StackPanel>
              <DockPanel>
                <Border x:Name="AcTodayChip" DockPanel.Dock="Right" CornerRadius="12" Padding="10,4" Background="#14FFFFFF" VerticalAlignment="Center">
                  <TextBlock x:Name="AcToday" Text="oggi 0" Foreground="#B8FFFFFF" FontSize="12" FontWeight="SemiBold"/>
                </Border>
                <Ellipse Width="9" Height="9" Fill="#DA8FFF" Margin="0,0,9,0" VerticalAlignment="Center"/>
                <TextBlock Text="A-coin" Foreground="#B8FFFFFF" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </DockPanel>
              <TextBlock x:Name="AcVal" Text="—" Style="{StaticResource Big}" Margin="0,12,0,0"/>
              <TextBlock x:Name="AcRate" Foreground="#7AFFFFFF" FontSize="12" TextWrapping="Wrap"/>
              <Canvas x:Name="SparkAc" Height="56" Margin="0,16,0,0" ClipToBounds="False"/>
            </StackPanel>
          </Border>
        </Grid>

        <Grid Margin="0,16,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Serie senza spese" Style="{StaticResource Label}"/>
              <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                <TextBlock x:Name="StreakBig" Text="0" FontSize="60" FontWeight="Light" Foreground="#F5F5F7"/>
                <TextBlock Text="giorni" Foreground="#7AFFFFFF" FontSize="16" VerticalAlignment="Bottom" Margin="10,0,0,14"/>
              </StackPanel>
              <TextBlock x:Name="BestTxt" Foreground="#7AFFFFFF" FontSize="12"/>
              <UniformGrid x:Name="Cal" Columns="14" Rows="1" Height="18" Margin="0,18,0,6"/>
              <DockPanel>
                <TextBlock DockPanel.Dock="Right" Text="oggi" Foreground="#52FFFFFF" FontSize="11"/>
                <TextBlock Text="14 giorni fa" Foreground="#52FFFFFF" FontSize="11"/>
              </DockPanel>
            </StackPanel>
          </Border>
          <Border Grid.Column="2" Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Budget missioni di oggi" Style="{StaticResource Label}"/>
              <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                <TextBlock x:Name="MisUsed" Text="0" FontSize="60" FontWeight="Light"/>
                <TextBlock x:Name="MisTot" Text="/ 2.000 crediti" Foreground="#7AFFFFFF" FontSize="16" VerticalAlignment="Bottom" Margin="10,0,0,14"/>
              </StackPanel>
              <Grid x:Name="MisBar" Height="8" Margin="0,8,0,12">
                <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
                <Border Grid.ColumnSpan="2" Background="#17FFFFFF" CornerRadius="4"/>
                <Border Background="{StaticResource GWarn}" CornerRadius="4"/>
              </Grid>
              <TextBlock x:Name="MisSub" Foreground="#7AFFFFFF" FontSize="12" TextWrapping="Wrap" Text="Spese per le missioni giornaliere (es. «usa 2.000 crediti»): non rompono la serie. Si azzera a mezzanotte."/>
            </StackPanel>
          </Border>
        </Grid>

        <Border Style="{StaticResource Card}" Margin="0,16,0,0">
          <StackPanel>
            <DockPanel>
              <Button x:Name="BtnAllActivity" DockPanel.Dock="Right" Style="{StaticResource Ghost}" Content="Vedi tutto" Padding="6,0" FontSize="12"/>
              <TextBlock Text="Ultime attività" Style="{StaticResource Label}" VerticalAlignment="Center"/>
            </DockPanel>
            <StackPanel x:Name="RecentList" Margin="0,14,0,0"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>

    <ScrollViewer x:Name="PageGoals" Grid.Row="1" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
      <StackPanel Margin="40,14,40,40" MaxWidth="1000">
        <TextBlock Text="Obiettivi" Style="{StaticResource H1}"/>
        <TextBlock x:Name="GoalsSummary" Foreground="#7AFFFFFF" Margin="0,4,0,22"/>
        <StackPanel x:Name="GoalsPanel"/>
        <Border Style="{StaticResource Card}" Margin="0,6,0,0">
          <StackPanel>
            <TextBlock Text="Nuovo obiettivo" Style="{StaticResource Label}"/>
            <Grid Margin="0,12,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/><ColumnDefinition Width="140"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="GoalName" ToolTip="Nome (es. Hadron Lance liv. 20)"/>
              <TextBox x:Name="GoalCost" Grid.Column="1" Margin="10,0,0,0" ToolTip="Costo (es. 827k)"/>
              <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="10,0,0,0">
                <RadioButton x:Name="RbCred" Content="Crediti" GroupName="cur" IsChecked="True" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="RbAc" Content="A-coin" GroupName="cur" Style="{StaticResource Pill}"/>
              </StackPanel>
              <Button x:Name="GoalAdd" Grid.Column="3" Content="Aggiungi" Style="{StaticResource Primary}"/>
            </Grid>
            <TextBlock Text="Nome · costo (es. 827k) · valuta. L'ordine conta: si può comprare solo il primo della lista per ogni valuta." Foreground="#52FFFFFF" FontSize="11" Margin="4,8,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>

    <ScrollViewer x:Name="PageActivity" Grid.Row="1" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
      <StackPanel Margin="40,14,40,40" MaxWidth="1000">
        <TextBlock Text="Attività" Style="{StaticResource H1}"/>
        <TextBlock Text="Tutto quello che MechVault ha visto cambiare nei tuoi saldi." Foreground="#7AFFFFFF" Margin="0,4,0,22"/>
        <UniformGrid Columns="4" Margin="0,0,0,16">
          <Border Style="{StaticResource Card}" Margin="0,0,12,0" Padding="20,16">
            <StackPanel><TextBlock Text="Crediti guadagnati · 14 gg" Style="{StaticResource Label}"/><TextBlock x:Name="StatGainC" Text="0" FontSize="26" FontWeight="Light" Margin="0,4,0,0"/></StackPanel>
          </Border>
          <Border Style="{StaticResource Card}" Margin="0,0,12,0" Padding="20,16">
            <StackPanel><TextBlock Text="A-coin guadagnate · 14 gg" Style="{StaticResource Label}"/><TextBlock x:Name="StatGainA" Text="0" FontSize="26" FontWeight="Light" Margin="0,4,0,0"/></StackPanel>
          </Border>
          <Border Style="{StaticResource Card}" Margin="0,0,12,0" Padding="20,16">
            <StackPanel><TextBlock Text="Crediti sprecati · 14 gg" Style="{StaticResource Label}"/><TextBlock x:Name="StatSpendC" Text="0" FontSize="26" FontWeight="Light" Foreground="#FF8A80" Margin="0,4,0,0"/></StackPanel>
          </Border>
          <Border Style="{StaticResource Card}" Padding="20,16">
            <StackPanel><TextBlock Text="A-coin sprecate · 14 gg" Style="{StaticResource Label}"/><TextBlock x:Name="StatSpendA" Text="0" FontSize="26" FontWeight="Light" Foreground="#FF8A80" Margin="0,4,0,0"/></StackPanel>
          </Border>
        </UniformGrid>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions>
          <Border Style="{StaticResource Card}" VerticalAlignment="Top">
            <StackPanel>
              <TextBlock Text="Cronologia" Style="{StaticResource Label}"/>
              <StackPanel x:Name="ActivityList" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>
          <Border Grid.Column="2" Style="{StaticResource Card}" VerticalAlignment="Top">
            <StackPanel>
              <TextBlock Text="Confessionale" Style="{StaticResource Label}"/>
              <TextBlock x:Name="ViolTotal" Foreground="#B8FFFFFF" TextWrapping="Wrap" Margin="0,8,0,6"/>
              <StackPanel x:Name="ViolPanel"/>
            </StackPanel>
          </Border>
        </Grid>
      </StackPanel>
    </ScrollViewer>

    <ScrollViewer x:Name="PageTools" Grid.Row="1" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
      <StackPanel Margin="40,14,40,40" MaxWidth="820">
        <TextBlock Text="Strumenti" Style="{StaticResource H1}"/>
        <TextBlock Text="Pianifica i potenziamenti con le risorse lette dal gioco. Calcolatore e gestore di obiettivi sono di MechVault: niente siti esterni." Foreground="#7AFFFFFF" Margin="0,4,0,22" TextWrapping="Wrap"/>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Le mie risorse" Style="{StaticResource Label}"/>
            <TextBlock x:Name="ToolAccount" Foreground="#7AFFFFFF" FontSize="12" Margin="0,4,0,0"/>
            <Grid Margin="0,10,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Border CornerRadius="20" Padding="20,14" Background="#0FFFFFFF" BorderBrush="#1AFFFFFF" BorderThickness="1">
                <DockPanel>
                  <Button x:Name="BtnCopyCred" DockPanel.Dock="Right" Content="Copia" Padding="14,7" VerticalAlignment="Center"/>
                  <StackPanel>
                    <StackPanel Orientation="Horizontal"><Ellipse Width="9" Height="9" Fill="#64D2FF" Margin="0,0,9,0" VerticalAlignment="Center"/><TextBlock Text="Crediti" Foreground="#B8FFFFFF" FontWeight="SemiBold"/></StackPanel>
                    <TextBlock x:Name="ToolCred" Text="—" FontSize="32" FontWeight="Light"/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <Border Grid.Column="2" CornerRadius="20" Padding="20,14" Background="#0FFFFFFF" BorderBrush="#1AFFFFFF" BorderThickness="1">
                <DockPanel>
                  <Button x:Name="BtnCopyAc" DockPanel.Dock="Right" Content="Copia" Padding="14,7" VerticalAlignment="Center"/>
                  <StackPanel>
                    <StackPanel Orientation="Horizontal"><Ellipse Width="9" Height="9" Fill="#DA8FFF" Margin="0,0,9,0" VerticalAlignment="Center"/><TextBlock Text="A-coin" Foreground="#B8FFFFFF" FontWeight="SemiBold"/></StackPanel>
                    <TextBlock x:Name="ToolAc" Text="—" FontSize="32" FontWeight="Light"/>
                  </StackPanel>
                </DockPanel>
              </Border>
            </Grid>
            <TextBlock x:Name="ToolMsg" Foreground="#8CF0A8" Margin="4,10,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>

        <Border x:Name="CalcCard" Style="{StaticResource Card}" Margin="0,14,0,0">
          <StackPanel>
            <DockPanel>
              <Border DockPanel.Dock="Right" CornerRadius="12" Padding="10,4" Background="#14FFFFFF" VerticalAlignment="Center">
                <TextBlock Text="MechVault" Foreground="#B8FFFFFF" FontSize="11" FontWeight="SemiBold"/>
              </Border>
              <TextBlock Text="Calcolatore potenziamenti" FontSize="20" FontWeight="SemiBold"/>
            </DockPanel>
            <TextBlock TextWrapping="Wrap" Foreground="#B8FFFFFF" Margin="0,8,0,0" Text="Mech o arma, rarità, da quale stella e livello a quale: somma crediti, blueprint e A-coin e li confronta con le tue risorse."/>
            <Grid Margin="0,16,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="CalcName" ToolTip="Nome dell'oggetto"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="10,0,0,0">
                <RadioButton x:Name="CalcWeapon" Content="Arma" GroupName="calckind" IsChecked="True" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CalcMech" Content="Mech" GroupName="calckind" Style="{StaticResource Pill}"/>
              </StackPanel>
            </Grid>
            <WrapPanel Margin="0,10,0,0">
              <RadioButton x:Name="CalcR_common" Content="Comune" GroupName="calcrar" Style="{StaticResource Pill}"/>
              <RadioButton x:Name="CalcR_uncommon" Content="Non comune" GroupName="calcrar" Style="{StaticResource Pill}"/>
              <RadioButton x:Name="CalcR_rare" Content="Raro" GroupName="calcrar" Style="{StaticResource Pill}"/>
              <RadioButton x:Name="CalcR_epic" Content="Epico" GroupName="calcrar" IsChecked="True" Style="{StaticResource Pill}"/>
              <RadioButton x:Name="CalcR_legendary" Content="Leggendario" GroupName="calcrar" Style="{StaticResource Pill}"/>
            </WrapPanel>
            <StackPanel x:Name="CalcEnergyPanel" Margin="0,12,0,0">
              <TextBlock Text="Energia dell'arma (la vedi nella scheda dell'arma)" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,6"/>
              <WrapPanel>
                <RadioButton x:Name="CalcE_2" Content="2" GroupName="calcen" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CalcE_4" Content="4" GroupName="calcen" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CalcE_6" Content="6" GroupName="calcen" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CalcE_8" Content="8" GroupName="calcen" IsChecked="True" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CalcE_10" Content="10" GroupName="calcen" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CalcE_12" Content="12" GroupName="calcen" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CalcE_14" Content="14" GroupName="calcen" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CalcE_16" Content="16" GroupName="calcen" Style="{StaticResource Pill}"/>
              </WrapPanel>
            </StackPanel>
            <Grid Margin="0,14,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel><TextBlock Text="Da stella" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="CalcFS" Text="4"/></StackPanel>
              <StackPanel Grid.Column="1" Margin="8,0,0,0"><TextBlock Text="Da livello" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="CalcFL" Text="1"/></StackPanel>
              <TextBlock Grid.Column="2" Text="→" Foreground="#7AFFFFFF" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,10"/>
              <StackPanel Grid.Column="3"><TextBlock Text="A stella" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="CalcTS" Text="6"/></StackPanel>
              <StackPanel Grid.Column="4" Margin="8,0,0,0"><TextBlock Text="A livello" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="CalcTL" Text="7"/></StackPanel>
              <Button x:Name="BtnCalcMax" Grid.Column="5" Content="Al massimo" VerticalAlignment="Bottom" Margin="10,0,0,0"/>
            </Grid>
            <TextBlock Text="1-6 stelle, 7 livelli per stella. Dopo il livello 7 si sale di stella e si riparte dal livello 1. Il massimo è 6 stelle livello 7." Foreground="#52FFFFFF" FontSize="11" Margin="4,8,0,0" TextWrapping="Wrap"/>
            <Button x:Name="BtnCalcRun" Style="{StaticResource Primary}" Content="Calcola il costo del potenziamento" HorizontalAlignment="Stretch" Margin="0,16,0,0" Padding="18,13" FontSize="14"/>
            <TextBlock x:Name="CalcHint" Foreground="#7AFFFFFF" FontSize="12" Margin="4,8,0,0" TextWrapping="Wrap"/>

            <StackPanel x:Name="CalcResult" Visibility="Collapsed">
            <TextBlock Text="Costo totale del potenziamento" FontSize="17" FontWeight="SemiBold" Margin="0,22,0,0"/>
            <TextBlock x:Name="CalcSummary" Foreground="#B8FFFFFF" Margin="0,4,0,0" TextWrapping="Wrap"/>
            <Grid Margin="0,14,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Border CornerRadius="20" Padding="18,12" Background="#0FFFFFFF" BorderBrush="#1AFFFFFF" BorderThickness="1">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><Ellipse Width="9" Height="9" Fill="#64D2FF" Margin="0,0,9,0" VerticalAlignment="Center"/><TextBlock Text="Crediti" Foreground="#B8FFFFFF" FontWeight="SemiBold"/></StackPanel>
                  <TextBlock x:Name="CalcTotC" Text="0" FontSize="26" FontWeight="Light"/>
                  <TextBlock x:Name="CalcNeedC" Foreground="#7AFFFFFF" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="2" CornerRadius="20" Padding="18,12" Background="#0FFFFFFF" BorderBrush="#1AFFFFFF" BorderThickness="1">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><Ellipse Width="9" Height="9" Fill="#FFD60A" Margin="0,0,9,0" VerticalAlignment="Center"/><TextBlock Text="Blueprint" Foreground="#B8FFFFFF" FontWeight="SemiBold"/></StackPanel>
                  <TextBlock x:Name="CalcTotB" Text="0" FontSize="26" FontWeight="Light"/>
                  <TextBox x:Name="CalcMyBp" Height="30" FontSize="12" Margin="0,4,0,4" ToolTip="I miei blueprint"/>
                  <TextBlock x:Name="CalcNeedB" Foreground="#7AFFFFFF" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="4" CornerRadius="20" Padding="18,12" Background="#0FFFFFFF" BorderBrush="#1AFFFFFF" BorderThickness="1">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><Ellipse Width="9" Height="9" Fill="#DA8FFF" Margin="0,0,9,0" VerticalAlignment="Center"/><TextBlock Text="A-coin" Foreground="#B8FFFFFF" FontWeight="SemiBold"/></StackPanel>
                  <TextBlock x:Name="CalcTotA" Text="0" FontSize="26" FontWeight="Light"/>
                  <TextBlock x:Name="CalcNeedA" Foreground="#7AFFFFFF" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </Grid>
            <TextBlock x:Name="CalcInfo" Foreground="#B8FFFFFF" Margin="4,12,0,0" TextWrapping="Wrap"/>
            <WrapPanel Margin="0,14,0,0">
              <Button x:Name="BtnCalcGoal" Style="{StaticResource Primary}" Content="Aggiungi agli obiettivi" Margin="0,0,8,8"/>
              <Button x:Name="BtnCalcImport" Content="Importa tabella" Margin="0,0,8,8"/>
              <Button x:Name="BtnCalcExport" Content="Esporta tabella" Margin="0,0,8,8"/>
            </WrapPanel>
            <TextBlock x:Name="CalcMsg" Foreground="#8CF0A8" Margin="4,2,0,0" TextWrapping="Wrap"/>
            <Button x:Name="BtnCalcDetail" Content="Mostra il dettaglio passo per passo" HorizontalAlignment="Left" Margin="0,8,0,0"/>

            <StackPanel x:Name="CalcBreakdown" Visibility="Collapsed">
            <TextBlock Text="Costi passo per passo" Style="{StaticResource Label}" Margin="0,20,0,0"/>
            <TextBlock TextWrapping="Wrap" Foreground="#7AFFFFFF" FontSize="12" Margin="0,6,0,10" Text="Costi già inclusi dal Mech Arena Wiki (Fandom, licenza CC BY-SA 3.0). Se nel gioco vedi un numero diverso correggilo qui: la tua correzione vale per tutti gli oggetti uguali. Una casella vuota è un costo che il wiki non ha. Con Esporta/Importa condividi la tabella con altri piloti."/>
            <Grid Margin="0,0,0,4">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="130"/><ColumnDefinition Width="110"/><ColumnDefinition Width="110"/></Grid.ColumnDefinitions>
              <TextBlock Text="Passo" Foreground="#7AFFFFFF" FontSize="11"/>
              <TextBlock Grid.Column="1" Text="Crediti" Foreground="#7AFFFFFF" FontSize="11" Margin="12,0,0,0"/>
              <TextBlock Grid.Column="2" Text="Blueprint" Foreground="#7AFFFFFF" FontSize="11" Margin="12,0,0,0"/>
              <TextBlock Grid.Column="3" Text="A-coin" Foreground="#7AFFFFFF" FontSize="11" Margin="12,0,0,0"/>
            </Grid>
            <StackPanel x:Name="CalcSteps"/>
            </StackPanel>
            </StackPanel>
          </StackPanel>
        </Border>

        <Border x:Name="CrateCard" Style="{StaticResource Card}" Margin="0,14,0,0">
          <StackPanel>
            <DockPanel>
              <Border DockPanel.Dock="Right" CornerRadius="12" Padding="10,4" Background="#14FFFFFF" VerticalAlignment="Center">
                <TextBlock Text="MechVault" Foreground="#B8FFFFFF" FontSize="11" FontWeight="SemiBold"/>
              </Border>
              <TextBlock Text="Analisi Crate Rush" FontSize="20" FontWeight="SemiBold"/>
            </DockPanel>
            <TextBlock TextWrapping="Wrap" Foreground="#B8FFFFFF" Margin="0,8,0,0" Text="Confronta una Crate Rush (a A-coin o a crediti) con l'acquisto diretto nel Gear Hub (a crediti o A-coin), usando il tuo ritmo: quanto costa in media, nel caso peggiore, e fino a quanto ha senso spendere."/>
            <Grid Margin="0,14,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="CrName" ToolTip="Premio principale della Crate Rush"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="10,0,0,0">
                <RadioButton x:Name="CrKW" Content="Arma" GroupName="crkind" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CrKM" Content="Mech" GroupName="crkind" IsChecked="True" Style="{StaticResource Pill}"/>
              </StackPanel>
            </Grid>
            <WrapPanel Margin="0,10,0,0">
              <RadioButton x:Name="CrR_common" Content="Comune" GroupName="crrar" Style="{StaticResource Pill}"/>
              <RadioButton x:Name="CrR_uncommon" Content="Non comune" GroupName="crrar" Style="{StaticResource Pill}"/>
              <RadioButton x:Name="CrR_rare" Content="Raro" GroupName="crrar" Style="{StaticResource Pill}"/>
              <RadioButton x:Name="CrR_epic" Content="Epico" GroupName="crrar" Style="{StaticResource Pill}"/>
              <RadioButton x:Name="CrR_legendary" Content="Leggendario" GroupName="crrar" IsChecked="True" Style="{StaticResource Pill}"/>
            </WrapPanel>
            <StackPanel x:Name="CrEnergyPanel" Margin="0,10,0,0" Visibility="Collapsed">
              <TextBlock Text="Energia dell'arma (la vedi nella scheda dell'arma)" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,6"/>
              <WrapPanel>
                <RadioButton x:Name="CrE_2" Content="2" GroupName="cren" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CrE_4" Content="4" GroupName="cren" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CrE_6" Content="6" GroupName="cren" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CrE_8" Content="8" GroupName="cren" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CrE_10" Content="10" GroupName="cren" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CrE_12" Content="12" GroupName="cren" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CrE_14" Content="14" GroupName="cren" Style="{StaticResource Pill}"/>
                <RadioButton x:Name="CrE_16" Content="16" GroupName="cren" IsChecked="True" Style="{StaticResource Pill}"/>
              </WrapPanel>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <TextBlock Text="Gli spin si pagano in" Foreground="#7AFFFFFF" VerticalAlignment="Center" Margin="4,0,10,0"/>
              <RadioButton x:Name="CrAc" Content="A-coin" GroupName="crcur" IsChecked="True" Style="{StaticResource Pill}"/>
              <RadioButton x:Name="CrCr" Content="crediti" GroupName="crcur" Style="{StaticResource Pill}"/>
            </StackPanel>
            <Grid Margin="0,12,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel><TextBlock Text="Costo di uno spin" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="CrSpin"/></StackPanel>
              <StackPanel Grid.Column="2"><TextBlock Text="Probabilità del premio a spin (%)" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="CrP" ToolTip="La trovi nelle info della Crate Rush (es. 1,5)"/></StackPanel>
              <StackPanel Grid.Column="4"><TextBlock Text="Garantito spendendo (0 = no)" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="CrPity" Text="7.000" ToolTip="Di solito 7.000 A-coin per la Crate Rush"/></StackPanel>
            </Grid>
            <Grid Margin="0,12,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Prezzo dello stesso oggetto nel Gear Hub" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="CrDirect"/>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="8,0,0,0" VerticalAlignment="Center">
                    <RadioButton x:Name="CrDirCr" Content="crediti" GroupName="crdir" IsChecked="True" Style="{StaticResource Pill}"/>
                    <RadioButton x:Name="CrDirAc" Content="A-coin" GroupName="crdir" Style="{StaticResource Pill}"/>
                  </StackPanel>
                </Grid>
              </StackPanel>
              <Button x:Name="CrFromCalc" Grid.Column="1" Content="Dal calcolatore" VerticalAlignment="Bottom" Margin="8,0,0,0"/>
              <StackPanel Grid.Column="3"><TextBlock Text="Quanto vorresti spendere (facoltativo)" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="CrBudget"/></StackPanel>
            </Grid>
            <CheckBox x:Name="CrUpg" Style="{StaticResource Switch}" IsChecked="True" Margin="0,14,0,0" Content="Conta la differenza di rango tra il premio e il Gear Hub"/>
            <Grid x:Name="CrUpgGrid" Margin="0,6,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Il premio della cassa arriva a ★ / liv." Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="6"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <TextBox x:Name="CrPS" Text="4"/><TextBox x:Name="CrPL" Grid.Column="2" Text="1"/></Grid>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Text="Comprato nel Gear Hub arriva a ★ / liv." Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="6"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <TextBox x:Name="CrDS" Text="5"/><TextBox x:Name="CrDL" Grid.Column="2" Text="1"/></Grid>
              </StackPanel>
            </Grid>
            <DockPanel Margin="0,18,0,0">
              <Button x:Name="CrAddPrize" DockPanel.Dock="Right" Content="+ Aggiungi premio" Padding="14,7"/>
              <StackPanel>
                <TextBlock Text="Altri premi della stessa Crate Rush" Foreground="#B8FFFFFF" FontWeight="SemiBold"/>
                <TextBlock Text="Ogni premio con la sua probabilità a spin e il prezzo nel Gear Hub. Spunta «Lo voglio» solo per quelli che useresti davvero: gli altri valgono zero." Foreground="#7AFFFFFF" FontSize="11" TextWrapping="Wrap" Margin="0,2,12,0"/>
              </StackPanel>
            </DockPanel>
            <Grid x:Name="CrPrizeHead" Margin="0,10,0,4" Visibility="Collapsed">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="100"/><ColumnDefinition Width="130"/><ColumnDefinition Width="180"/><ColumnDefinition Width="112"/><ColumnDefinition Width="36"/></Grid.ColumnDefinitions>
              <TextBlock Text="Premio" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,0"/>
              <TextBlock Grid.Column="1" Text="Prob. %" Foreground="#7AFFFFFF" FontSize="11" Margin="12,0,0,0"/>
              <TextBlock Grid.Column="2" Text="Prezzo Gear Hub" Foreground="#7AFFFFFF" FontSize="11" Margin="12,0,0,0"/>
              <TextBlock Grid.Column="3" Text="Valuta" Foreground="#7AFFFFFF" FontSize="11" Margin="12,0,0,0"/>
            </Grid>
            <StackPanel x:Name="CrPrizes"/>
            <Border x:Name="CrVerdictBox" CornerRadius="20" Padding="18,14" Margin="0,16,0,0" Background="#0FFFFFFF" BorderBrush="#1AFFFFFF" BorderThickness="1">
              <StackPanel>
                <TextBlock x:Name="CrVerdict" FontSize="18" FontWeight="SemiBold" TextWrapping="Wrap"/>
                <TextBlock x:Name="CrStats" Foreground="#B8FFFFFF" Margin="0,8,0,0" TextWrapping="Wrap" LineHeight="21"/>
              </StackPanel>
            </Border>
            <TextBlock TextWrapping="Wrap" Foreground="#52FFFFFF" FontSize="11" Margin="4,8,0,0" Text="Ogni premio vale quanto costerebbe nel Gear Hub, in giorni di grind al tuo ritmo; un doppione non vale niente. Le probabilità le trovi nelle info della Crate Rush (pulsante i)."/>
          </StackPanel>
        </Border>

        <Border x:Name="MechCard" Style="{StaticResource Card}" Margin="0,14,0,0">
          <StackPanel>
            <DockPanel>
              <Border DockPanel.Dock="Right" CornerRadius="12" Padding="10,4" Background="#14FFFFFF" VerticalAlignment="Center">
                <TextBlock Text="MechVault" Foreground="#B8FFFFFF" FontSize="11" FontWeight="SemiBold"/>
              </Border>
              <TextBlock Text="Scheda mech" FontSize="20" FontWeight="SemiBold"/>
            </DockPanel>
            <TextBlock TextWrapping="Wrap" Foreground="#B8FFFFFF" Margin="0,8,0,0" Text="Quanto vale un mech in battaglia prima di spenderci: resistenza, velocità, energia per le armi e abilità, confrontati con tutti gli altri mech."/>
            <DockPanel Margin="0,14,0,0">
              <Button x:Name="MsEditBtn" DockPanel.Dock="Right" Content="+ Aggiungi o correggi" Margin="8,0,0,0" Padding="14,7"/>
              <TextBox x:Name="MsSearch" ToolTip="Cerca un mech"/>
            </DockPanel>
            <DockPanel Margin="4,8,0,0">
              <Button x:Name="MsRefresh" DockPanel.Dock="Right" Content="Aggiorna dal wiki" Padding="12,5" FontSize="12"/>
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="MsCount" Foreground="#7AFFFFFF" FontSize="11"/>
                <TextBlock x:Name="MsSource" Foreground="#7AFFFFFF" FontSize="11" TextWrapping="Wrap"/>
              </StackPanel>
            </DockPanel>
            <WrapPanel x:Name="MsList" Margin="0,8,0,0"/>
            <Border x:Name="MsEdit" Visibility="Collapsed" CornerRadius="20" Padding="18,14" Margin="0,8,0,0" Background="#0FFFFFFF" BorderBrush="#1AFFFFFF" BorderThickness="1">
              <StackPanel>
                <TextBlock Text="Mech mancante o con dati sbagliati? Scrivili come li vedi nel gioco (al rango massimo). Restano salvati solo su questo PC." Foreground="#B8FFFFFF" TextWrapping="Wrap"/>
                <Grid Margin="0,12,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="8"/><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <StackPanel><TextBlock Text="Nome" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="MeName"/></StackPanel>
                  <StackPanel Grid.Column="2"><TextBlock Text="HP massimi" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="MeHp"/></StackPanel>
                  <StackPanel Grid.Column="4"><TextBlock Text="Velocità km/h" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="MeSpeed"/></StackPanel>
                  <StackPanel Grid.Column="6"><TextBlock Text="Energia" Foreground="#7AFFFFFF" FontSize="11" Margin="4,0,0,4"/><TextBox x:Name="MeEnergy"/></StackPanel>
                </Grid>
                <WrapPanel Margin="0,10,0,0">
                  <RadioButton x:Name="MeR_Attacker" Content="Attaccante" GroupName="merole" IsChecked="True" Style="{StaticResource Pill}"/>
                  <RadioButton x:Name="MeR_Tank" Content="Tank" GroupName="merole" Style="{StaticResource Pill}"/>
                  <RadioButton x:Name="MeR_Scout" Content="Scout" GroupName="merole" Style="{StaticResource Pill}"/>
                  <RadioButton x:Name="MeR_Support" Content="Supporto" GroupName="merole" Style="{StaticResource Pill}"/>
                </WrapPanel>
                <WrapPanel Margin="0,8,0,0">
                  <RadioButton x:Name="MeQ_Common" Content="Comune" GroupName="merar" Style="{StaticResource Pill}"/>
                  <RadioButton x:Name="MeQ_Uncommon" Content="Non comune" GroupName="merar" Style="{StaticResource Pill}"/>
                  <RadioButton x:Name="MeQ_Rare" Content="Raro" GroupName="merar" Style="{StaticResource Pill}"/>
                  <RadioButton x:Name="MeQ_Epic" Content="Epico" GroupName="merar" Style="{StaticResource Pill}"/>
                  <RadioButton x:Name="MeQ_Legendary" Content="Leggendario" GroupName="merar" IsChecked="True" Style="{StaticResource Pill}"/>
                </WrapPanel>
                <Grid Margin="0,10,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="MeAbility" ToolTip="Abilità (facoltativo)"/>
                  <Button x:Name="MeSave" Grid.Column="1" Style="{StaticResource Primary}" Content="Salva" Margin="8,0,0,0"/>
                  <Button x:Name="MeDel" Grid.Column="2" Content="Togli i miei dati" Margin="8,0,0,0"/>
                </Grid>
                <TextBlock x:Name="MeMsg" Foreground="#8CF0A8" FontSize="12" Margin="4,8,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <StackPanel x:Name="MsDetail" Visibility="Collapsed" Margin="0,8,0,0">
              <DockPanel>
                <Border x:Name="MsTierBox" DockPanel.Dock="Right" CornerRadius="16" Padding="14,6" Background="#1AFFFFFF" BorderBrush="#33FFFFFF" BorderThickness="1" VerticalAlignment="Center">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock x:Name="MsTier" FontSize="20" FontWeight="Bold" VerticalAlignment="Center"/>
                    <TextBlock x:Name="MsScore" Foreground="#B8FFFFFF" Margin="8,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                </Border>
                <StackPanel>
                  <TextBlock x:Name="MsName" FontSize="24" FontWeight="SemiBold"/>
                  <TextBlock x:Name="MsTag" Foreground="#B8FFFFFF"/>
                </StackPanel>
              </DockPanel>
              <TextBlock x:Name="MsVerdict" FontSize="15" FontWeight="SemiBold" Margin="0,6,0,0" TextWrapping="Wrap"/>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <TextBlock Text="Valuta al rango" Foreground="#7AFFFFFF" VerticalAlignment="Center" Margin="2,0,10,0"/>
                <WrapPanel x:Name="MsRankPills"/>
              </StackPanel>
              <StackPanel x:Name="MsBars" Margin="0,12,0,0"/>
              <TextBlock x:Name="MsAbilityAxes" Foreground="#F5F5F7" Margin="0,4,0,0" TextWrapping="Wrap"/>
              <TextBlock x:Name="MsAbility" Foreground="#B8FFFFFF" Margin="0,10,0,0" TextWrapping="Wrap"/>
              <TextBlock x:Name="MsAbilityText" Foreground="#7AFFFFFF" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap"/>
              <TextBlock Text="Statistiche per rango" Style="{StaticResource Label}" Margin="0,16,0,6"/>
              <Grid x:Name="MsRankTable"/>
              <TextBlock x:Name="MsRankNote" Foreground="#7AFFFFFF" FontSize="11" Margin="2,6,0,0" TextWrapping="Wrap"/>
              <TextBlock x:Name="MsWiki" Foreground="#7AFFFFFF" FontSize="12" FontStyle="Italic" Margin="0,8,0,0" TextWrapping="Wrap"/>
            </StackPanel>
            <TextBlock TextWrapping="Wrap" Foreground="#52FFFFFF" FontSize="11" Margin="4,10,0,0" Text="Voto 0-100 e fascia S-D: HP, velocità ed energia rispetto a tutti i mech, più l'abilità (effetti × durata e ricarica) e la nota della community, pesati secondo il ruolo. Dati: Mech Arena Wiki, licenza CC BY-SA 3.0."/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}" Margin="0,14,0,0">
          <StackPanel>
            <TextBlock Text="Informazioni" Style="{StaticResource Label}"/>
            <TextBlock TextWrapping="Wrap" Foreground="#B8FFFFFF" Margin="0,8,0,0" Text="MechVault è un progetto di fan. Non è affiliato, approvato o sponsorizzato da Plarium Global Ltd. Mech Arena e i relativi nomi e marchi appartengono ai rispettivi proprietari."/>
            <TextBlock TextWrapping="Wrap" Foreground="#7AFFFFFF" FontSize="12" Margin="0,8,0,0" Text="MechVault legge solo lo schermo, come uno screenshot: non modifica il gioco, non legge la sua memoria e non automatizza nulla."/>
            <TextBlock TextWrapping="Wrap" Foreground="#7AFFFFFF" FontSize="12" Margin="0,8,0,0" Text="Costi di potenziamento: Mech Arena: Robot Showdown Wiki (mech-arena-robot-showdown.fandom.com, pagine Mechs e Weapons), licenza CC BY-SA 3.0. Dati riformattati in calc\wiki-costs.json, stessa licenza."/>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>

    <ScrollViewer x:Name="PageSettings" Grid.Row="1" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
      <StackPanel Margin="40,14,40,40" MaxWidth="820">
        <TextBlock Text="Impostazioni" Style="{StaticResource H1}" Margin="0,0,0,22"/>

        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
          <StackPanel>
            <TextBlock Text="Lingua" Style="{StaticResource Label}"/>
            <WrapPanel x:Name="LangPanel" Margin="0,12,0,0"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Account" Style="{StaticResource Label}"/>
            <TextBlock x:Name="AccInfo" TextWrapping="Wrap" Foreground="#B8FFFFFF" Margin="0,6,0,14"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="AccRename" ToolTip="Nuovo nome per questo account"/>
              <Button x:Name="BtnAccRename" Grid.Column="1" Content="Rinomina" Margin="8,0,0,0"/>
              <Button x:Name="BtnAccSwitch" Grid.Column="2" Content="Cambia o crea" Margin="8,0,0,0"/>
              <Button x:Name="BtnAccDelete" Grid.Column="3" Content="Elimina" Style="{StaticResource Ghost}" Foreground="#FF8A80" Margin="4,0,0,0"/>
            </Grid>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}" Margin="0,14,0,0">
          <StackPanel>
            <TextBlock Text="Budget missioni" Style="{StaticResource Label}"/>
            <TextBlock TextWrapping="Wrap" Foreground="#7AFFFFFF" FontSize="12" Margin="0,6,0,14" Text="Quanto puoi spendere ogni giorno per completare le missioni giornaliere (es. «usa 2.000 crediti») senza rompere la serie. Oltre il budget è una spesa vietata."/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="18"/><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <TextBlock Text="Crediti al giorno" VerticalAlignment="Center" Margin="0,0,14,0"/>
              <TextBox x:Name="MisCred" Grid.Column="1"/>
              <TextBlock Grid.Column="3" Text="A-coin al giorno" VerticalAlignment="Center" Margin="0,0,14,0"/>
              <TextBox x:Name="MisAc" Grid.Column="4"/>
            </Grid>
            <Button x:Name="MisSave" Content="Salva" HorizontalAlignment="Left" Margin="0,14,0,0"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}" Margin="0,14,0,0">
          <StackPanel>
            <TextBlock Text="Lettura automatica" Style="{StaticResource Label}"/>
            <CheckBox x:Name="ChkAuto" Style="{StaticResource Switch}" Margin="0,12,0,4" Content="Leggi crediti e A-coin dallo schermo del gioco"/>
            <TextBlock TextWrapping="Wrap" Foreground="#7AFFFFFF" FontSize="12" Text="Guarda solo la barra delle valute in alto a destra, come uno screenshot, ogni 3 secondi. Non legge la memoria del gioco e non tocca i suoi file: niente rischio ban. Funziona nell'hangar e nei menu."/>
            <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
              <Button x:Name="BtnTestRead" Content="Prova lettura adesso"/>
              <TextBlock x:Name="TestReadTxt" Foreground="#B8FFFFFF" VerticalAlignment="Center" Margin="14,0,0,0" TextWrapping="Wrap" MaxWidth="460"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}" Margin="0,14,0,0">
          <StackPanel>
            <TextBlock Text="Correggi a mano" Style="{StaticResource Label}"/>
            <TextBlock TextWrapping="Wrap" Foreground="#7AFFFFFF" FontSize="12" Margin="0,6,0,14" Text="Solo se la lettura automatica sbaglia o è spenta. Anche qui un saldo più basso conta come spesa."/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="18"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="CredIn" ToolTip="Crediti attuali (es. 512k)"/>
              <Button x:Name="CredBtn" Grid.Column="1" Content="Crediti" Margin="8,0,0,0"/>
              <TextBox x:Name="AcIn" Grid.Column="3" ToolTip="A-coin attuali"/>
              <Button x:Name="AcBtn" Grid.Column="4" Content="A-coin" Margin="8,0,0,0"/>
            </Grid>
            <Grid Margin="0,14,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="18"/><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock Text="Ritmo crediti/giorno" VerticalAlignment="Center" Margin="0,0,14,0" Foreground="#B8FFFFFF"/>
              <TextBox x:Name="RateCred" Grid.Column="1" ToolTip="0 = calcolato in automatico"/>
              <TextBlock Grid.Column="3" Text="A-coin/giorno" VerticalAlignment="Center" Margin="0,0,14,0" Foreground="#B8FFFFFF"/>
              <TextBox x:Name="RateAc" Grid.Column="4" ToolTip="0 = calcolato in automatico"/>
              <Button x:Name="RateSave" Grid.Column="5" Content="Salva" Margin="8,0,0,0"/>
            </Grid>
            <TextBlock Text="Ritmo automatico" Foreground="#B8FFFFFF" FontWeight="SemiBold" Margin="4,14,0,0"/>
            <TextBlock x:Name="RateAutoCred" Foreground="#7AFFFFFF" FontSize="12" Margin="4,4,0,0" TextWrapping="Wrap"/>
            <TextBlock x:Name="RateAutoAc" Foreground="#7AFFFFFF" FontSize="12" Margin="4,2,0,0" TextWrapping="Wrap"/>
            <TextBlock Text="Calcolato da solo dai saldi letti: guadagni meno spese per missioni, ultimi 28 giorni, i giorni recenti contano di più, e tiene conto dei giorni in cui non giochi. Lascia 0 nei campi sopra per usarlo." Foreground="#52FFFFFF" FontSize="11" Margin="4,6,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}" Margin="0,14,0,0">
          <StackPanel>
            <TextBlock Text="Sistema" Style="{StaticResource Label}"/>
            <CheckBox x:Name="ChkAutostart" Style="{StaticResource Switch}" Margin="0,12,0,4" Content="Avvia MechVault con Windows"/>
            <CheckBox x:Name="ChkGlass" Style="{StaticResource Switch}" Content="Liquid glass (finestre trasparenti con riflessi). Spento: finestre scure piene. Cambiando, l'app si riavvia."/>
            <CheckBox x:Name="ChkBanner" Style="{StaticResource Switch}" Content="Promemoria fisso sullo schermo mentre giochi"/>
            <CheckBox x:Name="ChkAutoUpdate" Style="{StaticResource Switch}" Content="Aggiornamenti automatici (da mechvault.github.io, solo se l'impronta SHA-256 coincide; i tuoi dati non si toccano)"/>
            <DockPanel Margin="0,4,0,6">
              <Button x:Name="BtnUpdate" DockPanel.Dock="Right" Content="Cerca aggiornamenti" Padding="14,7" VerticalAlignment="Center"/>
              <TextBlock x:Name="UpdStatus" Foreground="#7AFFFFFF" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,12,0"/>
            </DockPanel>
            <DockPanel Margin="0,4,0,6">
              <Button x:Name="BtnOverlayReset" DockPanel.Dock="Right" Content="Riporta in basso a destra" Padding="14,7" VerticalAlignment="Center"/>
              <TextBlock Text="Trascina il promemoria per spostarlo. Il pulsante nell'angolo lo rimpicciolisce: normale, piccolo, solo una riga." Foreground="#7AFFFFFF" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,12,0"/>
            </DockPanel>
            <TextBlock Text="Processo del gioco (espressione regolare)" Foreground="#B8FFFFFF" Margin="0,16,0,8"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="ProcPat"/>
              <Button x:Name="ProcSave" Grid.Column="1" Content="Salva" Margin="8,0,0,0"/>
            </Grid>
            <Button x:Name="BtnQuit" Content="Esci da MechVault" Style="{StaticResource Ghost}" HorizontalAlignment="Left" Padding="0,10" Margin="0,14,0,0" Foreground="#FF8A80"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>
  </Grid>
</Window>
'@

$script:DlgHead = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TITLE" WindowStyle="None" ResizeMode="NoResize" Background="Transparent"
        SizeToContent="Height" Width="WIDTH" Topmost="True" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" Foreground="#F5F5F7">
  <WindowChrome.WindowChrome><WindowChrome CaptionHeight="0" GlassFrameThickness="0" ResizeBorderThickness="0" UseAeroCaptionButtons="False"/></WindowChrome.WindowChrome>
  <Border x:Name="Root" Padding="36,32">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#24FFFFFF" Offset="0"/><GradientStop Color="#06FFFFFF" Offset="0.2"/><GradientStop Color="#03FFFFFF" Offset="0.8"/><GradientStop Color="#12FFFFFF" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
'@
$script:DlgTail = @'
  </Border>
</Window>
'@

function New-DlgXaml([string]$title, [int]$width, [string]$body) {
  $script:DlgHead.Replace('TITLE', $title).Replace('WIDTH', "$width") + $body + $script:DlgTail
}

$script:XamlMsg = New-DlgXaml 'MechVault' 460 @'
    <StackPanel>
      <TextBlock x:Name="Msg" TextWrapping="Wrap" FontSize="15" LineHeight="22" Margin="0,0,0,22"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="No" Content="Annulla" Margin="0,0,8,0" Visibility="Collapsed"/>
        <Button x:Name="Yes" Content="OK" Style="{DynamicResource Primary}" MinWidth="96"/>
      </StackPanel>
    </StackPanel>
'@
function Show-Msg([string]$text, [switch]$YesNo, [switch]$Danger) {
  $w = Parse-Xaml $script:XamlMsg
  Enable-Glass $w
  $w.FindName('Msg').Text = $text
  $script:MsgResult = 'No'
  if ($YesNo) {
    $w.FindName('No').Visibility = 'Visible'; $w.FindName('Yes').Content = T 'Conferma'
    if ($Danger) { $w.FindName('Yes').Style = $script:app.Resources['Danger'] }
  }
  $w.FindName('Yes').Add_Click({ $script:MsgResult = 'Yes'; $script:MsgWin.Close() })
  $w.FindName('No').Add_Click({ $script:MsgResult = 'No'; $script:MsgWin.Close() })
  $w.Add_KeyDown({ if ($_.Key -eq 'Escape') { $this.Close() } elseif ($_.Key -eq 'Return') { $script:MsgResult = 'Yes'; $this.Close() } })
  try { if ($script:win -and $script:win.IsVisible) { $w.Owner = $script:win; $w.WindowStartupLocation = 'CenterOwner' } else { $w.WindowStartupLocation = 'CenterScreen' } } catch {}
  $w.Topmost = $true
  $script:MsgWin = $w
  [void]$w.ShowDialog()
  if ($YesNo) { $script:MsgResult } else { 'OK' }
}

$script:XamlWarn = New-DlgXaml 'MechVault - prima di giocare' 600 @'
    <StackPanel>
      <Border HorizontalAlignment="Left" CornerRadius="12" Padding="12,5" Background="#24FFD60A" BorderBrush="#4DFFD60A" BorderThickness="1">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" Foreground="#FFD60A" Margin="0,2,8,0" FontSize="11"/>
          <TextBlock Text="Mech Arena rilevato" Foreground="#FFE98A" FontWeight="SemiBold" FontSize="12"/>
        </StackPanel>
      </Border>
      <TextBlock Text="Prima di giocare, leggi." FontSize="32" FontWeight="SemiBold" Margin="0,14,0,4"/>
      <TextBlock x:Name="Streak" Foreground="#B8FFFFFF"/>
      <Grid Margin="0,22,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border CornerRadius="20" Padding="18,14" Background="#1AFF453A" BorderBrush="#40FF453A" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="Vietato" Foreground="#FF8A80" FontWeight="SemiBold" FontSize="12"/>
            <TextBlock Text="Crate Rush · casse · offerte a tempo · spin · scorciatoie" Margin="0,6,0,0" TextWrapping="Wrap" Foreground="#F5F5F7"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="2" CornerRadius="20" Padding="18,14" Background="#1A30D158" BorderBrush="#4030D158" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="Consentito" Foreground="#8CF0A8" FontWeight="SemiBold" FontSize="12"/>
            <TextBlock x:Name="Allowed" Text="Giocare, farmare, missioni giornaliere. Comprare solo l'obiettivo #1 al 100%." Margin="0,6,0,0" TextWrapping="Wrap" Foreground="#F5F5F7"/>
          </StackPanel>
        </Border>
      </Grid>
      <TextBlock Text="I tuoi obiettivi" Foreground="#7AFFFFFF" FontWeight="SemiBold" FontSize="12" Margin="0,22,0,8"/>
      <TextBlock x:Name="Goals" TextWrapping="Wrap" LineHeight="24" Foreground="#B8FFFFFF"/>
      <TextBlock x:Name="Lesson" TextWrapping="Wrap" Foreground="#FFE98A" FontStyle="Italic" Margin="0,18,0,0"/>
      <TextBlock Text="Ti sto guardando: se i saldi scendono, lo vedo da solo." Foreground="#7AFFFFFF" FontSize="12" Margin="0,6,0,0"/>
      <Button x:Name="Ok" Style="{DynamicResource Primary}" Margin="0,24,0,0" Padding="14,13" IsEnabled="False" Content="Leggi..."/>
    </StackPanel>
'@

$script:XamlViol = New-DlgXaml 'MechVault - spesa rilevata' 580 @'
    <StackPanel>
      <Border HorizontalAlignment="Left" CornerRadius="12" Padding="12,5" Background="#29FF453A" BorderBrush="#59FF453A" BorderThickness="1">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE783;" FontFamily="Segoe MDL2 Assets" Foreground="#FF8A80" Margin="0,2,8,0" FontSize="11"/>
          <TextBlock x:Name="Head" Text="Spesa rilevata" Foreground="#FFB4AB" FontWeight="SemiBold" FontSize="12"/>
        </StackPanel>
      </Border>
      <TextBlock x:Name="Amt" FontSize="52" FontWeight="Light" Foreground="#FF8A80" Margin="0,10,0,0"/>
      <TextBlock x:Name="Body" TextWrapping="Wrap" Foreground="#B8FFFFFF" Margin="0,6,0,20" LineHeight="21"/>
      <TextBlock Text="Perché l'hai fatto? (obbligatorio, almeno 15 caratteri)" Foreground="#7AFFFFFF" FontSize="12"/>
      <TextBox x:Name="Why" Margin="0,8,0,18" Height="80" TextWrapping="Wrap" AcceptsReturn="True" VerticalContentAlignment="Top" Padding="14,10"/>
      <DockPanel>
        <Button x:Name="Ok" DockPanel.Dock="Right" Content="Confesso. Azzera la serie." Style="{DynamicResource Danger}" IsEnabled="False"/>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="Mission" Content="Era una missione" Margin="0,0,8,0" ToolTip="Non rompe la serie: viene contata nel budget missioni"/>
          <Button x:Name="Typo" Content="Lettura sbagliata" Style="{DynamicResource Ghost}" Padding="8,10"/>
        </StackPanel>
      </DockPanel>
    </StackPanel>
'@

$script:XamlAcc = New-DlgXaml 'MechVault - account' 480 @'
    <StackPanel>
      <Border HorizontalAlignment="Left" CornerRadius="12" Padding="12,5" Background="#1FFFFFFF" BorderBrush="#33FFFFFF" BorderThickness="1">
        <TextBlock x:Name="Head" Text="Mech Arena rilevato" Foreground="#F5F5F7" FontWeight="SemiBold" FontSize="12"/>
      </Border>
      <TextBlock Text="Con quale account giochi?" FontSize="26" FontWeight="SemiBold" Margin="0,14,0,4"/>
      <TextBlock Text="Ogni account ha saldi, obiettivi e serie separati." Foreground="#B8FFFFFF" Margin="0,0,0,20"/>
      <StackPanel x:Name="List"/>
      <TextBlock Text="Nuovo account" Foreground="#7AFFFFFF" FontWeight="SemiBold" FontSize="12" Margin="0,12,0,8"/>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBox x:Name="NewName" ToolTip="Nome del nuovo account"/>
        <Button x:Name="Create" Grid.Column="1" Content="Crea e usa" Margin="8,0,0,0"/>
      </Grid>
    </StackPanel>
'@

$script:XamlBanner = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        Focusable="False" FontFamily="Segoe UI">
  <Grid x:Name="Root" Margin="16" Cursor="SizeAll" ToolTip="Trascina per spostare">
    <Grid.LayoutTransform><ScaleTransform x:Name="Scale" ScaleX="1" ScaleY="1"/></Grid.LayoutTransform>
    <Border CornerRadius="26" Background="#01000000">
      <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Direction="270" Opacity="0.45" Color="Black"/></Border.Effect>
    </Border>
    <Border CornerRadius="26">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#3A1C1C22" Offset="0"/><GradientStop Color="#2410121A" Offset="0.5"/><GradientStop Color="#3A1C1C22" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
    </Border>
    <Border CornerRadius="26" Tag="glass">
      <Border.Background>
        <RadialGradientBrush Center="0.5,0.5" GradientOrigin="0.5,0.5" RadiusX="0.75" RadiusY="0.9">
          <GradientStop Color="#05FFFFFF" Offset="0.55"/><GradientStop Color="#2BFFFFFF" Offset="0.92"/><GradientStop Color="#40FFFFFF" Offset="1"/>
        </RadialGradientBrush>
      </Border.Background>
    </Border>
    <Border CornerRadius="25" Margin="1" BorderThickness="3" Tag="glass">
      <Border.BorderBrush>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0.35,1">
          <GradientStop Color="#55FFFFFF" Offset="0"/><GradientStop Color="#0AFFFFFF" Offset="0.45"/><GradientStop Color="#0AFFFFFF" Offset="0.7"/><GradientStop Color="#40FFFFFF" Offset="1"/>
        </LinearGradientBrush>
      </Border.BorderBrush>
    </Border>
    <Border CornerRadius="26" BorderThickness="1.2" Tag="rim">
      <Border.BorderBrush>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#F2FFFFFF" Offset="0"/><GradientStop Color="#40FFFFFF" Offset="0.32"/><GradientStop Color="#1AFFFFFF" Offset="0.55"/><GradientStop Color="#B3FFFFFF" Offset="1"/>
        </LinearGradientBrush>
      </Border.BorderBrush>
    </Border>
    <Border CornerRadius="24,24,60,60" Margin="4,3,4,0" VerticalAlignment="Top" Height="20" IsHitTestVisible="False" Tag="glass">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#59FFFFFF"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush>
      </Border.Background>
    </Border>
    <Border CornerRadius="60,60,24,24" Margin="10,0,10,3" VerticalAlignment="Bottom" Height="14" IsHitTestVisible="False" Tag="glass">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#00FFFFFF"/><GradientStop Color="#26FFFFFF" Offset="1"/></LinearGradientBrush>
      </Border.Background>
    </Border>
    <DockPanel Margin="18,11,11,11">
      <Button x:Name="SizeBtn" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="10,0,0,0" Cursor="Hand" Focusable="False"
              FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#E6FFFFFF" Content="&#xE73F;" ToolTip="Rimpicciolisci / ingrandisci">
        <Button.Template>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Width="24" Height="24" CornerRadius="12" Background="#1FFFFFFF" BorderBrush="#66FFFFFF" BorderThickness="1"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#40FFFFFF"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate>
        </Button.Template>
      </Button>
      <Grid>
        <Grid.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="0" Opacity="0.7" Color="Black"/></Grid.Effect>
        <StackPanel x:Name="Full" Width="310">
          <StackPanel Orientation="Horizontal">
            <Ellipse Width="7" Height="7" Fill="#30D158" Margin="0,0,8,0" VerticalAlignment="Center"/>
            <TextBlock Text="Risparmio attivo · non spendere" Foreground="#A8F5BE" FontWeight="SemiBold" FontSize="11"/>
          </StackPanel>
          <TextBlock x:Name="Bal" Foreground="#FFFFFF" FontSize="15" FontWeight="SemiBold" Margin="0,4,0,0"/>
          <TextBlock x:Name="Txt" Foreground="#CCFFFFFF" FontSize="11" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <StackPanel x:Name="Mini" Orientation="Horizontal" Visibility="Collapsed" VerticalAlignment="Center">
          <Ellipse Width="7" Height="7" Fill="#30D158" Margin="0,0,8,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="MiniTxt" Foreground="#FFFFFF" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </StackPanel>
      </Grid>
    </DockPanel>
  </Grid>
</Window>
'@

function Parse-Xaml([string]$x) {
  if ($script:Map.Count) {
    $x = [regex]::Replace($x, '\b(Text|Content|ToolTip|Title)="([^"]+)"', {
      param($m)
      $v = $script:Map[[System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)]
      if ($v) { $m.Groups[1].Value + '="' + [Security.SecurityElement]::Escape($v) + '"' } else { $m.Value }
    })
  }
  [Windows.Markup.XamlReader]::Parse($x)
}

function Enable-Glass($w) {
  $w.Add_SourceInitialized({
    try {
      $h = (New-Object System.Windows.Interop.WindowInteropHelper($this)).Handle
      [System.Windows.Interop.HwndSource]::FromHwnd($h).CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
      $v = 2; [void][MechVaultNative3]::DwmSetWindowAttribute($h, 33, [ref]$v, 4)
      $v = 1; [void][MechVaultNative3]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)
      if (-not $script:LiquidGlass) {
        $r = $this.FindName('Root'); $r.Background = '#FF1B1B1F'
        if ($r -is [System.Windows.Controls.Border]) { $r.BorderBrush = '#2EFFFFFF' }
        $sh = $this.FindName('Sheen'); if ($sh) { $sh.Visibility = 'Collapsed' }
        return
      }
      $ok = [MechVaultNative3]::Accent($h, 2, [uint32]'0xB00C0C10')
      if (-not $ok) { $this.FindName('Root').Background = '#F21C1C1E' }
    } catch { try { $this.FindName('Root').Background = '#F21C1C1E' } catch {} }
  })
}

function Set-Ring($path, [double]$pct) {
  $size = 184.0; $thick = 12.0
  $r = ($size - $thick) / 2; $c = $size / 2
  $pct = [math]::Min(0.9999, [math]::Max(0.0, $pct))
  if ($pct -lt 0.005) { $path.Data = $null; return }
  $a = $pct * 2 * [math]::PI
  $x = $c + $r * [math]::Sin($a); $y = $c - $r * [math]::Cos($a)
  $large = if ($pct -gt 0.5) { 1 } else { 0 }
  $path.Data = [Windows.Media.Geometry]::Parse([string]::Format($script:INV, 'M {0},{1} A {2},{2} 0 {3} 1 {4},{5}', $c, ($c - $r), $r, $large, $x, $y))
}

function Draw-Spark($canvas) {
  $canvas.Children.Clear()
  $info = $canvas.Tag
  if (-not $info) { return }
  $vals = @($info.vals)
  $w = $canvas.ActualWidth; $h = $canvas.ActualHeight
  if ($w -lt 20 -or $h -lt 10) { return }
  $n = $vals.Count
  $nums = @($vals | Where-Object { $null -ne $_ })
  if ($nums.Count -lt 1) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = 'Il grafico si riempie man mano che giochi.'; $t.Foreground = '#52FFFFFF'; $t.FontSize = 11
    [System.Windows.Controls.Canvas]::SetTop($t, $h / 2 - 8)
    [void]$canvas.Children.Add($t); return
  }
  $mn = ($nums | Measure-Object -Minimum).Minimum; $mx = ($nums | Measure-Object -Maximum).Maximum
  $rng = [double]($mx - $mn); if ($rng -le 0) { $rng = [math]::Max(1.0, [double]$mx * 0.1); $mn = $mn - $rng / 2 }
  $line = New-Object System.Windows.Media.PointCollection
  for ($i = 0; $i -lt $n; $i++) {
    if ($null -eq $vals[$i]) { continue }
    $x = if ($n -gt 1) { $w * $i / ($n - 1) } else { 0.0 }
    $y = 4 + ($h - 8) * (1 - (([double]$vals[$i] - $mn) / $rng))
    $line.Add((New-Object System.Windows.Point($x, $y)))
  }
  if ($line.Count -eq 1) { $line.Add((New-Object System.Windows.Point($w, $line[0].Y))) }
  $c1 = [System.Windows.Media.ColorConverter]::ConvertFromString($info.c1)

  $area = New-Object System.Windows.Shapes.Polygon
  $ap = New-Object System.Windows.Media.PointCollection
  foreach ($p in $line) { $ap.Add($p) }
  $ap.Add((New-Object System.Windows.Point($line[$line.Count - 1].X, $h)))
  $ap.Add((New-Object System.Windows.Point($line[0].X, $h)))
  $area.Points = $ap
  $fill = New-Object System.Windows.Media.LinearGradientBrush
  $fill.StartPoint = '0,0'; $fill.EndPoint = '0,1'
  $fill.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(56, $c1.R, $c1.G, $c1.B), 0)))
  $fill.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, $c1.R, $c1.G, $c1.B), 1)))
  $area.Fill = $fill
  [void]$canvas.Children.Add($area)

  $pl = New-Object System.Windows.Shapes.Polyline
  $pl.Points = $line
  $pl.Stroke = New-Object System.Windows.Media.SolidColorBrush($c1)
  $pl.StrokeThickness = 2
  $pl.StrokeLineJoin = 'Round'; $pl.StrokeStartLineCap = 'Round'; $pl.StrokeEndLineCap = 'Round'
  [void]$canvas.Children.Add($pl)

  $last = $line[$line.Count - 1]
  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 9; $dot.Height = 9; $dot.Fill = '#F5F5F7'
  $dot.Stroke = New-Object System.Windows.Media.SolidColorBrush($c1); $dot.StrokeThickness = 2
  [System.Windows.Controls.Canvas]::SetLeft($dot, $last.X - 4.5); [System.Windows.Controls.Canvas]::SetTop($dot, $last.Y - 4.5)
  [void]$canvas.Children.Add($dot)
}

function New-ActivityRow($e) {
  $cur = $e.cur
  switch ($e.kind) {
    'gain'     { $glyph = '&#xE710;'; $fg = '#30D158'; $title = T 'Guadagno · {0}' (CurName $cur) }
    'spend'    { $glyph = '&#xE738;'; $fg = '#FF8A80'; $title = T 'Spesa non autorizzata' }
    'mission'  { $glyph = '&#xE7C1;'; $fg = '#FFD60A'; $title = T 'Spesa per missione' }
    'small'    { $glyph = '&#xE738;'; $fg = '#FFD60A'; $title = T 'Piccola spesa tollerata' }
    'purchase' { $glyph = '&#xE7BF;'; $fg = '#FFD60A'; $title = T 'Obiettivo comprato' }
    default    { $glyph = '&#xE8FB;'; $fg = '#B8FFFFFF'; $title = T 'Saldo iniziale · {0}' (CurName $cur) }
  }
  $time = try { ([datetime]$e.t).ToString('HH:mm', $script:IT) } catch { '' }
  $sub = "$time · $(if ($e.src -eq 'auto') { T 'letto dal gioco' } else { T 'manuale' })"
  if ($e.note) { $sub += " · $(T ([string]$e.note))" }
  $amt = if ($e.kind -eq 'init') { Fmt $e.bal } else { Signed $e.delta }
  $amtColor = if ($e.kind -eq 'init') { '#B8FFFFFF' } else { $fg }
  $curColor = CurColor $cur
  $x = @"
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,12">
  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <Border Width="34" Height="34" CornerRadius="17" Background="#14FFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" VerticalAlignment="Center">
    <TextBlock Text="$glyph" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="$fg" HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
  <StackPanel Grid.Column="1" Margin="12,0,10,0" VerticalAlignment="Center">
    <TextBlock Text="$(Esc $title)" Foreground="#F5F5F7" TextTrimming="CharacterEllipsis"/>
    <TextBlock Text="$(Esc $sub)" Foreground="#66FFFFFF" FontSize="11" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
  </StackPanel>
  <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
    <TextBlock Text="$amt" FontSize="16" Foreground="$amtColor"/>
    <Ellipse Width="7" Height="7" Fill="$curColor" Margin="8,1,0,0" VerticalAlignment="Center"/>
  </StackPanel>
</Grid>
"@
  Parse-Xaml $x
}

function Set-Bar($grid, [double]$pct) {
  $pct = [math]::Min(1.0, [math]::Max(0.0, $pct))
  $grid.ColumnDefinitions[0].Width = New-Object System.Windows.GridLength($pct, 'Star')
  $grid.ColumnDefinitions[1].Width = New-Object System.Windows.GridLength((1 - $pct), 'Star')
}

function Render-Home {
  $ui = $script:ui; $d = $script:Data
  $h = (Get-Date).Hour
  $ui.Hello.Text = if ($h -lt 12) { T 'Buongiorno, pilota' } elseif ($h -lt 18) { T 'Buon pomeriggio, pilota' } else { T 'Buonasera, pilota' }
  $ui.DateTxt.Text = (Get-Date).ToString('dddd d MMMM', $script:IT)
  $st = Get-Streak
  $ui.StreakChipTxt.Text = if ($st -eq 1) { T '1 giorno pulito' } else { T '{0} giorni puliti' $st }

  $n = $ui.Notice
  if ($script:PendingCheck) {
    $n.Background = '#1FFFD60A'; $n.BorderBrush = '#40FFD60A'; $ui.NoticeTxt.Foreground = '#FFE98A'; $ui.NoticeIcon.Foreground = '#FFD60A'
    $ui.NoticeTxt.Text = T 'Hai chiuso Mech Arena e la lettura automatica è spenta: aggiorna i saldi in Impostazioni.'
  } elseif (-not ($d.initCredits -and $d.initAcoins)) {
    $n.Background = '#1A64D2FF'; $n.BorderBrush = '#4064D2FF'; $ui.NoticeTxt.Foreground = '#C8EEFF'; $ui.NoticeIcon.Foreground = '#64D2FF'
    $ui.NoticeTxt.Text = if ($d.autoRead) { T "Apri Mech Arena e vai nell'hangar: leggo io crediti e A-coin dalla barra in alto." } else { T 'Inserisci i saldi attuali in Impostazioni › Correggi a mano.' }
  } else {
    $n.Background = '#0FFFFFFF'; $n.BorderBrush = '#1AFFFFFF'; $ui.NoticeTxt.Foreground = '#B8FFFFFF'; $ui.NoticeIcon.Foreground = '#B8FFFFFF'
    $ui.NoticeTxt.Text = T $script:Lessons[(Get-Date).DayOfYear % $script:Lessons.Count]
  }

  $first = @(Get-GoalStats) | Select-Object -First 1
  if ($first) {
    $g = $first.goal
    Set-Ring $ui.RingPath $first.pct
    $done = $first.remaining -le 0
    $ui.RingPath.Stroke = if ($done) { $script:app.Resources['GSafe'] } elseif ($g.currency -eq 'credits') { $script:app.Resources['GCred'] } else { $script:app.Resources['GAc'] }
    $ui.RingGlow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($(if ($done) { '#30D158' } else { CurColor $g.currency }))
    $ui.RingPct.Text = "$([math]::Floor($first.pct * 100))%"
    $ui.HeroName.Text = $g.name
    $ui.HeroCost.Text = "$(Fmt $g.cost) $(CurName $g.currency)"
    $ui.HeroLeft.Text = if ($done) { '0' } else { Short $first.remaining }
    $ui.HeroEta.Text  = Eta-Days $first.days
    $ui.HeroDate.Text = Eta-Date $first.days
    $rate = Get-Rate $g.currency
    if ($first.authorized) {
      $ui.HeroBuy.Visibility = 'Collapsed'
      $ui.HeroHint.Text = T 'Acquisto autorizzato: compralo in gioco, riconosco da solo la spesa.'; $ui.HeroHint.Foreground = '#8CF0A8'
    } elseif ($first.canBuy) {
      $ui.HeroBuy.Visibility = 'Visible'; $ui.HeroBuy.Tag = $g.id
      $ui.HeroHint.Text = T "Hai il 100%: autorizza l'acquisto, poi compralo in gioco."; $ui.HeroHint.Foreground = '#8CF0A8'
    } else {
      $ui.HeroBuy.Visibility = 'Collapsed'
      $ui.HeroHint.Text = if ($rate.v -gt 0) { T 'Al ritmo di ~{0} {1} al giorno ({2}).' (Short $rate.v) (CurName $g.currency) $rate.src } else { T 'Il tempo stimato compare dopo un giorno di letture.' }
      $ui.HeroHint.Foreground = '#7AFFFFFF'
    }
  } else {
    Set-Ring $ui.RingPath 0
    $ui.RingPct.Text = '—'; $ui.HeroName.Text = T 'Nessun obiettivo'; $ui.HeroCost.Text = T 'Aggiungine uno nella sezione Obiettivi.'
    $ui.HeroLeft.Text = '—'; $ui.HeroEta.Text = '—'; $ui.HeroDate.Text = '—'; $ui.HeroBuy.Visibility = 'Collapsed'; $ui.HeroHint.Text = ''
  }

  foreach ($c in 'credits', 'acoins') {
    $isC = $c -eq 'credits'
    $val = if ($isC) { $ui.CredVal } else { $ui.AcVal }
    $rateLbl = if ($isC) { $ui.CredRate } else { $ui.AcRate }
    $todayLbl = if ($isC) { $ui.CredToday } else { $ui.AcToday }
    $chip = if ($isC) { $ui.CredTodayChip } else { $ui.AcTodayChip }
    $spark = if ($isC) { $ui.SparkCred } else { $ui.SparkAc }
    $val.Text = if ($d.(InitProp $c)) { Fmt $d.$c } else { '—' }
    $r = Get-Rate $c
    $rateLbl.Text = if ($r.v -gt 0) { T '~{0} al giorno · {1}' (Short $r.v) $r.src } else { T 'Ritmo: gioca una partita e lo calcolo da solo' }
    $t = Get-Today $c
    $todayLbl.Text = T 'oggi {0}' (Signed ($t.gain + $t.spend))
    if ($t.gain + $t.spend -lt 0) { $chip.Background = '#26FF453A'; $todayLbl.Foreground = '#FFB4AB' }
    elseif ($t.gain -gt 0) { $chip.Background = '#2630D158'; $todayLbl.Foreground = '#B5F5C8' }
    else { $chip.Background = '#14FFFFFF'; $todayLbl.Foreground = '#B8FFFFFF' }
    $spark.Tag = @{ vals = (Get-DailySeries $c 14); c1 = (CurColor $c) }
    Draw-Spark $spark
  }

  $ui.StreakBig.Text = "$st"
  $best = [math]::Max([int]$d.bestStreak, $st)
  $ui.BestTxt.Text = T 'Record: {0} giorni  ·  Spese confessate: {1}' $best (@($d.violations).Count)
  $ui.Cal.Children.Clear()
  $spendDays = @{}; $misDays = @{}
  foreach ($e in @($d.events)) {
    $k = ([datetime]$e.t).Date.ToString('yyyyMMdd')
    if ($e.kind -eq 'spend') { $spendDays[$k] = $true } elseif ($e.kind -eq 'mission') { $misDays[$k] = $true }
  }
  $firstDay = try { ([datetime]$d.createdAt).Date } catch { (Get-Date).Date }
  if (@($d.events).Count) { $fe = ([datetime]@($d.events)[0].t).Date; if ($fe -lt $firstDay) { $firstDay = $fe } }
  for ($k = 13; $k -ge 0; $k--) {
    $day = (Get-Date).Date.AddDays(-$k)
    $key = $day.ToString('yyyyMMdd')
    $el = New-Object System.Windows.Shapes.Ellipse
    $el.Width = 14; $el.Height = 14; $el.HorizontalAlignment = 'Center'; $el.VerticalAlignment = 'Center'
    if ($spendDays.ContainsKey($key)) { $el.Fill = '#FF6961' }
    elseif ($day -lt $firstDay) { $el.Fill = '#14FFFFFF' }
    elseif ($misDays.ContainsKey($key)) { $el.Fill = '#CCFFD60A' }
    elseif ($k -eq 0) { $el.Fill = '#30D158' }
    else { $el.Fill = '#7330D158' }
    $el.ToolTip = $day.ToString('ddd d MMM', $script:IT)
    [void]$ui.Cal.Children.Add($el)
  }

  $mb = Get-MissionBudget 'credits'
  $ui.MisUsed.Text = Fmt $mb.used
  $ui.MisTot.Text = T '/ {0} crediti' (Fmt $mb.budget)
  Set-Bar $ui.MisBar $(if ($mb.budget -gt 0) { $mb.used / $mb.budget } else { 0.0 })
  $ma = Get-MissionBudget 'acoins'
  $ui.MisSub.Text = if ($mb.budget -le 0) { T 'Budget missioni disattivato: imposta un valore in Impostazioni.' }
    else { T 'Restano {0} crediti{1} per le missioni giornaliere, senza rompere la serie. Si azzera a mezzanotte.' (Fmt $mb.left) $(if ($ma.budget -gt 0) { T ' e {0} A-coin' (Fmt $ma.left) } else { '' }) }

  $ui.RecentList.Children.Clear()
  $recent = @($d.events | Where-Object { $_.kind -ne 'init' } | Select-Object -Last 5)
  [array]::Reverse($recent)
  if ($recent.Count -eq 0) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = T 'Ancora niente. Gioca una partita: ogni guadagno o spesa comparirà qui da solo.'
    $t.Foreground = '#66FFFFFF'; $t.TextWrapping = 'Wrap'
    [void]$ui.RecentList.Children.Add($t)
  } else { foreach ($e in $recent) { [void]$ui.RecentList.Children.Add((New-ActivityRow $e)) } }
}

function Render-Goals {
  $p = $script:ui.GoalsPanel
  $p.Children.Clear()
  $stats = @(Get-GoalStats)
  foreach ($s in $stats) {
    $g = $s.goal; $cur = $g.currency
    $c1 = CurColor $cur; $c2 = CurColor2 $cur
    $pct = [math]::Min(1.0, [math]::Max(0.0, [double]$s.pct))
    $p1 = $pct.ToString('0.####', $script:INV); $p2 = (1 - $pct).ToString('0.####', $script:INV)
    if ($s.remaining -le 0) { $c1 = '#8CF0A8'; $c2 = '#30D158' }
    if ($s.authorized) { $status = T 'Acquisto autorizzato · compralo in gioco, la spesa verrà riconosciuta'; $statusColor = '#8CF0A8' }
    elseif ($s.canBuy) { $status = T 'Pronto · hai abbastanza {0}' (CurName $cur); $statusColor = '#8CF0A8' }
    elseif ($s.isFirst) { $status = T 'mancano {0} · ~{1} · entro {2}' (Short $s.remaining) (Eta-Days $s.days) (Eta-Date $s.days); $statusColor = '#B8FFFFFF' }
    else { $status = T 'in coda dopo «{0}» · mancano {1} in totale · entro {2}' $s.after (Short $s.remaining) (Eta-Date $s.days); $statusColor = '#7AFFFFFF' }
    $buyXaml = if ($s.authorized) {
      '<Button Name="Buy" Content="Annulla" Margin="0,0,6,0" ToolTip="Revoca l''autorizzazione"/>'
    } elseif ($s.canBuy) {
      '<Button Name="Buy" Style="{DynamicResource Safe}" Content="Compra ora" Margin="0,0,6,0"/>'
    } else {
      '<Button Name="Buy" IsEnabled="False" Margin="0,0,6,0"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Bloccato"/></StackPanel></Button>'
    }
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Style="{DynamicResource Card}" Margin="0,0,0,12" Padding="24,20">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel>
      <StackPanel Orientation="Horizontal">
        <Border Width="38" Height="38" CornerRadius="19" Background="#14FFFFFF" BorderBrush="#26FFFFFF" BorderThickness="1" Margin="0,0,14,0">
          <TextBlock Text="$($s.rank)" FontSize="16" FontWeight="SemiBold" Foreground="$(CurColor $cur)" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="$(Esc $g.name)" FontSize="17" FontWeight="SemiBold" Foreground="#F5F5F7"/>
          <TextBlock Text="$(Esc ("{0} {1}" -f (Fmt $g.cost), (CurName $cur)))" Foreground="#7AFFFFFF" FontSize="12" Margin="0,1,0,0"/>
        </StackPanel>
      </StackPanel>
      <Grid Margin="0,16,0,10" Height="8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="$($p1)*"/><ColumnDefinition Width="$($p2)*"/></Grid.ColumnDefinitions>
        <Border Grid.ColumnSpan="2" Background="#17FFFFFF" CornerRadius="4"/>
        <Border CornerRadius="4">
          <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="$c2"/><GradientStop Color="$c1" Offset="1"/></LinearGradientBrush></Border.Background>
        </Border>
      </Grid>
      <DockPanel>
        <TextBlock DockPanel.Dock="Right" Text="$([math]::Floor($pct * 100))%" FontSize="15" Foreground="#F5F5F7" Margin="12,0,0,0"/>
        <TextBlock Text="$(Esc $status)" Foreground="$statusColor" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center"/>
      </DockPanel>
    </StackPanel>
    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0,0,0">
      $buyXaml
      <Button Name="Up" Content="&#xE70E;" Style="{DynamicResource IconBtn}" ToolTip="Più importante"/>
      <Button Name="Down" Content="&#xE70D;" Style="{DynamicResource IconBtn}" ToolTip="Meno importante"/>
      <Button Name="Del" Content="&#xE74D;" Style="{DynamicResource IconBtn}" ToolTip="Elimina"/>
    </StackPanel>
  </Grid>
</Border>
"@
    $el = Parse-Xaml $x
    foreach ($n in 'Buy', 'Up', 'Down', 'Del') { $el.FindName($n).Tag = $g.id }
    if ($s.authorized) { $el.FindName('Buy').Add_Click({ Cancel-Purchase }) }
    else { $el.FindName('Buy').Add_Click({ Authorize-Purchase $this.Tag }) }
    $el.FindName('Up').Add_Click({ Move-Goal $this.Tag -1 })
    $el.FindName('Down').Add_Click({ Move-Goal $this.Tag 1 })
    $el.FindName('Del').Add_Click({ Remove-Goal $this.Tag })
    [void]$p.Children.Add($el)
  }

  foreach ($g in @($script:Data.goals | Where-Object { $_.done })) {
    $when = try { ([datetime]$g.doneAt).ToString('d MMM yyyy', $script:IT) } catch { '' }
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="#0AFFFFFF" BorderBrush="#14FFFFFF" BorderThickness="1" CornerRadius="20" Padding="20,10" Margin="0,0,0,10">
  <DockPanel>
    <Button Name="Del" DockPanel.Dock="Right" Content="&#xE74D;" Style="{DynamicResource IconBtn}" ToolTip="Rimuovi dalla lista"/>
    <Border DockPanel.Dock="Left" Width="26" Height="26" CornerRadius="13" Background="#2630D158" Margin="0,0,14,0" VerticalAlignment="Center">
      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#30D158" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <TextBlock VerticalAlignment="Center" Foreground="#7AFFFFFF"><Run Text="$(Esc $g.name)" Foreground="#F5F5F7"/><Run Text="$(Esc (T '   comprato il {0}' $when))"/></TextBlock>
  </DockPanel>
</Border>
"@
    $el = Parse-Xaml $x
    $el.FindName('Del').Tag = $g.id
    $el.FindName('Del').Add_Click({ Remove-Goal $this.Tag })
    [void]$p.Children.Add($el)
  }

  if ($p.Children.Count -eq 0) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = T 'Nessun obiettivo per questo account. Aggiungine uno qui sotto.'; $t.Foreground = '#7AFFFFFF'; $t.Margin = '4,0,0,14'
    [void]$p.Children.Add($t)
  }
  $need = @{}
  foreach ($s in $stats) { $need[$s.goal.currency] = $s.remaining }
  $parts = @()
  foreach ($c in 'credits', 'acoins') { if ($need.ContainsKey($c) -and $need[$c] -gt 0) { $parts += "$(Short $need[$c]) $(CurName $c)" } }
  $script:ui.GoalsSummary.Text = if ($parts) { (T 'Ancora da mettere da parte: ') + ($parts -join '  ·  ') } elseif ($stats) { T 'Tutti gli obiettivi attivi sono coperti.' } else { '' }
}

function Render-Activity {
  $ui = $script:ui; $d = $script:Data
  $since = (Get-Date).AddDays(-14)
  $gc = 0.0; $ga = 0.0; $sc = 0.0; $sa = 0.0
  foreach ($e in @($d.events)) {
    if ([datetime]$e.t -lt $since) { continue }
    if ($e.kind -eq 'gain') { if ($e.cur -eq 'credits') { $gc += $e.delta } else { $ga += $e.delta } }
    elseif ($e.kind -eq 'spend') { if ($e.cur -eq 'credits') { $sc -= $e.delta } else { $sa -= $e.delta } }
  }
  $ui.StatGainC.Text = Short $gc; $ui.StatGainA.Text = Fmt $ga
  $ui.StatSpendC.Text = Short $sc; $ui.StatSpendA.Text = Fmt $sa

  $list = $ui.ActivityList; $list.Children.Clear()
  $evs = @($d.events | Select-Object -Last 120); [array]::Reverse($evs)
  $lastDay = $null
  foreach ($e in $evs) {
    $day = ([datetime]$e.t).Date
    if ($day -ne $lastDay) {
      $lastDay = $day
      $lbl = if ($day -eq (Get-Date).Date) { T 'Oggi' } elseif ($day -eq (Get-Date).Date.AddDays(-1)) { T 'Ieri' } else { $day.ToString('dddd d MMMM', $script:IT) }
      $t = New-Object System.Windows.Controls.TextBlock
      $t.Text = $lbl; $t.Foreground = '#B8FFFFFF'; $t.FontWeight = 'SemiBold'; $t.Margin = '0,10,0,10'
      [void]$list.Children.Add($t)
    }
    [void]$list.Children.Add((New-ActivityRow $e))
  }
  if ($evs.Count -eq 0) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = T 'Nessuna attività registrata.'; $t.Foreground = '#66FFFFFF'; $t.Margin = '0,8,0,0'
    [void]$list.Children.Add($t)
  }

  $p = $ui.ViolPanel; $p.Children.Clear()
  $v = @($d.violations)
  if ($v.Count -eq 0) {
    $ui.ViolTotal.Text = T 'Nessuna spesa confessata. Continua così.'
    $ui.ViolTotal.Foreground = '#8CF0A8'
    return
  }
  $totC = [double]($v | Where-Object currency -eq 'credits' | Measure-Object amount -Sum).Sum
  $totA = [double]($v | Where-Object currency -eq 'acoins'  | Measure-Object amount -Sum).Sum
  $ui.ViolTotal.Text = T 'Totale buttato: {0} crediti · {1} A-coin' (Fmt $totC) (Fmt $totA)
  $ui.ViolTotal.Foreground = '#FFB4AB'
  $recent = @($v | Select-Object -Last 8); [array]::Reverse($recent)
  foreach ($e in $recent) {
    $when = try { ([datetime]$e.t).ToString('d MMM HH:mm', $script:IT) } catch { '' }
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" BorderBrush="#14FFFFFF" BorderThickness="0,1,0,0" Padding="0,12,0,12">
  <StackPanel>
    <DockPanel>
      <TextBlock DockPanel.Dock="Right" Text="$when" Foreground="#66FFFFFF" FontSize="11" VerticalAlignment="Center"/>
      <TextBlock Text="−$(Fmt $e.amount) $(CurName $e.currency)" Foreground="#FF8A80" FontSize="16"/>
    </DockPanel>
    <TextBlock Text="$(Esc $e.reason)" Foreground="#B8FFFFFF" FontSize="12" TextWrapping="Wrap" Margin="0,3,0,8"/>
    <Button Name="Fix" Content="Era una missione: ripristina la serie" HorizontalAlignment="Left" Padding="12,6" FontSize="12"/>
  </StackPanel>
</Border>
"@
    $el = Parse-Xaml $x
    $el.FindName('Fix').Tag = [string]$e.t
    $el.FindName('Fix').Add_Click({ Undo-Violation $this.Tag })
    [void]$p.Children.Add($el)
  }
}

function Render-Tools {
  $ui = $script:ui; $d = $script:Data
  $ui.ToolAccount.Text = T "Lette dal gioco per l'account «{0}»." (Get-AccountName)
  $ui.ToolCred.Text = if ($d.initCredits) { Fmt $d.credits } else { '—' }
  $ui.ToolAc.Text   = if ($d.initAcoins)  { Fmt $d.acoins }  else { '—' }
  Update-CalcTotals
  Update-Crate
}

function Copy-Resource([string]$cur) {
  $d = $script:Data
  if (-not $d.(InitProp $cur)) { $script:ui.ToolMsg.Text = T "Saldo non ancora letto: apri Mech Arena e vai nell'hangar."; return $false }
  try { [System.Windows.Clipboard]::SetText(([long]$d.$cur).ToString()) } catch { return $false }
  $script:ui.ToolMsg.Text = T '{0} copiati negli appunti: {1}' (CurName $cur) (Fmt $d.$cur)
  $true
}

$script:CostFile = Join-Path $script:AppDir 'costi.json'
$script:Rarities = @(
  @{ k = 'common'; min = 1 }, @{ k = 'uncommon'; min = 2 }, @{ k = 'rare'; min = 3 },
  @{ k = 'epic'; min = 4 }, @{ k = 'legendary'; min = 5 })
$script:BaseCostFile = Join-Path $script:Here 'calc\wiki-costs.json'
$script:BaseCosts = @{}
$script:Costs = @{}
$script:CalcKeys = @()
$script:Energies = @(2, 4, 6, 8, 10, 12, 14, 16)
$script:CalcTot = @{ c = 0.0; b = 0.0; a = 0.0; miss = 0; n = 0 }
$script:CalcBuilding = $false

function Num-OrNull($v) { if ($null -eq $v -or "$v" -eq '') { $null } else { [double]$v } }

function Get-Cost([string]$key) {
  $e = $script:Costs[$key]; if ($e) { return $e }
  $script:BaseCosts[$key]
}

function Merge-Costs($j, $target) {
  if (-not $target) { $target = $script:Costs }
  if (-not $j -or $j.format -ne 'mechvault-costs' -or -not $j.costs) { return -1 }
  $n = 0
  foreach ($p in $j.costs.PSObject.Properties) {
    if ($p.Name -notmatch '^(mech\|(common|uncommon|rare|epic|legendary)|weapon\|(common|uncommon|rare|epic|legendary)\|e(2|4|6|8|10|12|14|16))\|(lvl\|[1-6]\|[2-7]|star\|[2-6])$') { continue }
    $e = @{ c = (Num-OrNull $p.Value.c); b = (Num-OrNull $p.Value.b); a = (Num-OrNull $p.Value.a) }
    if ($null -eq $e.c -and $null -eq $e.b -and $null -eq $e.a) { continue }
    $target[$p.Name] = $e; $n++
  }
  $n
}

function Load-Costs {
  $script:Costs = @{}; $script:BaseCosts = @{}
  if (Test-Path $script:BaseCostFile) {
    try { [void](Merge-Costs (Read-JsonFile $script:BaseCostFile) $script:BaseCosts) } catch { Write-Log "Costi wiki: $_" }
  }
  $fix = Join-Path $script:Here 'calc\cost-fixes.json'
  if (Test-Path $fix) {
    try { [void](Merge-Costs (Read-JsonFile $fix) $script:BaseCosts) } catch { Write-Log "Correzioni costi: $_" }
  }
  if (-not (Test-Path $script:CostFile)) { return }
  try { [void](Merge-Costs (Read-JsonFile $script:CostFile)) } catch { Write-Log "Costi: $_" }
}

function Save-Costs([string]$path = $script:CostFile, [switch]$All) {
  $src = $script:Costs
  if ($All) { $src = @{}; foreach ($k in $script:BaseCosts.Keys) { $src[$k] = $script:BaseCosts[$k] }; foreach ($k in $script:Costs.Keys) { $src[$k] = $script:Costs[$k] } }
  $script:LastSaved = $src.Count
  $o = [ordered]@{}
  foreach ($k in @($src.Keys | Sort-Object)) { $v = $src[$k]; $o[$k] = [ordered]@{ c = $v.c; b = $v.b; a = $v.a } }
  $j = [ordered]@{ format = 'mechvault-costs'; version = 1; updated = (Now-Iso); costs = $o }
  try { [IO.File]::WriteAllText($path, ($j | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false))); return $true }
  catch { Write-Log "Salva costi: $_"; return $false }
}

function Get-CalcInput {
  $ui = $script:ui
  $r = @($script:Rarities | Where-Object { $ui["CalcR_$($_.k)"].IsChecked })[0]
  if (-not $r) { $r = $script:Rarities[3] }
  $v = @{}
  foreach ($n in 'FS', 'FL', 'TS', 'TL') {
    $x = 0
    $max = if ($n -like '?S') { 6 } else { 7 }
    if (-not [int]::TryParse($ui["Calc$n"].Text.Trim(), [ref]$x) -or $x -lt 1 -or $x -gt $max) { return @{ err = (T 'Stelle da 1 a 6, livelli da 1 a 7.') } }
    $v[$n] = $x
  }
  $en = @($script:Energies | Where-Object { $ui["CalcE_$_"].IsChecked })[0]
  if (-not $en) { $en = 8 }
  $kind = if ($ui.CalcMech.IsChecked) { 'mech' } else { 'weapon' }
  $grp = if ($kind -eq 'mech') { "mech|$($r.k)" } else { "weapon|$($r.k)|e$en" }
  @{ err = $null; kind = $kind; rarity = $r.k; energy = $en; grp = $grp
     fs = $v.FS; fl = $v.FL; ts = $v.TS; tl = $v.TL }
}

function Get-CalcPath($in) {
  $steps = @(); $s = $in.fs; $l = $in.fl
  while ($s -lt $in.ts -or ($s -eq $in.ts -and $l -lt $in.tl)) {
    if ($l -lt 7) { $steps += @{ key = "lvl|$s|$($l + 1)"; label = (T '★{0} · liv. {1} → {2}' $s $l ($l + 1)) }; $l++ }
    else { $steps += @{ key = "star|$($s + 1)"; label = (T '★{0} → ★{1}' $s ($s + 1)) }; $s++; $l = 1 }
  }
  $steps
}

function Build-Calc {
  $ui = $script:ui
  if (-not $ui -or -not $ui.CalcSteps) { return }
  $script:CalcBuilding = $true
  $ui.CalcSteps.Children.Clear(); $script:CalcKeys = @()
  $in = Get-CalcInput
  if (-not $in.err) {
    $pre = "$($in.grp)|"
    foreach ($st in @(Get-CalcPath $in)) {
      $key = $pre + $st.key
      $x = @"
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,6">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="130"/><ColumnDefinition Width="110"/><ColumnDefinition Width="110"/></Grid.ColumnDefinitions>
  <TextBlock Name="L" VerticalAlignment="Center" Foreground="#B8FFFFFF"/>
  <TextBox Name="Cc" Grid.Column="1" Height="34" Margin="8,0,0,0"/>
  <TextBox Name="Cb" Grid.Column="2" Height="34" Margin="8,0,0,0"/>
  <TextBox Name="Ca" Grid.Column="3" Height="34" Margin="8,0,0,0"/>
</Grid>
"@
      $el = [Windows.Markup.XamlReader]::Parse($x)
      $el.FindName('L').Text = $st.label
      if ($st.key -like 'star|*') { $el.FindName('L').Foreground = '#DA8FFF' }
      $e = Get-Cost $key
      $fromWiki = (-not $script:Costs[$key]) -and $script:BaseCosts[$key]
      foreach ($f in 'c', 'b', 'a') {
        $tb = $el.FindName('C' + $f)
        $tb.Tag = "$key#$f"
        if ($e -and $null -ne $e[$f]) { $tb.Text = Fmt $e[$f] }
        if ($fromWiki) { $tb.Foreground = '#B8FFFFFF'; $tb.ToolTip = T 'Dal Mech Arena Wiki: correggilo se nel gioco è diverso.' }
        $tb.Add_TextChanged({ Set-CalcCell $this })
        $tb.Add_LostFocus({ [void](Save-Costs) })
      }
      $script:CalcKeys += $key
      [void]$ui.CalcSteps.Children.Add($el)
    }
  }
  $script:CalcBuilding = $false
  Update-CalcTotals $in
  if (-not $script:CalcRunning -and $ui.CalcResult -and $ui.CalcResult.Visibility -eq 'Visible') {
    $ui.CalcResult.Visibility = 'Collapsed'
    $ui.CalcHint.Text = T 'Dati cambiati: premi di nuovo «Calcola» per aggiornare il risultato.'
  }
}

function Run-Calc {
  $ui = $script:ui
  $script:CalcRunning = $true
  try { Build-Calc } finally { $script:CalcRunning = $false }
  $in = Get-CalcInput
  if ($in.err) { $ui.CalcResult.Visibility = 'Collapsed'; $ui.CalcHint.Text = $in.err; return }
  if ($script:CalcTot.n -eq 0) { $ui.CalcResult.Visibility = 'Collapsed'; $ui.CalcHint.Text = T 'Scegli un arrivo più alto della partenza.'; return }
  $name = $ui.CalcName.Text.Trim()
  $kind = if ($in.kind -eq 'mech') { 'Mech' } else { T 'Arma' }
  $rar = WW ((Get-Culture).TextInfo.ToTitleCase($in.rarity))
  $en = if ($in.kind -eq 'weapon') { " · $($in.energy) " + (T 'energia') } else { '' }
  $item = if ($name) { "$name ($kind · $rar$en)" } else { "$kind · $rar$en" }
  $ui.CalcSummary.Text = T '{0} · da ★{1} liv. {2} a ★{3} liv. {4} · {5} passi' $item $in.fs $in.fl $in.ts $in.tl $script:CalcTot.n
  $ui.CalcHint.Text = ''
  $ui.CalcResult.Visibility = 'Visible'
}
function Toggle-CalcDetail {
  $ui = $script:ui
  if ($ui.CalcBreakdown.Visibility -eq 'Visible') { $ui.CalcBreakdown.Visibility = 'Collapsed'; $ui.BtnCalcDetail.Content = T 'Mostra il dettaglio passo per passo' }
  else { $ui.CalcBreakdown.Visibility = 'Visible'; $ui.BtnCalcDetail.Content = T 'Nascondi il dettaglio' }
}

function Set-CalcCell($tb) {
  if ($script:CalcBuilding) { return }
  $parts = ([string]$tb.Tag).Split('#'); $key = $parts[0]; $f = $parts[1]
  $v = Parse-Amount $tb.Text
  $e = $script:Costs[$key]
  if (-not $e) {
    $b0 = $script:BaseCosts[$key]
    $e = if ($b0) { @{ c = $b0.c; b = $b0.b; a = $b0.a } } else { @{ c = $null; b = $null; a = $null } }
    $script:Costs[$key] = $e
  }
  $e[$f] = if ($null -eq $v) { $null } else { [double]$v }
  if ($null -eq $e.c -and $null -eq $e.b -and $null -eq $e.a) { $script:Costs.Remove($key) }
  Update-CalcTotals
}

function Update-CalcTotals($in) {
  $ui = $script:ui; $d = $script:Data
  if (-not $ui -or -not $ui.CalcTotC) { return }
  if (-not $in) { $in = Get-CalcInput }
  $c = 0.0; $b = 0.0; $a = 0.0; $miss = 0
  foreach ($k in $script:CalcKeys) {
    $e = Get-Cost $k
    if (-not $e) { $miss++; continue }
    if ($null -ne $e.c) { $c += $e.c }; if ($null -ne $e.b) { $b += $e.b }; if ($null -ne $e.a) { $a += $e.a }
  }
  $n = $script:CalcKeys.Count
  $script:CalcTot = @{ c = $c; b = $b; a = $a; miss = $miss; n = $n }
  $pre = if ($miss -gt 0) { '≥ ' } else { '' }
  $ui.CalcTotC.Text = $pre + (Fmt $c); $ui.CalcTotB.Text = $pre + (Fmt $b); $ui.CalcTotA.Text = $pre + (Fmt $a)
  $needC = -1.0; $needA = -1.0
  if ($d.initCredits) { $needC = [math]::Max(0.0, $c - [double]$d.credits); $ui.CalcNeedC.Text = $(if ($needC -gt 0) { T 'mancano {0}' (Fmt $needC) } elseif ($miss) { T 'per ora coperto' } else { T 'coperto ✓' }) }
  else { $ui.CalcNeedC.Text = T 'saldo non ancora letto' }
  if ($d.initAcoins) { $needA = [math]::Max(0.0, $a - [double]$d.acoins); $ui.CalcNeedA.Text = $(if ($needA -gt 0) { T 'mancano {0}' (Fmt $needA) } elseif ($miss) { T 'per ora coperto' } else { T 'coperto ✓' }) }
  else { $ui.CalcNeedA.Text = T 'saldo non ancora letto' }
  $myBp = Parse-Amount $ui.CalcMyBp.Text
  $ui.CalcNeedB.Text = if ($null -eq $myBp) { T 'scrivi quanti ne hai' } elseif ($b -gt $myBp) { T 'mancano {0}' (Fmt ($b - $myBp)) } elseif ($miss) { T 'per ora coperto' } else { T 'coperto ✓' }
  if ($in.err) { $ui.CalcInfo.Text = $in.err; return }
  if ($n -eq 0) { $ui.CalcInfo.Text = T 'Scegli un arrivo più alto della partenza.'; return }
  if ($miss -gt 0) { $ui.CalcInfo.Text = T 'Mancano {0} costi su {1}: copiali qui sotto dalla schermata di potenziamento del gioco. Per ora il totale è un minimo.' $miss $n; return }
  $parts = @()
  if ($needC -gt 0) { $r = Get-Rate 'credits'; $parts += $(if ($r.v -gt 0) { T 'crediti tra ~{0}' (Eta-Days ($needC / $r.v)) } else { T 'crediti: imposta il ritmo' }) }
  if ($needA -gt 0) { $r = Get-Rate 'acoins'; $parts += $(if ($r.v -gt 0) { T 'A-coin tra ~{0}' (Eta-Days ($needA / $r.v)) } else { T 'A-coin: imposta il ritmo' }) }
  $ui.CalcInfo.Text = if ($parts.Count) { T '{0} passi. Al tuo ritmo: {1}.' $n ($parts -join ' · ') } elseif ($needC -eq 0 -and $needA -eq 0) { T '{0} passi. Hai già tutto il necessario.' $n } else { T '{0} passi.' $n }
}

function Set-CalcRarity {
  $r = @($script:Rarities | Where-Object { $script:ui["CalcR_$($_.k)"].IsChecked })[0]
  $fs = 0
  Build-Calc
}

function Add-CalcGoal {
  $ui = $script:ui; $in = Get-CalcInput; $t = $script:CalcTot
  if ($in.err) { $ui.CalcMsg.Text = $in.err; return }
  if ($t.n -eq 0) { $ui.CalcMsg.Text = T 'Scegli un arrivo più alto della partenza.'; return }
  if ($t.miss -gt 0) { $ui.CalcMsg.Text = T 'Prima compila tutti i costi ({0} mancanti).' $t.miss; return }
  $name = $ui.CalcName.Text.Trim()
  if (-not $name) { $name = if ($in.kind -eq 'mech') { 'Mech' } else { T 'Arma' } }
  $label = "$name ★$($in.ts) " + (T 'liv. {0}' $in.tl)
  $add = @()
  if ($t.c -gt 0) { $add += (New-Goal $label 'credits' $t.c) }
  if ($t.a -gt 0) { $add += (New-Goal "$label · A-coin" 'acoins' $t.a) }
  if (-not $add.Count) { $ui.CalcMsg.Text = T 'Costo totale zero: niente da aggiungere.'; return }
  $script:Data.goals = @(@($script:Data.goals) + $add)
  Save-Data; Refresh-UI
  $ui.CalcMsg.Text = T 'Aggiunto agli obiettivi: {0}' $label
}

function Import-Costs {
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Filter = 'JSON (*.json)|*.json'
  if (-not $dlg.ShowDialog($script:win)) { return }
  $n = -1
  try { $n = Merge-Costs (Read-JsonFile $dlg.FileName) } catch { Write-Log "Importa costi: $_" }
  if ($n -lt 0) { $script:ui.CalcMsg.Text = T 'File non valido: serve una tabella esportata da MechVault.'; return }
  [void](Save-Costs); Build-Calc
  $script:ui.CalcMsg.Text = T 'Importati {0} costi.' $n
}

function Export-Costs {
  $dlg = New-Object Microsoft.Win32.SaveFileDialog
  $dlg.Filter = 'JSON (*.json)|*.json'; $dlg.FileName = 'mechvault-costi.json'
  if (-not $dlg.ShowDialog($script:win)) { return }
  if (Save-Costs $dlg.FileName -All) { $script:ui.CalcMsg.Text = T 'Tabella esportata: {0} costi.' $script:LastSaved }
}

function Parse-Pct([string]$t) {
  if ([string]::IsNullOrWhiteSpace($t)) { return $null }
  $v = 0.0
  if (-not [double]::TryParse(($t.Trim().TrimEnd('%') -replace ',', '.'), [Globalization.NumberStyles]::Float, $script:INV, [ref]$v)) { return $null }
  if ($v -le 0 -or $v -gt 100) { return $null }
  $v / 100
}
function Pct([double]$f) { ($f * 100).ToString('0.##', $script:IT) + '%' }
function Spins-For([double]$p, [double]$q, [int]$pity) {
  if ($p -ge 1) { return 1 }
  $k = [int][math]::Ceiling([math]::Log(1 - $q) / [math]::Log(1 - $p))
  if ($pity -gt 0) { $k = [math]::Min($k, $pity) }
  [math]::Max(1, $k)
}

function Update-Crate {
  $ui = $script:ui
  if (-not $ui -or -not $ui.CrVerdict) { return }
  $cur = if ($ui.CrCr.IsChecked) { 'credits' } else { 'acoins' }
  $cn = CurName $cur
  $spin = Parse-Amount $ui.CrSpin.Text
  $direct = Parse-Amount $ui.CrDirect.Text
  $p = Parse-Pct $ui.CrP.Text
  $pityAmt = Parse-Amount $ui.CrPity.Text; if ($null -eq $pityAmt) { $pityAmt = 0 }
  $pity = 0
  $budget = Parse-Amount $ui.CrBudget.Text
  $rc = (Get-Rate 'credits').v; $rx = (Get-Rate $cur).v
  $lines = @()
  $ui.CrVerdictBox.Background = '#0FFFFFFF'; $ui.CrVerdictBox.BorderBrush = '#1AFFFFFF'; $ui.CrVerdict.Foreground = '#F5F5F7'
  if ($null -eq $spin -or $spin -le 0) { $ui.CrVerdict.Text = T 'Scrivi il costo di uno spin.'; $ui.CrStats.Text = ''; return }
  if ($pityAmt -gt 0) { $pity = [int][math]::Ceiling($pityAmt / $spin) }

  $dDays = $null; $beSpins = $null; $beCost = $null
  $ra = (Get-Rate 'acoins').v
  $ui.CrUpgGrid.IsEnabled = [bool]$ui.CrUpg.IsChecked
  $upg = $null; $budgetDays = $null
  if ($ui.CrUpg.IsChecked -and $direct -gt 0) { $upg = Get-CrateUpgrades }
  if ($upg -and $upg.err) { $lines += $upg.err; $upg = $null }
  $dCur = if ($ui.CrDirAc.IsChecked) { 'acoins' } else { 'credits' }
  $rd = if ($dCur -eq 'credits') { $rc } else { $ra }
  if ($direct -gt 0 -and $rd -gt 0) { $dDays = $direct / $rd }
  if ($upg -and $null -ne $dDays -and $ra -gt 0) {
    $dirTot = $dDays + $upg.dir.c / $rc + $upg.dir.a / $ra
    $boxUpg = $upg.box.c / $rc + $upg.box.a / $ra
    $lines += T 'Via diretta: {0} {6}, poi da {1} servono {2} crediti, {3} A-coin e {4} blueprint = ~{5} in tutto.' (Fmt $direct) $upg.dirLbl (Fmt $upg.dir.c) (Fmt $upg.dir.a) (Fmt $upg.dir.b) (Eta-Fine $dirTot) (CurName $dCur)
    $lines += T 'Con la cassa: da {0} servono ancora {1} crediti, {2} A-coin e {3} blueprint (~{4}).' $upg.boxLbl (Fmt $upg.box.c) (Fmt $upg.box.a) (Fmt $upg.box.b) (Eta-Fine $boxUpg)
    if ($upg.boxS -lt $upg.dirS) {
      $lines += T 'Il premio arriva a ★{0}, dal Gear Hub a ★{1}: finché non paghi le stelle mancanti non hai i bonus di rango (per esempio la Voidghost sblocca la doppia abilità a rango 5).' $upg.boxS $upg.dirS
    }
    if ($upg.box.b -ne $upg.dir.b) { $lines += T 'Blueprint: con la cassa ne servono {0} in più (non convertibili in giorni).' (Fmt ($upg.box.b - $upg.dir.b)) }
    if ($upg.miss -gt 0) { $lines += T 'Mancano {0} costi di potenziamento nella tabella: il confronto è approssimato.' $upg.miss }
    $budgetDays = $dirTot - $boxUpg
    if ($rx -gt 0) { $beCost = [math]::Max(0.0, $budgetDays * $rx) }
    if ($budgetDays -le 0) { $lines += T 'Il premio della cassa arriva così basso che i soli potenziamenti costano più della via diretta.' }
  } else {
    if ($direct -gt 0) {
      if ($cur -eq $dCur) { $beCost = [double]$direct } elseif ($null -ne $dDays -and $rx -gt 0) { $beCost = $dDays * $rx }
    }
    if ($null -ne $dDays) { $lines += T 'Via diretta: {0} {2} = ~{1} di grind.' (Fmt $direct) (Eta-Fine $dDays) (CurName $dCur) }
  }
  if ($null -ne $beCost) { $beSpins = [math]::Floor($beCost / $spin) }

  if ($null -ne $p) {
    $E = if ($pity -gt 0) { (1 - [math]::Pow(1 - $p, $pity)) / $p } else { 1 / $p }
    $expCost = $E * $spin
    $expTxt = if ($rx -gt 0) { T ' (~{0} di grind)' (Eta-Fine ($expCost / $rx)) } else { '' }
    $lines += T 'In media servono {0} spin = {1} {2}{3}.' (([math]::Round($E, 1)).ToString('0.#', $script:IT)) (Fmt $expCost) $cn $expTxt
    $s50 = Spins-For $p 0.5 $pity; $s90 = Spins-For $p 0.9 $pity
    $lines += T 'Metà dei giocatori lo prende entro {0} spin ({1} {3}), 9 su 10 entro {2} ({4} {3}).' $s50 (Fmt ($s50 * $spin)) $s90 $cn (Fmt ($s90 * $spin))
    if ($pity -gt 0) { $lines += T 'Caso peggiore, con il garantito: {0} spin = {1} {2}.' $pity (Fmt ($pity * $spin)) $cn }
    else { $lines += T 'Nessun garantito: 1 giocatore su 10 spende più di {0} {1} e non c''è un tetto.' (Fmt ($s90 * $spin)) $cn }
    if ($budget -gt 0) {
      $n = [math]::Floor($budget / $spin)
      $pr = if ($pity -gt 0 -and $n -ge $pity) { 1.0 } else { 1 - [math]::Pow(1 - $p, $n) }
      $lines += T 'Con {0} {1} ({2} spin) hai il {3} di probabilità di prenderlo.' (Fmt $budget) $cn $n (Pct $pr)
    }
    if ($null -ne $beCost) {
      $ratio = $expCost / $beCost
      if ($ratio -gt 1.15) {
        $ui.CrVerdict.Text = T 'Truffa: in media costa {0} volte la via diretta.' ($ratio.ToString('0.#', $script:IT))
        $ui.CrVerdict.Foreground = '#FFB4AB'; $ui.CrVerdictBox.Background = '#1FFF453A'; $ui.CrVerdictBox.BorderBrush = '#4DFF453A'
      } elseif ($ratio -lt 0.85) {
        $ui.CrVerdict.Text = T 'In media conviene ({0} della via diretta), ma resta un azzardo.' (Pct $ratio)
        $ui.CrVerdict.Foreground = '#8CF0A8'; $ui.CrVerdictBox.Background = '#1A30D158'; $ui.CrVerdictBox.BorderBrush = '#4D30D158'
      } else {
        $ui.CrVerdict.Text = T 'Pari con la via diretta: nessun vantaggio, solo rischio.'
        $ui.CrVerdict.Foreground = '#FFD60A'; $ui.CrVerdictBox.Background = '#1AFFD60A'; $ui.CrVerdictBox.BorderBrush = '#4DFFD60A'
      }
    } else { $ui.CrVerdict.Text = T 'Scrivi il costo a crediti per avere il giudizio.' }
  } elseif ($pity -gt 0 -and $null -ne $beCost) {
    $worst = $pity * $spin
    $wTxt = if ($rx -gt 0) { T ' (~{0} di grind)' (Eta-Fine ($worst / $rx)) } else { '' }
    $lines += T 'Garantito: al massimo {0} spin = {1} {2}{3}, qualunque sia la fortuna.' $pity (Fmt $worst) $cn $wTxt
    if ($worst -le $beCost) {
      $ui.CrVerdict.Text = T 'Conviene: anche nel caso peggiore costa {0} della via diretta.' (Pct ($worst / $beCost))
      $ui.CrVerdict.Foreground = '#8CF0A8'; $ui.CrVerdictBox.Background = '#1A30D158'; $ui.CrVerdictBox.BorderBrush = '#4D30D158'
    } else {
      $rr = if ($beCost -gt 0) { ($worst / $beCost).ToString('0.#', $script:IT) } else { '∞' }
      $ui.CrVerdict.Text = T 'Rischio: nel caso peggiore costa {0} volte la via diretta. Scrivi la probabilità per il costo medio.' $rr
      $ui.CrVerdict.Foreground = '#FFD60A'; $ui.CrVerdictBox.Background = '#1AFFD60A'; $ui.CrVerdictBox.BorderBrush = '#4DFFD60A'
    }
  } else {
    $ui.CrVerdict.Text = T 'Scrivi la probabilità del premio per il giudizio.'
    if ($null -ne $beSpins -and $beSpins -ge 1) {
      $lines += T 'Conviene solo se lo prendi entro {0} spin: serve almeno il {1} a spin. Se le info della Crate Rush dicono meno, è una truffa.' $beSpins (Pct (1.0 / $beSpins))
    } elseif ($null -ne $beSpins) {
      $ui.CrVerdict.Text = T 'Truffa: un solo spin costa più della via diretta.'
      $ui.CrVerdict.Foreground = '#FFB4AB'; $ui.CrVerdictBox.Background = '#1FFF453A'; $ui.CrVerdictBox.BorderBrush = '#4DFF453A'
    }
  }
  if ($upg -and $null -ne $budgetDays -and $budgetDays -le 0) {
    $ui.CrVerdict.Text = T 'Truffa: anche gratis, il premio della cassa ti costa più potenziamenti della via diretta.'
    $ui.CrVerdict.Foreground = '#FFB4AB'; $ui.CrVerdictBox.Background = '#1FFF453A'; $ui.CrVerdictBox.BorderBrush = '#4DFF453A'
  }
  $prizes = @(Get-CratePrizes)
  $ui.CrPrizeHead.Visibility = if ($prizes.Count) { 'Visible' } else { 'Collapsed' }
  $others = @(); $skipped = 0
  foreach ($o in $prizes) {
    if (-not $o.want) { continue }
    $r = if ($o.cur -eq 'credits') { $rc } else { $ra }
    if ($null -eq $o.p -or -not ($o.price -gt 0) -or $r -le 0) { $skipped++; continue }
    $others += @{ name = $o.name; p = $o.p; days = $o.price / $r }
  }
  if ($others.Count -and $rx -gt 0) {
    $v0 = if ($null -ne $beCost -and $null -ne $p) { $beCost / $rx } else { 0.0 }
    $p0 = if ($null -ne $p) { $p } else { 0.0 }
    $ptot = $p0; foreach ($o in $others) { $ptot += $o.p }
    $nMax = if ($pity -gt 0) { $pity } else { [int][math]::Min(400, [math]::Max(10, [math]::Ceiling([math]::Log(0.02) / [math]::Log(1 - [math]::Min(0.99, $ptot))))) }
    $cv = Get-CrateCurve $p0 $v0 $pity $others ($spin / $rx) $nMax
    $wantNames = (@($others | ForEach-Object { $_.name }) | Where-Object { $_ }) -join ', '
    $lines += T 'Premi che vuoi oltre al principale: {0}.' $(if ($wantNames) { $wantNames } else { $others.Count })
    if ($skipped) { $lines += T '{0} premi senza probabilità o prezzo non sono contati.' $skipped }
    if ($cv.best.n -gt 0) {
      $lines += T 'Il punto migliore è fermarsi a {0} spin ({1} {2}): valore atteso ~{3} contro ~{4} spesi.' $cv.best.n (Fmt ($cv.best.n * $spin)) $cn (Eta-Fine $cv.best.ev) (Eta-Fine ($cv.best.n * $spin / $rx))
      $last = $cv.rows[-1]
      if ($pity -gt 0) { $lines += T 'Fino al garantito ({0} spin): valore atteso ~{1} contro ~{2} spesi.' $pity (Eta-Fine $last.ev) (Eta-Fine ($pity * $spin / $rx)) }
      $ui.CrVerdict.Text = T 'Conviene fino a {0} spin con tutti i premi che vuoi: oltre, ogni spin vale meno di quanto costa.' $cv.best.n
      $ui.CrVerdict.Foreground = '#8CF0A8'; $ui.CrVerdictBox.Background = '#1A30D158'; $ui.CrVerdictBox.BorderBrush = '#4D30D158'
      $beSpins = $cv.best.n
    } else {
      $ui.CrVerdict.Text = T 'Truffa: nemmeno contando tutti i premi che vuoi un solo spin ripaga quello che costa.'
      $ui.CrVerdict.Foreground = '#FFB4AB'; $ui.CrVerdictBox.Background = '#1FFF453A'; $ui.CrVerdictBox.BorderBrush = '#4DFF453A'
      $beSpins = 0
    }
  }
  $mk = Find-Mech $ui.CrName.Text
  if ($mk) {
    $pr = Get-MechProfile $mk; $rt = $script:Ratings[$mk]
    if ($rt) {
      $lines += T '{0}: fascia {1} ({2}/100) al massimo · {3} · abilità migliore del {4} dei mech.' $mk $rt.tier $rt.score $pr.summary "$([math]::Round($rt.abP * 100))%"
      $ps2 = Get-StarLvl 'CrPS' 'CrPL'
      if ($ps2) {
        $ra2 = Get-RatingAt $mk $ps2.s $ps2.l
        if ($ra2.r) { $lines += T 'Al rango con cui arriva dalla cassa ({0}): fascia {1} ({2}/100), {3} HP, più resistente del {4} dei mech allo stesso rango.' $script:RankLabels[$ra2.idx] $ra2.r.tier $ra2.r.score (Fmt $ra2.r.hp) "$([math]::Round($ra2.r.hpP * 100))%" }
      }
      if ($rt.tier -in 'C', 'D') { $lines += T 'Attenzione: {0} è un mech debole (fascia {1}). Anche se il prezzo conviene, valuta se lo useresti davvero.' $mk $rt.tier }
    } else { $lines += T '{0}: {1}. Dettagli in «Scheda mech».' $mk $pr.summary }
  }
  if ($null -ne $beSpins -and $beSpins -ge 1) {
    $lines += T 'Budget massimo sensato: {0} {1} ({2} spin). Oltre, la via diretta costa meno.' (Fmt ($beSpins * $spin)) $cn $beSpins
  }
  if ($cur -eq 'acoins') { $lines += T 'Ricorda: le A-coin servono anche per salire di stella (810 per un''arma epica, 1.875 per un mech epico).' }
  if ($cur -eq 'acoins' -and $rx -gt 0) { $lines += T 'Calcolato con il tuo ritmo: ~{0} crediti e ~{1} A-coin al giorno.' (Fmt $rc) (Fmt $rx) }
  $warn = @()
  $rr = @($script:Rarities | Where-Object { $ui["CrR_$($_.k)"].IsChecked })[0]
  if ($ui.CrUpg.IsChecked) {
    $dd = Get-StarLvl 'CrDS' 'CrDL'
    if ($dd -and $rr -and $dd.s -lt $rr.min) { $warn += T 'Il Gear Hub vende questa rarità a partire da ★{0}, non da ★{1}.' $rr.min $dd.s }
  }
  $mk2 = Find-Mech $ui.CrName.Text
  if ($mk2 -and $direct -gt 0) {
    $gh = $script:Mechs[$mk2].gearHub
    if ($gh -and $gh.amount) {
      $dCur2 = if ($ui.CrDirAc.IsChecked) { 'acoins' } else { 'credits' }
      if ($gh.currency -ne $dCur2 -or [math]::Abs($direct - $gh.amount) / $gh.amount -gt 0.5) { $warn += T 'Nel Gear Hub {0} costa {1} {2}, tu hai scritto {3} {4}.' $mk2 (Fmt $gh.amount) (CurName $gh.currency) (Fmt $direct) (CurName $dCur2) }
    }
    $rk = @{ Common = 'common'; Uncommon = 'uncommon'; Rare = 'rare'; Epic = 'epic'; Legendary = 'legendary' }[[string]$script:Mechs[$mk2].rarity]
    if ($rk -and $rr -and $rk -ne $rr.k) { $warn += T '{0} è {1}, non {2}.' $mk2 (WW $script:Mechs[$mk2].rarity) (WW ((Get-Culture).TextInfo.ToTitleCase($rr.k))) }
  }
  if ($rx -gt 0 -and ($spin / $rx) -lt 0.02 -and ($null -eq $dDays -or $dDays -lt 0.02)) { $warn += T 'Importi troppo piccoli per un confronto sensato.' }
  if ($warn.Count) {
    $ui.CrVerdict.Text = T 'Controlla i dati: qualcosa non torna.'
    $ui.CrVerdict.Foreground = '#FFD60A'; $ui.CrVerdictBox.Background = '#1AFFD60A'; $ui.CrVerdictBox.BorderBrush = '#4DFFD60A'
    $lines = @($warn) + @($lines)
  }
  $ui.CrStats.Text = ($lines | ForEach-Object { '• ' + $_ }) -join "`n"
}

function Get-StarLvl([string]$sn, [string]$ln) {
  $s = 0; $l = 0
  if (-not [int]::TryParse($script:ui[$sn].Text.Trim(), [ref]$s) -or $s -lt 1 -or $s -gt 6) { return $null }
  if (-not [int]::TryParse($script:ui[$ln].Text.Trim(), [ref]$l) -or $l -lt 1 -or $l -gt 7) { return $null }
  @{ s = $s; l = $l }
}
function Get-UpgSum([string]$grp, $from, $to) {
  $r = @{ c = 0.0; b = 0.0; a = 0.0; miss = 0 }
  if ($from.s -gt $to.s -or ($from.s -eq $to.s -and $from.l -ge $to.l)) { return $r }
  foreach ($st in @(Get-CalcPath @{ fs = $from.s; fl = $from.l; ts = $to.s; tl = $to.l })) {
    $e = Get-Cost "$grp|$($st.key)"
    if (-not $e) { $r.miss++; continue }
    if ($null -ne $e.c) { $r.c += $e.c }; if ($null -ne $e.b) { $r.b += $e.b }; if ($null -ne $e.a) { $r.a += $e.a }
  }
  $r
}
function Get-CrateGroup {
  $ui = $script:ui
  $r = @($script:Rarities | Where-Object { $ui["CrR_$($_.k)"].IsChecked })[0]; if (-not $r) { $r = $script:Rarities[4] }
  $en = @($script:Energies | Where-Object { $ui["CrE_$_"].IsChecked })[0]; if (-not $en) { $en = 16 }
  if ($ui.CrKW.IsChecked) { "weapon|$($r.k)|e$en" } else { "mech|$($r.k)" }
}
function Set-CrateRarity {
  $r = @($script:Rarities | Where-Object { $script:ui["CrR_$($_.k)"].IsChecked })[0]
  if ($r) { $script:ui.CrDS.Text = [string]$r.min; $script:ui.CrDL.Text = '1' }
  Update-Crate
}
function Get-CrateUpgrades {
  $in = @{ grp = (Get-CrateGroup) }
  $p = Get-StarLvl 'CrPS' 'CrPL'; $d = Get-StarLvl 'CrDS' 'CrDL'
  $t = if ($p -and $d) { if (($p.s * 10 + $p.l) -ge ($d.s * 10 + $d.l)) { $p } else { $d } } else { $null }
  if (-not $p -or -not $d -or -not $t) { return @{ err = (T 'Potenziamenti: stelle da 1 a 6, livelli da 1 a 7.') } }
  $box = Get-UpgSum $in.grp $p $t; $dir = Get-UpgSum $in.grp $d $t
  @{ err = $null; box = $box; dir = $dir; miss = $box.miss + $dir.miss; boxS = $p.s; dirS = $d.s
     boxLbl = "★$($p.s) $(T 'liv. {0}' $p.l)"; dirLbl = "★$($d.s) $(T 'liv. {0}' $d.l)" }
}

function Set-CratePreset([string]$name, [double]$spin, [double]$direct) {
  $ui = $script:ui
  $ui.CrName.Text = $name; $ui.CrAc.IsChecked = $true
  $ui.CrDirCr.IsChecked = $true; $ui.CrSpin.Text = Fmt $spin; $ui.CrDirect.Text = Fmt $direct; $ui.CrPity.Text = Fmt 7000
  Update-Crate
}

$script:CrPrizeSeq = 0
function Add-CratePrize([string]$name = '', [string]$p = '', [string]$price = '', [string]$cur = 'acoins', [bool]$want = $true) {
  $script:CrPrizeSeq++; $g = "crp$($script:CrPrizeSeq)"
  $x = @"
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,6">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="100"/><ColumnDefinition Width="130"/><ColumnDefinition Width="180"/><ColumnDefinition Width="112"/><ColumnDefinition Width="36"/></Grid.ColumnDefinitions>
  <TextBox Name="N" Height="34"/>
  <TextBlock Name="NH" IsHitTestVisible="False" Foreground="#52FFFFFF" VerticalAlignment="Center" Margin="16,0,0,0"/>
  <TextBox Name="P" Grid.Column="1" Height="34" Margin="8,0,0,0"/>
  <TextBlock Name="PH" Grid.Column="1" IsHitTestVisible="False" Foreground="#52FFFFFF" VerticalAlignment="Center" Margin="24,0,0,0"/>
  <TextBox Name="V" Grid.Column="2" Height="34" Margin="8,0,0,0"/>
  <TextBlock Name="VH" Grid.Column="2" IsHitTestVisible="False" Foreground="#52FFFFFF" VerticalAlignment="Center" Margin="24,0,0,0"/>
  <StackPanel Grid.Column="3" Orientation="Horizontal" Margin="8,0,0,0" VerticalAlignment="Center">
    <RadioButton Name="Cr" GroupName="$g" Content="cr"/>
    <RadioButton Name="Ac" GroupName="$g" Content="A-c"/>
  </StackPanel>
  <CheckBox Name="W" Grid.Column="4" Margin="8,0,0,0" VerticalAlignment="Center" Foreground="#B8FFFFFF"/>
  <Button Name="X" Grid.Column="5" Margin="6,0,0,0" Width="30" Height="30" Padding="0" FontFamily="Segoe MDL2 Assets" FontSize="10" Content="&#xE711;"/>
</Grid>
"@
  $el = [Windows.Markup.XamlReader]::Parse($x)
  foreach ($n in 'Cr', 'Ac') { $el.FindName($n).Style = $script:app.Resources['Pill'] }
  $el.FindName('Cr').Content = T 'crediti'; $el.FindName('Ac').Content = 'A-coin'
  $el.FindName('W').Content = T 'Lo voglio'
  $el.FindName('NH').Text = T 'nome (es. Lacewing)'; $el.FindName('PH').Text = T 'es. 1,5'; $el.FindName('VH').Text = T 'prezzo'
  $el.FindName('N').Text = $name; $el.FindName('P').Text = $p; $el.FindName('V').Text = $price
  foreach ($n in 'N', 'P', 'V') { $el.FindName($n).Tag = $el }
  Update-PrizeHints $el
  if ($cur -eq 'credits') { $el.FindName('Cr').IsChecked = $true } else { $el.FindName('Ac').IsChecked = $true }
  $el.FindName('W').IsChecked = $want
  foreach ($n in 'N', 'P', 'V') { $el.FindName($n).Add_TextChanged({ Update-PrizeHints $this.Tag; Update-Crate }) }
  $el.FindName('N').Add_TextChanged({ Fill-PrizePrice $this.Tag })
  foreach ($n in 'Cr', 'Ac', 'W') { $el.FindName($n).Add_Click({ Update-Crate }) }
  $el.FindName('X').Tag = $el
  $el.FindName('X').Add_Click({ [void]$script:ui.CrPrizes.Children.Remove($this.Tag); Update-Crate })
  [void]$script:ui.CrPrizes.Children.Add($el)
  Update-Crate
}

function Update-PrizeHints($el) {
  foreach ($n in 'N', 'P', 'V') { $el.FindName($n + 'H').Visibility = if ($el.FindName($n).Text) { 'Collapsed' } else { 'Visible' } }
}
function Fill-PrizePrice($el) {
  if ($el.FindName('V').Text.Trim()) { return }
  $k = Find-Mech $el.FindName('N').Text
  if (-not $k) { return }
  $gh = $script:Mechs[$k].gearHub
  if ($gh -and $gh.amount) {
    if ($gh.currency -eq 'credits') { $el.FindName('Cr').IsChecked = $true } else { $el.FindName('Ac').IsChecked = $true }
    $el.FindName('V').Text = Fmt $gh.amount
  }
}

function Get-CratePrizes {
  $list = @()
  foreach ($el in @($script:ui.CrPrizes.Children)) {
    $p = Parse-Pct $el.FindName('P').Text
    $v = Parse-Amount $el.FindName('V').Text
    $list += @{ name = $el.FindName('N').Text.Trim(); p = $p; price = $v
                cur = $(if ($el.FindName('Cr').IsChecked) { 'credits' } else { 'acoins' }); want = [bool]$el.FindName('W').IsChecked }
  }
  $list
}

function Get-CrateCurve([double]$p0, [double]$v0, [int]$pity, $others, [double]$spinDays, [int]$nMax) {
  $best = @{ n = 0; net = 0.0; ev = 0.0 }; $rows = @()
  for ($n = 1; $n -le $nMax; $n++) {
    $P0 = if ($pity -gt 0 -and $n -ge $pity) { 1.0 } else { 1 - [math]::Pow(1 - $p0, $n) }
    $ev = $v0 * $P0
    foreach ($o in $others) { $ev += $o.days * (1 - [math]::Pow(1 - $o.p, $n)) }
    $net = $ev - $n * $spinDays
    if ($net -gt $best.net) { $best = @{ n = $n; net = $net; ev = $ev } }
    $rows += @{ n = $n; ev = $ev; net = $net }
  }
  @{ best = $best; rows = $rows }
}

$script:Mechs = @{}
$script:WikiIt = @{ Energy = 'Energia'; Speed = 'Velocità'; Power = 'Potenza'; 'Ability Cooldown' = 'Ricarica abilità'; 'Ability Duration' = 'Durata abilità'; 'Shield Durability' = 'Resistenza scudo'; Tank = 'Tank'; Scout = 'Scout'; Attacker = 'Attaccante'; Support = 'Supporto'; Legendary = 'Leggendario'; Epic = 'Epico'; Rare = 'Raro'; Uncommon = 'Non comune'; Common = 'Comune'; Heavy = 'Pesante'; Medium = 'Medio'; Light = 'Leggero' }
function WW([string]$w) { if ($script:Lang -eq 'it' -and $script:WikiIt[$w]) { $script:WikiIt[$w] } else { T $w } }

$script:AbilityModel = @{
  'personal shield' = @{ s = 6 };          'shield' = @{ s = 4 };               'exterior shield' = @{ s = 5; t = 4 }
  'external shield' = @{ s = 5; t = 4 };   'damage reduction' = @{ s = 5 };     'stealth' = @{ s = 5; m = 2 }
  'heal' = @{ s = 4; t = 3 };              'healing' = @{ s = 4 };              'repair' = @{ s = 3 }
  'spawn drop' = @{ s = 4; m = 3 };        'invulnerable' = @{ s = 8 };         'damage' = @{ o = 4 }
  'damage boost' = @{ o = 6 };             'weapon system' = @{ o = 5 };        'emp' = @{ c = 6 }
  'daze' = @{ c = 4 };                     'stasis' = @{ c = 5 };               'dash' = @{ m = 6; o = 1 }
  'jump' = @{ m = 6 };                     'speed boost' = @{ m = 4 }
}
$script:AxisW = @{ s = 0.35; o = 0.30; c = 0.20; m = 0.15; t = 0.10 }

function Get-Seconds([string]$t) {
  if (-not $t) { return $null }
  if ($t -match '(?i)infinite') { return [double]::PositiveInfinity }
  if ($t -match '(?i)^\s*(instant|none)') { return 0.0 }
  $m = [regex]::Match($t, '(\d+(?:[\.,]\d+)?)')
  if ($m.Success) { [double]($m.Groups[1].Value -replace ',', '.') } else { $null }
}

function Get-DurSeconds([string]$t) {
  if (-not $t) { return $null }
  if ($t -match '(?i)infinite') { return [double]::PositiveInfinity }
  if ($t -match '(?i)^\s*(instant|none)') { return 0.0 }
  $x = [regex]::Match($t, '(?i)(\d+(?:\.\d+)?)\s*seconds?\s*\(duration\)')
  if (-not $x.Success) { $x = [regex]::Match($t, '(?i)(\d+(?:\.\d+)?)\s*(?:s|sec|seconds?)\b(?!\s*back)') }
  if ($x.Success) { return [double]$x.Groups[1].Value }
  if ($t -match '^\s*(\d+(?:\.\d+)?)\s*$') { return [double]$Matches[1] }
  $null
}

$script:AbilityCur = @{}
try {
  $f = Join-Path $script:Here 'calc\ability-ratings.json'
  if (Test-Path $f) { foreach ($p in (Read-JsonFile $f).mechs.PSObject.Properties) { $script:AbilityCur[$p.Name] = $p.Value } }
} catch { Write-Log "ability-ratings.json: $_" }

function Get-AbilityTags($m) {
  $tags = @(@($m.abilityTags) | Where-Object { $_ })
  $txt = [string]$m.abilityText
  if ($txt -match '(?i)immaterial|cannot take damage|invulnerab|untargetable') { $tags += 'invulnerable' }
  if ($txt -match '(?i)\bteleport|\bwarp') { $tags += 'spawn drop' }
  if ($txt -match '(?i)\bfreez|\bstasis') { $tags += 'stasis' }
  @($tags | Select-Object -Unique)
}

function Get-AbilityRaw($m, [string]$name = '', $cdBase = $null) {
  $dur = Get-DurSeconds $m.abilityDuration; $cd = Get-Seconds $m.cooldown
  $up = $null
  if ($null -ne $dur -and $dur -gt 0 -and $null -ne $cd) { $up = if ([double]::IsInfinity($dur) -or $cd -le 0) { 1.0 } else { $dur / ($dur + $cd) } }
  $f = 1.0
  if ($null -ne $cdBase -and $cdBase -gt 0 -and $null -ne $cd -and $cd -gt 0) { $f = [math]::Max(0.85, [math]::Min(1.0, [math]::Pow($cdBase / $cd, 0.25))) }
  $cur = if ($name) { $script:AbilityCur[$name] } else { $null }
  if ($cur) {
    $a = @($cur.ax)
    $axv = @{ s = [double]$a[0]; o = [double]$a[1]; c = [double]$a[2]; m = [double]$a[3]; t = [double]$a[4] }
    $note = if ($script:Lang -eq 'it' -and $cur.it) { [string]$cur.it } else { [string]$cur.en }
    return @{ raw = [double]$cur.p * $f; p = [double]$cur.p; axes = $axv; uptime = $up; cd = $cd; dur = $dur; tags = @(Get-AbilityTags $m); est = $false; note = $note }
  }
  $tags = Get-AbilityTags $m
  if (-not $tags.Count) { return $null }
  $ax = @{ s = @(); o = @(); c = @(); m = @(); t = @() }
  foreach ($tg in $tags) { $v = $script:AbilityModel[$tg]; if ($v) { foreach ($k in $v.Keys) { $ax[$k] += [double]$v[$k] } } }
  $axv = @{}
  foreach ($k in $ax.Keys) {
    $l = @($ax[$k] | Sort-Object -Descending)
    $axv[$k] = [math]::Min(10.0, $(if ($l.Count) { $l[0] + 0.4 * $(if ($l.Count -gt 1) { $l[1] } else { 0 }) + 0.2 * $(if ($l.Count -gt 2) { $l[2] } else { 0 }) } else { 0 }))
  }
  $raw = 0.0; foreach ($k in $axv.Keys) { $raw += $axv[$k] * $script:AxisW[$k] }
  $tempo = if ($null -ne $up) { 0.9 + 0.2 * $up } else { 1.0 }
  $p = [math]::Max(20, [math]::Min(70, 15 + 9 * $raw * $tempo))
  @{ raw = $p * $f; p = $p; axes = $axv; uptime = $up; cd = $cd; dur = $dur; tags = $tags; est = $true; note = (T 'Stima dalle categorie del wiki: nessun profilo rivisto per questo mech.') }
}

$script:RankLabels = @('★1', '★2', '★3', '★4', '★5', '★6', 'Max')
function Get-RankRow($m, [string]$name) {
  if (-not $m -or -not $m.ranks) { return $null }
  foreach ($p in $m.ranks.PSObject.Properties) { if ($p.Name -ieq $name) { return @($p.Value) } }
  $null
}
function Get-StatAt($m, [string]$stat, [int]$idx) {
  $row = Get-RankRow $m $stat
  if ($row -and $row.Count -gt $idx -and $null -ne $row[$idx]) { return [double]$row[$idx] }
  if ($idx -eq 6) {
    switch ($stat) { 'HP' { if ($m.hp) { return [double]$m.hp } } 'Energy' { if ($m.energy) { return [double]$m.energy } } }
  }
  if ($stat -eq 'Speed' -and $m.speed) { return [double]$m.speed }
  $null
}
function Get-StatAtLevel($m, [string]$stat, [int]$star, [int]$lvl) {
  $i = [math]::Max(0, [math]::Min(5, $star - 1))
  $a = Get-StatAt $m $stat $i
  $b = Get-StatAt $m $stat $(if ($star -ge 6) { 6 } else { $i + 1 })
  if ($null -eq $a) { return $b }; if ($null -eq $b -or $lvl -le 1) { return $a }
  $a + ($b - $a) * ([math]::Min(7, $lvl) - 1) / 6.0
}
function Get-RankPctile([string]$stat, [int]$idx, [double]$v) {
  $vals = @(foreach ($m in $script:Mechs.Values) { $x = Get-StatAt $m $stat $idx; if ($null -ne $x) { $x } })
  if ($vals.Count -lt 2) { return $null }
  (@($vals | Where-Object { $_ -lt $v }).Count) / [double]($vals.Count - 1)
}

function Get-Ratings([int]$idx = 6) {
  if (-not $script:RatingCache) { $script:RatingCache = @{} }
  if ($script:RatingCache.ContainsKey($idx)) { return $script:RatingCache[$idx] }
  $abil = @{}
  foreach ($k in $script:Mechs.Keys) {
    $m = $script:Mechs[$k]
    $cdr = Get-StatAt $m 'Ability Cooldown' $idx
    $mm = if ($null -ne $cdr) { $c = $m.PSObject.Copy(); $c | Add-Member -NotePropertyName cooldown -NotePropertyValue "$cdr s" -Force; $c } else { $m }
    $a = Get-AbilityRaw $mm $k (Get-Seconds $m.cooldown); if ($a) { $abil[$k] = $a }
  }
  $vals = @($abil.Values | ForEach-Object { $_.raw })
  $res = @{}
  foreach ($k in $script:Mechs.Keys) {
    $m = $script:Mechs[$k]
    $hp = Get-StatAt $m 'HP' $idx; $en = Get-StatAt $m 'Energy' $idx; $sp = Get-StatAt $m 'Speed' $idx
    if ($null -eq $hp -or $null -eq $en -or $null -eq $sp -or -not $abil[$k]) { continue }
    $a = $abil[$k]
    $abP = (@($vals | Where-Object { $_ -lt $a.raw }).Count + 0.5 * (@($vals | Where-Object { $_ -eq $a.raw }).Count - 1)) / [math]::Max(1, $vals.Count - 1)
    $hpP = Get-RankPctile 'HP' $idx $hp; if ($null -eq $hpP) { continue }
    $spP = Get-Pctile 'speed' $sp
    $enF = [math]::Min(1.0, $en / 32.0)
    $w = switch ([string]$m.role) {
      'Tank'    { @{ hp = 0.32; ab = 0.48; sp = 0.04; en = 0.16 } }
      'Scout'   { @{ hp = 0.20; ab = 0.50; sp = 0.12; en = 0.18 } }
      'Support' { @{ hp = 0.24; ab = 0.52; sp = 0.08; en = 0.16 } }
      default   { @{ hp = 0.24; ab = 0.50; sp = 0.08; en = 0.18 } }
    }
    $abS = [math]::Max(0.0, [math]::Min(1.0, ($a.raw - 20) / 75.0))
    $score = 100 * ($w.hp * $hpP + $w.ab * $abS + $w.sp * $spP + $w.en * $enF)
    $v = [string]$m.viability; $adj = 0
    if ($v -match '(?i)early game only|no longer viable|not (?:be )?(?:viable|played)|should not be|useless|(?:out|over)[- ]?powered by|becomes? overpowered|bested by|replaced by') { $adj -= 6 }
    elseif ($v -match '(?i)(?:not|n''t|never)[^.]{0,40}end ?game|struggle') { $adj -= 4 }
    elseif ($v -match '(?i)end ?game|all (?:levels|stages)') { $adj += 6 }
    if ($v -match '(?i)dominant|one of the best|very strong|\bmeta\b') { $adj += 3 }
    $rf = @{ Common = 0.72; Uncommon = 0.8; Rare = 0.88; Epic = 0.95; Legendary = 1.0 }[[string]$m.rarity]; if (-not $rf) { $rf = 1.0 }
    $score = [math]::Max(0, [math]::Min(100, $score * $rf + $adj))
    $tier = if ($score -ge 78) { 'S' } elseif ($score -ge 64) { 'A' } elseif ($score -ge 50) { 'B' } elseif ($score -ge 36) { 'C' } else { 'D' }
    $res[$k] = @{ score = [math]::Round($score); tier = $tier; abP = $abP; ab = $a; adj = $adj; hp = $hp; hpP = $hpP; en = $en; sp = $sp; spP = $spP; idx = $idx }
  }
  $script:RatingCache[$idx] = $res
  $res
}
function Update-MechRatings {
  $script:RatingCache = @{}
  $script:Ratings = Get-Ratings 6
}

function Get-RatingAt([string]$k, [int]$star, [int]$lvl) {
  $idx = if ($star -ge 6 -and $lvl -ge 7) { 6 } elseif ($lvl -ge 4 -and $star -lt 6) { $star } else { $star - 1 }
  $idx = [math]::Max(0, [math]::Min(6, $idx))
  @{ r = (Get-Ratings $idx)[$k]; idx = $idx }
}

function Axis-Dots([double]$v) { $n = [int][math]::Min(5, [math]::Round($v / 2, [MidpointRounding]::AwayFromZero));('●' * $n) + ('○' * (5 - $n)) }
function Get-AbilityLine($r) {
  $names = @{ s = (T 'Sopravvivenza'); o = (T 'Danno'); c = (T 'Controllo'); m = (T 'Mobilità'); t = (T 'Squadra') }
  $parts = foreach ($k in 's', 'o', 'c', 'm', 't') { if ($r.ab.axes[$k] -gt 0) { "$($names[$k]) $(Axis-Dots $r.ab.axes[$k])" } }
  $tempo = if ($null -ne $r.ab.uptime) { T 'attiva il {0} del tempo' "$([math]::Round($r.ab.uptime * 100))%" } elseif ($r.ab.cd) { T 'ricarica {0} s' $r.ab.cd } else { '' }
  ((@($parts) + @($tempo)) | Where-Object { $_ }) -join '  ·  '
}

$script:WikiCache = Join-Path $script:AppDir 'wiki-mechs.json'
$script:WikiFetch = @'
param($out)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$api = 'https://mech-arena-robot-showdown.fandom.com/api.php'
$hdr = @{ 'User-Agent' = 'MechVault/1.0 (fan tool)' }
function Clean([string]$v) {
  $v = [regex]::Replace($v, '\[\[(?:File|Image):[^\]]*\]\]', '')
  $v = [regex]::Replace($v, '\[\[(?:[^\]|]*\|)?([^\]]*)\]\]', '$1')
  $v = [regex]::Replace($v, '<[^>]+>', ' ')
  ($v -replace "'''", '' -replace "''", '' -replace '\s+', ' ').Trim()
}
function Template([string]$t) {
  $i = $t.IndexOf('{{Mech Information'); if ($i -lt 0) { $i = $t.IndexOf('{{Mech_Information') }
  if ($i -lt 0) { return $null }
  $dep = 0; $j = $i
  while ($j -lt $t.Length) {
    if ($j + 1 -lt $t.Length -and $t.Substring($j, 2) -eq '{{') { $dep++; $j += 2; continue }
    if ($j + 1 -lt $t.Length -and $t.Substring($j, 2) -eq '}}') { $dep--; $j += 2; if ($dep -eq 0) { break }; continue }
    $j++
  }
  $body = $t.Substring($i + 2, $j - $i - 4)
  $body = [regex]::Replace($body, '(?i)\{\{\s*AcoinsIcon\s*\}\}', ' ACOINS')
  $body = [regex]::Replace($body, '(?i)\{\{\s*CreditsIcon\s*\}\}', ' CREDITS')
  do { $b0 = $body; $body = [regex]::Replace($body, '\{\{[^{}]*\}\}', '') } while ($body -ne $b0)
  $d = @{}
  foreach ($part in ($body -split '\|' | Select-Object -Skip 1)) {
    $q = $part.IndexOf('='); if ($q -lt 1) { continue }
    $d[$part.Substring(0, $q).Trim().TrimEnd(':').ToLower()] = Clean $part.Substring($q + 1)
  }
  $d
}
function RankTable([string]$t) {
  foreach ($tm in [regex]::Matches($t, '(?s)\{\|(.*?)\n\|\}')) {
    $rows = [ordered]@{}
    foreach ($r in ($tm.Groups[1].Value -split '\n\|-[^\n]*')) {
      $cells = @()
      foreach ($line in ($r -split '\n')) {
        $line = $line.Trim()
        if ($line.StartsWith('|+') -or $line.StartsWith('{|')) { continue }
        if ($line.StartsWith('!') -or $line.StartsWith('|')) {
          foreach ($c in ($line.Substring(1) -split '\|\||!!')) {
            $c = [regex]::Replace($c, '^\s*[^|]*?style="[^"]*"\s*\|', '')
            $cells += (Clean $c)
          }
        } elseif ($cells.Count -and $line) { $cells[$cells.Count - 1] += ' ' + (Clean $line) }
      }
      if ($cells.Count -ge 8) {
        $lab = $cells[0].Trim()
        $vals = @(for ($i = 1; $i -le 7; $i++) { $mm = [regex]::Match(($cells[$i] -replace '[,\s]', ''), '^-?\d+(?:\.\d+)?'); if ($mm.Success) { [double]$mm.Value } else { $null } })
        if ($lab -and $lab -notmatch '^(?i)rank' -and @($vals | Where-Object { $null -ne $_ }).Count -ge 6) { $rows[$lab] = $vals }
      }
    }
    if (@($rows.Keys | Where-Object { $_ -match '^(?i)hp' }).Count) { return $rows }
  }
  $null
}
$list = Invoke-RestMethod -Uri "$api`?action=query&list=categorymembers&cmtitle=Category:Mech&cmlimit=500&format=json" -Headers $hdr -TimeoutSec 20
$res = [ordered]@{}
foreach ($cm in $list.query.categorymembers) {
  if ($cm.ns -ne 0 -or $cm.title -in 'Crates', 'Test') { continue }
  try {
    $r = Invoke-RestMethod -Uri "$api`?action=parse&format=json&prop=wikitext|categories&redirects=1&page=$([uri]::EscapeDataString($cm.title))" -Headers $hdr -TimeoutSec 20
  } catch { continue }
  $t = [string]$r.parse.wikitext.'*'
  $cats = @($r.parse.categories | ForEach-Object { ([string]$_.'*') -replace '_', ' ' })
  $d = Template $t
  if (-not $d) { continue }
  $hp = ($d['maxhp'] -split '\(')[0] -replace '[^\d]', ''
  $sp = [regex]::Match([string]$d['speed'], '(\d+(?:\.\d+)?)')
  $en = [regex]::Match([string]$d['energy_capacity'], '(\d+)')
  $cls = if ($d['energy_capacity'] -match 'Heavy' -or ($en.Success -and [int]$en.Value -ge 32)) { 'Heavy' } elseif ($d['energy_capacity'] -match 'Medium' -or ($en.Success -and [int]$en.Value -ge 24)) { 'Medium' } elseif ($en.Success -or $d['energy_capacity'] -match 'Light') { 'Light' } else { '' }
  $role = ([string]$d['role'] -split ' ')[0]
  if (-not $role) { foreach ($c in 'Tank', 'Scout', 'Attacker', 'Support') { if ($cats -contains $c) { $role = $c } } }
  $rar = ([string]$d['rarity'] -split '[ /]')[-1]
  if (-not $rar) { foreach ($c in 'Legendary', 'Epic', 'Rare', 'Uncommon', 'Common') { if ($cats -contains $c) { $rar = $c } } }
  $energy = if ($en.Success) { [int]$en.Value } else { @{ Heavy = 32; Medium = 24; Light = 16 }[$cls] }
  $gh = $null; $pm = [regex]::Matches([string]$d['price'], '([\d][\d,\.]*)\s*(ACOINS|CREDITS)')
  if ($pm.Count) { $last = $pm[$pm.Count - 1]; $gh = [ordered]@{ amount = [int]($last.Groups[1].Value -replace '[^\d]', ''); currency = $(if ($last.Groups[2].Value -eq 'ACOINS') { 'acoins' } else { 'credits' }) } }
  elseif ([string]$d['price'] -match '^\s*\$') { $gh = [ordered]@{ amount = $null; currency = 'money' } }
  $via = ''; $vm = [regex]::Match($t, '(?s)==\s*Viability\s*==\s*(.+?)(?:\n==|\[\[Category|$)'); if ($vm.Success) { $via = (Clean $vm.Groups[1].Value); if ($via.Length -gt 280) { $via = $via.Substring(0, 280) } }
  $am = [regex]::Match($t, '(?s)==\s*Abilit(?:y|ies)\s*==(.+?)(?:\n==[^=]|$)'); if (-not $am.Success) { $am = [regex]::Match($t, '(?s)==\s*Mech Information\s*==(.+?)(?:\n==[^=]|$)') }
  $atext = if ($am.Success) { $x = Clean ([regex]::Replace($am.Groups[1].Value, '\{\{[^}]*\}\}', '')); if ($x.Length -gt 600) { $x.Substring(0, 600) } else { $x } } else { '' }
  $tags = @($cats | Where-Object { $_ -match '(?i)^abilit?r?y:' } | ForEach-Object { ($_ -replace '(?i)^abilit?r?y:\s*', '').Trim().ToLower() })
  $tags += @($cats | Where-Object { $_ -in 'Stealth', 'Healing', 'Heal', 'Repair', 'Speed boost', 'Damage boost', 'Personal shield', 'Exterior shield', 'Emp', 'Daze', 'Stasis', 'Dash' } | ForEach-Object { $_.ToLower() })
  $res[$cm.title] = [ordered]@{
    role = $role; rarity = $rar; class = $cls; energy = $energy
    hp = $(if ($hp -and [double]$hp -gt 10000) { [double]$hp } else { $null })
    speed = $(if ($sp.Success) { [double]$sp.Value } else { $null })
    ability = ([string]$d['ability'] -replace '\s*\d+px.*$', '').Trim(); cooldown = [string]$d['ability_cooldown']
    abilityDuration = [string]$d['ability_duration']; abilityDamage = [string]$d['ability_damage']
    traits = @(@($d['trait1'], $d['trait2']) | Where-Object { $_ }); viability = $via; gearHub = $gh
    abilityTags = @($tags | Select-Object -Unique); abilityText = $atext }
  $rk = RankTable $t
  if (-not $rk) {
    $g = $cm.title -replace '^M\.D\.$', 'M.D' -replace '^Dreadnought$', 'Dreadnaught' -replace '^Volti$', 'Voti'
    for ($try = 0; $try -lt 3 -and -not $rk; $try++) {
      try {
        $r2 = Invoke-RestMethod -Uri "https://mecharena.wiki.gg/api.php?action=parse&format=json&prop=wikitext&redirects=1&page=$([uri]::EscapeDataString('Mech:' + $g))" -Headers $hdr -TimeoutSec 20
        $rk = RankTable ([string]$r2.parse.wikitext.'*'); if ($rk) { $res[$cm.title].ranksSource = 'Mech Arena Wiki (wiki.gg, CC BY-SA 4.0)' }
        break
      } catch { if ("$_" -match '429') { Start-Sleep -Seconds 8 } else { break } }
    }
    Start-Sleep -Milliseconds 2500
  } else { $res[$cm.title].ranksSource = 'Mech Arena Wiki (Fandom)' }
  if ($rk) { $res[$cm.title].ranks = $rk }
  Start-Sleep -Milliseconds 120
}
if ($res.Count -lt 30) { throw "Wiki: solo $($res.Count) mech letti" }
$o = [ordered]@{ format = 'mechvault-mechs'; version = 1; source = 'Mech Arena: Robot Showdown Wiki (Fandom)'; license = 'CC BY-SA 3.0'; retrieved = (Get-Date).ToString('o'); mechs = $res }
[IO.File]::WriteAllText($out, ($o | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
$res.Count
'@

function Start-WikiUpdate([switch]$Force) {
  if ($script:WikiJob) { return }
  if (-not $Force -and (Test-Path $script:WikiCache) -and ((Get-Date) - (Get-Item $script:WikiCache).LastWriteTime).TotalDays -lt 3) { return }
  Write-Log 'Wiki: aggiornamento avviato'
  $ps = [powershell]::Create()
  [void]$ps.AddScript($script:WikiFetch).AddArgument($script:WikiCache)
  $script:WikiJob = @{ ps = $ps; h = $ps.BeginInvoke() }
  if ($script:ui.MsSource) { $script:ui.MsSource.Text = T 'Aggiornamento dal wiki in corso…' }
  $tm = New-Object System.Windows.Threading.DispatcherTimer
  $tm.Interval = [TimeSpan]::FromSeconds(1)
  $tm.Add_Tick({
    $j = $script:WikiJob
    if (-not $j -or -not $j.h.IsCompleted) { return }
    $this.Stop()
    try { [void]$j.ps.EndInvoke($j.h) } catch { Write-Log "Wiki: $_" }
    if ($j.ps.Streams.Error.Count) { Write-Log "Wiki: $($j.ps.Streams.Error[0])" }
    $j.ps.Dispose(); $script:WikiJob = $null; $script:WikiTimer = $null
    Write-Log "Wiki: aggiornamento finito ($(Test-Path $script:WikiCache))"
    Load-Mechs; Update-MechList; if ($script:MsCurrent) { Show-Mech $script:MsCurrent }; Update-Crate
  })
  $script:WikiTimer = $tm
  $tm.Start()
}

function Get-WikiSourceText {
  if (Test-Path $script:WikiCache) { T 'Dati dal Mech Arena Wiki, aggiornati il {0}.' ((Get-Item $script:WikiCache).LastWriteTime.ToString('d MMM yyyy HH:mm', $script:IT)) }
  else { T 'Dati inclusi nell''app (Mech Arena Wiki). Premi Aggiorna per scaricare la versione più recente.' }
}

$script:MechCustomFile = Join-Path $script:AppDir 'mech-miei.json'
function Load-Mechs {
  $script:Mechs = @{}
  $f = Join-Path $script:Here 'calc\mech-stats.json'
  if (Test-Path $f) {
    try { $j = Read-JsonFile $f; foreach ($p in $j.mechs.PSObject.Properties) { $script:Mechs[$p.Name] = $p.Value } } catch { Write-Log "Mech: $_" }
  }
  if (Test-Path $script:WikiCache) {
    try {
      $j = Read-JsonFile $script:WikiCache
      foreach ($p in $j.mechs.PSObject.Properties) {
        $base = $script:Mechs[$p.Name]
        if (-not $base) { $script:Mechs[$p.Name] = $p.Value; continue }
        foreach ($q in $p.Value.PSObject.Properties) {
          $v = $q.Value
          if ($null -eq $v -or ($v -is [string] -and -not $v) -or ($v -is [array] -and -not $v.Count)) { continue }
          if ($base.PSObject.Properties.Name -contains $q.Name) { $base.($q.Name) = $v } else { $base | Add-Member -NotePropertyName $q.Name -NotePropertyValue $v }
        }
      }
    } catch { Write-Log "Cache wiki: $_" }
  }
  $fx = Join-Path $script:Here 'calc\mech-fixes.json'
  if (Test-Path $fx) {
    try {
      foreach ($p in (Read-JsonFile $fx).mechs.PSObject.Properties) {
        $base = $script:Mechs[$p.Name]; if (-not $base) { continue }
        foreach ($q in $p.Value.PSObject.Properties) { if ($base.PSObject.Properties.Name -contains $q.Name) { $base.($q.Name) = $q.Value } else { $base | Add-Member -NotePropertyName $q.Name -NotePropertyValue $q.Value } }
      }
    } catch { Write-Log "Correzioni mech: $_" }
  }
  if (Test-Path $script:MechCustomFile) {
    try {
      $j = Read-JsonFile $script:MechCustomFile
      foreach ($p in $j.PSObject.Properties) {
        $base = $script:Mechs[$p.Name]; $v = $p.Value
        $m = [pscustomobject]@{ role = $v.role; rarity = $v.rarity; class = $v.class; energy = $v.energy; hp = $v.hp; speed = $v.speed
                                ability = $(if ($v.ability) { $v.ability } elseif ($base) { $base.ability } else { '' })
                                cooldown = $(if ($base) { $base.cooldown } else { '' }); traits = @(); viability = $(if ($base) { $base.viability } else { '' })
                                gearHub = $(if ($base) { $base.gearHub } else { $null }); custom = $true
                                abilityTags = $(if ($base) { $base.abilityTags } else { @() }); abilityDuration = $(if ($base) { $base.abilityDuration } else { '' })
                                abilityText = $(if ($base) { $base.abilityText } else { '' }) }
        $script:Mechs[$p.Name] = $m
      }
    } catch { Write-Log "Mech miei: $_" }
  }
  foreach ($m in $script:Mechs.Values) {
    foreach ($f in 'role', 'rarity', 'class', 'ability') {
      $v = $m.$f
      if ($v -is [string] -and $v -match '\[\[|\{\{|<') { $m.$f = (($v -replace '\[\[[^\]]*\]\]', '' -replace '\[\[.*$', '' -replace '\{\{.*$', '' -replace '<[^>]*>', '')).Trim() }
    }
  }
  Update-MechRatings
}
function Open-MechEdit([string]$k) {
  $ui = $script:ui; $ui.MsEdit.Visibility = 'Visible'; $ui.MeMsg.Text = ''
  $m = if ($k) { $script:Mechs[$k] } else { $null }
  $ui.MeName.Text = if ($k) { $k } else { $ui.MsSearch.Text.Trim() }
  $ui.MeHp.Text = if ($m -and $m.hp) { Fmt $m.hp } else { '' }
  $ui.MeSpeed.Text = if ($m -and $m.speed) { [string]$m.speed } else { '' }
  $ui.MeEnergy.Text = if ($m -and $m.energy) { [string]$m.energy } else { '' }
  $ui.MeAbility.Text = if ($m) { [string]$m.ability } else { '' }
  if ($m -and $m.role -and $ui["MeR_$($m.role)"]) { $ui["MeR_$($m.role)"].IsChecked = $true }
  if ($m -and $m.rarity -and $ui["MeQ_$($m.rarity)"]) { $ui["MeQ_$($m.rarity)"].IsChecked = $true }
}
function Save-MechEdit {
  $ui = $script:ui
  $name = $ui.MeName.Text.Trim()
  if (-not $name) { $ui.MeMsg.Text = T 'Scrivi il nome del mech.'; return }
  $hp = Parse-Amount $ui.MeHp.Text
  $sp = 0.0; [void][double]::TryParse(($ui.MeSpeed.Text.Trim() -replace ',', '.'), [Globalization.NumberStyles]::Float, $script:INV, [ref]$sp)
  $en = 0; [void][int]::TryParse($ui.MeEnergy.Text.Trim(), [ref]$en)
  if ($null -eq $hp -or $hp -lt 20000 -or $hp -gt 2000000) { $ui.MeMsg.Text = T 'HP non validi: scrivi gli HP massimi, per esempio 198.900.'; return }
  if ($sp -lt 5 -or $sp -gt 60) { $ui.MeMsg.Text = T 'Velocità non valida: di solito tra 14 e 30 km/h.'; return }
  if ($en -notin 16, 18, 20, 24, 32) { $ui.MeMsg.Text = T 'Energia non valida: 16, 24 o 32.'; return }
  $role = @('Attacker', 'Tank', 'Scout', 'Support' | Where-Object { $ui["MeR_$_"].IsChecked })[0]
  $rar = @('Common', 'Uncommon', 'Rare', 'Epic', 'Legendary' | Where-Object { $ui["MeQ_$_"].IsChecked })[0]
  $cls = if ($en -ge 32) { 'Heavy' } elseif ($en -ge 24) { 'Medium' } else { 'Light' }
  $all = [ordered]@{}
  if (Test-Path $script:MechCustomFile) { try { $j = Read-JsonFile $script:MechCustomFile; foreach ($p in $j.PSObject.Properties) { $all[$p.Name] = $p.Value } } catch {} }
  $key = Find-Mech $name; if (-not $key) { $key = $name }
  $all[$key] = [ordered]@{ role = $role; rarity = $rar; class = $cls; energy = $en; hp = [double]$hp; speed = $sp; ability = $ui.MeAbility.Text.Trim() }
  try { [IO.File]::WriteAllText($script:MechCustomFile, ($all | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false))) } catch { $ui.MeMsg.Text = "$_"; return }
  Load-Mechs; Update-MechList; Show-Mech $key
  $ui.MeMsg.Text = T 'Salvato: {0}.' $key
}
function Remove-MechEdit {
  $ui = $script:ui; $key = Find-Mech $ui.MeName.Text
  if (-not $key -or -not (Test-Path $script:MechCustomFile)) { return }
  $all = [ordered]@{}
  try { $j = Read-JsonFile $script:MechCustomFile; foreach ($p in $j.PSObject.Properties) { if ($p.Name -ne $key) { $all[$p.Name] = $p.Value } } } catch {}
  try { [IO.File]::WriteAllText($script:MechCustomFile, ($all | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false))) } catch {}
  Load-Mechs; Update-MechList
  if ($script:Mechs[$key]) { Show-Mech $key } else { $ui.MsDetail.Visibility = 'Collapsed' }
  $ui.MeMsg.Text = T 'Tolti i tuoi dati per {0}.' $key
}
function Find-Mech([string]$name) {
  if (-not $name) { return $null }
  $n = $name.Trim().ToLower() -replace '[^a-z\.]', ''
  foreach ($k in $script:Mechs.Keys) { if (($k.ToLower() -replace '[^a-z\.]', '') -eq $n) { return $k } }
  foreach ($k in $script:Mechs.Keys) { $kk = $k.ToLower() -replace '[^a-z\.]', ''; if ($kk.Length -ge 4 -and $n.StartsWith($kk)) { return $k } }
  $null
}
function Get-Pctile([string]$prop, [double]$v) {
  $vals = @($script:Mechs.Values | Where-Object { $_.$prop } | ForEach-Object { [double]$_.$prop })
  if (-not $vals.Count) { return 0 }
  (@($vals | Where-Object { $_ -lt $v }).Count) / [double]$vals.Count
}
function Get-MechProfile([string]$k) {
  $m = $script:Mechs[$k]; if (-not $m) { return $null }
  $hpP = if ($m.hp) { Get-Pctile 'hp' $m.hp } else { $null }
  $spP = if ($m.speed) { Get-Pctile 'speed' $m.speed } else { $null }
  $tank = if ($null -eq $hpP) { T 'resistenza sconosciuta' } elseif ($hpP -ge 0.75) { T 'molto resistente' } elseif ($hpP -ge 0.5) { T 'resistente' } elseif ($hpP -ge 0.25) { T 'resistenza media' } else { T 'fragile' }
  $fast = if ($null -eq $spP) { '' } elseif ($spP -ge 0.75) { T 'molto veloce' } elseif ($spP -ge 0.4) { T 'velocità media' } else { T 'lento' }
  $en = if ($m.energy -ge 32) { T 'armi pesanti (32 energia)' } elseif ($m.energy -ge 24) { T 'armi medie (24 energia)' } elseif ($m.energy) { T 'armi leggere (16 energia)' } else { '' }
  @{ m = $m; hpP = $hpP; spP = $spP; summary = (@($tank, $fast, $en) | Where-Object { $_ }) -join ' · ' }
}
function Show-Mech([string]$k) {
  $ui = $script:ui; $script:MsCurrent = $k; $pr = Get-MechProfile $k
  if (-not $pr) { $ui.MsDetail.Visibility = 'Collapsed'; return }
  $m = $pr.m
  if ($ui.MsEdit.Visibility -eq 'Visible') { Open-MechEdit $k }
  $ui.MsDetail.Visibility = 'Visible'
  $ui.MsName.Text = $k
  $ui.MsTag.Text = "$(WW $m.role) · $(WW $m.rarity) · $(WW $m.class)"
  $ui.MsVerdict.Text = if ($m.hp) { $pr.summary } else { T 'Dati incompleti: premi «+ Aggiungi o correggi» e scrivili come li vedi nel gioco.' }
  if ($m.custom) { $ui.MsTag.Text += ' · ' + (T 'dati tuoi') }
  $ui.MsBars.Children.Clear()
  if ($null -eq $script:MsRank) { $script:MsRank = 6 }
  $idx = [int]$script:MsRank
  $r = (Get-Ratings $idx)[$k]
  Build-RankPills
  Build-RankTable $k $idx
  if ($r) {
    $ui.MsTierBox.Visibility = 'Visible'; $ui.MsTier.Text = $r.tier; $ui.MsScore.Text = "$($r.score)/100"
    $col = @{ S = '#FFD60A'; A = '#30D158'; B = '#64D2FF'; C = '#FF9F0A'; D = '#FF453A' }[$r.tier]
    $ui.MsTier.Foreground = $col; $ui.MsTierBox.BorderBrush = $col
    $ui.MsAbilityAxes.Text = (T 'Abilità') + ':  ' + (Get-AbilityLine $r) + $(if ($r.ab.note) { "`n" + $r.ab.note } else { '' })
  } else { $ui.MsTierBox.Visibility = 'Collapsed'; $ui.MsAbilityAxes.Text = '' }
  $bars = @(
    @{ l = (T 'Abilità'); v = $(if ($r) { [string]$m.ability } else { '—' }); f = $(if ($r) { $r.abP } else { $null }); c = '#FFD60A' },
    @{ l = (T 'HP'); v = $(if ($r) { Fmt $r.hp } elseif ($m.hp -and $idx -eq 6) { Fmt $m.hp } else { '—' }); f = $(if ($r) { $r.hpP } else { $null }); c = '#30D158' },
    @{ l = (T 'Velocità'); v = $(if ($m.speed) { "$($m.speed) km/h" } else { '—' }); f = $(if ($r) { $r.spP } else { $pr.spP }); c = '#64D2FF' },
    @{ l = (T 'Energia per le armi'); v = $(if ($r) { [string]$r.en } elseif ($m.energy) { [string]$m.energy } else { '—' }); f = $(if ($r) { $r.en / 32.0 } elseif ($m.energy) { $m.energy / 32.0 } else { $null }); c = '#DA8FFF' })
  foreach ($b in $bars) {
    $x = @"
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,8">
  <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/><ColumnDefinition Width="240"/></Grid.ColumnDefinitions>
  <TextBlock Name="L" Foreground="#B8FFFFFF" VerticalAlignment="Center"/>
  <Border Grid.Column="1" Height="8" CornerRadius="4" Background="#1AFFFFFF" VerticalAlignment="Center">
    <Border Name="F" HorizontalAlignment="Left" CornerRadius="4"/>
  </Border>
  <TextBlock Name="V" Grid.Column="2" Foreground="#F5F5F7" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="12,0,0,0"/>
</Grid>
"@
    $el = [Windows.Markup.XamlReader]::Parse($x)
    $el.FindName('L').Text = $b.l
    $txt = $b.v
    if ($null -ne $b.f -and $b.l -ne (T 'Energia per le armi')) { $txt += '  ·  ' + (T 'meglio del {0}' ("$([math]::Round([double]$b.f * 100))%")) }
    $el.FindName('V').Text = $txt
    $fb = $el.FindName('F'); $fb.Background = $b.c
    $frac = if ($null -ne $b.f) { [math]::Max(0.03, [math]::Min(1.0, [double]$b.f)) } else { 0 }
    $el.Add_SizeChanged({ param($s, $e) $s.FindName('F').Width = [math]::Max(0, ($s.ColumnDefinitions[1].ActualWidth) * [double]$s.Tag) })
    $el.Tag = $frac
    [void]$ui.MsBars.Children.Add($el)
  }
  $cd = if ($m.cooldown) { ' · ' + (T 'ricarica {0}' $m.cooldown) } else { '' }
  $ui.MsAbility.Text = (T 'Abilità: {0}' $m.ability) + $cd + $(if (@($m.traits).Count) { ' · ' + (@($m.traits) -join ', ') } else { '' })
  $gh = $m.gearHub
  $ghTxt = if ($gh -and $gh.amount) { T 'Gear Hub: {0} {1}' (Fmt $gh.amount) (CurName $gh.currency) } elseif ($gh -and $gh.currency -eq 'money') { T 'Gear Hub: solo a pagamento' } else { '' }
  if ($ghTxt) { $ui.MsAbility.Text += "`n" + $ghTxt }
  $ui.MsAbilityText.Text = if ($m.abilityText) { $m.abilityText } else { '' }
  $ui.MsWiki.Text = if ($m.viability) { (T 'Dal wiki: ') + '“' + $m.viability + '”' } else { '' }
}
function Build-RankPills {
  $ui = $script:ui
  if ($ui.MsRankPills.Children.Count -eq 7) { for ($i = 0; $i -lt 7; $i++) { $ui.MsRankPills.Children[$i].IsChecked = ($i -eq $script:MsRank) }; return }
  $ui.MsRankPills.Children.Clear()
  for ($i = 0; $i -lt 7; $i++) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Content = $script:RankLabels[$i]; $rb.Tag = $i; $rb.GroupName = 'msrank'
    $rb.Style = $script:app.Resources['Pill']; $rb.IsChecked = ($i -eq $script:MsRank)
    $rb.Add_Click({ $script:MsRank = [int]$this.Tag; if ($script:MsCurrent) { Show-Mech $script:MsCurrent } })
    [void]$ui.MsRankPills.Children.Add($rb)
  }
}
function Build-RankTable([string]$k, [int]$sel) {
  $ui = $script:ui; $g = $ui.MsRankTable; $m = $script:Mechs[$k]
  $g.Children.Clear(); $g.RowDefinitions.Clear(); $g.ColumnDefinitions.Clear()
  if (-not $m.ranks) {
    $ui.MsRankNote.Text = T 'Per questo mech le fonti non pubblicano ancora le statistiche per rango.'
    return
  }
  $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = '1.6*'; $g.ColumnDefinitions.Add($cd)
  for ($i = 0; $i -lt 7; $i++) { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = '*'; $g.ColumnDefinitions.Add($c) }
  $rows = @($m.ranks.PSObject.Properties)
  for ($r = 0; $r -le $rows.Count; $r++) { $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = 'Auto'; $g.RowDefinitions.Add($rd) }
  $hl = New-Object System.Windows.Controls.Border
  $hl.Background = '#14FFFFFF'; $hl.CornerRadius = 8; [System.Windows.Controls.Grid]::SetColumn($hl, $sel + 1); [System.Windows.Controls.Grid]::SetRowSpan($hl, $rows.Count + 1)
  [void]$g.Children.Add($hl)
  function Cell($text, $row, $col, $fg, $bold) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.Foreground = $fg; $t.Margin = '6,3,6,3'; $t.FontSize = 12
    if ($bold) { $t.FontWeight = 'SemiBold' }
    if ($col -gt 0) { $t.HorizontalAlignment = 'Right' }
    [System.Windows.Controls.Grid]::SetRow($t, $row); [System.Windows.Controls.Grid]::SetColumn($t, $col)
    [void]$g.Children.Add($t)
  }
  for ($i = 0; $i -lt 7; $i++) { Cell $script:RankLabels[$i] 0 ($i + 1) '#7AFFFFFF' ($i -eq $sel) }
  $r = 1
  foreach ($p in $rows) {
    Cell (WW $p.Name) $r 0 '#B8FFFFFF' $false
    $vals = @($p.Value)
    for ($i = 0; $i -lt 7; $i++) {
      $v = if ($i -lt $vals.Count -and $null -ne $vals[$i]) { $d = [double]$vals[$i]; if ($d -ge 1000) { Short $d } else { $d.ToString('0.##', $script:IT) } } else { '—' }
      Cell $v $r ($i + 1) $(if ($i -eq $sel) { '#F5F5F7' } else { '#B8FFFFFF' }) ($i -eq $sel)
    }
    $r++
  }
  $note = T 'Fonte: {0}. ★N = rango N livello 1, Max = ★6 livello 7.' $(if ($m.ranksSource) { $m.ranksSource } else { 'Mech Arena Wiki' })
  $hpRow = Get-RankRow $m 'HP'
  if ($hpRow -and $m.hp -and $hpRow[6] -and [math]::Abs($hpRow[6] - $m.hp) / $m.hp -gt 0.02) { $note += ' ' + (T 'Attenzione: le fonti non concordano sugli HP massimi ({0} contro {1}).' (Fmt $m.hp) (Fmt $hpRow[6])) }
  $ui.MsRankNote.Text = $note
}

function Update-MechList {
  $ui = $script:ui; $q = $ui.MsSearch.Text.Trim().ToLower()
  $ui.MsList.Children.Clear()
  $keys = @($script:Mechs.Keys | Sort-Object | Where-Object { -not $q -or $_.ToLower().Contains($q) })
  $ui.MsCount.Text = T '{0} mech nel database · {1} mostrati' $script:Mechs.Count $keys.Count
  if (-not $script:WikiJob) { $ui.MsSource.Text = Get-WikiSourceText }
  foreach ($k in $keys) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $k; $b.Tag = $k; $b.Margin = '0,0,6,6'; $b.Padding = '12,6'; $b.FontSize = 12
    $b.Add_Click({ Show-Mech ([string]$this.Tag) })
    if ($script:Mechs[$k].custom) { $b.BorderBrush = '#8CF0A8' }
    if (-not $script:Mechs[$k].hp) { $b.Opacity = 0.6; $b.ToolTip = T 'Dati incompleti: aggiungili tu' }
    elseif ($script:Ratings[$k]) { $b.Content = "$k  ·  $($script:Ratings[$k].tier)" }
    [void]$ui.MsList.Children.Add($b)
  }
  if ($keys.Count -eq 1) { Show-Mech $keys[0] }
}

function Render-Settings {
  $ui = $script:ui; $d = $script:Data
  $ui.RateCred.Text = Fmt $d.rateCredits; $ui.RateAc.Text = Fmt $d.rateAcoins
  $ui.RateAutoCred.Text = Format-AutoRate 'credits'; $ui.RateAutoAc.Text = Format-AutoRate 'acoins'
  $ui.MisCred.Text  = Fmt $d.missionCredits; $ui.MisAc.Text = Fmt $d.missionAcoins
  $ui.ProcPat.Text  = $d.processPattern
  $ui.ChkAuto.IsChecked      = [bool]$d.autoRead
  $ui.ChkAutostart.IsChecked = [bool]$d.autostart
  $ui.ChkBanner.IsChecked    = [bool]$d.showBanner
  $accs = @(Get-Accounts)
  $ui.AccInfo.Text = T "Attivo: {0}  ·  Account salvati: {1}`nQuando apri Mech Arena ti chiedo sempre con quale giochi." (Get-AccountName) (($accs | ForEach-Object { $_.name }) -join ', ')
}

function Update-Status {
  $ui = $script:ui
  $ui.AccName.Text = Get-AccountName
  if ($script:GameRunning) {
    $ui.GameTxt.Text = T 'Mech Arena aperto'
    $ui.StatusDot.Fill = '#FFD60A'; $ui.StatusGlow.Fill = '#4DFFD60A'; $ui.StatusTitle.Text = T 'Sorveglianza attiva'
  } else {
    $ui.GameTxt.Text = T 'Mech Arena chiuso'
    $ui.StatusDot.Fill = '#30D158'; $ui.StatusGlow.Fill = '#4D30D158'; $ui.StatusTitle.Text = T 'Blocco attivo'
  }
  $ui.ReadTxt.Text = if (-not $script:Data.autoRead) { T 'lettura automatica spenta' }
    elseif (-not $script:OcrReady) { T 'OCR non disponibile' }
    elseif ($script:Data.lastReadAt) { T 'ultima lettura {0}' (Ago $script:Data.lastReadAt) }
    else { T 'in attesa del gioco' }
  if ($script:Banner) { Update-Banner }
}

function Refresh-UI {
  try {
    Render-Home
    Render-Goals
    Render-Activity
    Render-Settings
    Render-Tools
    Update-Status
  } catch { Write-Log "Refresh: $_ $($_.InvocationInfo.PositionMessage)" }
  if ($script:Tray) {
    $first = @(Get-GoalStats) | Select-Object -First 1
    $tip = T 'MechVault · {0} · {1} gg puliti' (Get-AccountName) (Get-Streak)
    if ($first) { $tip += " · $([math]::Floor($first.pct * 100))%" }
    $script:Tray.Text = $tip.Substring(0, [math]::Min(63, $tip.Length))
  }
}

function Show-Page([string]$name) {
  foreach ($p in 'PageHome', 'PageGoals', 'PageActivity', 'PageTools', 'PageSettings') {
    $script:ui[$p].Visibility = if ($p -eq $name) { 'Visible' } else { 'Collapsed' }
  }
  $map = @{ PageHome = 'NavHome'; PageGoals = 'NavGoals'; PageActivity = 'NavActivity'; PageTools = 'NavTools'; PageSettings = 'NavSettings' }
  $script:ui[$map[$name]].IsChecked = $true
  if ($name -eq 'PageHome') {
    [void]$script:win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{ Draw-Spark $script:ui.SparkCred; Draw-Spark $script:ui.SparkAc })
  }
}

function Show-Violation([string]$cur, [double]$lost, [double]$covered, [string]$src) {
  $script:InDialog = $true
  try {
    $streak = Get-Streak
    $rate = (Get-Rate $cur).v
    $w = Parse-Xaml $script:XamlViol
    Enable-Glass $w
    $w.FindName('Amt').Text = "−$(Fmt $lost) $(CurName $cur)"
    if ($src -eq 'auto') { $w.FindName('Head').Text = T 'Spesa rilevata dal gioco' }
    $body = ''
    if ($covered -gt 0) { $body += T 'Il budget missioni di oggi ha coperto {0} {1}; questo è il resto. ' (Fmt $covered) (CurName $cur) }
    $body += if ($streak -gt 0) { T 'Avevi {0} giorni puliti: la serie riparte da zero.' $streak } else { T 'La serie riparte da zero.' }
    if ($rate -gt 0) { $body += T ' Hai bruciato circa {0} giorni di grind.' (([math]::Round($lost / $rate, 1)).ToString('0.#', $script:IT)) }
    $body += "`n" + (T 'Se era per una missione giornaliera premi «Era una missione»: non rompe la serie.')
    $w.FindName('Body').Text = $body
    $script:VDlg = $w; $script:VResult = $null
    $w.FindName('Why').Add_TextChanged({ $script:VDlg.FindName('Ok').IsEnabled = ($script:VDlg.FindName('Why').Text.Trim().Length -ge 15) })
    $w.FindName('Ok').Add_Click({ $script:VResult = 'confess'; $script:VDlg.Close() })
    $w.FindName('Mission').Add_Click({ $script:VResult = 'mission'; $script:VDlg.Close() })
    $w.FindName('Typo').Add_Click({ $script:VResult = 'typo'; $script:VDlg.Close() })
    $w.Add_Closing({ if (-not $script:VResult) { $_.Cancel = $true } })
    $w.Add_ContentRendered({ [void]$script:VDlg.FindName('Why').Focus() })
    [void]$w.ShowDialog()
    @{ kind = $script:VResult; reason = $w.FindName('Why').Text.Trim(); streak = $streak }
  } finally { $script:InDialog = $false }
}

function Find-BogusGain([string]$cur, [double]$old, [double]$v) {
  $evs = @($script:Data.events)
  $since = (Get-Date).AddHours(-24)
  $later = 0.0
  for ($i = $evs.Count - 1; $i -ge 0 -and $i -ge $evs.Count - 60; $i--) {
    $e = $evs[$i]
    if ($e.cur -ne $cur) { continue }
    if ([datetime]$e.t -lt $since) { break }
    if ($e.kind -eq 'gain' -and [double]$e.delta -ge 50) {
      $truth = $old - [double]$e.delta
      if ([math]::Abs($truth - $v) -le [math]::Max(5.0, 0.03 * [double]$e.delta)) { return $e }
    }
    $later += [double]$e.delta
  }
  $null
}
function Remove-BogusGain($e, [string]$cur, [double]$v) {
  $d = $script:Data
  $after = $false; $keep = @()
  foreach ($x in @($d.events)) {
    if ([object]::ReferenceEquals($x, $e)) { $after = $true; continue }
    if ($after -and $x.cur -eq $cur) { $x.bal = [double]$x.bal - [double]$e.delta }
    $keep += $x
  }
  $d.events = $keep
  $d.$cur = $v
  Write-Log "Lettura sbagliata annullata: $cur +$($e.delta) del $($e.t), saldo $v"
  Save-Data; Refresh-UI
}

function Commit-Balance([string]$cur, [double]$v, [string]$src) {
  $d = $script:Data
  $ip = InitProp $cur
  $old = [double]$d.$cur
  if (-not $d.$ip) {
    $d.$cur = $v; $d.$ip = $true
    Add-Event $cur 0 $v 'init' '' $src
    Save-Data; Refresh-UI
    if ($script:Tray) { $script:Tray.ShowBalloonTip(4000, (T 'Saldo letto'), (T '{0}: {1} {2}. Da qui parte il conteggio.' (Get-AccountName) (Fmt $v) (CurName $cur)), 'Info') }
    return
  }
  $delta = $v - $old
  if ($delta -eq 0) { return }
  if ($delta -gt 0) {
    $d.$cur = $v
    Add-Event $cur $delta $v 'gain' '' $src
    Save-Data; Refresh-UI
    return
  }
  $lost = -$delta
  $bogus = Find-BogusGain $cur $old $v
  if ($bogus) { Remove-BogusGain $bogus $cur $v; return }
  $auth = $d.purchase
  if ($auth -and $auth.currency -eq $cur -and [datetime]$auth.until -gt (Get-Date) -and
      $lost -ge [double]$auth.amount * 0.5 -and $lost -le [double]$auth.amount * 1.03 + 10) {
    $g = @($d.goals | Where-Object { $_.id -eq $auth.goalId })[0]
    $d.$cur = $v
    Add-Event $cur $delta $v 'purchase' $(if ($g) { $g.name } else { '' }) $src
    if ($g) { $g.done = $true; $g.doneAt = Now-Iso }
    $d.purchase = $null
    Save-Data; Refresh-UI
    if ($script:Tray) { $script:Tray.ShowBalloonTip(6000, (T 'Obiettivo completato!'), (T '{0}: te lo sei guadagnato.' $(if ($g) { $g.name } else { T 'Acquisto' })), 'Info') }
    return
  }
  $mb = Get-MissionBudget $cur
  if ($lost -le $mb.left) {
    $d.$cur = $v
    Add-Event $cur $delta $v 'mission' 'budget missioni' $src
    Save-Data; Refresh-UI
    return
  }
  $covered = $mb.left
  $excess = $lost - $covered
  $res = Show-Violation $cur $excess $covered $src
  if ($res.kind -eq 'typo') {
    if ($src -eq 'auto') { $script:Ignore[$cur] = $v }
    return
  }
  if ($covered -gt 0) { Add-Event $cur (-$covered) ($old - $covered) 'mission' 'budget missioni' $src }
  $d.$cur = $v
  if ($res.kind -eq 'mission') {
    Add-Event $cur (-$excess) $v 'mission' 'segnata come missione' $src
    Save-Data; Refresh-UI
    return
  }
  Add-Event $cur (-$excess) $v 'spend' $res.reason $src
  $d.violations = @(@($d.violations) + [pscustomobject]@{
    t = (Now-Iso); currency = $cur; amount = $excess; reason = $res.reason; streakLost = $res.streak; prevClean = $d.cleanSince })
  $d.bestStreak = [math]::Max([int]$d.bestStreak, [int]$res.streak)
  $d.cleanSince = Now-Iso
  Save-Data; Refresh-UI
}

function Undo-Violation([string]$t) {
  $d = $script:Data
  $viol = @($d.violations | Where-Object { [string]$_.t -eq $t })[0]
  if (-not $viol) { return }
  $r = (Show-Msg (T "Segnare −{0} {1} come spesa per una missione?`nLa serie torna com'era prima." (Fmt $viol.amount) (CurName $viol.currency)) -YesNo)
  if ("$r" -ne 'Yes') { return }
  $vt = [datetime]$viol.t
  $d.violations = @($d.violations | Where-Object { [string]$_.t -ne $t })
  foreach ($e in @($d.events)) {
    if ($e.kind -eq 'spend' -and $e.cur -eq $viol.currency -and [math]::Abs(([datetime]$e.t - $vt).TotalSeconds) -lt 120 -and [math]::Abs([double]$e.delta + [double]$viol.amount) -lt 1) {
      $e.kind = 'mission'; $e.note = 'segnata come missione'
    }
  }
  $lastV = @($d.violations | Sort-Object { [datetime]$_.t } | Select-Object -Last 1)[0]
  $d.cleanSince = if ($lastV) { $lastV.t }
    elseif ($viol.prevClean) { $viol.prevClean }
    elseif (@($d.events).Count) { @($d.events)[0].t }
    else { $d.createdAt }
  Save-Data; Refresh-UI
}

function Process-Read([string]$cur, [double]$v) {
  $d = $script:Data
  if ($v -lt 0 -or $v -gt $(if ($cur -eq 'credits') { 500000000 } else { 5000000 })) { return }
  if ($null -ne $script:Ignore[$cur]) {
    if ($script:Ignore[$cur] -eq $v) { return }
    $script:Ignore[$cur] = $null
  }
  if ($d.(InitProp $cur) -and $v -eq [double]$d.$cur) { $script:Pend[$cur] = $null; return }
  $p = $script:Pend[$cur]
  if ($p -and $p.v -eq $v) { $p.n++ } else { $p = @{ v = $v; n = 1 }; $script:Pend[$cur] = $p }
  $need = if ($d.(InitProp $cur) -and $v -lt [double]$d.$cur) { 3 } else { 2 }
  if ($d.(InitProp $cur) -and ($v - [double]$d.$cur) -gt [math]::Max(3 * [double]$d.$cur, $(if ($cur -eq 'credits') { 100000 } else { 1000 }))) { $need = 6 }
  if ($p.n -ge $need) { $script:Pend[$cur] = $null; Commit-Balance $cur $v 'auto' }
}

function Submit-Manual([string]$cur) {
  $tb = if ($cur -eq 'credits') { $script:ui.CredIn } else { $script:ui.AcIn }
  $v = Parse-Amount $tb.Text
  if ($null -eq $v) { [void](Show-Msg (T 'Numero non valido. Esempi: 512000 · 512k · 1,2M')); return }
  $tb.Text = ''
  $script:PendingCheck = $false
  Commit-Balance $cur ([double]$v) 'manuale'
}

function Authorize-Purchase([string]$id) {
  $g = @($script:Data.goals | Where-Object { $_.id -eq $id })[0]
  if (-not $g) { return }
  $msg = T "Obiettivo raggiunto: {0}`n`nAutorizzo UNA spesa di circa {1} {2} per le prossime 6 ore.`nCompralo in gioco: riconosco l'acquisto da solo e segno l'obiettivo come completato.`n`nQualsiasi altra spesa resta vietata. Procedo?" $g.name (Fmt $g.cost) (CurName $g.currency)
  $r = (Show-Msg $msg -YesNo)
  if ("$r" -ne 'Yes') { return }
  $script:Data.purchase = [pscustomobject]@{ goalId = $g.id; currency = $g.currency; amount = [double]$g.cost; until = (Get-Date).AddHours(6).ToString('o') }
  Save-Data; Refresh-UI
}

function Cancel-Purchase { $script:Data.purchase = $null; Save-Data; Refresh-UI }

function Move-Goal([string]$id, [int]$dir) {
  $list = New-Object System.Collections.ArrayList
  foreach ($g in @($script:Data.goals)) { [void]$list.Add($g) }
  $i = -1
  for ($k = 0; $k -lt $list.Count; $k++) { if ($list[$k].id -eq $id) { $i = $k; break } }
  $j = $i + $dir
  if ($i -lt 0 -or $j -lt 0 -or $j -ge $list.Count) { return }
  $tmp = $list[$i]; $list[$i] = $list[$j]; $list[$j] = $tmp
  $script:Data.goals = @($list.ToArray())
  Save-Data; Refresh-UI
}

function Remove-Goal([string]$id) {
  $g = @($script:Data.goals | Where-Object { $_.id -eq $id })[0]
  if (-not $g) { return }
  $r = (Show-Msg (T "Eliminare l'obiettivo «{0}»?" $g.name) -YesNo)
  if ("$r" -ne 'Yes') { return }
  $script:Data.goals = @($script:Data.goals | Where-Object { $_.id -ne $id })
  if ($script:Data.purchase -and $script:Data.purchase.goalId -eq $id) { $script:Data.purchase = $null }
  Save-Data; Refresh-UI
}

function Add-GoalFromForm {
  $name = $script:ui.GoalName.Text.Trim()
  $cost = Parse-Amount $script:ui.GoalCost.Text
  if (-not $name) { [void](Show-Msg (T "Scrivi il nome dell'obiettivo.")); return }
  if ($null -eq $cost -or $cost -le 0) { [void](Show-Msg (T 'Costo non valido. Esempi: 827k · 932000 · 1,2M')); return }
  $cur = if ($script:ui.RbAc.IsChecked) { 'acoins' } else { 'credits' }
  $script:Data.goals = @(@($script:Data.goals) + (New-Goal $name $cur $cost))
  $script:ui.GoalName.Text = ''; $script:ui.GoalCost.Text = ''
  Save-Data; Refresh-UI
}

function Save-Rates {
  $rc = Parse-Amount $script:ui.RateCred.Text; $ra = Parse-Amount $script:ui.RateAc.Text
  if (($rc -and $rc -gt 2000000) -or ($ra -and $ra -gt 50000)) {
    [void](Show-Msg (T 'Ritmo troppo alto: massimo 2.000.000 crediti e 50.000 A-coin al giorno. Lascia 0 per il calcolo automatico.')); Render-Settings; return
  }
  $script:Data.rateCredits = if ($null -eq $rc) { 0.0 } else { [double]$rc }
  $script:Data.rateAcoins  = if ($null -eq $ra) { 0.0 } else { [double]$ra }
  Save-Data; Refresh-UI
}

function Save-Missions {
  $mc = Parse-Amount $script:ui.MisCred.Text; $ma = Parse-Amount $script:ui.MisAc.Text
  $script:Data.missionCredits = if ($null -eq $mc) { 0.0 } else { [double]$mc }
  $script:Data.missionAcoins  = if ($null -eq $ma) { 0.0 } else { [double]$ma }
  Save-Data; Refresh-UI
}

function Save-ProcPattern {
  $t = $script:ui.ProcPat.Text.Trim()
  if (-not $t) { return }
  try { [void][regex]::new($t) } catch { [void](Show-Msg (T 'Espressione non valida.')); return }
  $script:Data.processPattern = $t
  Save-Data; Refresh-UI
}

function Test-ReadNow {
  $lbl = $script:ui.TestReadTxt
  if (-not $script:OcrReady) { $lbl.Text = T 'OCR di Windows non disponibile su questo PC.'; $lbl.Foreground = '#FF8A80'; return }
  $p = Get-GameProcess
  if (-not $p) { $lbl.Text = T 'Mech Arena non è aperto.'; $lbl.Foreground = '#FFE98A'; return }
  $r = Read-GameBalances $p
  if ($r.Count -eq 0) { $lbl.Text = T "Barra delle valute non visibile: vai nell'hangar (non in battaglia) e riprova."; $lbl.Foreground = '#FFE98A'; return }
  $parts = @()
  if ($r.ContainsKey('credits')) { $parts += "$(T 'crediti') $(Fmt $r.credits)" }
  if ($r.ContainsKey('acoins'))  { $parts += "A-coin $(Fmt $r.acoins)" }
  $lbl.Text = (T 'Letto: ') + ($parts -join ' · '); $lbl.Foreground = '#8CF0A8'
}

function Show-AccountPicker([bool]$fromGame) {
  if ($script:InDialog) { return }
  $script:InDialog = $true
  $script:AccPicked = $null
  try {
    $w = Parse-Xaml $script:XamlAcc
    Enable-Glass $w
    $script:AccDlg = $w
    if (-not $fromGame) { $w.FindName('Head').Text = T 'Cambia account' }
    $list = $w.FindName('List')
    foreach ($a in @(Get-Accounts)) {
      $b = New-Object System.Windows.Controls.Button
      $b.Tag = $a.id; $b.Margin = '0,0,0,10'; $b.Padding = '18,13'; $b.FontSize = 15
      $b.Content = if ($a.id -eq $script:ActiveId) { T '{0}   ·   ultimo usato' $a.name } else { $a.name }
      if ($a.id -eq $script:ActiveId) { $b.Style = $script:app.Resources['Primary'] }
      $b.Add_Click({ $script:AccPicked = [string]$this.Tag; $script:AccDlg.Close() })
      [void]$list.Children.Add($b)
    }
    $w.FindName('Create').Add_Click({ $n = $script:AccDlg.FindName('NewName').Text.Trim(); if ($n) { $script:AccPicked = "new:$n"; $script:AccDlg.Close() } })
    $w.FindName('NewName').Add_KeyDown({ if ($_.Key -eq 'Return') { $n = $script:AccDlg.FindName('NewName').Text.Trim(); if ($n) { $script:AccPicked = "new:$n"; $script:AccDlg.Close() } } })
    $w.Add_Closing({ if (-not $script:AccPicked) { $script:AccPicked = [string]$script:ActiveId } })
    [void]$w.ShowDialog()
  } finally { $script:InDialog = $false }
  if ($script:AccPicked -like 'new:*') { New-Account $script:AccPicked.Substring(4) }
  elseif ($script:AccPicked -and $script:AccPicked -ne $script:ActiveId) { Switch-Account $script:AccPicked }
}

function Show-LaunchWarning {
  if ($script:WarnOpen) { return }
  $w = Parse-Xaml $script:XamlWarn
  Enable-Glass $w
  $st = Get-Streak
  $w.FindName('Streak').Text = T '{0} · sei a {1} giorni senza spendere. Non buttarli via per una cassa.' (Get-AccountName) $st
  $w.FindName('Goals').Text = (Get-GoalLines) -join "`n"
  $mb = Get-MissionBudget 'credits'
  if ($mb.budget -gt 0) { $w.FindName('Allowed').Text = T "Giocare, farmare, missioni giornaliere (fino a {0} crediti al giorno). Comprare solo l'obiettivo #1 al 100%." (Fmt $mb.budget) }
  $w.FindName('Lesson').Text = T $script:Lessons[(Get-Random -Maximum $script:Lessons.Count)]
  $script:WarnWin = $w
  $script:WarnLeft = 8
  $w.FindName('Ok').Content = T 'Leggi... ({0})' $script:WarnLeft
  $script:WarnTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:WarnTimer.Interval = [TimeSpan]::FromSeconds(1)
  $script:WarnTimer.Add_Tick({
    $script:WarnLeft--
    $b = $script:WarnWin.FindName('Ok')
    if ($script:WarnLeft -le 0) { $script:WarnTimer.Stop(); $b.IsEnabled = $true; $b.Content = T 'Ho capito: oggi non spendo' }
    else { $b.Content = T 'Leggi... ({0})' $script:WarnLeft }
  })
  $w.FindName('Ok').Add_Click({ $script:WarnWin.Close() })
  $w.Add_Closing({ if ($script:WarnLeft -gt 0) { $_.Cancel = $true } })
  $w.Add_Closed({ $script:WarnOpen = $false; $script:WarnTimer.Stop() })
  $script:WarnOpen = $true
  $script:WarnTimer.Start()
  $w.Show(); [void]$w.Activate()
}

function Update-Banner {
  $b = $script:Banner
  if (-not $b) { return }
  $d = $script:Data
  $cTxt = if ($d.initCredits) { Fmt $d.credits } else { '—' }
  $aTxt = if ($d.initAcoins) { Fmt $d.acoins } else { '—' }
  $b.FindName('Bal').Text = T '{0} crediti  ·  {1} A-coin' $cTxt $aTxt
  $first = @(Get-GoalStats) | Select-Object -First 1
  $mb = Get-MissionBudget 'credits'
  $tail = if ($mb.budget -gt 0) { T ' · missioni {0} rimasti' (Short $mb.left) } else { '' }
  $b.FindName('MiniTxt').Text = if ($first) { "$([math]::Floor($first.pct * 100))% · $(Short $d.credits) cr · $(Short $d.acoins) A" } else { "$(Short $d.credits) cr · $(Short $d.acoins) A" }
  $b.FindName('Txt').Text = if ($first) { "$(Get-AccountName) · $($first.goal.name) $([math]::Floor($first.pct * 100))%$tail" } else { "$(Get-AccountName) · $(T '{0} giorni puliti' (Get-Streak))$tail" }
}

$script:OverlayFile = Join-Path $script:AppDir 'overlay.json'
function Get-Overlay {
  $o = @{ mode = 'full'; x = $null; y = $null; compat = $false }
  if (Test-Path $script:OverlayFile) {
    try { $j = Read-JsonFile $script:OverlayFile; if ($j.mode -in 'full', 'small', 'mini') { $o.mode = $j.mode }; if ($null -ne $j.x) { $o.x = [double]$j.x; $o.y = [double]$j.y }; $o.compat = [bool]$j.compat } catch {}
  }
  $o
}
function Save-Overlay($o) {
  try { [IO.File]::WriteAllText($script:OverlayFile, ([ordered]@{ mode = $o.mode; x = $o.x; y = $o.y; compat = [bool]$o.compat } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) } catch { Write-Log "Overlay: $_" }
}
function Apply-OverlayMode($b, [string]$mode) {
  $sc = if ($mode -eq 'small') { 0.78 } else { 1.0 }
  $b.FindName('Scale').ScaleX = $sc; $b.FindName('Scale').ScaleY = $sc
  $b.FindName('Full').Visibility = if ($mode -eq 'mini') { 'Collapsed' } else { 'Visible' }
  $b.FindName('Mini').Visibility = if ($mode -eq 'mini') { 'Visible' } else { 'Collapsed' }
  $b.FindName('SizeBtn').Content = if ($mode -eq 'mini') { [string][char]0xE740 } else { [string][char]0xE73F }
}
function Place-Overlay($b) {
  $o = Get-Overlay
  $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
  $vr = $vl + [System.Windows.SystemParameters]::VirtualScreenWidth; $vb = $vt + [System.Windows.SystemParameters]::VirtualScreenHeight
  $w = [math]::Max(40, $b.ActualWidth); $hh = [math]::Max(20, $b.ActualHeight)
  if ($null -ne $o.x -and $o.x -ge $vl -and $o.x + 40 -le $vr -and $o.y -ge $vt -and $o.y + 20 -le $vb) { $b.Left = $o.x; $b.Top = $o.y }
  else { $wa = [System.Windows.SystemParameters]::WorkArea; $b.Left = $wa.Right - $w - 18; $b.Top = $wa.Bottom - $hh - 18 }
}
function Reset-Overlay {
  $o = Get-Overlay; $o.x = $null; $o.y = $null; $o.mode = 'full'; Save-Overlay $o
  if ($script:Banner) { Apply-OverlayMode $script:Banner 'full'; $script:Banner.UpdateLayout(); Place-Overlay $script:Banner }
}

function Show-Banner {
  if ($script:Banner -or -not $script:Data.showBanner) { return }
  $bx = $script:XamlBanner
  if (-not $script:LiquidGlass) {
    $bx = $bx.Replace('<GradientStop Color="#3A1C1C22" Offset="0"/><GradientStop Color="#2410121A" Offset="0.5"/><GradientStop Color="#3A1C1C22" Offset="1"/>', '<GradientStop Color="#F21E1E22" Offset="0"/><GradientStop Color="#F21B1B1F" Offset="0.5"/><GradientStop Color="#F21E1E22" Offset="1"/>')
  }
  $b = Parse-Xaml $bx
  if (-not $script:LiquidGlass) {
    foreach ($c in $b.FindName('Root').Children) {
      if ($c.Tag -eq 'glass') { $c.Visibility = 'Collapsed' } elseif ($c.Tag -eq 'rim') { $c.BorderBrush = '#2EFFFFFF'; $c.BorderThickness = 1 }
    }
  }
  $script:Banner = $b
  Update-Banner
  Apply-OverlayMode $b (Get-Overlay).mode
  $b.Left = -4000; $b.Top = -4000
  $b.Add_SourceInitialized({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($this)).Handle
    $ex = [MechVaultNative3]::GetWindowLong($h, -20)
    [void][MechVaultNative3]::SetWindowLong($h, -20, ($ex -bor 0x80 -bor 0x08000000))
  })
  $b.Add_ContentRendered({ Place-Overlay $this })
  $b.Add_MouseLeftButtonDown({
    try { $this.DragMove() } catch {}
    $o = Get-Overlay; $o.x = [math]::Round($this.Left); $o.y = [math]::Round($this.Top); Save-Overlay $o
  })
  $b.FindName('SizeBtn').Add_Click({
    $o = Get-Overlay
    $o.mode = switch ($o.mode) { 'full' { 'small' } 'small' { 'mini' } default { 'full' } }
    $win = $script:Banner
    $right = $win.Left + $win.ActualWidth; $bottom = $win.Top + $win.ActualHeight
    Apply-OverlayMode $win $o.mode; $win.UpdateLayout()
    $win.Left = $right - $win.ActualWidth; $win.Top = $bottom - $win.ActualHeight
    $o.x = [math]::Round($win.Left); $o.y = [math]::Round($win.Top); Save-Overlay $o
  })
  $b.Show()
}

function Hide-Banner { if ($script:Banner) { $script:Banner.Close(); $script:Banner = $null } }

function On-GameStart([bool]$quiet = $false) {
  $script:Pend = @{ credits = $null; acoins = $null }
  if ($quiet) {
    Update-Status
    Show-Banner
    if ($script:Tray) { $script:Tray.ShowBalloonTip(5000, (T 'Mech Arena aperto'), (T '{0}: blocco spese attivo. Per cambiare account: icona MechVault › Cambia account.' (Get-AccountName)), 'Info') }
    return
  }
  Show-AccountPicker $true
  Update-Status
  Show-LaunchWarning
  Show-Banner
  if ($script:Tray) { $script:Tray.ShowBalloonTip(5000, (T 'Mech Arena aperto'), (T '{0}: blocco spese attivo.' (Get-AccountName)), 'Warning') }
}

function On-GameStop {
  Hide-Banner
  Update-Status
  if ($script:UpdPrompt) { $script:UpdPrompt = $false; Prompt-UpdateRestart }
  if (-not ($script:Data.autoRead -and $script:OcrReady)) {
    $script:PendingCheck = $true
    Show-Main
    Show-Page 'PageSettings'
    [void]$script:ui.CredIn.Focus()
  } elseif ($script:Tray) {
    $c = if ($script:Data.initCredits) { Fmt $script:Data.credits } else { '—' }
    $a = if ($script:Data.initAcoins) { Fmt $script:Data.acoins } else { '—' }
    $script:Tray.ShowBalloonTip(5000, (T 'Partita finita'), (T '{0}: {1} crediti · {2} A-coin. Serie: {3} giorni.' (Get-AccountName) $c $a (Get-Streak)), 'Info')
  }
}

function Show-Main {
  Refresh-UI
  $script:win.Show()
  if ($script:win.WindowState -eq 'Minimized') { $script:win.WindowState = 'Normal' }
  [void]$script:win.Activate()
}

function Exit-App {
  $r = (Show-Msg (T "Se chiudi MechVault smette di sorvegliarti fino al prossimo avvio del PC.`n`nVuoi davvero uscire?") -YesNo -Danger)
  if ("$r" -ne 'Yes') { return }
  $script:Exiting = $true
  Hide-Banner
  if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
  Save-Data
  $script:app.Shutdown()
}

function New-AppIcon {
  $bmp = New-Object System.Drawing.Bitmap 64, 64
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear([System.Drawing.Color]::Transparent)
  $rect = New-Object System.Drawing.Rectangle(2, 2, 60, 60)
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(255, 120, 120, 128), [System.Drawing.Color]::FromArgb(255, 44, 44, 48), 90.0)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $rr = 18
  $path.AddArc(2, 2, $rr, $rr, 180, 90); $path.AddArc(62 - $rr, 2, $rr, $rr, 270, 90)
  $path.AddArc(62 - $rr, 62 - $rr, $rr, $rr, 0, 90); $path.AddArc(2, 62 - $rr, $rr, $rr, 90, 90); $path.CloseFigure()
  $g.FillPath($br, $path)
  $g.DrawPath((New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(140, 255, 255, 255), 2)), $path)
  $font = New-Object System.Drawing.Font('Segoe UI', 32, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString('V', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 2, 64, 64)), $sf)
  $g.Dispose()
  [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$script:app = [System.Windows.Application]::Current
if (-not $script:app) { $script:app = New-Object System.Windows.Application }
$script:app.ShutdownMode = 'OnExplicitShutdown'
$script:LiquidGlass = Get-LiquidGlass
$res = $script:XamlRes
if (-not $script:LiquidGlass) {
  $res = [regex]::Replace($res, '(?s)<LinearGradientBrush x:Key="GlassFill" .*?</LinearGradientBrush>', '<SolidColorBrush x:Key="GlassFill" Color="#FF26262A"/>')
  $res = [regex]::Replace($res, '(?s)<LinearGradientBrush x:Key="GlassEdge" .*?</LinearGradientBrush>', '<SolidColorBrush x:Key="GlassEdge" Color="#24FFFFFF"/>')
  $res = [regex]::Replace($res, '(?s)<LinearGradientBrush x:Key="GlassFillStrong" .*?</LinearGradientBrush>', '<SolidColorBrush x:Key="GlassFillStrong" Color="#FF303035"/>')
}
$script:app.Resources = Parse-Xaml $res
$script:app.Add_DispatcherUnhandledException({ Write-Log $_.Exception.ToString(); $_.Handled = $true })

if ($IsTest -and (Test-Path $script:AppDir)) { Remove-Item $script:AppDir -Recurse -Force; New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
Load-Lang
$script:LiquidGlass = Get-LiquidGlass
Init-Accounts
Init-Ocr

if ($IsTest) {
  $d = Get-DefaultData
  $d.accountName = 'Main'
  $now = Get-Date
  $c = 300000.0; $a = 40.0
  $evs = @()
  for ($k = 12; $k -ge 0; $k--) {
    $day = $now.Date.AddDays(-$k).AddHours(15)
    if ($k -eq 12) { $evs += [pscustomobject]@{ t = $day.ToString('o'); cur = 'credits'; delta = 0.0; bal = $c; kind = 'init'; note = ''; src = 'auto' }
                     $evs += [pscustomobject]@{ t = $day.ToString('o'); cur = 'acoins'; delta = 0.0; bal = $a; kind = 'init'; note = ''; src = 'auto' }; continue }
    $gc = 14000.0 + (($k * 7919) % 11000); $c += $gc
    $evs += [pscustomobject]@{ t = $day.ToString('o'); cur = 'credits'; delta = $gc; bal = $c; kind = 'gain'; note = ''; src = 'auto' }
    $ga = 15.0 + (($k * 31) % 25); $a += $ga
    $evs += [pscustomobject]@{ t = $day.AddMinutes(20).ToString('o'); cur = 'acoins'; delta = $ga; bal = $a; kind = 'gain'; note = ''; src = 'auto' }
    if ($k -eq 6) { $a -= 120; $evs += [pscustomobject]@{ t = $day.AddMinutes(40).ToString('o'); cur = 'acoins'; delta = -120.0; bal = $a; kind = 'spend'; note = 'Timed offer'; src = 'auto' } }
    if ($k -eq 0 -or $k -eq 2) { $c -= 1200; $evs += [pscustomobject]@{ t = $day.AddMinutes(50).ToString('o'); cur = 'credits'; delta = -1200.0; bal = $c; kind = 'mission'; note = 'budget missioni'; src = 'auto' } }
  }
  $d.events = $evs
  $d.credits = $c; $d.initCredits = $true
  $d.acoins = $a; $d.initAcoins = $true
  $d.violations = @([pscustomobject]@{ t = $now.Date.AddDays(-6).AddHours(15).AddMinutes(40).ToString('o'); currency = 'acoins'; amount = 120; reason = 'Timed offer.'; streakLost = 3; prevClean = $now.AddDays(-12).ToString('o') })
  $d.cleanSince = $now.Date.AddDays(-6).AddHours(16).ToString('o')
  $d.bestStreak = 6
  $d.firstRun = $false
  $d.createdAt = $now.AddDays(-12).ToString('o')
  $d.lastReadAt = $now.AddMinutes(-2).ToString('o')
  $d.goals += (New-Goal 'Epic weapon ★6 lvl 7' 'credits' 683000)
  $d.goals += (New-Goal 'Legendary mech ★6 lvl 7' 'credits' 2450000)
  $d.goals += (New-Goal 'A-coin reserve' 'acoins' 2500)
  $script:Data = $d
  Save-Data
  New-Account 'Alt'
  Switch-Account (@(Get-Accounts | Where-Object { $_.name -eq 'Main' })[0].id)
}

$script:win = Parse-Xaml $script:XamlMain
Enable-Glass $script:win
$script:ui = @{}
foreach ($m in [regex]::Matches($script:XamlMain, 'x:Name="(\w+)"')) {
  $n = $m.Groups[1].Value
  $script:ui[$n] = $script:win.FindName($n)
}

$script:Icon = New-AppIcon
try {
  $script:win.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($script:Icon.Handle, [System.Windows.Int32Rect]::Empty,
    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
} catch {}

$ui = $script:ui
$ui.NavHome.Add_Checked({ Show-Page 'PageHome' })
$ui.NavGoals.Add_Checked({ Show-Page 'PageGoals' })
$ui.NavActivity.Add_Checked({ Show-Page 'PageActivity' })
$ui.NavSettings.Add_Checked({ Show-Page 'PageSettings' })
$ui.NavTools.Add_Checked({ Show-Page 'PageTools' })
$ui.BtnCopyCred.Add_Click({ [void](Copy-Resource 'credits') })
$ui.BtnCopyAc.Add_Click({ [void](Copy-Resource 'acoins') })
foreach ($n in 'CalcFS', 'CalcFL', 'CalcTS', 'CalcTL') { $ui[$n].Add_TextChanged({ Build-Calc }) }
$ui.CalcMyBp.Add_TextChanged({ Update-CalcTotals })
$ui.CalcWeapon.Add_Checked({ $script:ui.CalcEnergyPanel.Visibility = 'Visible'; Build-Calc }); $ui.CalcMech.Add_Checked({ $script:ui.CalcEnergyPanel.Visibility = 'Collapsed'; Build-Calc })
foreach ($en in $script:Energies) { $ui["CalcE_$en"].Add_Checked({ Build-Calc }) }
foreach ($r in $script:Rarities) { $ui["CalcR_$($r.k)"].Add_Checked({ Set-CalcRarity }) }
$ui.BtnCalcMax.Add_Click({ $script:ui.CalcTS.Text = '6'; $script:ui.CalcTL.Text = '7' })
$ui.BtnCalcGoal.Add_Click({ Add-CalcGoal })
$ui.BtnCalcRun.Add_Click({ Run-Calc })
$ui.BtnCalcDetail.Add_Click({ Toggle-CalcDetail })
$ui.BtnCalcImport.Add_Click({ Import-Costs })
$ui.BtnCalcExport.Add_Click({ Export-Costs })
$ui.CrUpg.Add_Click({ $script:ui.CrUpgGrid.IsEnabled = [bool]$script:ui.CrUpg.IsChecked; Update-Crate })
$ui.CrAddPrize.Add_Click({ Add-CratePrize })
$ui.CrName.Add_TextChanged({ Update-Crate })
$ui.CrName.Add_LostFocus({
  if ($script:ui.CrDirect.Text.Trim()) { return }
  $k = Find-Mech $script:ui.CrName.Text; if (-not $k) { return }
  $m = $script:Mechs[$k]; $gh = $m.gearHub
  $script:ui.CrKM.IsChecked = $true
  $r = @{ Common = 'common'; Uncommon = 'uncommon'; Rare = 'rare'; Epic = 'epic'; Legendary = 'legendary' }[[string]$m.rarity]
  if ($r) { $script:ui["CrR_$r"].IsChecked = $true }
  if ($gh -and $gh.amount) {
    if ($gh.currency -eq 'credits') { $script:ui.CrDirCr.IsChecked = $true } else { $script:ui.CrDirAc.IsChecked = $true }
    $script:ui.CrDirect.Text = Fmt $gh.amount
  }
})
$ui.MsSearch.Add_TextChanged({ Update-MechList })
$ui.MsEditBtn.Add_Click({ if ($script:ui.MsEdit.Visibility -eq 'Visible') { $script:ui.MsEdit.Visibility = 'Collapsed' } else { Open-MechEdit $script:MsCurrent } })
$ui.MeSave.Add_Click({ Save-MechEdit })
$ui.MsRefresh.Add_Click({ Start-WikiUpdate -Force })
$ui.MeDel.Add_Click({ Remove-MechEdit })
Load-Mechs
Update-MechList
if (-not $IsTest) {
  Start-WikiUpdate
  $script:UpdClock = New-Object System.Windows.Threading.DispatcherTimer
  $script:UpdClock.Interval = [TimeSpan]::FromMinutes(1)
  $script:UpdClock.Add_Tick({ $this.Interval = [TimeSpan]::FromHours(6); Start-UpdateCheck })
  $script:UpdClock.Start()
}
foreach ($n in 'CrSpin', 'CrP', 'CrPity', 'CrDirect', 'CrBudget', 'CrPS', 'CrPL', 'CrDS', 'CrDL') { $ui[$n].Add_TextChanged({ Update-Crate }) }
$ui.CrAc.Add_Checked({ Update-Crate }); $ui.CrCr.Add_Checked({ Update-Crate })
$ui.CrDirCr.Add_Checked({ Update-Crate }); $ui.CrDirAc.Add_Checked({ Update-Crate })
$ui.CrKW.Add_Checked({ $script:ui.CrEnergyPanel.Visibility = 'Visible'; Update-Crate }); $ui.CrKM.Add_Checked({ $script:ui.CrEnergyPanel.Visibility = 'Collapsed'; Update-Crate })
foreach ($r in $script:Rarities) { $ui["CrR_$($r.k)"].Add_Checked({ Set-CrateRarity }) }
foreach ($en in $script:Energies) { $ui["CrE_$en"].Add_Checked({ Update-Crate }) }
$ui.CrFromCalc.Add_Click({
  if ($script:CalcTot.n -gt 0) {
    $in = Get-CalcInput
    if (-not $in.err) {
      if ($in.kind -eq 'mech') { $script:ui.CrKM.IsChecked = $true } else { $script:ui.CrKW.IsChecked = $true; $script:ui["CrE_$($in.energy)"].IsChecked = $true }
      $script:ui["CrR_$($in.rarity)"].IsChecked = $true
    }
    $script:ui.CrDirCr.IsChecked = $true; $script:ui.CrDirect.Text = Fmt $script:CalcTot.c
    if (-not $script:ui.CrName.Text.Trim()) { $script:ui.CrName.Text = $script:ui.CalcName.Text }
  }
})
Load-Costs
Build-Calc
foreach ($l in @(Get-Languages)) {
  $rb = New-Object System.Windows.Controls.RadioButton
  $rb.Content = $l.name; $rb.Tag = $l.code; $rb.GroupName = 'lang'
  $rb.Style = $script:app.Resources['Pill']
  $rb.IsChecked = ($l.code -eq $script:Lang)
  $rb.Add_Click({ Set-Language ([string]$this.Tag) })
  [void]$ui.LangPanel.Children.Add($rb)
}
$ui.BtnAllActivity.Add_Click({ Show-Page 'PageActivity' })
$ui.BtnMin.Add_Click({ $script:win.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $script:win.WindowState = if ($script:win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$ui.BtnClose.Add_Click({ $script:win.Close() })
$ui.BtnQuit.Add_Click({ Exit-App })
$ui.BtnAccount.Add_Click({ Show-AccountPicker $false })
$ui.BtnAccSwitch.Add_Click({ Show-AccountPicker $false })
$ui.BtnAccRename.Add_Click({ Rename-Account })
$ui.AccRename.Add_KeyDown({ if ($_.Key -eq 'Return') { Rename-Account } })
$ui.BtnAccDelete.Add_Click({ Remove-Account })
$ui.HeroBuy.Add_Click({ Authorize-Purchase $this.Tag })
$ui.CredBtn.Add_Click({ Submit-Manual 'credits' })
$ui.AcBtn.Add_Click({ Submit-Manual 'acoins' })
$ui.CredIn.Add_KeyDown({ if ($_.Key -eq 'Return') { Submit-Manual 'credits' } })
$ui.AcIn.Add_KeyDown({ if ($_.Key -eq 'Return') { Submit-Manual 'acoins' } })
$ui.GoalAdd.Add_Click({ Add-GoalFromForm })
$ui.GoalCost.Add_KeyDown({ if ($_.Key -eq 'Return') { Add-GoalFromForm } })
$ui.RateSave.Add_Click({ Save-Rates })
$ui.MisSave.Add_Click({ Save-Missions })
$ui.ProcSave.Add_Click({ Save-ProcPattern })
$ui.BtnTestRead.Add_Click({ Test-ReadNow })
$ui.SparkCred.Add_SizeChanged({ Draw-Spark $this })
$ui.SparkAc.Add_SizeChanged({ Draw-Spark $this })
$ui.ChkAuto.Add_Click({ $script:Data.autoRead = [bool]$script:ui.ChkAuto.IsChecked; Save-Data; Update-Status })
$ui.ChkAutostart.Add_Click({ $script:Data.autostart = [bool]$script:ui.ChkAutostart.IsChecked; Set-Autostart $script:Data.autostart; Save-Data })
$ui.BtnOverlayReset.Add_Click({ Reset-Overlay })
$ui.ChkGlass.IsChecked = $script:LiquidGlass
$ui.ChkGlass.Add_Click({ Set-LiquidGlass ([bool]$script:ui.ChkGlass.IsChecked) })
$ui.ChkAutoUpdate.IsChecked = [bool](Get-UiPref 'autoUpdate' $true)
$ui.ChkAutoUpdate.Add_Click({ try { Set-UiPref 'autoUpdate' ([bool]$script:ui.ChkAutoUpdate.IsChecked) } catch { Write-Log "ui.json: $_" } })
$ui.BtnUpdate.Add_Click({ Start-UpdateCheck -Manual })
$ui.UpdStatus.Text = T 'Versione {0}.' $script:AppVersion
$ui.ChkBanner.Add_Click({
  $script:Data.showBanner = [bool]$script:ui.ChkBanner.IsChecked; Save-Data
  if (-not $script:Data.showBanner) { Hide-Banner } elseif ($script:GameRunning) { Show-Banner }
})
$script:win.Add_StateChanged({
  $script:ui.Root.Margin = if ($script:win.WindowState -eq 'Maximized') { '7' } else { '0' }
  $script:ui.BtnMax.Content = if ($script:win.WindowState -eq 'Maximized') { [string][char]0xE923 } else { [string][char]0xE922 }
})
$script:win.Add_Closing({
  if (-not $script:Exiting) {
    $_.Cancel = $true
    $script:win.Hide()
    if (-not $script:HideTipShown -and $script:Tray) {
      $script:HideTipShown = $true
      $script:Tray.ShowBalloonTip(4000, (T 'MechVault resta attivo'), (T "Ti sorveglio dalla barra. Per uscire: tasto destro sull'icona › Esci."), 'Info')
    }
  }
})

if ($IsTest) {
  if (-not (Test-Path $SelfTest)) { New-Item -ItemType Directory -Path $SelfTest -Force | Out-Null }
  $fake = New-Object System.Windows.Media.LinearGradientBrush
  $fake.StartPoint = '0,0'; $fake.EndPoint = '1,1'
  $fake.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(58, 60, 66), 0)))
  $fake.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(34, 35, 40), 0.6)))
  $fake.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(46, 44, 52), 1)))
  function Save-Png($visual, [string]$path) {
    $visual.UpdateLayout()
    $w = [int][math]::Ceiling($visual.ActualWidth); $h = [int][math]::Ceiling($visual.ActualHeight)
    $dv = New-Object System.Windows.Media.DrawingVisual
    $ctx = $dv.RenderOpen()
    if ($env:MECHVAULT_BG -and (Test-Path $env:MECHVAULT_BG)) {
      $img = New-Object System.Windows.Media.Imaging.BitmapImage([uri]$env:MECHVAULT_BG)
      $ib = New-Object System.Windows.Media.ImageBrush($img); $ib.Stretch = 'UniformToFill'
      $ctx.DrawRectangle($ib, $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
      $ctx.DrawRectangle((New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(0xB0, 0x10, 0x0C, 0x0C))), $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
    } else { $ctx.DrawRectangle($fake, $null, (New-Object System.Windows.Rect(0, 0, $w, $h))) }
    $ctx.DrawRectangle((New-Object System.Windows.Media.VisualBrush($visual)), $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
    $ctx.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($path); $enc.Save($fs); $fs.Close()
  }
  $script:win.Height = 1320
  $script:win.WindowStartupLocation = 'Manual'; $script:win.Left = -4000; $script:win.Top = 0
  Refresh-UI
  $script:win.Show()
  Show-LaunchWarning; $script:WarnWin.Left = -4000
  $script:GameRunning = $true; Show-Banner; Update-Status
  $script:TestViol = Parse-Xaml $script:XamlViol
  $script:TestViol.FindName('Amt').Text = '−' + (Fmt 2480) + ' A-coin'
  $script:TestViol.FindName('Head').Text = T 'Spesa rilevata dal gioco'
  $script:TestViol.FindName('Body').Text = (T 'Il budget missioni di oggi ha coperto {0} {1}; questo è il resto. ' (Fmt 800) (CurName 'credits')) + (T 'Avevi {0} giorni puliti: la serie riparte da zero.' 6) + "`n" + (T 'Se era per una missione giornaliera premi «Era una missione»: non rompe la serie.')
  $script:TestViol.WindowStartupLocation = 'Manual'; $script:TestViol.Left = -4000
  $script:TestViol.Show()
  $script:TestMsg = Parse-Xaml $script:XamlMsg; Enable-Glass $script:TestMsg
  $script:TestMsg.FindName('Msg').Text = T "Eliminare l'obiettivo «{0}»?" 'Test'; $script:TestMsg.FindName('No').Visibility = 'Visible'; $script:TestMsg.FindName('Yes').Content = T 'Conferma'
  $script:TestMsg.WindowStartupLocation = 'Manual'; $script:TestMsg.Left = -4000; $script:TestMsg.Show()
  $script:TestAcc = Parse-Xaml $script:XamlAcc
  foreach ($a in @(Get-Accounts)) { $bb = New-Object System.Windows.Controls.Button; $bb.Content = $(if ($a.id -eq $script:ActiveId) { T '{0}   ·   ultimo usato' $a.name } else { $a.name }); $bb.Margin = '0,0,0,10'; $bb.Padding = '18,13'; $bb.FontSize = 15; if ($a.id -eq $script:ActiveId) { $bb.Style = $script:app.Resources['Primary'] }; [void]$script:TestAcc.FindName('List').Children.Add($bb) }
  $script:TestAcc.WindowStartupLocation = 'Manual'; $script:TestAcc.Left = -4000
  $script:TestAcc.Show()
  $script:TestStep = 0
  $script:ui.CalcName.Text = 'Epic beam'; $script:ui.CalcFS.Text = '6'; $script:ui.CalcFL.Text = '5'; $script:ui.CalcMyBp.Text = '120'
  $script:ui.CalcFS.Text = '4'; $script:ui.CalcFL.Text = '1'; $script:ui.CalcTS.Text = '6'; $script:ui.CalcTL.Text = '7'; $script:ui.CalcE_10.IsChecked = $true
  Build-Calc; Run-Calc; Toggle-CalcDetail
  $t = New-Object System.Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromMilliseconds(1200)
  $t.Add_Tick({
    try {
      switch ($script:TestStep) {
        0 { Save-Png $script:ui.Root (Join-Path $SelfTest 'home.png'); Show-Page 'PageGoals' }
        1 { Save-Png $script:ui.Root (Join-Path $SelfTest 'goals.png'); Show-Page 'PageActivity' }
        2 { Save-Png $script:ui.Root (Join-Path $SelfTest 'activity.png'); Show-Page 'PageTools' }
        3 { Save-Png $script:ui.Root (Join-Path $SelfTest 'tools.png'); Save-Png $script:ui.CalcCard (Join-Path $SelfTest 'calc.png')
           Set-CratePreset 'Legendary scout' 1000 937500; $script:ui.CrP.Text = '1'; $script:ui.CrBudget.Text = '20000'
           $script:TestCrate = "crate1=[$($script:ui.CrVerdict.Text)]"
           Save-Png $script:ui.CrateCard (Join-Path $SelfTest 'crate.png')
           Set-CratePreset 'Epic weapon 16' 350 826000; $script:ui.CrP.Text = ''
           $script:TestCrate += " crate2=[$($script:ui.CrVerdict.Text) | $($script:ui.CrStats.Text -replace "`n", ' / ')]"
           Save-Png $script:ui.CrateCard (Join-Path $SelfTest 'crate2.png')
           $script:ui.CrCr.IsChecked = $true; $script:ui.CrSpin.Text = '50000'; $script:ui.CrPity.Text = '500000'; $script:ui.CrDirAc.IsChecked = $true; $script:ui.CrDirect.Text = '3000'; $script:ui.CrUpg.IsChecked = $false; Update-Crate
           $script:TestCrate += " crate3=[$($script:ui.CrVerdict.Text) | $((($script:ui.CrStats.Text -split "`n") | Select-Object -First 2) -join ' / ')]"
           Save-Png $script:ui.CrateCard (Join-Path $SelfTest 'crate3.png')
           Set-CratePreset 'Mimicker' 1000 937500; $script:ui.CrP.Text = '1'; $script:ui.CrBudget.Text = ''; $script:ui.CrUpg.IsChecked = $false
           Add-CratePrize 'Lacewing' '1' '' 'credits' $true; $lw = $script:ui.CrPrizes.Children[0]; Fill-PrizePrice $lw
           $script:TestCrate += " autofill=$($lw.FindName('V').Text)/$($lw.FindName('Ac').IsChecked)"
           Add-CratePrize 'Charge Rocket 12' '3' '200000' 'credits' $true
           Add-CratePrize 'Particle Beam 12' '3' '200000' 'credits' $false
           Update-Crate
           $script:TestCrate += " multi=[$($script:ui.CrVerdict.Text) | $((($script:ui.CrStats.Text -split "`n") | Where-Object { $_ -match 'spin' } | Select-Object -First 2) -join ' / ')]"
           Save-Png $script:ui.CrateCard (Join-Path $SelfTest 'crate4.png')
           $script:ui.CrPrizes.Children.Clear(); $script:ui.CrName.Text = 'Redox'; $script:ui.CrSpin.Text = '1'; $script:ui.CrP.Text = '100'; $script:ui.CrPity.Text = '1'
           $script:ui.CrDirCr.IsChecked = $true; $script:ui.CrDirect.Text = '1'; $script:ui.CrUpg.IsChecked = $true
           $script:ui.CrPS.Text = '6'; $script:ui.CrPL.Text = '7'; $script:ui.CrDS.Text = '1'; $script:ui.CrDL.Text = '1'; Update-Crate
           $script:TestCrate += " absurd=[$($script:ui.CrVerdict.Text) | $((($script:ui.CrStats.Text -split "`n") | Select-Object -First 4) -join ' / ')]"
           Save-Png $script:ui.CrateCard (Join-Path $SelfTest 'crate5.png')
           $script:ui.MsSearch.Text = ''; Update-MechList; $script:TestCrate += " list=$($script:ui.MsList.Children.Count)"
           Open-MechEdit $null; $script:ui.MeName.Text = 'Testmech'; $script:ui.MeHp.Text = '250.000'; $script:ui.MeSpeed.Text = '21'; $script:ui.MeEnergy.Text = '32'; $script:ui.MeR_Tank.IsChecked = $true; Save-MechEdit
           $script:TestCrate += " custom=[$($script:ui.MeMsg.Text) $($script:ui.MsVerdict.Text)] n=$($script:Mechs.Count)"
           $script:ui.MeName.Text = 'Testmech'; Remove-MechEdit; $script:TestCrate += " after=$($script:Mechs.Count)"; $script:ui.MsEdit.Visibility = 'Collapsed'
           $script:ui.MsSearch.Text = 'lacew'; Update-MechList
           $script:TestCrate += " mech=[$($script:ui.MsVerdict.Text)] mechs=$($script:Mechs.Count) rated=$($script:Ratings.Count) ranked=$(@($script:Mechs.Values | Where-Object { $_.ranks }).Count)"
           $script:MsRank = 3; Show-Mech 'Lacewing'; $r4 = (Get-Ratings 3)['Lacewing']
           $script:TestCrate += " lace4=$($r4.tier)$($r4.score)/hp$($r4.hp) rated4=$((Get-Ratings 3).Count) table=$($script:ui.MsRankTable.Children.Count)"
           $rk = @($script:Ratings.Keys | Sort-Object { -$script:Ratings[$_].score }) | ForEach-Object { "$_ $($script:Ratings[$_].tier)$($script:Ratings[$_].score)" }
           [IO.File]::WriteAllLines((Join-Path $SelfTest 'ratings.txt'), [string[]]$rk)
           $script:TestCalc0 = "wiki=$($script:BaseCosts.Count) path=$($script:CalcTot.n) miss=$($script:CalcTot.miss) tot=$($script:CalcTot.c)/$($script:CalcTot.b)/$($script:CalcTot.a)"
           foreach ($ck in $script:CalcKeys) { if (-not (Get-Cost $ck)) { $script:Costs[$ck] = @{ c = 1000.0; b = 1.0; a = $null } } }
           $g0 = @($script:Data.goals).Count; Update-CalcTotals; Add-CalcGoal
           $script:TestCalc = "calc: tot=$($script:CalcTot.c)/$($script:CalcTot.b)/$($script:CalcTot.a) miss=$($script:CalcTot.miss) goals+$(@($script:Data.goals).Count - $g0) msg=$($script:ui.CalcMsg.Text)"
           $row0 = $script:ui.CalcSteps.Children[0]; $row0.FindName('Cc').Text = '6000'; $k0 = $script:CalcKeys[0]; $g = Get-Cost $k0
           $script:TestCalc += " override=$($g.c)/$($g.b) user=$($script:Costs.Count)"
           $script:ui.CalcMech.IsChecked = $true; $script:ui.CalcR_legendary.IsChecked = $true; $script:ui.CalcFS.Text = '3'; $script:ui.CalcFL.Text = '7'
           $script:TestCalc += " leg3=$($script:CalcTot.c)/$($script:CalcTot.b)/$($script:CalcTot.a) miss=$($script:CalcTot.miss) err=$((Get-CalcInput).err)"
           $cnt = $script:Costs.Count; [void](Save-Costs); Load-Costs; $script:TestCalc += " roundtrip=$cnt/$($script:Costs.Count)"
           Show-Page 'PageSettings' }
        4 {
          Save-Png $script:ui.Root (Join-Path $SelfTest 'settings.png')
          $script:MsRank = 6; Show-Mech 'Lacewing'
          Save-Png $script:ui.MechCard (Join-Path $SelfTest 'mech.png')
          $script:Dump = New-Object System.Collections.Generic.List[string]
          function Dump-Tree($o) {
            if ($o -is [System.Windows.Controls.TextBlock] -and $o.Text) { $script:Dump.Add($o.Text) }
            elseif ($o -is [System.Windows.Controls.ContentControl] -and $o.Content -is [string]) { $script:Dump.Add($o.Content) }
            if ($o -is [System.Windows.FrameworkElement] -and $o.ToolTip -is [string]) { $script:Dump.Add('TT:' + $o.ToolTip) }
            if ($o -is [System.Windows.DependencyObject]) { foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($o)) { Dump-Tree $c } }
          }
          foreach ($w in @($script:win, $script:WarnWin, $script:Banner, $script:TestViol, $script:TestAcc)) { if ($w) { Dump-Tree $w } }
          [IO.File]::WriteAllLines((Join-Path $SelfTest 'texts.txt'), $script:Dump, (New-Object Text.UTF8Encoding($false)))
          Save-Png $script:WarnWin.Content (Join-Path $SelfTest 'avviso.png')
          Save-Png $script:Banner.Content (Join-Path $SelfTest 'banner.png')
          Apply-OverlayMode $script:Banner 'small'; $script:Banner.UpdateLayout(); Save-Png $script:Banner.Content (Join-Path $SelfTest 'banner_small.png')
          Apply-OverlayMode $script:Banner 'mini'; $script:Banner.UpdateLayout(); Save-Png $script:Banner.Content (Join-Path $SelfTest 'banner_mini.png')
          Save-Png $script:TestViol.Content (Join-Path $SelfTest 'spesa.png')
          Save-Png $script:TestAcc.Content (Join-Path $SelfTest 'account.png')
          Save-Png $script:TestMsg.Content (Join-Path $SelfTest 'msg.png')
          "OK ocr=$($script:OcrReady) accounts=$((@(Get-Accounts) | ForEach-Object { $_.name }) -join ',') active=$(Get-AccountName) $($script:TestCrate) rateC=[$(Format-AutoRate 'credits')] rateA=[$(Format-AutoRate 'acoins')] $($script:TestCalc0) | $($script:TestCalc)" | Set-Content (Join-Path $SelfTest 'result.txt')
          $this.Stop(); $script:WarnLeft = 0; $script:Exiting = $true; $script:app.Shutdown()
        }
      }
    } catch { "ERR $_ $($_.InvocationInfo.PositionMessage)" | Set-Content (Join-Path $SelfTest 'result.txt'); $this.Stop(); $script:app.Shutdown() }
    $script:TestStep++
  })
  $t.Start()
  [void]$script:app.Run()
  return
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $script:Icon
$script:Tray.Text = 'MechVault'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add((T 'Apri MechVault'))
$miOpen.add_Click({ Show-Main })
$miAcc = $menu.Items.Add((T 'Cambia account'))
$miAcc.add_Click({ Show-AccountPicker $false })
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add((T 'Esci'))
$miExit.add_Click({ Exit-App })
$script:Tray.ContextMenuStrip = $menu
$script:Tray.add_MouseClick({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Main } })
$script:Tray.Visible = $true

$script:Watch = New-Object System.Windows.Threading.DispatcherTimer
$script:Watch.Interval = [TimeSpan]::FromSeconds(3)
$script:Watch.Add_Tick({
  if ($script:InDialog) { return }
  $proc = Get-GameProcess
  $running = [bool]$proc
  $firstCheck = -not $script:WatchStarted; $script:WatchStarted = $true
  if ($running -and -not $script:GameRunning) { $script:GameRunning = $true; On-GameStart $firstCheck; return }
  elseif (-not $running -and $script:GameRunning) { $script:GameRunning = $false; On-GameStop }

  if ($running -and $script:Data.autoRead -and $script:OcrReady -and -not $script:InDialog) {
    $r = Read-GameBalances $proc
    if ($r.Count -gt 0) {
      $script:Data.lastReadAt = Now-Iso
      foreach ($c in 'credits', 'acoins') {
        if ($r.ContainsKey($c) -and -not $script:InDialog) { Process-Read $c $r[$c] }
      }
    }
  }
  $script:TickN++
  if ($script:TickN % 10 -eq 0) { Update-Status; if ($script:win.IsVisible) { $script:ui.StreakBig.Text = "$(Get-Streak)" } }
})
$script:Watch.Start()

if ($script:Data.autostart) { Set-Autostart $true }
if ($script:Data.firstRun) {
  $script:Data.firstRun = $false
  Save-Data
  Show-Main
} elseif ($Minimized) {
  Refresh-UI
  $first = @(Get-GoalStats) | Select-Object -First 1
  $msg = T '{0} · {1} giorni senza spendere.' (Get-AccountName) (Get-Streak)
  if ($first) { $msg += " $($first.goal.name): $([math]::Floor($first.pct * 100))%" }
  $script:Tray.ShowBalloonTip(6000, (T 'MechVault attivo'), $msg, 'Info')
} else {
  Show-Main
}

[void]$script:app.Run()
