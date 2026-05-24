@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "EMAIL=%~1"
set "STAMP=%~2"
set "APIBASE=%~3"
if "%EMAIL%"=="" set "EMAIL=%SEEDESKTOP_USER_EMAIL%"
if "%EMAIL%"=="" (
  echo ERROR: Provide email as first argument or set SEEDESKTOP_USER_EMAIL
  exit /b 1
)
if "%STAMP%"=="" (
  echo ERROR: Provide backup stamp as second argument ^(YYYYMMDD_HHMMSS^)
  exit /b 1
)

if not exist "%~dp0seedesktop_backup_helper.exe" (
  echo ERROR: seedesktop_backup_helper.exe not found next to SeeDesktop.exe
  exit /b 1
)

"%~dp0seedesktop_backup_helper.exe" restore "%EMAIL%" "%STAMP%" "%APIBASE%"
if errorlevel 1 exit /b 1
REM Fallback if the helper could not spawn the GUI reliably
timeout /t 2 /nobreak >nul
if exist "%~dp0SeeDesktop.exe" start "" /D "%~dp0" "%~dp0SeeDesktop.exe"
exit /b 0
