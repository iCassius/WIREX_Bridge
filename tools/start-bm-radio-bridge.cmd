@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-bm-radio-bridge.ps1" %*
exit /b %ERRORLEVEL%
