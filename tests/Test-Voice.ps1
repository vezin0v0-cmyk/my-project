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
if ($null -ne (ConvertTo-NovaVoiceKeys 'ctrl+боб')) { throw 'непонятные клавиши должны отклоняться' }
Write-Host 'ok  клавиши'

# Ошибки в voice.json находятся
$bad = Join-Path $env:TEMP ('voice-bad-{0}.json' -f [guid]::NewGuid())
$badJson = '{"wakeWord":"nova","delaySeconds":1,"commands":[{"say":["format c"],"do":"format"},{"say":["тест"],"do":"lock","run":"x.exe"},{"say":["клавиши"],"keys":"ctrl+???"}]}'
[System.IO.File]::WriteAllText($bad, $badJson, (New-Object System.Text.UTF8Encoding($false)))
$badConfig = Read-NovaVoiceConfig -Path $bad
Remove-Item -LiteralPath $bad -Force
if ($badConfig.Problems.Count -lt 5) { $badConfig.Problems | ForEach-Object { Write-Host $_ }; throw ('нашлось только {0} ошибок в плохом voice.json' -f $badConfig.Problems.Count) }
Write-Host ('ok  в плохом voice.json найдено ошибок: {0}' -f $badConfig.Problems.Count)

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
    $probe = @('перезагрузи', 'перезагрузка', 'перезагрузить', 'перезапусти', 'компьютера', 'скрой', 'спрячь', 'дискорд', 'браузер', 'стим', 'проводник', 'скриншот', 'нова', 'закрой', 'окно')
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
if ($failed.Count -gt 0) { throw ('Неверно распознано: {0}' -f ($failed -join ', ')) }
Write-Host 'ТЕСТ ГОЛОСОВЫХ КОМАНД ПРОЙДЕН'
