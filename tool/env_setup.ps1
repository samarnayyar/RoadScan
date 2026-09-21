<#
    RoadScan -- put the toolchain on PATH for future terminals.

        powershell -ExecutionPolicy Bypass -File tool\env_setup.ps1
        powershell -ExecutionPolicy Bypass -File tool\env_setup.ps1 -DevRoot D:\dev

    Sets, for the CURRENT USER only (never machine-wide, so no admin rights are
    needed and nothing outside this account is touched):

        JAVA_HOME     -> the JDK sdkmanager and Gradle both need
        ANDROID_HOME  -> <DevRoot>\android-sdk
        PATH          += flutter\bin, android-sdk\platform-tools,
                         android-sdk\cmdline-tools\latest\bin

    -DevRoot picks WHICH drive the toolchain lives under -- this project has
    been built on more than one machine, and the toolchain root moves with it
    (D:\dev when C: was nearly full, C:\dev when it wasn't). Without a param
    here, this script would silently point PATH at a drive that doesn't exist
    on whichever machine it's next run on, and every tool would quietly
    resolve to nothing.

    Default: the first of C:\dev, D:\dev that actually has a flutter\bin in
    it, so re-running this on the machine that set it up is a no-op. Pass
    -DevRoot explicitly on a fresh machine before the toolchain exists yet.

    To undo: run this with -Revert, or edit them out via
    System Properties -> Environment Variables -> User variables.
#>

param(
    [string]$DevRoot,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'

if (-not $DevRoot) {
    $candidate = @('C:\dev', 'D:\dev') | Where-Object { Test-Path "$_\flutter\bin\flutter.bat" } | Select-Object -First 1
    if (-not $candidate) {
        Write-Host "No flutter\bin found under C:\dev or D:\dev." -ForegroundColor Red
        Write-Host "Pass -DevRoot <path> pointing at the directory that contains flutter\ and android-sdk\."
        exit 1
    }
    $DevRoot = $candidate
}
Write-Host "Using DevRoot = $DevRoot" -ForegroundColor Cyan

$flutterBin  = "$DevRoot\flutter\bin"
$androidHome = "$DevRoot\android-sdk"
$platformTools = "$androidHome\platform-tools"
$cmdlineTools  = "$androidHome\cmdline-tools\latest\bin"
$wanted = @($flutterBin, $platformTools, $cmdlineTools)

function Get-UserPath {
    [Environment]::GetEnvironmentVariable('Path', 'User')
}

if ($Revert) {
    $current = (Get-UserPath) -split ';' | Where-Object { $_ -and ($wanted -notcontains $_) }
    [Environment]::SetEnvironmentVariable('Path', ($current -join ';'), 'User')
    [Environment]::SetEnvironmentVariable('ANDROID_HOME', $null, 'User')
    Write-Host "Reverted. JAVA_HOME left alone (other tools may rely on it)." -ForegroundColor Yellow
    exit 0
}

# --- JDK ------------------------------------------------------------------
# Gradle is particular about JDK versions. 17 is the safe choice for current
# Android Gradle Plugin releases; 21 also works, but 8/11 will fail the build.
$jdk = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -match 'jdk-(17|21)' } |
       Sort-Object Name -Descending | Select-Object -First 1

if ($jdk) {
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk.FullName, 'User')
    Write-Host "JAVA_HOME = $($jdk.FullName)" -ForegroundColor Green
} else {
    Write-Host "No Adoptium JDK 17/21 found -- leaving JAVA_HOME as-is." -ForegroundColor Yellow
}

# --- ANDROID_HOME ---------------------------------------------------------
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $androidHome, 'User')
Write-Host "ANDROID_HOME = $androidHome" -ForegroundColor Green

# --- PATH -----------------------------------------------------------------
# Read/modify/write rather than appending blindly: re-running this script
# should be a no-op, not a way to accumulate duplicate PATH entries.
$existing = (Get-UserPath) -split ';' | Where-Object { $_ }
$added = @()
foreach ($dir in $wanted) {
    if ($existing -notcontains $dir) {
        $existing += $dir
        $added += $dir
    }
}
[Environment]::SetEnvironmentVariable('Path', ($existing -join ';'), 'User')

if ($added.Count -gt 0) {
    Write-Host "Added to PATH:" -ForegroundColor Green
    $added | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "PATH already had everything." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Open a NEW terminal for these to take effect, then run: flutter doctor" -ForegroundColor Cyan
