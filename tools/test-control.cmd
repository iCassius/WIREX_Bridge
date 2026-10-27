@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-control.ps1"
set "result=%ERRORLEVEL%"
if not "%result%"=="0" (
  echo Protocol diagnostic failed. See messages above.
  pause
) else (
  echo Protocol diagnostic passed. Press any key to close.
  pause
)
exit /b %result%
