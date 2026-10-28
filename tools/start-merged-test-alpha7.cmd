@echo off
setlocal
title WIREX Bridge alpha7 local test
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-merged-test.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
