@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

REM Close SeeDesktop so log/config files are not locked (Compress-Archive cannot read open files).
taskkill /F /IM SeeDesktop.exe >nul 2>&1
timeout /t 2 /nobreak >nul

set "EMAIL=%~1"
set "APIBASE=%~2"
if "%EMAIL%"=="" set "EMAIL=%SEEDESKTOP_USER_EMAIL%"
if "%EMAIL%"=="" (
  echo ERROR: Provide email as first argument or set SEEDESKTOP_USER_EMAIL
  exit /b 1
)

if not exist "%~dp0seedesktop_backup_helper.exe" (
  echo ERROR: seedesktop_backup_helper.exe not found next to SeeDesktop.exe
  exit /b 1
)

set "DATA=%APPDATA%\SeeDesktop"
if not exist "%DATA%" (
  echo ERROR: Data folder not found: %DATA%
  exit /b 1
)

set "TMPZIP=%TEMP%\SeeDesktop_backup_%RANDOM%%RANDOM%.zip"
if exist "%TMPZIP%" del /f /q "%TMPZIP%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_package.ps1" -DestinationZip "%TMPZIP%"
if errorlevel 1 (
  echo ERROR: Failed to create backup zip
  if exist "%~dp0SeeDesktop.exe" start "" "%~dp0SeeDesktop.exe"
  exit /b 1
)

"%~dp0seedesktop_backup_helper.exe" upload "%EMAIL%" "%TMPZIP%" "%APIBASE%"
set ERR=!ERRORLEVEL!

:done_script
del /f /q "%TMPZIP%" 2>nul
REM Always bring the app back after zip+upload attempt (success or failure).
if exist "%~dp0SeeDesktop.exe" start "" "%~dp0SeeDesktop.exe"
exit /b !ERR!
