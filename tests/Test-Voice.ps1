# Проверка голосовых команд без микрофона: разбор фраз, voice.json, клавиши и распознавание записей.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaVoice.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaPlay.psm1') -Force -DisableNameChecking

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
    @('нова режим игры', 'gameMode'),
    @('нова включи режим игры', 'gameMode'),
    @('нова выключи режим игры', 'gameModeOff'),
    @('нова игра окончена', 'gameModeOff'),
    @('нова запусти игру', 'game'),
    @('[unk] нова [unk]', ''),
    @('привет нова как дела', '')
)
foreach ($case in $cases) {
    $got = Get-Actions $case[0]
    if ($got -ne $case[1]) { throw ('«{0}»: ожидалось «{1}», получилось «{2}»' -f $case[0], $case[1], $got) }
    Write-Host ('ok  «{0}» → {1}' -f $case[0], $(if ($got) { $got } else { 'ничего' }))
}

# Игры: свой список вместо поиска на диске. «Запусти доту» — Dota 2, «запусти игру» — последняя.
$fakeGames = @(
    (New-NovaGame -Name 'Dota 2' -Store 'Steam' -Id '570' -Uri 'steam://rungameid/570' -LastPlayed 10),
    (New-NovaGame -Name 'Counter-Strike 2' -Store 'Steam' -Id '730' -Uri 'steam://rungameid/730' -LastPlayed 20),
    (New-NovaGame -Name 'Some English Game' -Store 'Steam' -Id '42' -Uri 'steam://rungameid/42'))
