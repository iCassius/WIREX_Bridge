@echo off
setlocal
powershell.exe -NoLogo -NoProfile -File "%~dp0start-hri-test.ps1"
exit /b %ERRORLEVEL%
