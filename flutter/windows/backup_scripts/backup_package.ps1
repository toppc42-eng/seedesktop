# Build SeeDesktop cloud backup zip: Rust data + Flutter path_provider folders (Windows).
# Requires PowerShell 5.1+ (built into Windows). No PowerShell 7.
param(
  [Parameter(Mandatory = $true)]
  [string]$DestinationZip
)

$ErrorActionPreference = "Stop"

# Must match Runner.rc CompanyName / ProductName (path_provider_windows).
$FlutterCompany = "Toppc"
$FlutterProduct = "SeeDesktop"

$stage = Join-Path $env:TEMP ("SeeDesktop_backup_stage_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
  $sdStage = Join-Path $stage "SeeDesktop"
  New-Item -ItemType Directory -Path $sdStage -Force | Out-Null
  $roamingCore = Join-Path $env:APPDATA "SeeDesktop"
  if (-not (Test-Path $roamingCore)) {
    throw "Data folder not found: $roamingCore"
  }
  & robocopy.exe $roamingCore $sdStage /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
  if ($LASTEXITCODE -ge 8) { throw "robocopy SeeDesktop failed (exit $LASTEXITCODE)" }

  # Address book (cloud AB store) is synced separately — exclude from cloud backup.
  $abFile = Join-Path $sdStage "SeeDesktop_ab"
  if (Test-Path $abFile) { Remove-Item -Path $abFile -Force }
  $abMergeFlag = Join-Path $sdStage "ab_restore_merge_pending"
  if (Test-Path $abMergeFlag) { Remove-Item -Path $abMergeFlag -Force }

  $flutterRoaming = Join-Path $env:APPDATA ($FlutterCompany + "\" + $FlutterProduct)
  if (Test-Path $flutterRoaming) {
    $fs = Join-Path $stage "FlutterSupport"
    New-Item -ItemType Directory -Path $fs -Force | Out-Null
    & robocopy.exe $flutterRoaming $fs /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "robocopy FlutterSupport failed (exit $LASTEXITCODE)" }
  }

  $flutterLocal = Join-Path $env:LOCALAPPDATA ($FlutterCompany + "\" + $FlutterProduct)
  if (Test-Path $flutterLocal) {
    $fl = Join-Path $stage "FlutterLocal"
    New-Item -ItemType Directory -Path $fl -Force | Out-Null
    & robocopy.exe $flutterLocal $fl /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "robocopy FlutterLocal failed (exit $LASTEXITCODE)" }
  }

  if (Test-Path $DestinationZip) { Remove-Item -Path $DestinationZip -Force }
  $dirs = Get-ChildItem -Path $stage -Directory
  if ($dirs.Count -eq 0) { throw "staging folder is empty" }
  Compress-Archive -Path ($dirs.FullName) -DestinationPath $DestinationZip -Force
}
finally {
  if (Test-Path $stage) { Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
