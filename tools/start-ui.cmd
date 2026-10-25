@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-ui.ps1" %*
set "_wirex_exit=%ERRORLEVEL%"
if not "%_wirex_exit%"=="0" (
  echo UI failed. Exit code: %_wirex_exit%.
  pause
)
exit /b %_wirex_exit%
