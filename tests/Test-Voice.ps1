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

# Опасные команды объясняют, как отменить
$shutdown = $config.Commands | Where-Object { $_.Do -eq 'shutdown' } | Select-Object -First 1
$text = Invoke-NovaVoiceCommand -Command $shutdown -Config $config -DryRun
if ($text -notlike '*отмена*') { throw 'выключение должно подсказывать отмену' }
Write-Host ('ok  «выключи компьютер» → {0}' -f $text)

# Движок и записи голоса
Install-NovaVoiceEngine
if (-not (Test-NovaVoiceEngine)) { throw 'Движок не установился' }
Write-Host 'ok  движок Vosk и русская модель на месте, контрольные суммы совпали'

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
