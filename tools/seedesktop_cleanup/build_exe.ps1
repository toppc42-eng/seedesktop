$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$py = Get-Command py -ErrorAction SilentlyContinue
if ($null -eq $py) {
    $py = Get-Command python -ErrorAction SilentlyContinue
}
if ($null -eq $py) {
    throw "Python not found (py or python)."
}

& $py.Source -m pip install -q -r requirements.txt
& $py.Source -m PyInstaller --noconfirm --clean `
    --onefile --windowed --uac-admin --name SeeDesktopCleanup `
    --paths "$PSScriptRoot" `
    "$PSScriptRoot\app_entry.py"

$out = Join-Path $PSScriptRoot "dist\SeeDesktopCleanup.exe"
if (-not (Test-Path $out)) {
    throw "Build failed: $out not found"
}
Write-Host "OK: $out" -ForegroundColor Green
