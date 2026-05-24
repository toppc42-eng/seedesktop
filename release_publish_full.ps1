param(
    [string]$Version = "",
    [string]$FlutterExe = "",
    [switch]$SkipUpload,
    [switch]$SkipCloudVerify,
    # Use existing flutter/build/windows/x64/runner/Release + bundled tools already copied there (skip cargo/flutter/pyinstaller).
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# PS 7+: native commands writing to stderr (pip notices, cargo progress) must not be treated as failures
# or pollute the process exit code at script end.
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# Suppress pip's stderr notices entirely — they trigger NativeCommandError on PS 5.1 and clutter logs.
$env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
$env:PYTHONIOENCODING = 'utf-8'

function Write-Step([string]$Text) {
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Validate-Version([string]$Value) {
    return $Value -match '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z\.-]+)?$'
}

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

function Get-CurrentVersion([string]$VersionRsPath) {
    $content = Get-Content -Path $VersionRsPath -Raw -Encoding UTF8
    $m = [regex]::Match($content, 'pub const VERSION: &str = "([^"]+)"')
    if (-not $m.Success) {
        throw "Could not read current version from: $VersionRsPath"
    }
    return $m.Groups[1].Value
}

function Get-AutoBumpedVersion([string]$CurrentVersion) {
    $parts = $CurrentVersion.Split(".")
    if ($parts.Length -lt 3) {
        throw "Cannot auto-bump non semver version: $CurrentVersion"
    }
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    $patch = [int]$parts[2]
    $patch += 1
    return "$major.$minor.$patch"
}

function Resolve-FlutterExe([string]$Requested) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if (-not (Test-Path $Requested)) {
            throw "Flutter executable not found: $Requested"
        }
        return $Requested
    }

    $commonPath = "C:\tools\flutter-3.24.5\bin\flutter.bat"
    if (Test-Path $commonPath) {
        return $commonPath
    }

    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return $cmd.Source
    }

    throw "Flutter executable not found. Pass -FlutterExe explicitly."
}

function Invoke-PyToolBuild {
    param(
        [Parameter(Mandatory = $true)][string]$ToolDirName,
        [Parameter(Mandatory = $true)][string]$ExeFileName
    )
    $toolDir = Join-Path $repoRoot "tools\$ToolDirName"
    $buildScript = Join-Path $toolDir "build_exe.ps1"
    if (-not (Test-Path $buildScript)) {
        Write-Host "Build script missing: $buildScript - skipping $ExeFileName" -ForegroundColor Yellow
        return
    }
    $procBase = [System.IO.Path]::GetFileNameWithoutExtension($ExeFileName)
    Stop-Process -Name $procBase -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $buildScript
        if ($LASTEXITCODE -ne 0) {
            throw "PyInstaller build failed ($ExeFileName) exit $LASTEXITCODE"
        }
    } finally {
        $ErrorActionPreference = $prevEa
    }
    $exePath = Join-Path $toolDir "dist\$ExeFileName"
    if (-not (Test-Path $exePath)) {
        throw "$ExeFileName not found: $exePath"
    }
    Copy-Item -Path $exePath -Destination $releaseDir -Force
    Write-Host "Copied $ExeFileName next to SeeDesktop.exe" -ForegroundColor Gray
}

