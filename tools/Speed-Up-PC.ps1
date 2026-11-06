<#
    Speed-Up-PC.ps1
    Safe, reversible speed tune-up for Windows 10 / 11.

    What it does:
      1. Creates a System Restore point (so you can undo everything).
      2. Shows a health report: RAM, disk space, uptime, heaviest programs, startup apps.
      3. Resets virtual memory (pagefile) to "System managed" - fixes bad manual memory settings.
      4. Makes sure memory compression is on.
      5. Deletes temporary junk files.
      6. Switches to the High performance power plan (asks first).
      7. Optimizes the C: drive (TRIM for SSD, defrag for HDD).
      8. Optionally turns off fancy animations (asks first).

    What it does NOT do: disable antivirus, delete your files, remove apps, or apply registry "hacks".

    How to run (PowerShell):
      cd <folder where this file is>
      powershell -ExecutionPolicy Bypass -File .\Speed-Up-PC.ps1
#>

# ---------- Re-launch as Administrator if needed ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Asking for Administrator permission..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$ErrorActionPreference = 'Continue'
$desktop = [Environment]::GetFolderPath('Desktop')
$logFile = Join-Path $desktop ("SpeedUp-Report-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".txt")
Start-Transcript -Path $logFile | Out-Null

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "    [OK] $text" -ForegroundColor Green }
function Warn($text) { Write-Host "    [!]  $text" -ForegroundColor Yellow }
function Ask($question) {
    $answer = Read-Host "    $question (Y/N)"
    return ($answer -match '^[Yy]')
}

$needsRestart = $false

# ---------- 1. Restore point ----------
Step "Creating a System Restore point (safety net)"
try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
    Checkpoint-Computer -Description "Before Speed-Up-PC" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    Ok "Restore point created."
} catch {
    Warn "Could not create a restore point: $($_.Exception.Message)"
    Warn "(Windows allows only one per 24 hours. Your files are not touched either way.)"
    if (-not (Ask "Continue anyway?")) { Stop-Transcript | Out-Null; exit }
}

# ---------- 2. Health report ----------
Step "Health report"
$os   = Get-CimInstance Win32_OperatingSystem
$cs   = Get-CimInstance Win32_ComputerSystem
$ramGB      = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$freeRamGB  = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
$uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
$sysDrive   = Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')
$freeDiskGB = [math]::Round($sysDrive.Free / 1GB, 1)
$totalDiskGB = [math]::Round(($sysDrive.Used + $sysDrive.Free) / 1GB, 1)
$freePct    = [math]::Round(100 * $sysDrive.Free / ($sysDrive.Used + $sysDrive.Free), 0)

Write-Host "    Windows:      $($os.Caption)"
Write-Host "    RAM:          $ramGB GB total, $freeRamGB GB free right now"
Write-Host "    Disk $($env:SystemDrive)       $freeDiskGB GB free of $totalDiskGB GB ($freePct% free)"
Write-Host "    Uptime:       $uptimeDays days since last restart"

try {
    $disk = Get-PhysicalDisk | Select-Object -First 1
    Write-Host "    Drive type:   $($disk.MediaType) ($($disk.FriendlyName))"
    if ($disk.MediaType -eq 'HDD') { Warn "You have a spinning hard drive. Upgrading to an SSD is the single biggest speed boost possible." }
} catch {}

if ($ramGB -lt 8)    { Warn "Less than 8 GB RAM. Windows 11 + a browser feels slow below 8 GB; 16 GB is ideal." }
if ($freePct -lt 15) { Warn "Disk is almost full. Windows slows down badly under 15% free. Delete or move big files." }
if ($uptimeDays -gt 3) { Warn "PC has not been restarted in $uptimeDays days. A restart alone often helps a lot." }

Write-Host ""
Write-Host "    Top 10 programs using memory right now:" -ForegroundColor White
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 |
    ForEach-Object { "      {0,-35} {1,8:N0} MB" -f $_.ProcessName, ($_.WorkingSet64 / 1MB) } | Write-Host

Write-Host ""
Write-Host "    Programs that start automatically with Windows:" -ForegroundColor White
Get-CimInstance Win32_StartupCommand | Select-Object -ExpandProperty Name -Unique |
    ForEach-Object { "      - $_" } | Write-Host
Write-Host "    (Turn off the ones you don't need: Ctrl+Shift+Esc > Startup apps > right-click > Disable)" -ForegroundColor DarkGray

