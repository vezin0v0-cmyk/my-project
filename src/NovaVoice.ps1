<#
.SYNOPSIS
    Nova Голос — голосовые команды: «Нова, сверни все окна», «Нова, выключи компьютер».
.DESCRIPTION
    Речь распознаётся прямо на компьютере (Vosk), без интернета: звук никуда не отправляется
    и не сохраняется. Команды — в voice.json. Права администратора не нужны.
.EXAMPLE
    .\NovaVoice.ps1                          # слушать микрофон
    .\NovaVoice.ps1 -WavFile test.wav        # распознать запись (проверка без микрофона)
    .\NovaVoice.ps1 -Startup                 # запускать ли Nova Голос вместе с Windows
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$WavFile,
    [switch]$Startup,
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
Import-Module (Join-Path $PSScriptRoot 'NovaStartup.psm1') -Force -DisableNameChecking

# Запускать ли Nova Голос вместе с Windows. Работает без прав администратора: ярлык — в своей «Автозагрузке».
function Invoke-NovaVoiceStartupFlow {
    $cmd = Join-Path $projectRoot 'NovaVoice.cmd'
    $state = Get-NovaVoiceAutostart -Target $cmd
    Write-Host ''
    $turnOn = $true
    switch ($state.State) {
        'on' {
            Write-Nova 'Сейчас Nova Голос запускается вместе с Windows.' ok
            $question = 'Выключить?'
            $turnOn = $false
        }
        'disabled' {
            Write-Nova 'Ярлык есть, но запуск выключен — в Диспетчере задач или в пункте 10 Nova.' warn
            $question = 'Включить снова?'
        }
        'other' {
            Write-Nova ('Ярлык ведёт на другую папку Nova: {0}' -f $state.Target) warn
            Write-Host '  1  Запускать голос из этой папки' -ForegroundColor White
            Write-Host '  2  Убрать старый ярлык' -ForegroundColor White
            Write-Host '  0  Ничего не менять' -ForegroundColor White
            $pick = '1'
            if (-not $Yes) { $pick = (Read-Host '  Выбери пункт').Trim() }
            if ($pick -eq '2') { Remove-NovaVoiceAutostart; Write-Nova 'Старый ярлык убран: голос больше не запускается вместе с Windows.' ok; return }
            if ($pick -ne '1') { Write-Nova 'Ничего не меняю.' dim; return }
            $question = ''
        }
        default {
            Write-Nova 'Сейчас Nova Голос сам не запускается.' info
            $question = 'Запускать вместе с Windows, чтобы Нова слушала сразу после включения?'
        }
    }
    $answer = '1'
    if ($question -and -not $Yes) { $answer = Read-Host ('  {0}  1 — да, 0 — нет' -f $question) }
    if ($answer.Trim() -ne '1') { Write-Nova 'Ничего не меняю.' dim; return }
    if ($turnOn) {
        # Без движка окно голоса при включении компьютера молча ждало бы ответа «скачать?» — спросим сейчас.
        if (-not (Test-NovaVoiceEngine) -and -not $Yes) {
            Write-Nova 'Для голоса нужен бесплатный движок распознавания Vosk и русская модель (~60 МБ).' info
            if ((Read-Host '  Скачать сейчас? 1 — да, 0 — нет').Trim() -eq '1') {
                Install-NovaVoiceEngine
                Write-Nova 'Движок на месте.' ok
            } else {
                Write-Nova 'Хорошо. Тогда при включении компьютера окно голоса само спросит, скачать ли его.' dim
            }
        }
        [void](Add-NovaVoiceAutostart -Target $cmd)
        Write-Nova 'Готово: после включения компьютера Nova Голос откроется свёрнутым и сразу начнёт слушать.' ok
        Write-Nova 'В играх с голосовым чатом удобно включить pushToTalk в voice.json.' dim
    } else {
        Remove-NovaVoiceAutostart
        Write-Nova 'Готово: Nova Голос больше не запускается вместе с Windows.' ok
    }
}

# Найденные игры: какие запускаются голосом и что сказать. Для остальных — готовая строка для voice.json.
function Show-NovaVoiceGames {
    param($Config)
    $gameCommands = @($Config.Commands | Where-Object { $_.Do -eq 'game' })
    if ($gameCommands.Count -eq 0) { return }
    $prefix = ($gameCommands[0].Say[0] -split ' ')[0]
    Write-Nova ('«{0}, {1}» — последняя игра, в которую ты играл в Steam' -f $Config.WakeWord, $gameCommands[0].Say[0]) info
    $games = @($Config.Games)
    if ($games.Count -eq 0) { Write-Nova 'Игр Steam, Epic Games и Riot на этом компьютере не нашла.' dim; return }
    $named = @($gameCommands | Where-Object { $_.Game })
    foreach ($c in $named) { Write-Nova ('«{0}, {1}» → {2}' -f $Config.WakeWord, $c.Say[0], $c.Game.Name) info }
    $silent = @($games | Where-Object { @($_.Words).Count -eq 0 -and $_.Uri })
    if ($silent.Count -gt 0) {
        Write-Nova ('Эти игры я знаю только по-английски — добавь им свою фразу в voice.json:') dim
        foreach ($g in @($silent | Select-Object -First 8)) {
            Write-Nova ('  {0}: {{ "say": ["{1} …"], "run": "{2}" }}' -f $g.Name, $prefix, $g.Uri) dim
        }
        if ($silent.Count -gt 8) { Write-Nova ('  …и ещё {0}' -f ($silent.Count - 8)) dim }
    }
}

try { $Host.UI.RawUI.WindowTitle = 'Nova Голос' } catch { Write-Verbose 'Заголовок окна не меняется.' }
Write-Host ''
Write-Nova 'NOVA ГОЛОС' title
Write-Nova 'Распознавание идёт на этом компьютере, без интернета. Звук никуда не отправляется и не сохраняется.' dim