$gameConfig = Read-NovaVoiceConfig -Path (Join-Path $root 'voice.json') -Games $fakeGames
foreach ($case in @(@('нова запусти доту', '570'), @('нова включи доту', '570'), @('нова запусти контру', '730'), @('нова запусти игру', ''))) {
    $found = @(Resolve-NovaVoiceText -Text $case[0] -Config $gameConfig)
    if ($found.Count -ne 1 -or $found[0].Do -ne 'game') { throw ('«{0}» — не команда игры' -f $case[0]) }
    $id = ''
    if ($found[0].Game) { $id = $found[0].Game.Id }
    if ($id -ne $case[1]) { throw ('«{0}» → игра {1}, а ждали {2}' -f $case[0], $id, $case[1]) }
    Write-Host ('ok  «{0}» → {1}' -f $case[0], (Invoke-NovaVoiceCommand -Command $found[0] -Config $gameConfig -DryRun))
}
$last = @(Resolve-NovaVoiceText -Text 'нова запусти игру' -Config $gameConfig)[0]
if ((Invoke-NovaVoiceCommand -Command $last -Config $gameConfig -DryRun) -ne 'запускаю Counter-Strike 2') { throw '«запусти игру» должна запускать последнюю игру' }
$noGames = Read-NovaVoiceConfig -Path (Join-Path $root 'voice.json') -Games @()
$lastNone = @(Resolve-NovaVoiceText -Text 'нова запусти игру' -Config $noGames)[0]
if ((Invoke-NovaVoiceCommand -Command $lastNone -Config $noGames -DryRun) -notlike 'не знаю*') { throw '«запусти игру» без игр должна честно сказать, что не знает' }
foreach ($w in @('нова режим игры', 'нова игра окончена')) {
    $cmd = @(Resolve-NovaVoiceText -Text $w -Config $gameConfig)[0]
    Write-Host ('ok  «{0}» → {1}' -f $w, (Invoke-NovaVoiceCommand -Command $cmd -Config $gameConfig -DryRun))
}
Write-Host 'ok  игры голосом: «запусти доту», «включи контру», «запусти игру» (последняя), режим игры'

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
        'steam://run/730//+exec evil', 'steam://run/730//-console', 'tg://proxy?server=evil&port=1', 'tg:socks?server=x', ('notepad.exe' + [char]0x200B), 'x..exe',
        'C:\Games/../Windows/System32/cmd.exe', 'C:\x/./y.exe', 'tg://%70roxy?server=evil', ('C:\Games\game' + [char]::ConvertFromUtf32(0xE0041) + '.exe'))) {
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

# Таймер: «Нова, таймер на пять минут», от десяти секунд до часа, «сколько осталось», «отмена».
$timerCases = [ordered]@{ 'нова таймер на пять минут' = 300; 'нова поставь таймер на сорок пять секунд' = 45; 'нова таймер на двадцать одну минуту' = 1260
    'нова таймер на минуту' = 60; 'нова таймер на две минуты' = 120; 'нова таймер на полчаса' = 1800; 'нова таймер на час' = 3600; 'нова таймер на пятьдесят девять минут' = 3540 }
foreach ($phrase in $timerCases.Keys) {
    $hit = @(Resolve-NovaVoiceText -Text $phrase -Config $config)
    if ($hit.Count -ne 1 -or $hit[0].Do -ne 'timer' -or $hit[0].Seconds -ne $timerCases[$phrase]) { throw ('«{0}» → {1}' -f $phrase, (($hit | ForEach-Object { '{0}/{1}' -f $_.Do, $_.Seconds }) -join ',')) }
}
foreach ($pair in @(@(300, '5 минут'), @(61, '1 минута 1 секунда'), @(3600, '1 час'), @(45, '45 секунд'), @(1260, '21 минута'), @(0, '0 секунд'))) {
    if ((Get-NovaVoiceDurationText $pair[0]) -ne $pair[1]) { throw ('{0} с → «{1}», ждали «{2}»' -f $pair[0], (Get-NovaVoiceDurationText $pair[0]), $pair[1]) }
}
$quiet = [pscustomobject]@{ WakeWord = 'нова'; Delay = 15; Speak = $false; Commands = @() }
if ((Get-NovaVoiceTimerLeftText) -ne 'Таймер не запущен') { throw 'без таймера «сколько осталось» отвечает не то' }
[void](Invoke-NovaVoiceCommand -Command ([pscustomobject]@{ Do = 'timer'; Run = ''; Keys = ''; Label = 'тест'; Seconds = 2 }) -Config $quiet)
if ((Get-NovaVoiceTimerLeftText) -notmatch '^Осталось [12] секунд') { throw ('«сколько осталось»: {0}' -f (Get-NovaVoiceTimerLeftText)) }
if ($null -ne (Invoke-NovaVoicePending -Config $quiet)) { throw 'таймер сработал раньше времени' }
Start-Sleep -Milliseconds 2300
$fired = Invoke-NovaVoicePending -Config $quiet
if ($fired -notlike 'время вышло*') { throw ('таймер не сработал: {0}' -f $fired) }
[void](Invoke-NovaVoiceCommand -Command ([pscustomobject]@{ Do = 'timer'; Run = ''; Keys = ''; Label = 'тест'; Seconds = 600 }) -Config $quiet)
if ((Invoke-NovaVoiceCommand -Command ([pscustomobject]@{ Do = 'cancel'; Run = ''; Keys = ''; Label = 'отмена' }) -Config $quiet) -ne 'таймер отменён' -or $null -ne (Get-NovaVoiceTimer)) { throw '«отмена» не отменила таймер' }
Write-Host 'ok  таймер: фразы от «сорок пять секунд» до «час», сколько осталось, срабатывает вовремя, отменяется'

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
    # Названия игр вслух: варианты, которых модель не знает, Nova Голос сама пропускает — но в словаре их быть не должно.
    $gameWords = @(Get-NovaGameWordList | ForEach-Object { $_.Words } | ForEach-Object { $_ -split ' ' } | Select-Object -Unique)
    $unknownGames = @(Get-NovaVoiceUnknownWord -Model $model -Words $gameWords)
    $deadGames = @(Get-NovaGameWordList | Where-Object { @($_.Words | Where-Object { @($_ -split ' ' | Where-Object { $unknownGames -contains $_ }).Count -eq 0 }).Count -eq 0 } | ForEach-Object { $_.Match })
    Write-Host ('названия игр: слов {0}, модель не знает {1}: {2}' -f $gameWords.Count, $unknownGames.Count, ($unknownGames -join ', '))
    Write-Host ('игры, которые не назвать ни одним вариантом: {0}' -f ($deadGames -join ' | '))
} finally {
    [NovaVoice.Vosk]::vosk_model_free($model)
}
if ($unknown.Count -gt 0) { throw ('В voice.json слова, которых модель не знает: {0}' -f ($unknown -join ', ')) }
Write-Host 'ok  все слова из voice.json модель знает'

