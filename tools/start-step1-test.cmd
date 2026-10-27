@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-step1-test.ps1" %*
set "result=%ERRORLEVEL%"
if not "%result%"=="0" (
  echo Step 1 test UI failed. See messages above.
  pause
)
exit /b %result%
