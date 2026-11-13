@echo off
rem Nova Voice: voice commands like "Nova, minimize all windows". Runs without admin rights.
rem The file stays ASCII: messages are UTF-8 in base64 and printed by PowerShell.
setlocal
title Nova Voice

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%~dp0src\NovaVoice.ps1" goto nofiles
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\NovaVoice.ps1"
if errorlevel 1 pause
exit /b

:nofiles
set "NOVA_MSG=Tm92YSDQvdC1INC90LDRiNC70LAg0YHQstC+0Lgg0YTQsNC50LvRiyDRgNGP0LTQvtC8INGBIE5vdmFWb2ljZS5jbWQuCtCh0L3QsNGH0LDQu9CwINGA0LDRgdC/0LDQutGD0Lkg0LDRgNGF0LjQsjog0L/RgNCw0LLQvtC5INC60L3QvtC/0LrQvtC5INC/0L4g0LDRgNGF0LjQstGDIOKGkiDCq9CY0LfQstC70LXRh9GMINCy0YHRkeKApsK7LArQv9C+0YLQvtC8INC+0YLQutGA0L7QuSDRgNCw0YHQv9Cw0LrQvtCy0LDQvdC90YPRjiDQv9Cw0L/QutGDINC4INC30LDQv9GD0YHRgtC4IE5vdmFWb2ljZS5jbWQg0L7RgtGC0YPQtNCwLg=="
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; Write-Host ''; Write-Host ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:NOVA_MSG))) -ForegroundColor Yellow; Write-Host ''"
pause
exit /b 1