function Remove-StaleZip([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    for ($zi = 0; $zi -lt 40; $zi++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    $aside = "$Path.old_" + (Get-Date -Format 'yyyyMMddHHmmss')
    Move-Item -LiteralPath $Path -Destination $aside -Force -ErrorAction Stop
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$flutterDir = Join-Path $repoRoot "flutter"
$cargoTomlPath = Join-Path $repoRoot "Cargo.toml"
$rustVersionPath = Join-Path $repoRoot "src\version.rs"
$pubspecPath = Join-Path $flutterDir "pubspec.yaml"
$releaseDir = Join-Path $flutterDir "build\windows\x64\runner\Release"
$zipOutput = Join-Path $repoRoot "SeeDesktopinst.zip"
$packageStagingDir = Join-Path $repoRoot "SeeDesktopinst_pkg"
$updateTemplatePrimary = Join-Path $repoRoot "SeeDesktopinst\update.bat"
$updateTemplateFallback = Join-Path $repoRoot "SeeDesktopinst_pkg\update.bat"
$publishScript = Join-Path $repoRoot "publish_update_from_build.py"
if (-not $SkipBuild) {
    $flutterExeResolved = Resolve-FlutterExe -Requested $FlutterExe
}

$currentVersion = Get-CurrentVersion -VersionRsPath $rustVersionPath
if ($SkipBuild) {
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = $currentVersion.Trim()
    }
    elseif ($Version.Trim() -ne $currentVersion.Trim()) {
        Write-Host "SkipBuild: using repo version $currentVersion (ignoring -Version '$Version')." -ForegroundColor Yellow
        $Version = $currentVersion.Trim()
    }
    else {
        $Version = $Version.Trim()
    }
}
elseif ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-AutoBumpedVersion -CurrentVersion $currentVersion
}

if (-not (Validate-Version $Version)) {
    throw "Invalid version format: $Version"
}

Write-Host "Current version: $currentVersion" -ForegroundColor Yellow
Write-Host "New version:     $Version" -ForegroundColor Yellow

if (-not $SkipBuild) {
    Write-Step "Updating version files"
    Update-FirstRegexMatch -Path $cargoTomlPath -Pattern '^version\s*=\s*"[^"]+"' -Replacement "version = `"$Version`""
    Update-FirstRegexMatch -Path $rustVersionPath -Pattern 'pub const VERSION: &str = "[^"]+";' -Replacement "pub const VERSION: &str = `"$Version`";"
    Update-FirstRegexMatch -Path $rustVersionPath -Pattern 'pub const BUILD_DATE: &str = "[^"]+";' -Replacement ("pub const BUILD_DATE: &str = `"" + (Get-Date -Format 'yyyy-MM-dd HH:mm') + "`";")
    Update-FirstRegexMatch -Path $pubspecPath -Pattern '^version:\s*[^\r\n]+' -Replacement "version: $Version+1"

    Write-Step "Closing running SeeDesktop process (if any)"
    $runningSeeDesktop = Get-Process -Name "SeeDesktop" -ErrorAction SilentlyContinue
    if ($null -ne $runningSeeDesktop) {
        $runningSeeDesktop | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Write-Step "Building Rust core (flutter release)"
# Use a stable isolated target dir so this pipeline does not block on `target/` locks from IDE/rust-analyzer/other cargo runs,
# but ALSO reuses the cargo incremental cache between releases. Without this, each release
# rebuilt the entire workspace from scratch (~5-7 min) and accumulated multi-GB stale dirs.
# Cleanup of stale timestamped dirs from earlier versions of this script:
$staleIsoDirs = Get-ChildItem -LiteralPath $repoRoot -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^target-publish-cloud-\d{14}$' }
foreach ($d in $staleIsoDirs) {
    Write-Host "Removing stale isolated build dir: $($d.Name)" -ForegroundColor DarkGray
    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
}
$rustIsoTargetDir = Join-Path $repoRoot "target-publish-cloud"
$canonicalReleaseDir = Join-Path $repoRoot "target\release"
# Native tools (cargo, flutter) write progress to stderr; with $ErrorActionPreference Stop that aborts the script.
$prevEa = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $repoRoot
try {
    cargo build --lib --features flutter --release --target-dir $rustIsoTargetDir
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
    cargo build -p seedesktop_backup_helper --release --target-dir $rustIsoTargetDir
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build seedesktop_backup_helper failed with exit code $LASTEXITCODE"
    }
    $isoRelease = Join-Path $rustIsoTargetDir "release"
    if (-not (Test-Path $isoRelease)) {
        throw "Isolated cargo output missing: $isoRelease"
    }
    New-Item -ItemType Directory -Force -Path $canonicalReleaseDir | Out-Null
    Copy-Item -Path (Join-Path $isoRelease '*') -Destination $canonicalReleaseDir -Recurse -Force
}
finally {
    Pop-Location
    $ErrorActionPreference = $prevEa
}

Write-Step "Building Flutter Windows release"
$prevEa = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $flutterDir
try {
    & $flutterExeResolved build windows --release
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
    $ErrorActionPreference = $prevEa
}

$releaseExe = Join-Path $releaseDir "SeeDesktop.exe"
if (-not (Test-Path $releaseExe)) {
    throw "Release exe not found: $releaseExe"
}

Write-Step "Building hw_helper (LibreHardwareMonitor) and copying next to SeeDesktop.exe"
$hwProj = Join-Path $repoRoot "hw_helper\hw_helper.csproj"
if (-not (Test-Path $hwProj)) {
    Write-Host "hw_helper.csproj not found; skipping." -ForegroundColor Yellow
} else {
    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        dotnet build $hwProj -c Release
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet build hw_helper failed with exit code $LASTEXITCODE"
        }
    } finally {
        $ErrorActionPreference = $prevEa
    }
    $hwOut = Join-Path $repoRoot "hw_helper\bin\Release\net10.0-windows"
    if (-not (Test-Path $hwOut)) {
        $hwOut = Join-Path $repoRoot "hw_helper\bin\Release\net8.0-windows"
    }
    Get-ChildItem -Path $hwOut -File | Copy-Item -Destination $releaseDir -Force
    $rt = Join-Path $hwOut "runtimes"
    if (Test-Path $rt) {
        $destRt = Join-Path $releaseDir "runtimes"
        if (Test-Path $destRt) { Remove-Item $destRt -Recurse -Force }
        Copy-Item -Path $rt -Destination $releaseDir -Recurse -Force
    }
}

Write-Step "Building bundled Python tools (PyInstaller)"
Invoke-PyToolBuild -ToolDirName "seedesktop_cleanup" -ExeFileName "SeeDesktopCleanup.exe"
Invoke-PyToolBuild -ToolDirName "seedesktop_disk_check" -ExeFileName "SeeDesktopDiskCheck.exe"
Invoke-PyToolBuild -ToolDirName "seedesktop_system_repair" -ExeFileName "SeeDesktopSystemRepair.exe"
Invoke-PyToolBuild -ToolDirName "ensure_admintools_godmode" -ExeFileName "SeeDesktopEnsureGodmode.exe"

}

if ($SkipBuild) {
    Write-Host "SkipBuild: verifying existing flutter Release bundle..." -ForegroundColor Cyan
    $releaseExeSkip = Join-Path $releaseDir "SeeDesktop.exe"
    if (-not (Test-Path $releaseExeSkip)) {
        throw "SkipBuild: Release exe not found: $releaseExeSkip"
    }
}

Write-Step "Preparing update package"
Remove-StaleZip $zipOutput
if (Test-Path $packageStagingDir) {
    try {
        Remove-Item -Path $packageStagingDir -Recurse -Force -ErrorAction Stop
    }
    catch {
        $stagingBak = "${packageStagingDir}_bak_$(Get-Date -Format 'yyyyMMddHHmmss')"
        Write-Host "Staging folder locked; renaming to $(Split-Path $stagingBak -Leaf)" -ForegroundColor Yellow
        if (Test-Path $stagingBak) {
            Remove-Item -Path $stagingBak -Recurse -Force -ErrorAction SilentlyContinue
        }
        Rename-Item -LiteralPath $packageStagingDir -NewName (Split-Path $stagingBak -Leaf) -Force
    }
}
New-Item -ItemType Directory -Path $packageStagingDir -Force | Out-Null
Copy-Item -Path (Join-Path $releaseDir "*") -Destination $packageStagingDir -Recurse -Force

# External IT tools: ship tools\extapps inside the ZIP so clients get e.g. TreeSize, GodMode launcher paths match PF install.
$extAppsSrc = Join-Path $repoRoot "tools\extapps"
$extAppsDest = Join-Path $packageStagingDir "tools\extapps"
if (Test-Path $extAppsSrc) {
    New-Item -ItemType Directory -Path $extAppsDest -Force | Out-Null
    Get-ChildItem -Path $extAppsSrc -Force | ForEach-Object { Copy-Item -Path $_.FullName -Destination $extAppsDest -Recurse -Force }
    Write-Host "Included tools\extapps in update package ($extAppsDest)." -ForegroundColor Gray
} else {
    Write-Host "WARNING: tools\extapps not found under repo - add EXEs there before publish, or external tools will be missing on clients." -ForegroundColor Yellow
}

$updateTemplate = ""
if (Test-Path $updateTemplatePrimary) {
    $updateTemplate = $updateTemplatePrimary
} elseif (Test-Path $updateTemplateFallback) {
    $updateTemplate = $updateTemplateFallback
}

if ([string]::IsNullOrWhiteSpace($updateTemplate)) {
    throw "Could not find update.bat template (checked SeeDesktopinst and SeeDesktopinst_pkg)."
}
Copy-Item -Path $updateTemplate -Destination (Join-Path $packageStagingDir "update.bat") -Force

Write-Step "Creating SeeDesktopinst.zip"
$zipTmp = Join-Path $repoRoot ("SeeDesktopinst_" + [guid]::NewGuid().ToString('N') + ".zip")
Compress-Archive -Path (Join-Path $packageStagingDir "*") -DestinationPath $zipTmp -Force
Remove-StaleZip $zipOutput
try {
    Move-Item -LiteralPath $zipTmp -Destination $zipOutput -Force -ErrorAction Stop
} catch {
    throw "ZIP created at $zipTmp but could not finalize $zipOutput - close apps locking the ZIP and retry. $($_.Exception.Message)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Build a standalone installer EXE alongside the update ZIP.
#
# The same staged Release bundle is wrapped by libs/portable so that when the
# user runs it the binary self-extracts and (because the file name ends with
# "install.exe") forwards `--install` to SeeDesktop.exe, which then:
#   - registers under HKLM\...\Uninstall\SeeDesktop (Apps & Features entry +
#     working UninstallString), and
#   - creates Desktop + Start Menu shortcuts (incl. an Uninstall shortcut).
#
# This file is built locally only and is NOT uploaded to the cloud (the cloud
# update flow keeps using SeeDesktopinst.zip).
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Building standalone installer EXE (libs/portable wrapper)"
$portableDir = Join-Path $repoRoot "libs\portable"
$portableGenerate = Join-Path $portableDir "generate.py"
$portableCargoToml = Join-Path $portableDir "Cargo.toml"
$installerOutputName = "SeeDesktop-$Version-install.exe"
$installerOutputPath = Join-Path $repoRoot $installerOutputName
if (-not (Test-Path $portableGenerate)) {
    Write-Host "libs/portable/generate.py missing - skipping installer EXE build." -ForegroundColor Yellow
} elseif (-not (Test-Path $portableCargoToml)) {
    Write-Host "libs/portable/Cargo.toml missing - skipping installer EXE build." -ForegroundColor Yellow
} else {
    $venvPython = Join-Path $repoRoot ".venv\Scripts\python.exe"
    $pythonCmd = if (Test-Path $venvPython) { $venvPython } else { "py" }

    # generate.py compresses every file in the staging dir into data.bin and
    # writes app_metadata.toml (timestamp) next to libs/portable/src so the
    # subsequent cargo build embeds them via include_bytes!.
    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # generate.py records the relative startup exe path inside data.bin;
        # we point it at SeeDesktop.exe in the staged bundle.
        & $pythonCmd $portableGenerate `
            -f $packageStagingDir `
            -o $portableDir `
            -e "SeeDesktop.exe" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "libs/portable/generate.py failed with exit code $LASTEXITCODE"
        }

        # generate.py invokes a final `cargo build --release`. libs/portable is
        # a member of the root workspace, so the EXE actually lands in the
        # workspace target dir (target/release), not under libs/portable/target.
        # Search both locations to be robust against future Cargo.toml changes.
        $packerCandidates = @(
            (Join-Path $repoRoot "target\release\rustdesk-portable-packer.exe"),
            (Join-Path $portableDir "target\release\rustdesk-portable-packer.exe")
        )
        $packerExe = $packerCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $packerExe) {
            Push-Location $portableDir
            try {
                cargo build --release
                if ($LASTEXITCODE -ne 0) {
                    throw "cargo build (libs/portable) failed with exit code $LASTEXITCODE"
                }
            } finally {
                Pop-Location
            }
            $packerExe = $packerCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        if (-not $packerExe) {
            throw "Portable packer EXE missing after build. Searched: $($packerCandidates -join '; ')"
        }

        if (Test-Path $installerOutputPath) {
            Remove-Item -LiteralPath $installerOutputPath -Force -ErrorAction Stop
        }
        Copy-Item -LiteralPath $packerExe -Destination $installerOutputPath -Force
        Write-Host "Installer EXE: $installerOutputPath" -ForegroundColor Green
    } finally {
        $ErrorActionPreference = $prevEa
    }
}

