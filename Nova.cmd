@echo off
rem Nova launcher: asks Windows for admin rights and opens the Nova menu.
rem No parenthesized blocks on purpose: a folder like "Nova (1)" would break them.
rem The file stays ASCII: messages are UTF-8 in base64 and printed by PowerShell, so any console code page works.
setlocal
title Nova

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

rem Started from inside a ZIP: Windows copies only this file to a temp folder.
if not exist "%~dp0src\Nova.ps1" goto nofiles

rem fltmc works only with admin rights - a reliable way to check them.
fltmc >nul 2>&1
if not errorlevel 1 goto run
if /i "%~1"=="elevated" goto noadmin
rem The path goes through an environment variable, so quotes or apostrophes in folder names are safe.
set "NOVA_SELF=%~f0"
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:NOVA_SELF -ArgumentList 'elevated' -Verb RunAs"
exit /b

:nofiles
set "NOVA_MSG=Tm92YSDQvdC1INC90LDRiNC70LAg0YHQstC+0Lgg0YTQsNC50LvRiyDRgNGP0LTQvtC8INGBIE5vdmEuY21kLgrQodC90LDRh9Cw0LvQsCDRgNCw0YHQv9Cw0LrRg9C5INCw0YDRhdC40LI6INC/0YDQsNCy0L7QuSDQutC90L7Qv9C60L7QuSDQv9C+INCw0YDRhdC40LLRgyDihpIgwqvQmNC30LLQu9C10YfRjCDQstGB0ZHigKbCuywK0L/QvtGC0L7QvCDQvtGC0LrRgNC+0Lkg0YDQsNGB0L/QsNC60L7QstCw0L3QvdGD0Y4g0L/QsNC/0LrRgyDQuCDQt9Cw0L/Rg9GB0YLQuCBOb3ZhLmNtZCDQvtGC0YLRg9C00LAu"
goto say

:noadmin
set "NOVA_MSG=Tm92YSDQvdGD0LbQvdGLINC/0YDQsNCy0LAg0LDQtNC80LjQvdC40YHRgtGA0LDRgtC+0YDQsC4K0J3QsNC20LzQuCDQvdCwIE5vdmEuY21kINC/0YDQsNCy0L7QuSDQutC90L7Qv9C60L7QuSDihpIgwqvQl9Cw0L/Rg9GB0Log0L7RgiDQuNC80LXQvdC4INCw0LTQvNC40L3QuNGB0YLRgNCw0YLQvtGA0LDCuy4="
goto say

:say
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; Write-Host ''; Write-Host ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:NOVA_MSG))) -ForegroundColor Yellow; Write-Host ''"
pause
exit /b 1

:run
cd /d "%~dp0"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Nova.ps1"
if errorlevel 1 pause
endlocal
