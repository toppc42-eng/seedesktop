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
    --onefile --console --name SeeDesktopEnsureGodmode `
    --paths "$PSScriptRoot" `
    "$PSScriptRoot\app_entry.py"

$out = Join-Path $PSScriptRoot "dist\SeeDesktopEnsureGodmode.exe"
if (-not (Test-Path $out)) {
    throw "Build failed: $out not found"
}
Write-Host "OK: $out" -ForegroundColor Green
