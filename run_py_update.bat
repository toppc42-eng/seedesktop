@echo off
setlocal

REM Run from project root
cd /d "%~dp0"

REM Ensure venv exists
if not exist ".venv\Scripts\python.exe" (
    echo Virtual environment not found. Creating...
    py -m venv .venv
    if errorlevel 1 (
        echo Failed to create virtual environment.
        pause
        exit /b 1
    )
)

REM Launch the Python OTA uploader (no console window)
if exist ".venv\Scripts\pythonw.exe" (
    start "" /B ".venv\Scripts\pythonw.exe" "SeeDesktop_Uploader.py"
) else (
    start "" /B ".venv\Scripts\python.exe" "SeeDesktop_Uploader.py"
)

exit
