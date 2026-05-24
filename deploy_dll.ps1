$src = "c:\seedesktop\see-desk\target\release\librustdesk.dll"
$dst = "C:\Program Files\SeeDesktop\librustdesk.dll"

Write-Host "Stopping SeeDesktop service..." -ForegroundColor Cyan
Stop-Service -Name "SeeDesktop" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Write-Host "Deploying $src -> $dst" -ForegroundColor Cyan
Copy-Item $src $dst -Force
Write-Host "  Deployed. Size: $((Get-Item $dst).Length) bytes, Time: $((Get-Item $dst).LastWriteTime)" -ForegroundColor Green

Write-Host "Starting SeeDesktop service..." -ForegroundColor Cyan
Start-Service -Name "SeeDesktop"
Start-Sleep -Seconds 2
$svc = Get-Service -Name "SeeDesktop" -ErrorAction SilentlyContinue
Write-Host "  Service status: $($svc.Status)" -ForegroundColor Green