if ($unknownGames.Count -gt 0) { throw ('В словаре игр слова, которых модель не знает: {0}' -f ($unknownGames -join ', ')) }
if ($deadGames.Count -gt 0) { throw ('Игры, которые нельзя назвать голосом: {0}' -f ($deadGames -join ' | ')) }
Write-Host 'ok  все названия игр модель знает'
$expected = [ordered]@{
    'game'         = 'game'
    'game-mode'    = 'gameMode'
    'shutdown'     = 'shutdown'
    'minimize'     = 'minimizeAll'
    'close-window' = 'closeWindow'
    'cancel'       = 'cancel'
    'volume-up'    = 'volumeUp'
    'timer'        = 'timer'
    'no-wake'      = ''
    'chatter'      = ''
}
$failed = @()
foreach ($name in $expected.Keys) {
    $wav = Join-Path $root ('tests\voice\{0}.wav' -f $name)
    $useConfig = $config
    if ($name -eq 'game') { $useConfig = $gameConfig }
    $result = Invoke-NovaVoiceFile -Path $wav -Config $useConfig
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

# Слушатель целиком — как в окне Nova Голос: свой поток, «пульт» (пауза, остановка) и очередь событий.
# Настоящего микрофона на сервере нет — «микрофон» отдаёт запись кусками по 0,1 с, потом тишину.
$listenOk = @($expected.Keys | Where-Object { $expected[$_] -in @('volumeUp', 'minimizeAll') -and $failed -notcontains $_ } | Sort-Object)
if ($listenOk.Count -eq 0) { throw 'Нет распознанной записи для проверки слушателя' }
$listenWav = Join-Path $root ('tests\voice\{0}.wav' -f $listenOk[0])
$listenScript = @'
param([string]$Src, [string]$ConfigPath, [string]$Wav, $Queue, $Control, $Stats, [double]$Silence, [bool]$Mute)
$ErrorActionPreference = 'Stop'
$global:NovaVoiceEvents = $Queue
$global:NovaVoiceControl = $Control
function global:Write-Host { param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $Separator = ' ', [ConsoleColor]$ForegroundColor = 'Gray', $BackgroundColor) }
Import-Module (Join-Path $Src 'Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $Src 'NovaVoice.psm1') -Force -DisableNameChecking
$config = Read-NovaVoiceConfig -Path $ConfigPath -Games @()
$bytes = [IO.File]::ReadAllBytes($Wav)
$chunks = New-Object System.Collections.Generic.List[object]
for ($pos = 44; $pos -lt $bytes.Length; $pos += 3200) { $n = [Math]::Min(3200, $bytes.Length - $pos); $c = New-Object byte[] $n; [Array]::Copy($bytes, $pos, $c, 0, $n); $chunks.Add($c) }
$open = {
    $Stats.Opened++
    $src = [pscustomobject]@{ Chunks = $(if ($Stats.Opened -eq 1) { $chunks } else { @() }); I = 0; Stats = $Stats; Mute = $Mute }
    $src | Add-Member -MemberType ScriptMethod -Name Read -Value {
        Start-Sleep -Milliseconds 15
        if ($this.Mute) { return $null }
        if ($this.I -lt @($this.Chunks).Count) { $c = $this.Chunks[$this.I]; $this.I++; return , $c }
        return , (New-Object byte[] 3200)
    }
    $src | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Stats.Disposed++ }
    return $src
}.GetNewClosure()
Start-NovaVoiceListener -Config $config -OpenMic $open -SilenceSeconds $Silence
'@
function Start-TestListener([bool]$Mute, [double]$Silence) {
    $t = @{ Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Control = [hashtable]::Synchronized(@{ Paused = $false; Stop = $false }); Stats = [hashtable]::Synchronized(@{ Opened = 0; Disposed = 0 }) }
    $t.Rs = [runspacefactory]::CreateRunspace(); $t.Rs.ApartmentState = 'STA'; $t.Rs.Open()
    $t.Ps = [powershell]::Create(); $t.Ps.Runspace = $t.Rs
    [void]$t.Ps.AddScript($listenScript).AddArgument((Join-Path $root 'src')).AddArgument((Join-Path $root 'voice.json')).AddArgument($listenWav).AddArgument($t.Queue).AddArgument($t.Control).AddArgument($t.Stats).AddArgument($Silence).AddArgument($Mute)
    $t.Handle = $t.Ps.BeginInvoke()
    $t.Seen = New-Object System.Collections.Generic.List[string]
    return $t
}
function Wait-Event($T, [string]$Kind, [double]$Seconds) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    $item = $null
    while ([DateTime]::UtcNow -lt $until) {
        while ($T.Queue.TryDequeue([ref]$item)) { $T.Seen.Add($item) }
        $hit = @($T.Seen | Where-Object { $_ -like ($Kind + "`t*") -or $_ -eq $Kind })
        if ($hit.Count) { return $hit[-1] }
        if ($T.Handle.IsCompleted) { break }
        Start-Sleep -Milliseconds 100
    }
    $why = ''
    if ($T.Handle.IsCompleted) { try { [void]$T.Ps.EndInvoke($T.Handle) } catch { $why = $_.Exception.Message } }
    throw ('Слушатель: не дождался события «{0}». События: {1} {2}' -f $Kind, ($T.Seen -join ' | '), $why)
}

