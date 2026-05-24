@echo off
setlocal EnableExtensions
cd /d "%~dp0"

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

"%~dp0seedesktop_backup_helper.exe" list-json "%EMAIL%" "%APIBASE%"
exit /b %ERRORLEVEL%
