# ============================================================
#  Cihui one-click launcher (called by run-cihui.bat)
#  start emulator (stale-lock auto cleanup + wedge restart)
#  -> wait until the screen actually renders -> unlock
#  -> install HAP -> launch app
#  All messages are ASCII on purpose to avoid codepage issues.
# ============================================================
$ErrorActionPreference = 'Continue'

$Hdc       = 'E:\AAALSRJ\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$EmuDir    = 'E:\AAALSRJ\DevEco Studio\tools\emulator'
$EmuExe    = Join-Path $EmuDir 'Emulator.exe'
$InstDir   = Join-Path $env:LOCALAPPDATA 'Huawei\Emulator\deployed\Mate 60'
$LogFile   = Join-Path $InstDir 'Log\Emulator.log'
$Hap       = 'F:\PORJECT\cihui-harmony\Cihui\entry\build\default\outputs\default\entry-default-unsigned.hap'
$ShotLocal = Join-Path $env:TEMP 'cihui_bootshot.jpeg'

function Clean-Locks {
    if (-not (Test-Path $InstDir)) { return }
    $q = Join-Path $InstDir '_lockquarantine'
    New-Item -ItemType Directory -Force -Path $q | Out-Null
    Get-ChildItem -LiteralPath $InstDir -Force |
        Where-Object { $_.Name -like '*lock*' -and $_.Name -ne '_lockquarantine' } |
        ForEach-Object {
            $dest = Join-Path $q ((Get-Date -Format 'HHmmss') + '_' + (Get-Random) + '_' + $_.Name)
            try { Move-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction Stop } catch {}
        }
}
function Get-EmuProc { Get-Process -Name Emulator -ErrorAction SilentlyContinue }
function Stop-EmuHard {
    Get-Process -Name Emulator,emulator-crash-service -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
}
function Start-Emu {
    Clean-Locks
    Start-Process -FilePath $EmuExe -ArgumentList '-start "Mate 60"' -WorkingDirectory $EmuDir | Out-Null
}
function Hdc-Call { param([string[]]$ArgList)
    return (& $Hdc @ArgList 2>$null | Out-String)
}
function Test-CoreUp {
    ((Hdc-Call @('shell','param get const.ohos.apiversion')).Trim() -eq '26')
}
function Test-ScreenUp {
    # The real "booted" signal on this image: a non-black rendered frame.
    Hdc-Call @('shell','power-shell wakeup') | Out-Null
    Start-Sleep -Seconds 1
    Hdc-Call @('shell','snapshot_display -f /data/local/tmp/bootshot.jpeg') | Out-Null
    Hdc-Call @('file','recv','/data/local/tmp/bootshot.jpeg',$ShotLocal) | Out-Null
    if (Test-Path $ShotLocal) {
        $sz = (Get-Item $ShotLocal).Length
        if ($sz -gt 80000) { return $true }
    }
    return $false
}
function Unlock-Screen {
    Hdc-Call @('shell','power-shell wakeup') | Out-Null
    Start-Sleep -Seconds 2
    # 实测有效手势：快速向上 fling（普通慢速 swipe 在该镜像上不触发解锁）
    Hdc-Call @('shell','uitest uiInput dircFling 2 2000') | Out-Null
    Start-Sleep -Seconds 5
}

Write-Host '[1/4] Checking emulator...' -ForegroundColor Cyan
$targets = Hdc-Call @('list','targets')
if ($targets -notmatch '127\.0\.0\.1' -or -not (Test-CoreUp)) {
    Write-Host '      Emulator not ready. Booting Mate 60 (cold boot takes 20-35 min on this PC)...' -ForegroundColor Yellow
    $attempt = 0; $booted = $false
    while (-not $booted -and $attempt -lt 3) {
        $attempt++
        Write-Host ("      Boot attempt {0}/3" -f $attempt)
        if (-not (Get-EmuProc)) { Start-Emu } else { Hdc-Call @('kill') | Out-Null; Start-Sleep 1; Hdc-Call @('start') | Out-Null; Start-Sleep 2; Hdc-Call @('tconn','127.0.0.1:5555') | Out-Null }
        $deadFor = 0; $lastLogLen = 0; $stuckFor = 0
        for ($i = 0; $i -lt 240; $i++) {
            Start-Sleep -Seconds 10
            if ($i % 3 -eq 0) { Hdc-Call @('tconn','127.0.0.1:5555') | Out-Null }
            if ((Test-CoreUp) -and (Test-ScreenUp)) { $booted = $true; break }
            $proc = Get-EmuProc
            if (-not $proc) { $deadFor += 10; if ($deadFor -ge 40) { Write-Host '      Emulator exited early, retrying...' -ForegroundColor Yellow; break } } else { $deadFor = 0 }
            if (Test-Path $LogFile) {
                $len = (Get-Item $LogFile).Length
                if ($len -eq $lastLogLen) { $stuckFor += 10 } else { $stuckFor = 0; $lastLogLen = $len }
                if ($stuckFor -ge 240 -and $i -lt 30) {
                    Write-Host '      Startup wedged (stale locks), restarting...' -ForegroundColor Yellow
                    Stop-EmuHard; Clean-Locks; break
                }
            }
            if ($i % 6 -eq 0) { Write-Host ("      ...waiting for boot ({0}s)" -f ($i*10)) }
        }
        if (-not $booted) { Stop-EmuHard; Clean-Locks }
    }
    if (-not $booted) { Write-Host 'ERROR: emulator failed to boot after 3 attempts. Open Device Manager in DevEco Studio manually.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }
    Write-Host '      Screen is up.' -ForegroundColor Green
} else {
    Write-Host '      Emulator already connected.' -ForegroundColor Green
}

Write-Host '[2/4] Unlocking screen...' -ForegroundColor Cyan
Unlock-Screen

Write-Host '[3/4] Installing latest HAP...' -ForegroundColor Cyan
if (-not (Test-Path $Hap)) { Write-Host ("ERROR: HAP not found: {0}" -f $Hap) -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }
& $Hdc install -r $Hap
if ($LASTEXITCODE -ne 0) { Write-Host 'ERROR: install failed.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }

Write-Host '[4/4] Launching Cihui...' -ForegroundColor Cyan
Hdc-Call @('shell','aa force-stop com.cihui.word') | Out-Null
Start-Sleep -Seconds 2
$launched = $false
for ($i = 0; $i -lt 4; $i++) {
    $r = Hdc-Call @('shell','aa start -a EntryAbility -b com.cihui.word')
    if ($r -match 'successfully') { $launched = $true; break }
    if ($r -match '10106102|locked') { Write-Host '      Screen locked, swiping up and retrying...' -ForegroundColor Yellow; Unlock-Screen; Start-Sleep 2 }
    else { Start-Sleep 3 }
}
if (-not $launched) { Write-Host 'WARN: launch command did not report success; tap the Cihui icon manually.' -ForegroundColor Yellow }
Write-Host ''
Write-Host 'Done. Cihui should now be on the emulator screen.' -ForegroundColor Green
Write-Host 'Keep the emulator open; do not hard-close it during boot.' -ForegroundColor Yellow
Read-Host 'Press Enter to close this window'
