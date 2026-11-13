<#
.SYNOPSIS
    Nova Голос — голосовые команды: «Нова, сверни все окна», «Нова, выключи компьютер».
.DESCRIPTION
    Речь распознаётся прямо на компьютере (Vosk), без интернета: звук никуда не отправляется
    и не сохраняется. Команды — в voice.json. Права администратора не нужны.
.EXAMPLE
    .\NovaVoice.ps1                          # слушать микрофон
    .\NovaVoice.ps1 -WavFile test.wav        # распознать запись (проверка без микрофона)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$WavFile,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host '  Windows запустила PowerShell в ограниченном режиме — голосовые команды так не заработают.' -ForegroundColor Red
    exit 1
}
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $projectRoot 'voice.json' }
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NovaVoice.psm1') -Force -DisableNameChecking

try { $Host.UI.RawUI.WindowTitle = 'Nova Голос' } catch { Write-Verbose 'Заголовок окна не меняется.' }
Write-Host ''
Write-Nova 'NOVA ГОЛОС' title
Write-Nova 'Распознавание идёт на этом компьютере, без интернета. Звук никуда не отправляется и не сохраняется.' dim

$exitCode = 0
try {
    $config = Read-NovaVoiceConfig -Path $ConfigPath
    if ($config.Problems.Count -gt 0) {
        Write-Nova 'В voice.json есть ошибки:' err
        foreach ($problem in $config.Problems) { Write-Nova $problem warn }
        throw 'Исправь voice.json и запусти снова.'
    }
    if (Test-NovaAdmin) {
        # Если контроль учётных записей выключен или это встроенный «Администратор», у всех программ
        # и так права администратора — отдельной защиты тут не получится, работаем с предупреждением.
        $lua = Get-NovaRegValue -Path 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
        $alwaysAdmin = ($lua.Exists -and [int]$lua.Value -eq 0) -or ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -like '*-500')
        if (-not $alwaysAdmin) {
            Write-Nova 'Голосовые команды не нужно запускать от имени администратора — так безопаснее.' warn
            Write-Nova 'Открой NovaVoice.cmd обычным двойным кликом (или пункт 8 в меню Nova).' info
            throw 'Nova Голос запущен с правами администратора.'
        }
        Write-Nova 'Контроль учётных записей выключен — голос работает с правами администратора, как и все программы на этом ПК.' warn
    }
    if (-not (Test-NovaVoiceEngine)) {
        Write-Nova 'Нужно один раз скачать бесплатный движок распознавания Vosk и русскую модель (~60 МБ).' info
        if (-not $Yes) {
            $answer = Read-Host '  Скачать? 1 — да, 0 — нет'
            if ($answer.Trim() -ne '1') { Write-Nova 'Хорошо, без голоса.' dim; exit 0 }
        }
        Install-NovaVoiceEngine
        Write-Nova 'Готово.' ok
    }
    if ($WavFile) {
        $result = Invoke-NovaVoiceFile -Path $WavFile -Config $config
        Write-Nova ('Распознано: «{0}»' -f $result.Text) info
        foreach ($command in $result.Commands) { Write-Nova ('«{0}» → {1}' -f $command.Label, (Invoke-NovaVoiceCommand -Command $command -Config $config -DryRun)) ok }
        if ($result.Commands.Count -eq 0) { Write-Nova 'Команд нет.' dim }
    } else {
        Write-Host ''
        Write-Nova 'Команды:' title
        foreach ($command in $config.Commands) { Write-Nova ('«{0}, {1}»' -f $config.WakeWord, ($command.Say -join '» / «')) info }
        Write-Host ''
        Start-NovaVoiceListener -Config $config
    }
} catch {
    Write-Nova ('Ошибка: {0}' -f $_.Exception.Message) err
    $exitCode = 1
}
exit $exitCode
