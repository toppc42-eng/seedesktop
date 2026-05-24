$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'SystemCleanup_GUI.ps1'),
    [ref]$null,
    [ref]$errs
)
if ($errs) { $errs | ForEach-Object { $_.ToString() } }
else { 'Parse OK' }
