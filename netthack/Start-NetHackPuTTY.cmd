@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Start-NetHackPuTTY.ps1" -PauseOnError
if errorlevel 1 pause
