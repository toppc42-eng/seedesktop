$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$flutterDir = Join-Path $repoRoot "flutter"
$flutterExe = "C:\tools\flutter-3.24.5\bin\flutter.bat"
$cargoTomlPath = Join-Path $repoRoot "Cargo.toml"
$rustVersionPath = Join-Path $repoRoot "src\version.rs"
$pubspecPath = Join-Path $flutterDir "pubspec.yaml"

if (-not (Test-Path $flutterExe)) {
    throw "Flutter executable not found at: $flutterExe"
}

Add-Type -AssemblyName Microsoft.VisualBasic

function Update-FirstRegexMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement
    )
    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    if (-not [System.Text.RegularExpressions.Regex]::IsMatch($content, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
        throw "Could not find version pattern in: $Path"
    }
    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $content,
        $Pattern,
        $Replacement,
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )
    [System.IO.File]::WriteAllText($Path, $updated, [System.Text.UTF8Encoding]::new($false))
}

function Validate-Version([string]$Version) {
    return $Version -match '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z\.-]+)?$'
}

$currentVersion = "unknown"
if (Test-Path $rustVersionPath) {
    $rustVersionContent = Get-Content -Path $rustVersionPath -Raw -Encoding UTF8
    $m = [regex]::Match($rustVersionContent, 'pub const VERSION: &str = "([^"]+)"')
    if ($m.Success) {
        $currentVersion = $m.Groups[1].Value
    }
}

$newVersion = [Microsoft.VisualBasic.Interaction]::InputBox(
    "Current version: $currentVersion`r`nEnter new version (example: 1.5.0):",
    "SeeDesktop Rebuild - Version Update",
    $currentVersion
)

if ([string]::IsNullOrWhiteSpace($newVersion)) {
    throw "Version input was cancelled."
}

$newVersion = $newVersion.Trim()
if (-not (Validate-Version $newVersion)) {
    throw "Invalid version format: $newVersion"
}

