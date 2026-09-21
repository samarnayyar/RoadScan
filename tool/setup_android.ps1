<#
    RoadScan -- generate the Android platform scaffold and patch it.

        powershell -ExecutionPolicy Bypass -File tool\setup_android.ps1

    Run this ONCE, after installing Flutter and before the first build.

    Why a script instead of "just run flutter create ."
    ---------------------------------------------------
    Running `flutter create .` inside this directory can clobber lib/main.dart
    and pubspec.yaml, which are hand-written here. So we generate a throwaway
    project elsewhere and copy only the platform folder across. Nothing under
    lib/, test/, ml/ or supabase/ is touched.
#>

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1's `Set-Content -Encoding UTF8` writes a UTF-8 BOM.
# Gradle's Kotlin DSL parser and some XML tooling choke on a BOM at the start
# of the first line, so every file this script rewrites must go through here.
function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

$root = Split-Path -Parent $PSScriptRoot
Write-Host "RoadScan project: $root" -ForegroundColor Cyan

# --- 1. Toolchain check ----------------------------------------------------
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    Write-Host ""
    Write-Host "Flutter is not on PATH." -ForegroundColor Red
    Write-Host "Install it first:  https://docs.flutter.dev/get-started/install/windows"
    Write-Host "Then reopen the terminal and re-run this script."
    exit 1
}
Write-Host "flutter: $($flutter.Source)" -ForegroundColor Green

# --- 2. Generate the platform scaffold -------------------------------------
$androidDir = Join-Path $root 'android'
if (Test-Path $androidDir) {
    Write-Host "android/ already exists -- skipping generation." -ForegroundColor Yellow
} else {
    $temp = Join-Path $env:TEMP "roadscan_scaffold_$(Get-Random)"
    Write-Host "Generating scaffold in $temp ..."

    & flutter create --org com.roadscan --project-name roadscan --platforms=android $temp
    if ($LASTEXITCODE -ne 0) { throw "flutter create failed" }

    Copy-Item (Join-Path $temp 'android') $androidDir -Recurse
    foreach ($f in @('.metadata', '.gitignore')) {
        $src = Join-Path $temp $f
        $dst = Join-Path $root $f
        if ((Test-Path $src) -and -not (Test-Path $dst)) { Copy-Item $src $dst }
    }
    Remove-Item $temp -Recurse -Force
    Write-Host "android/ created." -ForegroundColor Green
}

# --- 3. Patch the manifest with the permissions RoadScan needs --------------
$manifest = Join-Path $androidDir 'app\src\main\AndroidManifest.xml'
if (-not (Test-Path $manifest)) { throw "manifest not found at $manifest" }

$xml = Get-Content $manifest -Raw

$permissions = @(
    @{ n = 'android.permission.INTERNET';                c = 'map tiles, Supabase' },
    @{ n = 'android.permission.ACCESS_FINE_LOCATION';    c = 'pin a report to a place; 20m dedup needs GPS-grade accuracy' },
    @{ n = 'android.permission.ACCESS_COARSE_LOCATION';  c = 'fallback if fine location is denied' },
    @{ n = 'android.permission.CAMERA';                  c = 'photograph the hazard' },
    @{ n = 'android.permission.POST_NOTIFICATIONS';      c = 'proximity alerts (Android 13+)' }
)

$added = 0
$block = ""
foreach ($p in $permissions) {
    if ($xml -notmatch [regex]::Escape($p.n)) {
        $block += "    <!-- $($p.c) -->`r`n"
        $block += "    <uses-permission android:name=""$($p.n)"" />`r`n"
        $added++
    }
}

# NOTE: ACCESS_BACKGROUND_LOCATION is deliberately NOT requested. RoadScan
# alerts only while the app is in the foreground; asking for the background
# grant we do not use would trigger a Play Store policy review for nothing.

if ($added -gt 0) {
    $xml = $xml -replace '(<manifest[^>]*>)', "`$1`r`n$block"
    Write-Utf8NoBom $manifest $xml
    Write-Host "Added $added permission(s) to the manifest." -ForegroundColor Green
} else {
    Write-Host "Manifest already has every permission." -ForegroundColor Yellow
}

# --- 4. Raise minSdk -------------------------------------------------------
# LiteRT inference and the notification APIs used here need 26. Below that the
# build succeeds and then fails at runtime on the first predict() call, which
# is a miserable thing to debug.
$gradle = Join-Path $androidDir 'app\build.gradle.kts'
if (-not (Test-Path $gradle)) { $gradle = Join-Path $androidDir 'app\build.gradle' }

if (Test-Path $gradle) {
    $g = Get-Content $gradle -Raw
    $before = $g
    $g = $g -replace 'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 26'
    $g = $g -replace 'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 26'
    # Flutter 3.47.4's template declares the Kotlin plugin in
    # settings.gradle.kts but never applies it in the app module, while still
    # emitting a kotlin { compilerOptions { ... } } block. That combination
    # fails to compile with "Unresolved reference 'compilerOptions'". Apply the
    # plugin so the template's own block resolves.
    if ($g -notmatch 'org\.jetbrains\.kotlin\.android') {
        $g = $g -replace '(plugins\s*\{\s*\r?\n\s*id\("com\.android\.application"\)\r?\n)',
                         "`$1    id(`"org.jetbrains.kotlin.android`")`r`n"
    }

    # flutter_local_notifications calls java.time APIs that do not exist below
    # Android 8, so the app module must enable core library desugaring or the
    # build dies at :app:checkDebugAarMetadata.
    if ($g -notmatch 'isCoreLibraryDesugaringEnabled') {
        $g = $g -replace '(compileOptions\s*\{\s*\r?\n)',
                         "`$1        isCoreLibraryDesugaringEnabled = true`r`n"
    }
    if ($g -notmatch 'coreLibraryDesugaring\(') {
        $desugar = @"
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
"@
        $g = $g -replace '(?m)^flutter \{', $desugar
    }

    if ($g -ne $before) {
        Write-Utf8NoBom $gradle $g
        Write-Host "Patched $(Split-Path -Leaf $gradle) (minSdk 26, Kotlin plugin, desugaring)." -ForegroundColor Green
    } else {
        Write-Host "Gradle file already patched." -ForegroundColor Yellow
    }
}

# --- 5. Assets + dependencies ---------------------------------------------
$models = Join-Path $root 'assets\models'
if (-not (Test-Path $models)) {
    New-Item -ItemType Directory -Path $models -Force | Out-Null
    Set-Content (Join-Path $models '.gitkeep') '' -Encoding UTF8
}

Write-Host ""
Write-Host "Fetching packages ..."
Push-Location $root
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Create a Supabase project, then run supabase/schema.sql in its SQL editor."
Write-Host "  2. flutter test              # severity + decay logic, no device needed"
Write-Host "  3. flutter run --dart-define=SUPABASE_URL=https://xxx.supabase.co \"
Write-Host "                 --dart-define=SUPABASE_ANON_KEY=eyJ..."