$t = Start-TestListener $false 4
[void](Wait-Event $t 'listen' 60)
$heard = Wait-Event $t 'heard' 30
$done = Wait-Event $t 'done' 30
Write-Host ('ok  слушатель: {0} → {1}' -f ($heard -split "`t")[1], (($done -split "`t") -join ' / '))
# Пауза: микрофон закрывается, поток живёт. Снова «слушать» — микрофон открывается заново.
$t.Control.Paused = $true
[void](Wait-Event $t 'paused' 10)
if ($t.Stats.Disposed -ne 1) { throw ('на паузе микрофон не закрылся (закрыт раз: {0})' -f $t.Stats.Disposed) }
$t.Seen.Clear()
$t.Control.Paused = $false
[void](Wait-Event $t 'listen' 10)
if ($t.Stats.Opened -ne 2) { throw ('после паузы микрофон не открылся заново (открыт раз: {0})' -f $t.Stats.Opened) }
# Остановка по просьбе окна: поток выходит сам и всё отпускает.
$t.Control.Stop = $true
if (-not $t.Handle.AsyncWaitHandle.WaitOne(10000)) { throw 'слушатель не остановился по просьбе окна за 10 с' }
[void]$t.Ps.EndInvoke($t.Handle)
if ($t.Ps.Streams.Error.Count) { throw ('слушатель записал ошибку: {0}' -f $t.Ps.Streams.Error[0]) }
if ($t.Stats.Disposed -ne 2) { throw ('после остановки микрофон не закрылся (закрыт раз: {0})' -f $t.Stats.Disposed) }
$t.Ps.Dispose(); $t.Rs.Dispose()
Write-Host 'ok  слушатель: пауза закрывает микрофон и не теряет поток, остановка всё отпускает'

# Микрофон замолчал совсем (выдернули) — понятная ошибка, а не вечное «Слушаю».
$t = Start-TestListener $true 1
if (-not $t.Handle.AsyncWaitHandle.WaitOne(60000)) { throw 'слушатель с молчащим микрофоном не остановился' }
$why = ''
try { [void]$t.Ps.EndInvoke($t.Handle) } catch { $why = $_.Exception.Message }
if ($why -notlike '*перестал присылать звук*') { throw ('молчащий микрофон: ожидалась понятная ошибка, а пришло «{0}»' -f $why) }
if ($t.Stats.Disposed -ne 1) { throw 'после ошибки микрофон не закрылся' }
$t.Ps.Dispose(); $t.Rs.Dispose()
Write-Host 'ok  слушатель: выдернутый микрофон — «Микрофон перестал присылать звук», микрофон закрыт'

Write-Host 'ТЕСТ ГОЛОСОВЫХ КОМАНД ПРОЙДЕН'
