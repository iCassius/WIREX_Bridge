@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-bm-radio-bridge.ps1" -Preset listen-91
exit /b %ERRORLEVEL%
