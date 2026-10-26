@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-hri-lcd-identity-candidate.ps1" -PackageRoot "%~dp0" %*
exit /b %errorlevel%