$exitCode = 0
try {
    # Голос может запускаться при каждом входе в Windows — его файлы не должен мочь подменить другой
    # пользователь этого компьютера: иначе чужой код запускался бы от твоего имени.
    if (-not ($env:NOVA_ALLOW_SHARED_FOLDER -eq '1' -and $env:GITHUB_ACTIONS -eq 'true')) {
        $folderProblem = Get-NovaProjectProblem -Root $projectRoot -ConfigPath $ConfigPath
        if ($folderProblem) {
            Write-Nova 'Папку Nova могут менять другие пользователи этого компьютера — голос оттуда запускать небезопасно.' err
            Write-Nova ('Подробно: {0}' -f $folderProblem) dim
            Write-Nova ('Перенеси папку Nova в свою папку пользователя, например {0}' -f $env:USERPROFILE) warn
            throw 'Папка Nova не защищена от других пользователей.'
        }
    }
    $config = Read-NovaVoiceConfig -Path $ConfigPath
    if ($config.Fatal) {
        Write-Nova 'В voice.json есть ошибки:' err
        foreach ($problem in $config.Problems) { Write-Nova $problem warn }
        throw 'Исправь voice.json и запусти снова.'
    }
    if ($config.Problems.Count -gt 0) {
        Write-Nova 'Эти команды из voice.json я пропущу — остальные работают:' warn
        foreach ($problem in $config.Problems) { Write-Nova $problem dim }
    }
    if (@($config.Commands).Count -eq 0) { throw 'В voice.json не осталось ни одной рабочей команды.' }
    if (Test-NovaAdmin) {
        # Если контроль учётных записей выключен или это встроенный «Администратор», у всех программ
        # и так права администратора — отдельной защиты тут не получится, работаем с предупреждением.
        $lua = Get-NovaRegValue -Path 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
        $alwaysAdmin = ($lua.Exists -and [int]$lua.Value -eq 0) -or ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -like '*-500')
        if (-not $alwaysAdmin) {
            Write-Nova 'Голосовые команды не нужно запускать от имени администратора — так безопаснее.' warn
            # Перезапускаем обычным окном через Проводник — от имени того, кто сидит за компьютером.
            # Только обычный запуск (без своих параметров) и не чаще раза в минуту: если сам Проводник
            # почему-то запущен с правами администратора, новое окно снова было бы таким — без петли.
            $mark = Get-NovaRegValue -Path 'HKCU\Software\Nova' -Name 'VoiceRelaunch'
            $recent = $false
            if ($mark.Exists) {
                $when = 0L
                if ([long]::TryParse([string]$mark.Value, [ref]$when)) { $recent = ([DateTime]::UtcNow.Ticks - $when) -lt [TimeSpan]::FromMinutes(1).Ticks }
            }
            $plain = -not $PSBoundParameters.ContainsKey('ConfigPath') -and -not $WavFile -and -not $Yes
            $relaunch = Join-Path (Split-Path -Parent $PSScriptRoot) 'NovaVoice.cmd'
            if ($Startup) { $relaunch = Join-Path $PSScriptRoot 'NovaVoiceStartup.cmd' }
            if ($plain -and -not $recent -and (Test-Path -LiteralPath $relaunch)) {
                Set-NovaRegValue -Path 'HKCU\Software\Nova' -Name 'VoiceRelaunch' -Value ([string][DateTime]::UtcNow.Ticks) -Kind 'String'
                if (Start-NovaAsUser $relaunch) {
                    Write-Nova 'Открываю Nova Голос обычным окном — это окно можно закрыть.' ok
                    exit 0
                }
            }
            Write-Nova 'Открой NovaVoice.cmd обычным двойным кликом (или пункт 8 в меню Nova).' info
            throw 'Nova Голос запущен с правами администратора.'
        }
        Write-Nova 'Контроль учётных записей выключен — голос работает с правами администратора, как и все программы на этом ПК.' warn
    }
    if ($Startup) {
        Invoke-NovaVoiceStartupFlow
        exit 0
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
        $shownTimer = $false
        foreach ($command in $config.Commands) {
            if ($command.Do -eq 'game') { continue }
            if ($command.Do -eq 'timer') {
                if (-not $shownTimer) { Write-Nova ('«{0}, {1} на пять минут» — от десяти секунд до часа' -f $config.WakeWord, $command.Say[0].Split(' ')[0]) info }
                $shownTimer = $true
                continue
            }
            # Свои команды — с тем, что именно они откроют или нажмут: чужой voice.json сразу виден.
            $what = ''
            if ($command.Run) { $what = ' → откроет ' + $command.Run } elseif ($command.Keys) { $what = ' → нажмёт ' + $command.Keys }
            Write-Nova ('«{0}, {1}»{2}' -f $config.WakeWord, ($command.Say -join '» / «'), $what) info
        }
        Show-NovaVoiceGames -Config $config
        Write-Host ''
        # Окно Nova Голос и консоль не слушают вдвоём — иначе каждая команда выполнялась бы дважды.
        $single = New-Object Threading.Mutex($false, 'Local\NovaVoice')
        $owned = $false
        try { $owned = $single.WaitOne(0) } catch { $owned = $true }
        if (-not $owned) { throw 'Nova Голос уже слушает в своём окне — второй раз не запускаю, иначе команды выполнялись бы дважды.' }
        Start-NovaVoiceListener -Config $config
    }
} catch {
    Write-Nova ('Ошибка: {0}' -f $_.Exception.Message) err
    Write-Nova ('Не получается? Напиши в поддержку: {0}' -f (Get-NovaSupportEmail)) dim
    $exitCode = 1
}
exit $exitCode
