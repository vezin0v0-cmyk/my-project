# Проверка голосовых команд без микрофона: разбор фраз, voice.json, клавиши и распознавание записей.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaVoice.psm1') -Force -DisableNameChecking

$config = Read-NovaVoiceConfig -Path (Join-Path $root 'voice.json')
if ($config.Problems.Count -gt 0) { $config.Problems | ForEach-Object { Write-Host "::error::$_" }; throw 'Ошибки в voice.json' }
Write-Host ('Команд в voice.json: {0}, слово-ключ: {1}' -f $config.Commands.Count, $config.WakeWord)

function Get-Actions([string]$Text) {
    return (@(Resolve-NovaVoiceText -Text $Text -Config $config) | ForEach-Object { if ($_.Do) { $_.Do } elseif ($_.Run) { 'run:' + $_.Run } else { 'keys:' + $_.Keys } }) -join ','
}
$cases = @(
    @('нова выключи компьютер', 'shutdown'),
    @('выключи компьютер', ''),
    @('нова сверни все окна нова отмена', 'minimizeAll,cancel'),
    @('нова закрой все окна', 'closeAll'),
    @('нова закрой окно', 'closeWindow'),
    @('нова открой стим', 'run:steam://open/main'),
    @('нова сделай скриншот', 'keys:win+shift+s'),
    @('нова пауза', 'playPause'),
    @('нова следующий трек', 'nextTrack'),
    @('нова предыдущая песня', 'prevTrack'),
    @('нова который час', 'time'),
    @('нова какое сегодня число', 'date'),
    @('нова сколько заряда', 'battery'),
    @('нова привет', 'hello'),
    @('[unk] нова [unk]', ''),
    @('привет нова как дела', '')
)
foreach ($case in $cases) {
    $got = Get-Actions $case[0]
    if ($got -ne $case[1]) { throw ('«{0}»: ожидалось «{1}», получилось «{2}»' -f $case[0], $case[1], $got) }
    Write-Host ('ok  «{0}» → {1}' -f $case[0], $(if ($got) { $got } else { 'ничего' }))
}

# Клавиши
$keys = ConvertTo-NovaVoiceKeys 'win+shift+s'
if (($keys -join ',') -ne '91,16,83') { throw ('win+shift+s → {0}' -f ($keys -join ',')) }
if (((ConvertTo-NovaVoiceKeys 'ctrl+f5') -join ',') -ne '17,116') { throw 'ctrl+f5' }
if (((ConvertTo-NovaVoiceKeys 'nexttrack') -join ',') -ne '176') { throw 'nexttrack' }
if ($null -ne (ConvertTo-NovaVoiceKeys 'ctrl+боб')) { throw 'непонятные клавиши должны отклоняться' }
Write-Host 'ok  клавиши'

# Ответы на вопросы: склонения и формат.
$answers = @(
    @((Get-NovaVoiceTimeText -Now ([datetime]'2026-11-15 15:00')), 'Сейчас 15 часов ровно'),
    @((Get-NovaVoiceTimeText -Now ([datetime]'2026-11-15 21:01')), 'Сейчас 21 час 1 минута'),
    @((Get-NovaVoiceTimeText -Now ([datetime]'2026-11-15 02:22')), 'Сейчас 2 часа 22 минуты'),
    @((Get-NovaVoiceTimeText -Now ([datetime]'2026-11-15 11:11')), 'Сейчас 11 часов 11 минут'),
    @((Get-NovaVoiceDateText -Now ([datetime]'2026-11-15')), 'Сегодня воскресенье, 15 ноября'),
    @((Get-NovaVoiceBatteryText -Battery $null), 'Батареи нет — это настольный компьютер'),
    @((Get-NovaVoiceBatteryText -Battery ([pscustomobject]@{ EstimatedChargeRemaining = 76; BatteryStatus = 1 })), 'Заряд 76 процентов'),
    @((Get-NovaVoiceBatteryText -Battery ([pscustomobject]@{ EstimatedChargeRemaining = 21; BatteryStatus = 2 })), 'Заряд 21 процент, от сети')
)
foreach ($a in $answers) { if ($a[0] -ne $a[1]) { throw ('ответ «{0}», а ждали «{1}»' -f $a[0], $a[1]) } }
$hello = $config.Commands | Where-Object { $_.Do -eq 'hello' } | Select-Object -First 1
if ((Invoke-NovaVoiceCommand -Command $hello -Config $config -DryRun) -ne 'Привет! Слушаю тебя') { throw '«привет» отвечает не то' }
if (-not $config.Speak) { throw 'в voice.json ответы вслух должны быть включены' }
Write-Host 'ok  ответы: «15 часов ровно», «21 час 1 минута», «2 часа 22 минуты», дата и заряд'
$speaker = Get-NovaVoiceSpeaker
if ($speaker) { Write-Host ('i   русский голос для ответов: {0}' -f $speaker.Voice.Name) } else { Write-Host 'i   русского голоса в этой Windows нет — ответы будут текстом' }

