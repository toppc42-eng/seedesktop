@echo off
setlocal EnableExtensions

REM Auto update flow:
REM 1) Read version.json from server
REM 2) Download package from download_url
REM 3) If ZIP -> extract and find installer
REM 4) Run update_seedesktop.bat (uninstall then install)

set "SCRIPT_DIR=%~dp0"
set "UPDATE_SCRIPT=%SCRIPT_DIR%update_seedesktop.bat"
set "VERSION_JSON_URL=https://storage.googleapis.com/my-saas-uploads-2025/seedesktop/updates/version.json"
set "TEMP_ROOT=%TEMP%\SeeDesktopUpdate"
set "TEMP_JSON=%TEMP_ROOT%\version.json"
set "TEMP_PACKAGE=%TEMP_ROOT%\package.bin"
set "TEMP_EXTRACT=%TEMP_ROOT%\extract"
set "DOWNLOAD_URL="
set "INSTALLER_PATH="

if not exist "%UPDATE_SCRIPT%" (
  echo Missing file: %UPDATE_SCRIPT%
  exit /b 1
)

if not exist "%TEMP_ROOT%" mkdir "%TEMP_ROOT%" >nul 2>&1
if exist "%TEMP_JSON%" del /f /q "%TEMP_JSON%" >nul 2>&1
if exist "%TEMP_PACKAGE%" del /f /q "%TEMP_PACKAGE%" >nul 2>&1
if exist "%TEMP_EXTRACT%" rmdir /s /q "%TEMP_EXTRACT%" >nul 2>&1

echo [1/5] Downloading version.json...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-WebRequest -Uri '%VERSION_JSON_URL%' -UseBasicParsing -OutFile '%TEMP_JSON%'; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
  echo Failed to download version.json
  exit /b 1
)

for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$j = Get-Content -Raw '%TEMP_JSON%' | ConvertFrom-Json; if ($j.download_url) { $j.download_url }"`) do (
  set "DOWNLOAD_URL=%%I"
)

if "%DOWNLOAD_URL%"=="" (
  echo download_url not found in version.json
  exit /b 1
)

echo [2/5] Downloading package...
echo URL: %DOWNLOAD_URL%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -UseBasicParsing -OutFile '%TEMP_PACKAGE%'; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
  echo Failed to download update package.
  exit /b 1
)

for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$u='%DOWNLOAD_URL%'; $name = [System.IO.Path]::GetFileName(([System.Uri]$u).AbsolutePath); if (-not $name) { $name='package.bin' }; $name"`) do (
  set "PKG_NAME=%%I"
)

set "PKG_EXT=%PKG_NAME:~-4%"
if /I "%PKG_EXT%"==".zip" (
  echo [3/5] Extracting zip package...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { Expand-Archive -Path '%TEMP_PACKAGE%' -DestinationPath '%TEMP_EXTRACT%' -Force; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
  if errorlevel 1 (
    echo Failed to extract zip package.
    exit /b 1
  )

  for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$c = Get-ChildItem -Path '%TEMP_EXTRACT%' -Recurse -File | Where-Object { $_.Name -ieq 'SeeDesktopinst.exe' -or $_.Name -ieq 'SeeDesktop.exe' -or $_.Extension -ieq '.msi' -or $_.Extension -ieq '.exe' } | Select-Object -First 1 -ExpandProperty FullName; if ($c) { $c }"`) do (
    set "INSTALLER_PATH=%%I"
  )
) else (
  echo [3/5] Package is not zip, using downloaded file as installer.
  set "INSTALLER_PATH=%TEMP_PACKAGE%"
)

if "%INSTALLER_PATH%"=="" (
  echo Could not find installer inside downloaded package.
  exit /b 1
)

echo [4/5] Running uninstall + install...
call "%UPDATE_SCRIPT%" "%INSTALLER_PATH%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo Update failed with code %RC%.
  exit /b %RC%
)

echo [5/5] Done. SeeDesktop updated successfully.
exit /b 0