# ---------- 3. Virtual memory (pagefile) ----------
Step "Resetting virtual memory (pagefile) to System managed"
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
        Ok "Pagefile set to System managed (takes effect after restart)."
        $needsRestart = $true
    } else {
        Ok "Already System managed - nothing to change."
    }
} catch { Warn "Could not change pagefile: $($_.Exception.Message)" }

# ---------- 4. Memory compression ----------
Step "Checking memory compression"
try {
    if (-not (Get-MMAgent).MemoryCompression) {
        Enable-MMAgent -MemoryCompression -ErrorAction Stop
        Ok "Memory compression turned on (takes effect after restart)."
        $needsRestart = $true
    } else { Ok "Already on." }
} catch { Warn "Could not check memory compression: $($_.Exception.Message)" }

# ---------- 5. Temporary files ----------
Step "Deleting temporary junk files"
$tempFolders = @(
    $env:TEMP,
    "$env:SystemRoot\Temp",
    "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
    "$env:LOCALAPPDATA\CrashDumps"
)
$freedBytes = 0
foreach ($folder in $tempFolders) {
    if (Test-Path $folder) {
        Get-ChildItem -Path $folder -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
            ForEach-Object {
                $size = $_.Length
                try { Remove-Item $_.FullName -Force -ErrorAction Stop; $freedBytes += $size } catch {}
            }
    }
}
Ok ("Freed {0:N0} MB of temp files (files in use were skipped - that's normal)." -f ($freedBytes / 1MB))

if (Ask "Also empty the Recycle Bin?") {
    try { Clear-RecycleBin -Force -ErrorAction Stop; Ok "Recycle Bin emptied." }
    catch { Warn "Recycle Bin was already empty or could not be emptied." }
}

# ---------- 6. Power plan ----------
Step "Power plan"
$active = (powercfg /getactivescheme) -join ' '
Write-Host "    Current: $active"
$isLaptop = $null -ne (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$prompt = "Switch to High performance power plan?"
if ($isLaptop) { $prompt = "Laptop detected - High performance uses more battery. Switch anyway?" }
if (Ask $prompt) {
    $highPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    powercfg /setactive $highPerf 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Plan is hidden on many Windows 11 PCs - restore it, then activate the copy
        $out = powercfg /duplicatescheme $highPerf 2>$null
        if ($out -match '([0-9a-fA-F-]{36})') { powercfg /setactive $Matches[1] 2>$null }
    }
    if ($LASTEXITCODE -eq 0) { Ok "High performance plan active." }
    else { Warn "This PC doesn't offer High performance. Use Settings > System > Power > Power mode > Best performance." }
}

# ---------- 7. Drive optimization ----------
Step "Optimizing drive $($env:SystemDrive) (TRIM for SSD / defrag for HDD) - may take a few minutes"
try {
    Optimize-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
    Ok "Drive optimized."
} catch { Warn "Drive optimization skipped: $($_.Exception.Message)" }

# ---------- 8. Visual effects (optional) ----------
Step "Visual effects"
Write-Host "    Turning off animations/shadows makes older PCs feel snappier (text stays smooth)."
if (Ask "Turn off animations for speed?") {
    $vfx = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    if (-not (Test-Path $vfx)) { New-Item -Path $vfx -Force | Out-Null }
    Set-ItemProperty -Path $vfx -Name VisualFXSetting -Value 3 -Type DWord   # 3 = Custom
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name MinAnimate -Value '0'
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name TaskbarAnimations -Value 0 -Type DWord
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name MenuShowDelay -Value '100'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name FontSmoothing -Value '2'   # keep text smooth
    Ok "Animations reduced (fully applies after sign-out or restart)."
    Write-Host "    To undo: Win+R > sysdm.cpl > Advanced > Performance Settings > 'Let Windows choose'." -ForegroundColor DarkGray
    $needsRestart = $true
}

# ---------- Done ----------
Step "Finished"
Write-Host "    A full report was saved to: $logFile"
Write-Host "    To undo everything: Win+R > rstrui > pick 'Before Speed-Up-PC'."
Stop-Transcript | Out-Null

if ($needsRestart -or $uptimeDays -gt 3) {
    if (Ask "Restart now to apply everything? (save your work first)") { Restart-Computer -Force }
    else { Write-Host "    Please restart later to apply the changes." -ForegroundColor Yellow }
}
Read-Host "Press Enter to close"