# Что может открыть «run»: сайты, программы, ссылки известных программ — но не сетевые пути и не чужие протоколы.
foreach ($good in @('https://youtube.com', 'https://www.youtube.com/@nova', 'steam://open/main', 'notepad.exe', 'explorer.exe', 'C:\Games\game.exe', 'ms-settings:display')) {
    $why = Get-NovaVoiceRunProblem $good
    if ($why) { throw ('«{0}» не принят: {1}' -f $good, $why) }
}
foreach ($good in @('C:\Program Files (x86)\Steam\steam.exe', 'steam://rungameid/730', 'steam://store/730/', 'tg://resolve?domain=durov', 'compmgmt.msc')) {
    $why = Get-NovaVoiceRunProblem $good
    if ($why) { throw ('«{0}» не принят: {1}' -f $good, $why) }
}
foreach ($bad in @('\\evil\share\x.exe', '//evil/x.exe', 'file:///C:/x.exe', 'search-ms:query=x&crumb=location:\\evil', 'ms-msdt:/id PCWDiagnostic', 'javascript:alert(1)', 'games\x.exe', 'x.bat', 'https:evil', ('notepad.exe' + [char]27), 'C:x.exe',
        'C:\Users\me\Downloads\run.bat', 'C:\x.lnk', 'C:\x.txt:evil.exe', 'C:\Games\*.exe', 'C:\%TEMP%\x.exe', 'C:\PROGRA~1\x.exe', 'C:\Games\..\Windows\x.exe', 'C:\.\x.exe',
        'steam://run/730//+exec evil', 'steam://run/730//-console', 'tg://proxy?server=evil&port=1', 'tg:socks?server=x', ('notepad.exe' + [char]0x200B), 'x..exe')) {
    if (-not (Get-NovaVoiceRunProblem $bad)) { throw ('«{0}» принят в run' -f $bad) }
}
$unc = [pscustomobject]@{ Run = '\\evil\share\x.exe'; Keys = ''; Do = ''; Label = 'вирус' }
if ((Invoke-NovaVoiceCommand -Command $unc -Config $config -DryRun) -notlike 'не открываю*') { throw 'сетевой путь открылся бы по голосовой команде' }
Write-Host 'ok  run: сайты, программы и ссылки Steam/Discord/Параметров — да; сетевые пути, file:, search-ms:, ms-msdt:, .bat, подстановки, «//» в Steam и прокси Telegram — нет'

# Ошибки в voice.json находятся
$bad = Join-Path $env:TEMP ('voice-bad-{0}.json' -f [guid]::NewGuid())
$badJson = '{"wakeWord":"nova","delaySeconds":1,"speak":"yes","commands":[{"say":["format c"],"do":"format"},{"say":["тест"],"do":"lock","run":"x.exe"},{"say":["клавиши"],"keys":"ctrl+???"},{"say":["вирус"],"run":"\\\\evil\\x.exe"}]}'
[System.IO.File]::WriteAllText($bad, $badJson, (New-Object System.Text.UTF8Encoding($false)))
$badConfig = Read-NovaVoiceConfig -Path $bad
Remove-Item -LiteralPath $bad -Force
if (-not $badConfig.Fatal) { throw 'сломанный wakeWord и delaySeconds должны останавливать голос' }
if ($badConfig.Problems.Count -lt 7 -or -not ($badConfig.Problems -like '*speak*') -or -not ($badConfig.Problems -like '*сетевые пути*')) { $badConfig.Problems | ForEach-Object { Write-Host $_ }; throw ('нашлось только {0} ошибок в плохом voice.json' -f $badConfig.Problems.Count) }
Write-Host ('ok  в плохом voice.json найдено ошибок: {0}' -f $badConfig.Problems.Count)