if ($SkipUpload) {
    Write-Host "Done. Build + package + installer complete. Upload skipped by switch." -ForegroundColor Green
    exit 0
}

if (-not (Test-Path $publishScript)) {
    throw "Publish helper not found: $publishScript"
}

Write-Step "Uploading ZIP + version.json to Google Cloud"
$venvPython = Join-Path $repoRoot ".venv\Scripts\python.exe"
$prevEa = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $repoRoot
try {
    if (Test-Path $venvPython) {
        # Merge stderr -> stdout so pip notices don't appear as PowerShell errors (PS 5.1 NativeCommandError).
        & $venvPython -m pip install -q google-cloud-storage 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "pip install google-cloud-storage failed with exit code $LASTEXITCODE"
        }
        & $venvPython "$publishScript" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "publish_update_from_build.py failed with exit code $LASTEXITCODE"
        }
    } else {
        py "$publishScript" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "publish_update_from_build.py failed with exit code $LASTEXITCODE"
        }
    }
}
finally {
    Pop-Location
    $ErrorActionPreference = $prevEa
}

if ($SkipCloudVerify) {
    Write-Host "Done. Upload complete. Cloud verification skipped by switch." -ForegroundColor Green
    exit 0
}

$versionJsonUrl = "https://storage.googleapis.com/my-saas-uploads-2025/seedesktop/updates/version.json"
$downloadUrl = "https://storage.googleapis.com/my-saas-uploads-2025/seedesktop/updates/SeeDesktopinst.zip"
$maxAttempts = 20
$delaySeconds = 4
$cloudReady = $false
$versionExpected = [string]$Version.Trim()

