@echo off
rem Nova Center: the Nova window (settings with switches, games, voice, updates). Asks Windows for admin rights itself.
rem The file stays ASCII: messages are UTF-8 in base64 and printed by PowerShell, so any console code page works.
setlocal
cd /d "%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
rem Started from inside a ZIP: Windows copies only this file to a temp folder.
if not exist "%~dp0src\NovaApp.ps1" goto nofiles
rem One line on purpose: an update may replace this file while it runs, and cmd.exe reads it line by line.
start "" "%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\NovaApp.ps1" & exit /b

:nofiles
set "NOVA_MSG=Tm92YSDQvdC1INC90LDRiNC70LAg0YHQstC+0Lgg0YTQsNC50LvRiyDRgNGP0LTQvtC8INGBIE5vdmFDZW50ZXIuY21kLgrQodC90LDRh9Cw0LvQsCDRgNCw0YHQv9Cw0LrRg9C5INCw0YDRhdC40LI6INC/0YDQsNCy0L7QuSDQutC90L7Qv9C60L7QuSDQv9C+INCw0YDRhdC40LLRgyDihpIgwqvQmNC30LLQu9C10YfRjCDQstGB0ZHigKbCuywK0L/QvtGC0L7QvCDQvtGC0LrRgNC+0Lkg0YDQsNGB0L/QsNC60L7QstCw0L3QvdGD0Y4g0L/QsNC/0LrRgyDQuCDQt9Cw0L/Rg9GB0YLQuCBOb3ZhQ2VudGVyLmNtZCDQvtGC0YLRg9C00LAu"
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; Write-Host ''; Write-Host ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:NOVA_MSG))) -ForegroundColor Yellow; Write-Host ''"
pause
exit /b 1
