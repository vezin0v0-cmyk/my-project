@echo off
rem Nova launcher: asks Windows for admin rights and opens the Nova menu.
rem No parenthesized blocks on purpose: a folder like "Nova (1)" would break them.
setlocal
title Nova

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

rem fltmc works only with admin rights - a reliable way to check them.
fltmc >nul 2>&1
if not errorlevel 1 goto run
if /i "%~1"=="elevated" goto noadmin
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
exit /b

:noadmin
echo Nova needs administrator rights. Right-click Nova.cmd and choose "Run as administrator".
pause
exit /b 1

:run
cd /d "%~dp0"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Nova.ps1"
endlocal