Write-Step 'Verifying cloud propagation (version.json is authoritative; ZIP HEAD is optional)'
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        $versionJsonUrlWithNonce = "$versionJsonUrl`?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        $json = Invoke-RestMethod -Uri $versionJsonUrlWithNonce -TimeoutSec 20 -Headers @{ "Cache-Control" = "no-cache" }
        $verRemote = [string]$json.latest_version
        if ($verRemote.Trim() -ne $versionExpected) {
            Write-Host "Cloud not ready yet ($attempt/$maxAttempts). latest_version=$verRemote expected=$versionExpected" -ForegroundColor Yellow
            Start-Sleep -Seconds $delaySeconds
            continue
        }
        # Do not fail the whole step if HEAD on ZIP fails (403, redirects, etc.) - clients use JSON + GET.
        try {
            $head = Invoke-WebRequest -Uri $downloadUrl -Method Head -UseBasicParsing -TimeoutSec 20
            if ($head.StatusCode -ne 200) {
                Write-Host ('Note: ZIP HEAD returned ' + [string]$head.StatusCode + '; version.json already matches.') -ForegroundColor DarkYellow
            }
        }
        catch {
            Write-Host "Note: ZIP HEAD not verified (non-fatal): $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        $cloudReady = $true
        break
    }
    catch {
        Write-Host "Cloud check failed ($attempt/$maxAttempts): $($_.Exception.Message)" -ForegroundColor Yellow
        Start-Sleep -Seconds $delaySeconds
    }
}

if (-not $cloudReady) {
    throw "Upload completed but cloud verification timed out. Check: $versionJsonUrl"
}

Write-Host "SUCCESS: version $Version build upload verification complete." -ForegroundColor Green
exit 0
