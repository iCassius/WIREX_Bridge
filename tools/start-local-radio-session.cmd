@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-local-radio-session.ps1" %*
exit /b %ERRORLEVEL%
