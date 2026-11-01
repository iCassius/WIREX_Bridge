@echo off
setlocal
set "_wirex_interactive=0"
if "%~1"=="" set "_wirex_interactive=1"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0tools\start-wirex-bridge.ps1" %*
set "_wirex_exit=%ERRORLEVEL%"
if "%_wirex_interactive%"=="1" if not "%_wirex_exit%"=="0" (
  echo WIREX Bridge failed to start. Review the error above.
  pause >nul
)
exit /b %_wirex_exit%