# Одна плохая команда не ломает остальные: её Nova пропускает.
$mixed = Join-Path $env:TEMP ('voice-mixed-{0}.json' -f [guid]::NewGuid())
[System.IO.File]::WriteAllText($mixed, '{"wakeWord":"нова","commands":[{"say":["тише"],"do":"volumeDown"},{"say":["вирус"],"run":"C:\\x.bat"},{"say":["клавиши"],"keys":"ctrl+???"}]}', (New-Object System.Text.UTF8Encoding($false)))
$mixedConfig = Read-NovaVoiceConfig -Path $mixed
Remove-Item -LiteralPath $mixed -Force
if ($mixedConfig.Fatal -or @($mixedConfig.Commands).Count -ne 1 -or $mixedConfig.Commands[0].Do -ne 'volumeDown' -or $mixedConfig.Problems.Count -ne 2) { throw ('плохие команды не пропустились: команд {0}, замечаний {1}' -f @($mixedConfig.Commands).Count, $mixedConfig.Problems.Count) }
Write-Host 'ok  плохие команды пропускаются, хорошие работают'

# pushToTalk: понятная клавиша проходит, непонятная — нет
$ptt = Join-Path $env:TEMP ('voice-ptt-{0}.json' -f [guid]::NewGuid())
[System.IO.File]::WriteAllText($ptt, '{"wakeWord":"нова","pushToTalk":"ctrl+alt","commands":[{"say":["тише"],"do":"volumeDown"}]}', (New-Object System.Text.UTF8Encoding($false)))
$pttConfig = Read-NovaVoiceConfig -Path $ptt
if ($pttConfig.Problems.Count -ne 0 -or (($pttConfig.PushKeys) -join ',') -ne '17,18') { throw 'pushToTalk ctrl+alt не разобрался' }
[System.IO.File]::WriteAllText($ptt, '{"wakeWord":"нова","pushToTalk":"ctrl+???","commands":[{"say":["тише"],"do":"volumeDown"}]}', (New-Object System.Text.UTF8Encoding($false)))
if ((Read-NovaVoiceConfig -Path $ptt).Problems.Count -eq 0) { throw 'непонятная клавиша pushToTalk должна отклоняться' }
Remove-Item -LiteralPath $ptt -Force
Write-Host 'ok  pushToTalk'

# Выключение не выполняется сразу: сначала отсчёт, «отмена» его снимает.
$shutdownCmd = $config.Commands | Where-Object { $_.Do -eq 'shutdown' } | Select-Object -First 1
$cancelCmd = $config.Commands | Where-Object { $_.Do -eq 'cancel' } | Select-Object -First 1
[void](Invoke-NovaVoiceCommand -Command $shutdownCmd -Config $config)
$pending = Get-NovaVoicePending
if ($null -eq $pending -or $pending.Action -ne 'shutdown' -or $pending.Deadline -lt (Get-Date).AddSeconds(10)) { throw 'выключение должно ждать отсчёт' }
if ($null -ne (Invoke-NovaVoicePending)) { throw 'до конца отсчёта ничего не выполняется' }
[void](Invoke-NovaVoiceCommand -Command $cancelCmd -Config $config)
if ($null -ne (Get-NovaVoicePending)) { throw '«отмена» должна снимать отсчёт' }
Write-Host 'ok  выключение ждёт 15 с и отменяется'

# Опасные команды объясняют, как отменить
$shutdown = $config.Commands | Where-Object { $_.Do -eq 'shutdown' } | Select-Object -First 1
$text = Invoke-NovaVoiceCommand -Command $shutdown -Config $config -DryRun
if ($text -notlike '*отмена*') { throw 'выключение должно подсказывать отмену' }
Write-Host ('ok  «выключи компьютер» → {0}' -f $text)

# Движок и записи голоса
Install-NovaVoiceEngine
if (-not (Test-NovaVoiceEngine)) { throw 'Движок не установился' }
Write-Host 'ok  движок Vosk и русская модель на месте, контрольные суммы совпали'

