@echo off
setlocal

REM 1) Change directory to this project root
cd /d "%~dp0"

REM 2) Activate virtual environment
call ".venv\Scripts\activate.bat"

REM 3) Run the uploader GUI in background-style process
if exist ".venv\Scripts\pythonw.exe" (
    start "" /B ".venv\Scripts\pythonw.exe" "SeeDesktop_Uploader.py"
) else (
    start "" /B ".venv\Scripts\python.exe" "SeeDesktop_Uploader.py"
)

REM 4) Close this command window immediately
exit
