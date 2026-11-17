# Режим игры и игры для голоса: поиск игр Steam, Epic Games и Riot по подложенным файлам, правила запуска
# и режим игры на настоящей Windows — включить и вернуть всё как было.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaPlay.psm1') -Force -DisableNameChecking

# Короткая сводка для конца проверки на GitHub (если задан файл NOVA_SUMMARY).
function Write-Summary([string]$Text) { Write-Host $Text; if ($env:NOVA_SUMMARY) { Add-Content -LiteralPath $env:NOVA_SUMMARY -Value $Text -Encoding UTF8 } }

function Set-TestText([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function New-TestManifest([string]$Id, [string]$Name, [int]$Flags, [long]$LastPlayed) {
    return ("`"AppState`"`n{{`n`t`"appid`"`t`t`"{0}`"`n`t`"name`"`t`t`"{1}`"`n`t`"StateFlags`"`t`t`"{2}`"`n`t`"LastPlayed`"`t`t`"{3}`"`n}}`n" -f $Id, $Name, $Flags, $LastPlayed)
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('nova-play-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # --- Steam: две библиотеки, служебная программа, недокачанная игра, мусор в названии ---
    $steam = Join-Path $tmp 'Steam'
    $lib2 = Join-Path $tmp 'Games Lib'
    $vdf = "`"libraryfolders`"`n{{`n`t`"0`"`n`t{{`n`t`t`"path`"`t`t`"{0}`"`n`t`t`"apps`"`n`t`t{{`n`t`t`t`"228980`"`t`t`"104637426`"`n`t`t}}`n`t}}`n`t`"1`"`n`t{{`n`t`t`"path`"`t`t`"{1}`"`n`t}}`n}}`n" -f $steam.Replace('\', '\\'), $lib2.Replace('\', '\\')
    Set-TestText (Join-Path $steam 'steamapps\libraryfolders.vdf') $vdf
    Set-TestText (Join-Path $steam 'steamapps\appmanifest_570.acf') (New-TestManifest '570' 'Dota 2' 4 1700000000)
    Set-TestText (Join-Path $steam 'steamapps\appmanifest_228980.acf') (New-TestManifest '228980' 'Steamworks Common Redistributables' 4 0)
    Set-TestText (Join-Path $steam 'steamapps\appmanifest_999.acf') (New-TestManifest '999' 'Half Downloaded' 1026 0)
    Set-TestText (Join-Path $steam 'steamapps\appmanifest_1.acf') (New-TestManifest '1x' 'Bad Id' 4 0)
    Set-TestText (Join-Path $lib2 'steamapps\appmanifest_730.acf') (New-TestManifest '730' 'Counter-Strike 2' 4 1700000500)
    Set-TestText (Join-Path $lib2 'steamapps\appmanifest_4242.acf') (New-TestManifest '4242' ('Evil' + [char]27 + '[2J Game') 4 0)
    $games = @(Get-NovaSteamGames -SteamPath $steam)
    $ids = (@($games | ForEach-Object { $_.Id } | Sort-Object) -join ',')
    if ($ids -ne '4242,570,730') { throw ('Steam: нашлись не те игры: {0}' -f $ids) }
    $dota = @($games | Where-Object { $_.Id -eq '570' })[0]
    if ($dota.Uri -ne 'steam://rungameid/570' -or @($dota.Words) -notcontains 'доту') { throw 'Steam: Dota 2 без ссылки или без «доту»' }
    $evil = @($games | Where-Object { $_.Id -eq '4242' })[0]
    if ($evil.Name -match '[\p{Cc}]' -or @($evil.Words).Count -ne 0) { throw 'Steam: управляющие символы из названия не убраны' }
    if ((Get-NovaLastGame -Games $games).Id -ne '730') { throw 'Steam: последней должна быть Counter-Strike 2' }
    # Время «последней игры» перечитывается из файла: Dota запустили только что.
    Set-TestText (Join-Path $steam 'steamapps\appmanifest_570.acf') (New-TestManifest '570' 'Dota 2' 4 1800000000)
    if ((Get-NovaLastGame -Games $games).Id -ne '570') { throw 'Steam: время последней игры не перечитано' }
    Write-Host 'ok  Steam: две библиотеки, служебное и недокачанное пропущено, мусор из названий убран, последняя игра'

    # --- Epic Games ---
    $epic = Join-Path $tmp 'Epic'
    Set-TestText (Join-Path $epic 'fortnite.item') '{"DisplayName":"Fortnite","AppName":"Fortnite","CatalogNamespace":"fn","CatalogItemId":"4fe75bbc5a674f4f9b356b5c90567da5","MainGameAppName":"Fortnite","AppCategories":["public","games","applications"],"bIsIncompleteInstall":false}'
    Set-TestText (Join-Path $epic 'evil.item') '{"DisplayName":"Evil","AppName":"Evil","CatalogNamespace":"../../x","CatalogItemId":"abc","AppCategories":["games"]}'
    Set-TestText (Join-Path $epic 'dlc.item') '{"DisplayName":"Some DLC","AppName":"Dlc1","CatalogNamespace":"ns","CatalogItemId":"abc","MainGameAppName":"Fortnite","AppCategories":["games"]}'
    Set-TestText (Join-Path $epic 'engine.item') '{"DisplayName":"Unreal Engine","AppName":"UE_5","CatalogNamespace":"ue","CatalogItemId":"abc","AppCategories":["engines"]}'
    Set-TestText (Join-Path $epic 'half.item') '{"DisplayName":"Half","AppName":"Half","CatalogNamespace":"ns","CatalogItemId":"abc","AppCategories":["games"],"bIsIncompleteInstall":true}'
    Set-TestText (Join-Path $epic 'broken.item') '{ not json'
    $epicGames = @(Get-NovaEpicGames -ManifestDir $epic)
    if ($epicGames.Count -ne 1 -or $epicGames[0].Uri -ne 'com.epicgames.launcher://apps/fn%3A4fe75bbc5a674f4f9b356b5c90567da5%3AFortnite?action=launch&silent=true') { throw ('Epic: нашлось не то: {0}' -f (($epicGames | ForEach-Object { $_.Name }) -join ', ')) }
    if (@($epicGames[0].Words) -notcontains 'фортнайт') { throw 'Epic: у Fortnite нет фразы' }
    Write-Host 'ok  Epic Games: Fortnite найден; дополнения, движок, недокачанное, сломанное и чужие символы в адресе — нет'

    # --- Riot ---
    $riot = Join-Path $tmp 'Riot Games'
    $client = Join-Path $tmp 'Riot Client\RiotClientServices.exe'
    Set-TestText $client 'fake'
    New-Item -ItemType Directory -Path (Join-Path $riot 'Metadata\valorant.live') -Force | Out-Null
    Set-TestText (Join-Path $riot 'RiotClientInstalls.json') ('{{"rc_default":"{0}"}}' -f $client.Replace('\', '/'))
    $riotGames = @(Get-NovaRiotGames -RiotData $riot)
    if ($riotGames.Count -ne 1 -or $riotGames[0].Exe -ne $client -or $riotGames[0].Arguments -ne '--launch-product=valorant --launch-patchline=live') { throw 'Riot: Valorant не найден' }
    if ((Get-NovaGameLaunchProblem $riotGames[0]) -ne '') { throw 'Riot: правильный запуск отклонён' }
    Set-TestText (Join-Path $riot 'RiotClientInstalls.json') '{"rc_default":"C:/Windows/System32/cmd.exe"}'
    if (@(Get-NovaRiotGames -RiotData $riot).Count -ne 0) { throw 'Riot: вместо Riot Client подсунули cmd.exe — и он принят' }
    Write-Host 'ok  Riot: Valorant найден, подменённый путь к клиенту не принят'

    # --- Правила запуска ---
    foreach ($good in @('steam://rungameid/570', $epicGames[0].Uri)) {
        if ((Get-NovaGameLaunchProblem ([pscustomobject]@{ Uri = $good })) -ne '') { throw ('Запуск: отклонена правильная ссылка {0}' -f $good) }
    }
    foreach ($bad in @('steam://rungameid/570 -console', 'steam://run/570//+connect 1.2.3.4', 'steam://rungameid/570/x', 'https://example.com/',
            'com.epicgames.launcher://apps/a%3Ab%3Ac?action=launch&silent=true&x=1', 'file:///C:/Windows/System32/cmd.exe', 'C:\Windows\System32\cmd.exe')) {
        if ((Get-NovaGameLaunchProblem ([pscustomobject]@{ Uri = $bad })) -eq '') { throw ('Запуск: принята опасная ссылка {0}' -f $bad) }
    }
    $badRiot = [pscustomobject]@{ Uri = ''; Exe = $client; Arguments = '--launch-product=valorant --launch-patchline=live --x' }
    if ((Get-NovaGameLaunchProblem $badRiot) -eq '') { throw 'Запуск: лишние параметры Riot приняты' }
    $threw = $false
    try { Start-NovaGame -Game ([pscustomobject]@{ Uri = 'file:///C:/x.exe' }) } catch { $threw = $true }
    if (-not $threw) { throw 'Запуск: Start-NovaGame не отказался от плохой ссылки' }
    Write-Host 'ok  запуск: только steam://rungameid/<номер>, ссылка Epic строгого вида и сам Riot Client'

    # --- Названия игр вслух ---
    foreach ($entry in (Get-NovaGameWordList)) {
        foreach ($word in $entry.Words) { if ($word -notmatch '^[а-яё]+( [а-яё]+)*\z') { throw ('Название вслух «{0}» — только русские буквы' -f $word) } }
    }
    Write-Host ('ok  словарь названий игр: {0} игр' -f @(Get-NovaGameWordList).Count)
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Режим игры на настоящей Windows ---
$toastKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$pauseKey = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$pauseNames = @('PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime')
function Get-Snapshot {
    $snap = [ordered]@{ scheme = (Get-NovaActivePowerScheme); overlay = (Get-NovaPowerOverlay) }
    $t = Get-NovaRegValue -Path $toastKey -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'
    $snap.toast = ('{0}:{1}' -f $t.Exists, $t.Value)
    foreach ($n in $pauseNames) { $v = Get-NovaRegValue -Path $pauseKey -Name $n; $snap[$n] = ('{0}:{1}' -f $v.Exists, $v.Value) }
    return (ConvertTo-Json -InputObject $snap -Compress)
}
if (Test-NovaGameModeActive) { [void](Stop-NovaGameMode) }
$before = Get-Snapshot
Write-Host ('до режима игры: {0}' -f $before)
Write-Summary ('режим игры: уведомления до — {0}' -f (Get-NovaToastSetting))

$r = Start-NovaGameMode -Updates
Write-Summary ('режим игры включён: питание {0}, уведомления {1} (применились: {2}), обновления {3}' -f $r.Power, $r.Toasts, $r.ToastsApplied, $r.Updates)
Write-Summary ('режим игры: уведомления во время игры — {0}' -f (Get-NovaToastSetting))
if (-not (Test-NovaGameModeActive)) { throw 'Режим игры: не включился' }
if ([int](Get-NovaRegValue -Path $toastKey -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED').Value -ne 0) { throw 'Режим игры: уведомления не выключены' }
$expiry = ConvertFrom-NovaUtcText ([string](Get-NovaRegValue -Path $pauseKey -Name 'PauseUpdatesExpiryTime').Value)
if (-not $expiry -or $expiry -lt [DateTime]::UtcNow.AddHours(11) -or $expiry -gt [DateTime]::UtcNow.AddHours(13)) { throw 'Режим игры: пауза обновлений не на 12 часов' }
if ($r.Power -eq 'set' -and (Get-NovaActivePowerScheme) -ne '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' -and (Get-NovaPowerOverlay) -ne 'ded574b5-45a0-4f42-8737-46345c09c238') { throw 'Режим игры: питание не на максимуме' }
Write-Host ('во время игры: {0}' -f (Get-Snapshot))
# Повторное включение ничего не портит: «как было» остаётся тем, что было до первого включения.
$again = Start-NovaGameMode -Updates
if ($again.Power -ne $r.Power) { throw 'Режим игры: повторное включение изменило запись о питании' }
$off = Stop-NovaGameMode
Write-Summary ('режим игры выключен: питание {0}, уведомления {1}, обновления {2}' -f $off.Power, $off.Toasts, $off.Updates)
$after = Get-Snapshot
if ($after -ne $before) { throw ("Режим игры: после выключения не как было.`nдо:    {0}`nпосле: {1}" -f $before, $after) }
if (Test-NovaGameModeActive) { throw 'Режим игры: после выключения остались записи' }
Write-Host 'ok  режим игры: включился (питание, уведомления, пауза обновлений на 12 часов) и вернул всё как было'

# Что ты поменял сам во время игры — Nova оставляет.
[void](Start-NovaGameMode -Updates)
Set-NovaRegValue -Path $toastKey -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -Value 1 -Kind 'DWord'
$mine = '2099-01-01T00:00:00Z'
Set-NovaRegValue -Path $pauseKey -Name 'PauseUpdatesExpiryTime' -Value $mine -Kind 'String'
$off = Stop-NovaGameMode
if ($off.Toasts -ne 'kept' -or [int](Get-NovaRegValue -Path $toastKey -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED').Value -ne 1) { throw 'Режим игры: включённые тобой уведомления не оставлены' }
if ($off.Updates -ne 'kept' -or [string](Get-NovaRegValue -Path $pauseKey -Name 'PauseUpdatesExpiryTime').Value -ne $mine) { throw 'Режим игры: твоя пауза обновлений не оставлена' }
Write-Host 'ok  режим игры: уведомления и паузу, которые ты поменял сам, Nova оставила'
# Возвращаем машину проверки как было.
$orig = ConvertFrom-Json $before
$t = [string]$orig.toast
if ($t.StartsWith('True:')) { Set-NovaRegValue -Path $toastKey -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -Value ([int]$t.Substring(5)) -Kind 'DWord' } else { Remove-NovaRegValue -Path $toastKey -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' }
foreach ($n in $pauseNames) {
    $v = [string]$orig.$n
    if ($v.StartsWith('True:')) { Set-NovaRegValue -Path $pauseKey -Name $n -Value $v.Substring(5) -Kind 'String' } else { Remove-NovaRegValue -Path $pauseKey -Name $n }
}

# Подделанные записи: чужой номер схемы питания и мусор в копии паузы — Nova не пишет их в систему.
Set-NovaRegValue -Path 'HKCU\Software\Nova' -Name 'GameMode' -Value '{"power":{"kind":"scheme","before":"x & calc","set":"8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"},"toasts":null,"apps":[{"name":"x","path":"C:\\Windows\\System32\\cmd.exe /c calc"}]}' -Kind 'String'
$off = Stop-NovaGameMode
if ($off.Power -ne 'failed' -or @($off.Reopen).Count -ne 0) { throw 'Режим игры: подделанная запись принята' }
[void](Get-NovaDataDir)
$fakeBackup = Get-NovaPauseBackupPath
$fakeSet = '2098-01-01T00:00:00Z'
Set-NovaRegValue -Path $pauseKey -Name 'PauseUpdatesExpiryTime' -Value $fakeSet -Kind 'String'
[IO.File]::WriteAllText($fakeBackup, ('{{"set":"{0}","before":{{"PauseUpdatesExpiryTime":{{"exists":true,"value":"junk; rm -rf"}}}}}}' -f $fakeSet))
if ((Restore-NovaGameUpdatesPause) -ne 'restored') { throw 'Режим игры: копия паузы не обработана' }
if ((Get-NovaRegValue -Path $pauseKey -Name 'PauseUpdatesExpiryTime').Exists) { throw 'Режим игры: мусор из копии записан в систему' }
foreach ($n in $pauseNames) {
    $v = [string]$orig.$n
    if ($v.StartsWith('True:')) { Set-NovaRegValue -Path $pauseKey -Name $n -Value $v.Substring(5) -Kind 'String' }
}
if ((Get-Snapshot) -ne $before) { throw 'Проверка не вернула машину как было' }
Write-Host 'ok  режим игры: подделанные записи (чужой номер схемы, команда вместо программы, мусор в паузе) не попали в систему'

$apps = @(Get-NovaBackgroundApps)
Write-Host ('фоновых программ сейчас: {0}' -f $apps.Count)
Write-Summary 'ok  тест режима игры и поиска игр пройден'