Write-Host "==> Updating project version to $newVersion..." -ForegroundColor Cyan
Update-FirstRegexMatch -Path $cargoTomlPath -Pattern '^version\s*=\s*"[^"]+"' -Replacement "version = `"$newVersion`""
Update-FirstRegexMatch -Path $rustVersionPath -Pattern 'pub const VERSION: &str = "[^"]+";' -Replacement "pub const VERSION: &str = `"$newVersion`";"
Update-FirstRegexMatch -Path $rustVersionPath -Pattern 'pub const BUILD_DATE: &str = "[^"]+";' -Replacement ("pub const BUILD_DATE: &str = `"" + (Get-Date -Format 'yyyy-MM-dd HH:mm') + "`";")
Update-FirstRegexMatch -Path $pubspecPath -Pattern '^version:\s*[^\r\n]+' -Replacement "version: $newVersion+1"

Write-Host "==> Closing running SeeDesktop process (if any)..." -ForegroundColor Cyan
$runningSeeDesktop = Get-Process -Name "SeeDesktop" -ErrorAction SilentlyContinue
if ($null -ne $runningSeeDesktop) {
    $runningSeeDesktop | Stop-Process -Force -ErrorAction SilentlyContinue
}

Write-Host "==> Building Rust core library (flutter release)..." -ForegroundColor Cyan
Push-Location $repoRoot
try {
    cargo build --lib --features flutter --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build --lib failed with exit code $LASTEXITCODE"
    }
    cargo build -p seedesktop_backup_helper --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build seedesktop_backup_helper failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

Write-Host "==> Building Flutter Windows release..." -ForegroundColor Cyan
Push-Location $flutterDir
try {
    & $flutterExe build windows --release
}
finally {
    Pop-Location
}

$releaseExe = Join-Path $flutterDir "build\windows\x64\runner\Release\SeeDesktop.exe"
if (Test-Path $releaseExe) {
    Write-Host "==> Build succeeded: $releaseExe (version $newVersion)" -ForegroundColor Green
} else {
    throw "Build finished but release exe was not found: $releaseExe"
}

$releaseDir = Join-Path $flutterDir "build\windows\x64\runner\Release"
$zipOutput = Join-Path $repoRoot "SeeDesktopinst.zip"
$updateScriptTemplate = Join-Path $repoRoot "SeeDesktopinst\update.bat"
$packageStagingDir = Join-Path $repoRoot "SeeDesktopinst_pkg"
if (-not (Test-Path $releaseDir)) {
    throw "Release directory not found: $releaseDir"
}
if (-not (Test-Path $updateScriptTemplate)) {
    throw "Missing updater script template: $updateScriptTemplate"
}

$godBuild = Join-Path $repoRoot "tools\ensure_admintools_godmode\build_exe.ps1"
$godExeDist = Join-Path $repoRoot "tools\ensure_admintools_godmode\dist\SeeDesktopEnsureGodmode.exe"
if (Test-Path $godBuild) {
    Write-Host "==> Building SeeDesktopEnsureGodmode.exe (PyInstaller)..." -ForegroundColor Cyan
    & powershell -NoProfile -ExecutionPolicy Bypass -File $godBuild
    if ($LASTEXITCODE -ne 0) {
        throw "SeeDesktopEnsureGodmode PyInstaller build failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path $godExeDist)) {
        throw "SeeDesktopEnsureGodmode.exe not found after build: $godExeDist"
    }
    Copy-Item -Path $godExeDist -Destination $releaseDir -Force
    Write-Host "==> Copied SeeDesktopEnsureGodmode.exe next to SeeDesktop.exe" -ForegroundColor Gray
} else {
    Write-Host "==> WARNING: tools\ensure_admintools_godmode\build_exe.ps1 missing — ZIP will use mkdir fallback only for God Mode folder." -ForegroundColor Yellow
}

if (Test-Path $zipOutput) {
    Remove-Item -Path $zipOutput -Force
}
if (Test-Path $packageStagingDir) {
    Remove-Item -Path $packageStagingDir -Recurse -Force
}

Write-Host "==> Preparing update package staging directory..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $packageStagingDir | Out-Null
Copy-Item -Path (Join-Path $releaseDir "*") -Destination $packageStagingDir -Recurse -Force
Copy-Item -Path $updateScriptTemplate -Destination (Join-Path $packageStagingDir "update.bat") -Force

$extAppsSrc = Join-Path $repoRoot "tools\extapps"
$extAppsDest = Join-Path $packageStagingDir "tools\extapps"
if (Test-Path $extAppsSrc) {
    New-Item -ItemType Directory -Path $extAppsDest -Force | Out-Null
    Get-ChildItem -Path $extAppsSrc -Force | ForEach-Object { Copy-Item -Path $_.FullName -Destination $extAppsDest -Recurse -Force }
    Write-Host "==> Included tools\extapps in update package." -ForegroundColor Gray
} else {
    Write-Host "==> WARNING: tools\extapps missing — external tools will not be in the ZIP." -ForegroundColor Yellow
}

Write-Host "==> Compressing staged update package to: $zipOutput" -ForegroundColor Cyan
Compress-Archive -Path (Join-Path $packageStagingDir "*") -DestinationPath $zipOutput -Force
Write-Host "==> ZIP created successfully: $zipOutput" -ForegroundColor Green

$publishScript = Join-Path $repoRoot "publish_update_from_build.py"
if (-not (Test-Path $publishScript)) {
    throw "Publish helper not found: $publishScript"
}

Write-Host "==> Uploading ZIP + version.json to cloud update server..." -ForegroundColor Cyan
Push-Location $repoRoot
try {
    py "$publishScript"
}
finally {
    Pop-Location
}

$versionJsonUrl = "https://storage.googleapis.com/my-saas-uploads-2025/seedesktop/updates/version.json"
$downloadUrl = "https://storage.googleapis.com/my-saas-uploads-2025/seedesktop/updates/SeeDesktopinst.zip"
$maxAttempts = 20
$delaySeconds = 4
$cloudReady = $false
$versionExpected = [string]$newVersion.Trim()

Write-Host "==> Waiting for version.json on cloud (ZIP HEAD optional)..." -ForegroundColor Cyan
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        $versionJsonUrlWithNonce = "$versionJsonUrl`?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        $json = Invoke-RestMethod -Uri $versionJsonUrlWithNonce -TimeoutSec 20 -Headers @{ "Cache-Control" = "no-cache" }
        $verRemote = [string]$json.latest_version
        if ($verRemote.Trim() -ne $versionExpected) {
            Write-Host "==> Cloud not ready yet ($attempt/$maxAttempts). latest_version=$verRemote expected=$versionExpected" -ForegroundColor Yellow
            Start-Sleep -Seconds $delaySeconds
            continue
        }
        try {
            $head = Invoke-WebRequest -Uri $downloadUrl -Method Head -UseBasicParsing -TimeoutSec 20
            if ($head.StatusCode -ne 200) {
                Write-Host "==> Note: ZIP HEAD status $($head.StatusCode); version.json matches." -ForegroundColor DarkYellow
            }
        }
        catch {
            Write-Host "==> Note: ZIP HEAD not verified (non-fatal): $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        $cloudReady = $true
        break
    }
    catch {
        Write-Host "==> Cloud check failed ($attempt/$maxAttempts): $($_.Exception.Message)" -ForegroundColor Yellow
        Start-Sleep -Seconds $delaySeconds
    }
}

if (-not $cloudReady) {
    throw "Build/upload finished, but cloud verification timed out. Check: $versionJsonUrl"
}

Write-Host "==> Cloud upload verified. Version $newVersion is downloadable." -ForegroundColor Green