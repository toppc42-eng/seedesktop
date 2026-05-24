@echo off
setlocal EnableExtensions
REM Manual test for SeeDesktop_OTA_Silent_Daily (same schtasks flow as the app).
REM Usage: test_ota_scheduled_task.bat [HH:MM]
REM Example: test_ota_scheduled_task.bat 13:00

set "ST=%~1"
if "%ST%"=="" set "ST=16:00"

set "EXE=%~dp0..\SeeDesktopinst\SeeDesktop.exe"
if not exist "%EXE%" (
  echo SeeDesktop.exe not found: "%EXE%"
  exit /b 1
)

set "TR=""%EXE%"" --ota-silent-scheduled"
set "TN=SeeDesktop_OTA_Silent_Daily"

echo Delete existing task (ignore errors)...
%SystemRoot%\System32\schtasks.exe /Delete /TN "%TN%" /F 2>nul

echo Create task at %ST% ...
%SystemRoot%\System32\schtasks.exe /Create /TN "%TN%" /TR %TR% /SC DAILY /ST %ST% /RU SYSTEM /RL HIGHEST /F
if errorlevel 1 exit /b 1

echo Query:
%SystemRoot%\System32\schtasks.exe /Query /TN "%TN%" /FO LIST /V
exit /b 0
