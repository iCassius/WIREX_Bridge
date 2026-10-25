@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-bm-radio-bridge.ps1" -Preset manual %*
exit /b %ERRORLEVEL%