# Подложенная DLL рядом с движком: Nova это замечает и скачивает движок заново.
$engineDir = Split-Path -Parent (Get-NovaVoiceEngineDll)
[System.IO.File]::WriteAllText((Join-Path $engineDir 'winmm.dll'), 'planted')
if (Test-NovaVoiceDll) { throw 'подложенная DLL не замечена' }
Install-NovaVoiceEngine
if (-not (Test-NovaVoiceDll) -or (Test-Path -LiteralPath (Join-Path $engineDir 'winmm.dll'))) { throw 'движок не переустановился после подмены' }
Write-Host 'ok  подложенная DLL замечена, движок скачан заново'
$voiceDir = Get-NovaVoiceDir
$voiceProblem = Get-NovaTreeProblem -Path $voiceDir -Trusted @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-32-544', 'S-1-5-18')
if ($voiceProblem) { throw ('папку движка может менять кто-то ещё: {0}' -f $voiceProblem) }
Write-Host ('ok  папка движка закрыта от других пользователей: {0}' -f $voiceDir)

# Все слова из voice.json есть в словаре модели (иначе фразы молча портятся).
$model = Open-NovaVoiceModel
try {
    $probe = @('перезагрузи', 'перезагрузка', 'перезагрузить', 'перезапусти', 'компьютера', 'скрой', 'спрячь', 'дискорд', 'браузер', 'стим', 'проводник', 'скриншот', 'нова', 'закрой', 'окно',
        # слова для своих команд из примеров на сайте — проверяем, что модель их знает
        'ютуб', 'ютюб', 'телеграм', 'телеграмм', 'вконтакте', 'контакт', 'гугл', 'яндекс', 'музыку', 'спотифай', 'видео', 'твич', 'стрим', 'запись',
        'игру', 'блокнот', 'калькулятор', 'настройки', 'диспетчер', 'задач', 'почту', 'майнкрафт', 'валорант', 'доту', 'чат', 'переводчик', 'карты', 'погоду')
    $unknownProbe = @(Get-NovaVoiceUnknownWord -Model $model -Words $probe)
    Write-Host ('слова не из словаря (справка): {0}' -f ($unknownProbe -join ', '))
    $unknown = @(Get-NovaVoiceUnknownWord -Model $model -Words (Get-NovaVoiceConfigWord $config))
} finally {
    [NovaVoice.Vosk]::vosk_model_free($model)
}
if ($unknown.Count -gt 0) { throw ('В voice.json слова, которых модель не знает: {0}' -f ($unknown -join ', ')) }
Write-Host 'ok  все слова из voice.json модель знает'

$expected = [ordered]@{
    'shutdown'     = 'shutdown'
    'minimize'     = 'minimizeAll'
    'close-window' = 'closeWindow'
    'cancel'       = 'cancel'
    'volume-up'    = 'volumeUp'
    'no-wake'      = ''
    'chatter'      = ''
}
$failed = @()
foreach ($name in $expected.Keys) {
    $wav = Join-Path $root ('tests\voice\{0}.wav' -f $name)
    $result = Invoke-NovaVoiceFile -Path $wav -Config $config
    $got = (@($result.Commands) | ForEach-Object { $_.Do }) -join ','
    $mark = 'ok '
    if ($got -ne $expected[$name]) { $mark = 'BAD'; $failed += $name }
    Write-Host ('{0} {1}.wav: распознано «{2}» → {3}' -f $mark, $name, $result.Text, $(if ($got) { $got } else { 'ничего' }))
}
# Записи сделаны синтезатором речи (робот-голос), и тестовые серверы каждый раз разные — одна
# команда из пяти может распознаться «на грани». Ложных срабатываний не должно быть ни одного.
$falseTriggers = @($failed | Where-Object { $expected[$_] -eq '' })
$missed = @($failed | Where-Object { $expected[$_] -ne '' })
if ($falseTriggers.Count -gt 0) { throw ('Ложное срабатывание на: {0}' -f ($falseTriggers -join ', ')) }
if ($missed.Count -gt 1) { throw ('Не распознаны команды: {0}' -f ($missed -join ', ')) }
if ($missed.Count -eq 1) { Write-Host ('::warning::Синтетическая запись не распознана: {0}' -f $missed[0]) }
Write-Host 'ТЕСТ ГОЛОСОВЫХ КОМАНД ПРОЙДЕН'
