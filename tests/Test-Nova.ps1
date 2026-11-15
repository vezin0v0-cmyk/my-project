# Полная проверка на настоящей Windows (запускается в GitHub Actions):
# 1) запоминает, как настроена система;
# 2) включает и применяет все настройки;
# 3) проверяет, что всё применилось;
# 4) отменяет изменения и проверяет, что система вернулась точно в исходное состояние.
# ВНИМАНИЕ: меняет систему. Запускай только на виртуальной машине.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking

if (-not (Test-NovaAdmin)) { throw 'Тест нужно запускать с правами администратора.' }

$context = Get-NovaContext -ConfigPath (Join-Path $root 'config.json') -TweaksPath (Join-Path $root 'src\tweaks.json')
if ($context.Problems.Count -gt 0) {
    $context.Problems | ForEach-Object { Write-Host "::error::$_" }
    throw 'Ошибки в tweaks.json или config.json'
}
Write-Host ('Система: {0} {1}, сборка {2}' -f $context.System.Name, $context.System.Version, $context.System.Build)

# Предохранитель: настройка, которая трогает защиту Windows, не проходит проверку.
$evil = @(
    [pscustomobject]@{ id = 'evil-av'; category = 'system'; title = 'x'; actions = @([pscustomobject]@{ type = 'registry'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender'; name = 'DisableAntiSpyware'; kind = 'DWord'; value = 1 }) },
    [pscustomobject]@{ id = 'evil-fw'; category = 'system'; title = 'x'; actions = @([pscustomobject]@{ type = 'service'; name = 'mpssvc'; startup = 'Disabled' }) },
    [pscustomobject]@{ id = 'evil-uac'; category = 'system'; title = 'x'; actions = @([pscustomobject]@{ type = 'registry'; path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; name = 'EnableLUA'; kind = 'DWord'; value = 0 }) },
    [pscustomobject]@{ id = 'evil-wu'; category = 'system'; title = 'x'; actions = @([pscustomobject]@{ type = 'scheduledTask'; path = '\Microsoft\Windows\WindowsUpdate\'; name = 'Scheduled Start' }) }
)
$evilProblems = @(Test-NovaDefinition -Config ([pscustomobject]@{ tweaks = [pscustomobject]@{} }) -Tweaks $evil | Where-Object { $_ -like '*защиту Windows*' })
if ($evilProblems.Count -ne 4) { throw ('Предохранитель пропустил отключение защиты: поймано {0} из 4.' -f $evilProblems.Count) }
Write-Host 'Предохранитель не пропускает отключение защиты Windows.'

# Пути в tweaks.json: «..» не выводит ни из папки assets, ни из папки данных Nova.
$escape = @(
    [pscustomobject]@{ id = 'esc-to'; category = 'style'; title = 'x'; actions = @([pscustomobject]@{ type = 'copyFile'; from = 'assets/oem/nova-logo.bmp'; to = '{NovaData}\..\..\Windows\evil.bmp' }) },
    [pscustomobject]@{ id = 'esc-from'; category = 'style'; title = 'x'; actions = @([pscustomobject]@{ type = 'copyFile'; from = 'assets/../config.json'; to = '{NovaData}\x.json' }) },
    [pscustomobject]@{ id = 'esc-wall'; category = 'style'; title = 'x'; actions = @([pscustomobject]@{ type = 'wallpaper'; file = 'assets/../config.json' }) }
)
$escProblems = @(Test-NovaDefinition -Config ([pscustomobject]@{ tweaks = [pscustomobject]@{} }) -Tweaks $escape | Where-Object { $_ -like '*только*' })
if ($escProblems.Count -ne 3) { throw ('Пути с «..» в tweaks.json прошли проверку: поймано {0} из 3.' -f $escProblems.Count) }
# Части Windows в removeApps — ошибка в config.json.
$protectedCfg = [pscustomobject]@{ tweaks = [pscustomobject]@{}; removeApps = [pscustomobject]@{ 'Microsoft.WindowsStore' = $true; 'Microsoft.DesktopAppInstaller' = $true; 'Microsoft.VCLibs.140.00' = $true; 'Microsoft.BingNews' = $true } }
$appProblems = @(Test-NovaDefinition -Config $protectedCfg -Tweaks @() | Where-Object { $_ -like '*часть Windows*' })
if ($appProblems.Count -ne 3) { throw ('Удаление частей Windows в config.json не поймано: {0} из 3.' -f $appProblems.Count) }
if (Test-NovaProtectedApp 'Microsoft.BingNews') { throw 'обычное приложение принято за часть Windows' }
Write-Host 'Пути с «..» и удаление Store/winget/библиотек в config.json не проходят проверку.'

# Отмена запуска прежней версии снимает «замок», который Nova больше не ставит (политика Game DVR).
$allowedNow = Get-NovaAllowedTargets $context.Tweaks
$oldEntry = [pscustomobject]@{ type = 'registry'; tweak = 'game-dvr-off'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; name = 'AllowGameDVR'; existed = $false; kind = 'DWord'; value = $null }
$why = Test-NovaJournalEntry -Entry $oldEntry -Allowed $allowedNow
if ($why) { throw ('отмена старого запуска не снимет прежний «замок»: {0}' -f $why) }
$alien = [pscustomobject]@{ type = 'registry'; tweak = 'x'; path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender'; name = 'DisableAntiSpyware'; existed = $false; kind = 'DWord'; value = $null }
if (-not (Test-NovaJournalEntry -Entry $alien -Allowed $allowedNow)) { throw 'отмена приняла запись, которой у Nova никогда не было' }
Write-Host 'Отмена старых запусков снимает прежние «замки», а чужие записи по-прежнему не принимает.'

# HKU — только служебный профиль NetworkService; другие профили и «ключ=значение» с «;» не проходят проверку.
$hku = @(
    [pscustomobject]@{ id = 'hku-system'; category = 'system'; title = 'x'; actions = @([pscustomobject]@{ type = 'registry'; path = 'HKU\S-1-5-18\Software\x'; name = 'y'; kind = 'DWord'; value = 1 }) },
    [pscustomobject]@{ id = 'hku-default'; category = 'system'; title = 'x'; actions = @([pscustomobject]@{ type = 'registry'; path = 'HKU\.DEFAULT\Software\x'; name = 'y'; kind = 'DWord'; value = 1 }) },
    [pscustomobject]@{ id = 'pair-bad'; category = 'system'; title = 'x'; actions = @([pscustomobject]@{ type = 'registry'; path = 'HKCU\Software\x'; name = 'y'; kind = 'String'; pair = 'A'; value = '1;B=2' }) },
    [pscustomobject]@{ id = 'keep-bad'; category = 'system'; title = 'x'; keepIfSet = @([pscustomobject]@{ path = 'HKCU\Software\x'; name = 'other' }); actions = @([pscustomobject]@{ type = 'registry'; path = 'HKCU\Software\x'; name = 'y'; kind = 'DWord'; value = 1 }) }
)
$hkuProblems = @(Test-NovaDefinition -Config ([pscustomobject]@{ tweaks = [pscustomobject]@{} }) -Tweaks $hku)
if ($hkuProblems.Count -ne 4) { throw ('Чужие профили HKU, плохая пара или keepIfSet прошли проверку: {0}' -f ($hkuProblems -join ' / ')) }
Write-Host 'HKU разрешён только для служебного профиля NetworkService; плохие пары и keepIfSet ловятся.'

# «Ключ=значение;»: свой ключ меняется, чужие остаются.
$pairCases = @(
    @('', 'SwapEffectUpgradeEnable', '1', 'SwapEffectUpgradeEnable=1;'),
    @('AutoHDREnable=1;', 'SwapEffectUpgradeEnable', '1', 'AutoHDREnable=1;SwapEffectUpgradeEnable=1;'),
    @('SwapEffectUpgradeEnable=0;AutoHDREnable=1;', 'SwapEffectUpgradeEnable', '1', 'SwapEffectUpgradeEnable=1;AutoHDREnable=1;'),
    @('AutoHDREnable=1;SwapEffectUpgradeEnable=1;', 'SwapEffectUpgradeEnable', $null, 'AutoHDREnable=1;'),
    @('SwapEffectUpgradeEnable=1;', 'SwapEffectUpgradeEnable', $null, '')
)
foreach ($case in $pairCases) {
    $got = Set-NovaPairValue $case[0] $case[1] $case[2]
    if ($got -cne $case[3]) { throw ('«ключ=значение»: из «{0}» получилось «{1}», ждали «{2}»' -f $case[0], $got, $case[3]) }
}
if ((Get-NovaPairValue 'A=1;SwapEffectUpgradeEnable=0;' 'SwapEffectUpgradeEnable') -cne '0') { throw '«ключ=значение»: не прочитался ключ' }
Write-Host '«Ключ=значение;» меняет только свой ключ.'

# Отмена не трогает то, что после Nova поменяли (ты сам или Windows).
$probe = 'HKCU\Software\NovaUndoTest'
Set-NovaRegValue -Path $probe -Name 'Mine' -Value 5 -Kind 'DWord'
$entry = [pscustomobject]@{ type = 'registry'; path = $probe; name = 'Mine'; existed = $true; kind = 'DWord'; value = 1; set = 2; setKind = 'DWord' }
Undo-NovaEntry -Entry $entry
if ((Get-NovaRegValue -Path $probe -Name 'Mine').Value -ne 5) { throw 'Отмена затёрла значение, которое поменяли после Nova.' }
Set-NovaRegValue -Path $probe -Name 'Mine' -Value 2 -Kind 'DWord'
Undo-NovaEntry -Entry $entry
if ((Get-NovaRegValue -Path $probe -Name 'Mine').Value -ne 1) { throw 'Отмена не вернула значение, которое никто не трогал.' }
Set-NovaRegValue -Path $probe -Name 'Gpu' -Value 'A=1;SwapEffectUpgradeEnable=0;' -Kind 'String'
$pairEntry = [pscustomobject]@{ type = 'registry'; path = $probe; name = 'Gpu'; existed = $true; kind = 'String'; value = 'A=1;'; pair = 'SwapEffectUpgradeEnable'; pairOld = $null; set = '1' }
Undo-NovaEntry -Entry $pairEntry
if ((Get-NovaRegValue -Path $probe -Name 'Gpu').Value -cne 'A=1;SwapEffectUpgradeEnable=0;') { throw 'Отмена затёрла ключ, который поменяли после Nova.' }
Set-NovaRegValue -Path $probe -Name 'Gpu' -Value 'A=1;SwapEffectUpgradeEnable=1;B=2;' -Kind 'String'
Undo-NovaEntry -Entry $pairEntry
if ((Get-NovaRegValue -Path $probe -Name 'Gpu').Value -cne 'A=1;B=2;') { throw 'Отмена «ключ=значение» стёрла чужие ключи.' }
# keepIfSet: сведения производителя не заменяются, свои — обновляются.
$keepTweak = [pscustomobject]@{ id = 'k'; keepIfSet = @([pscustomobject]@{ path = $probe; name = 'Maker' }); actions = @([pscustomobject]@{ type = 'registry'; path = $probe; name = 'Maker'; kind = 'String'; value = 'Nova' }) }
Set-NovaRegValue -Path $probe -Name 'Maker' -Value 'LENOVO' -Kind 'String'
if (-not (Get-NovaKeepReason $keepTweak)) { throw 'Nova заменила бы сведения производителя.' }
Set-NovaRegValue -Path $probe -Name 'Maker' -Value 'Nova' -Kind 'String'
if (Get-NovaKeepReason $keepTweak) { throw 'Nova не обновила бы свои же сведения.' }
Remove-Item -LiteralPath 'HKCU:\Software\NovaUndoTest' -Recurse -Force
Write-Host 'Отмена не трогает то, что поменяли после Nova; сведения производителя Nova не заменяет.'

# Версия Nova в «О системе» подставляется сама: «Nova 0.5 · твоя Windows».
$short = ((Get-NovaVersion) -split '\.')[0..1] -join '.'
$model = Expand-NovaText 'Nova {NovaVersion} · твоя Windows'
if ($short -notmatch '^\d+\.\d+\z' -or $model -ne ('Nova ' + $short + ' · твоя Windows')) { throw ('Версия в «О системе» подставилась неверно: «{0}»' -f $model) }
Write-Host ('Версия в «О системе»: {0}' -f $model)

# Включаем все настройки. Гибернацию не трогаем: на виртуальных машинах её обычно нельзя включить обратно.
foreach ($tweak in $context.Tweaks) {
    $context.Config.tweaks.($tweak.id) = ($tweak.id -ne 'hibernation-off')
}

function Get-RegistryKeyPath {
    param([string]$Path)
    $state = Get-NovaRegValue -Path $Path -Name '__nova_probe__'
    return $state.KeyExists
}

# Снимок всего, что Nova может изменить.
function Get-Snapshot {
    $snapshot = [ordered]@{}
    foreach ($tweak in $context.Tweaks) {
        foreach ($action in @($tweak.actions)) {
            switch ($action.type) {
                'registry' {
                    $state = Get-NovaRegValue -Path $action.path -Name $action.name
                    $snapshot["value|$($action.path)|$($action.name)"] = '{0}|{1}|{2}' -f $state.Exists, $state.Kind, (@($state.Value) -join ',')
                    $snapshot["key|$($action.path)"] = [string](Get-RegistryKeyPath $action.path)
                }
                'service' { $snapshot["service|$($action.name)"] = '{0}|{1}' -f (Get-NovaServiceStartup $action.name), (Get-NovaServiceDelayed $action.name) }
                'powerScheme' { $snapshot['power'] = [string](Get-NovaActivePowerScheme) }
                'hibernate' { $snapshot['hibernate'] = Get-NovaHibernateState }
                'wallpaper' {
                    $snapshot['wallpaper'] = Get-NovaCurrentWallpaper
                    foreach ($name in @('WallpaperStyle', 'TileWallpaper')) {
                        $state = Get-NovaRegValue -Path 'HKCU\Control Panel\Desktop' -Name $name
                        $snapshot["desktop|$name"] = '{0}|{1}' -f $state.Exists, $state.Value
                    }
                }
                'copyFile' {
                    $path = Expand-NovaText $action.to
                    $snapshot["file|$path"] = [string](Get-NovaFileHash $path)
                }
                'scheduledTask' {
                    $state = Get-NovaTaskState $action.path $action.name
                    # Running и Ready — это одно и то же «включена»: задача могла просто запуститься.
                    if ($state -eq 'Running') { $state = 'Ready' }
                    $snapshot["task|$($action.path)$($action.name)"] = [string]$state
                }
            }
        }
    }
    return $snapshot
}

# Чужая настройка графики в той же строке, что и «оптимизация игр в окне»: Nova её не стирает.
$gpuKey = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'
Set-NovaRegValue -Path $gpuKey -Name 'DirectXUserGlobalSettings' -Value 'AutoHDREnable=1;' -Kind 'String'

$before = Get-Snapshot
Write-Host ('Запомнено параметров: {0}' -f $before.Count)

$plan = @(Get-NovaPlan -Context $context)
$toChange = @($plan | Where-Object { $_.Enabled -and $_.Applicable -and $_.NeedsChange })
Write-Host ('Нужно изменить настроек: {0}' -f $toChange.Count)
if ($toChange.Count -eq 0) { throw 'Тест бесполезен: менять нечего.' }

$noApps = [pscustomobject]@{ Remove = @(); Install = @(); WingetAvailable = $false }
$result = Invoke-NovaApply -Context $context -Plan $plan -AppPlan $noApps
Write-Host ('Применено: {0}, ошибок: {1}' -f $result.Applied, $result.Failed)
if ($result.Failed -gt 0) { throw 'При применении были ошибки.' }
if (-not $result.BackupPath) { throw 'Не создана резервная копия.' }

# После применения менять должно быть нечего.
$after = @(Get-NovaPlan -Context $context)
$left = @($after | Where-Object { $_.Enabled -and $_.Applicable -and $_.NeedsChange })
if ($left.Count -gt 0) {
    $left | ForEach-Object { Write-Host "::error::Не применилось: $($_.Id)" }
    throw 'Часть настроек не применилась.'
}
Write-Host 'Все настройки применились.'
$gpuNow = [string](Get-NovaRegValue -Path $gpuKey -Name 'DirectXUserGlobalSettings').Value
if ($gpuNow -cne 'AutoHDREnable=1;SwapEffectUpgradeEnable=1;') { throw ('Оптимизация игр в окне стёрла чужую настройку графики: «{0}»' -f $gpuNow) }
Write-Host 'Оптимизация игр в окне дописалась к Auto HDR, не стерев его.'

$undo = Invoke-NovaUndo -BackupPath $result.BackupPath
Write-Host ('Отменено записей: {0}, ошибок: {1}' -f $undo.Restored, $undo.Failed)
if ($undo.Failed -gt 0) { throw 'При отмене были ошибки.' }

$restored = Get-Snapshot
$mismatches = @(foreach ($key in $before.Keys) {
        if ($before[$key] -ne $restored[$key]) { '{0}: было «{1}», стало «{2}»' -f $key, $before[$key], $restored[$key] }
    })
if ($mismatches.Count -gt 0) {
    $mismatches | ForEach-Object { Write-Host "::error::$_" }
    throw 'После отмены система не вернулась в исходное состояние.'
}
Write-Host ('Отмена вернула все {0} параметров точно как было.' -f $before.Count)

# --- Защита отмены ---
$backups = Join-Path (Get-NovaDataDir) 'backups'

# 1. Подменённая резервная копия: чужое значение реестра не должно записаться, файл через «..» — удалиться.
$victim = Join-Path $env:ProgramData 'nova-victim.txt'
Set-Content -LiteralPath $victim -Value 'не трогать'
$probeKey = 'HKCU\Software\NovaTamperTest'
$fake = [pscustomobject]@{
    tool    = 'Nova'
    entries = @(
        [pscustomobject]@{ type = 'registry'; path = $probeKey; name = 'Owned'; existed = $true; kind = 'String'; value = 'hacked' },
        [pscustomobject]@{ type = 'keyCreated'; path = 'HKCU\Software\Microsoft' },
        [pscustomobject]@{ type = 'service'; name = 'EventLog'; startup = 'Disabled' },
        [pscustomobject]@{ type = 'wallpaper'; path = ''; installed = (Join-Path $env:ProgramData 'Nova\..\nova-victim.txt') }
    )
}
$fakePath = Join-Path $backups 'backup-test-tamper.json'
[System.IO.File]::WriteAllText($fakePath, ($fake | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
$tamper = Invoke-NovaUndo -BackupPath $fakePath
Remove-Item -LiteralPath ($fakePath -replace '\.json$', '.restored.json') -Force -ErrorAction SilentlyContinue
if ((Get-NovaRegValue -Path $probeKey -Name 'Owned').Exists) { throw 'Подменённая резервная копия записала чужое значение в реестр.' }
if (-not (Get-NovaRegValue -Path 'HKCU\Software\Microsoft' -Name '__nova_probe__').KeyExists) { throw 'Подменённая резервная копия удалила раздел реестра.' }
if ((Get-NovaServiceStartup 'EventLog') -eq 'Disabled') { throw 'Подменённая резервная копия отключила службу.' }
if ($tamper.Failed -ne 3) { throw ('Ожидалось 3 пропущенные записи, а пропущено {0}.' -f $tamper.Failed) }
if (-not (Test-Path -LiteralPath $victim)) { throw 'Подменённая резервная копия удалила файл через «..».' }
Remove-Item -LiteralPath $victim -Force
Write-Host 'Подменённая резервная копия не выполнилась.'

# 2. Раздел, созданный Nova, не удаляется, если в него записала другая программа.
$created = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'
$hadKey = (Get-NovaRegValue -Path $created -Name '__nova_probe__').KeyExists
$journal = New-Object System.Collections.ArrayList
Set-NovaRegValue -Path $created -Name 'StartupDelayInMSec' -Value 0 -Kind 'DWord' -Journal $journal -Tweak 'no-startup-delay'
[void]$journal.Add([pscustomobject]@{ type = 'registry'; tweak = 'no-startup-delay'; path = $created; name = 'StartupDelayInMSec'; existed = $false; kind = $null; value = $null })
Set-NovaRegValue -Path $created -Name 'OtherProgram' -Value 'keep me' -Kind 'String'
$keepPath = Join-Path $backups 'backup-test-keep.json'
Save-NovaJournal -Path $keepPath -Context $context -Journal $journal -RestartExplorer $false
[void](Invoke-NovaUndo -BackupPath $keepPath)
Remove-Item -LiteralPath ($keepPath -replace '\.json$', '.restored.json') -Force -ErrorAction SilentlyContinue
if (-not (Get-NovaRegValue -Path $created -Name 'OtherProgram').Exists) { throw 'Отмена удалила значение другой программы.' }
if ((Get-NovaRegValue -Path $created -Name 'StartupDelayInMSec').Exists) { throw 'Отмена не убрала значение Nova.' }
Remove-NovaRegValue -Path $created -Name 'OtherProgram'
if (-not $hadKey) { [void](Remove-NovaRegKeyIfEmpty -Path $created) }
Write-Host 'Чужие настройки в разделах Nova сохраняются.'

# 3. Папку Nova может менять только администратор.
$acl = Get-Acl -LiteralPath (Get-NovaDataDir)
$usersWrite = @($acl.Access | Where-Object {
        $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0') -and
        $_.AccessControlType -eq 'Allow' -and
        ($_.FileSystemRights -band ([System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')) -ne 0
    })
if ($usersWrite.Count -gt 0) { throw 'Обычные пользователи могут менять папку Nova.' }
if (-not $acl.AreAccessRulesProtected) { throw 'Права на папку Nova наследуются от ProgramData.' }
Write-Host 'Папка Nova закрыта от изменений обычными пользователями.'

# 4. Кто-то дал себе право менять папку Nova: при следующем запуске Nova откладывает её и создаёт новую.
$dataDir = Get-NovaDataDir
$backupsDir = Join-Path $dataDir 'backups'
$aclB = Get-Acl -LiteralPath $backupsDir
$aclB.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
Set-Acl -LiteralPath $backupsDir -AclObject $aclB
& (Get-Module Nova) { $script:DataDirProtected = $false }
$null = Get-NovaDataDir
$moved = @(Get-ChildItem -LiteralPath $env:ProgramData -Directory -Filter 'Nova.untrusted-*')
if ($moved.Count -eq 0) { throw 'Изменённая чужими правами папка Nova не была отложена.' }
if (Get-NovaTreeProblem -Path $dataDir -Trusted (Get-NovaTrustedSid)) { throw 'Новая папка Nova небезопасна.' }
$moved | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
Write-Host 'Захваченная папка Nova откладывается, вместо неё создаётся чистая.'

# 5. Папка проекта, которую могут менять другие пользователи, распознаётся.
$shared = Join-Path $env:TEMP ('nova-shared-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $shared | Out-Null
New-Item -ItemType Directory -Path (Join-Path $shared 'src') | Out-Null
Set-Content -LiteralPath (Join-Path $shared 'src\Nova.ps1') -Value 'x'
$aclS = Get-Acl -LiteralPath $shared
$aclS.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-11')), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
Set-Acl -LiteralPath $shared -AclObject $aclS
if (-not (Get-NovaProjectProblem -Root $shared)) { throw 'Папка, которую могут менять все пользователи, не распознана.' }
# Такую папку Nova предлагает скопировать к себе: копия получает права новой папки, .git не копируется.
New-Item -ItemType Directory -Path (Join-Path $shared '.git') | Out-Null
Set-Content -LiteralPath (Join-Path $shared '.git\config') -Value 'x'
Set-Content -LiteralPath (Join-Path $shared 'config.json') -Value '{}'
$copy = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('nova-copy-test-' + [guid]::NewGuid())
Copy-NovaProject -From $shared -To $copy
$copyProblem = Get-NovaProjectProblem -Root $copy
if ($copyProblem) { throw ('Копия Nova в папке пользователя не защищена: {0}' -f $copyProblem) }
if (-not (Test-Path -LiteralPath (Join-Path $copy 'src\Nova.ps1')) -or (Test-Path -LiteralPath (Join-Path $copy '.git'))) { throw 'Копия Nova собрана неверно.' }
Remove-Item -LiteralPath $copy -Recurse -Force
# Ссылка внутри — копировать отказывается (не идёт по ней в чужую папку).
$linkTarget = Join-Path $env:TEMP ('nova-link-target-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $linkTarget | Out-Null
cmd.exe /c mklink /J "$shared\src\evil" "$linkTarget" | Out-Null
$refused = $false
try { Copy-NovaProject -From $shared -To $copy } catch { $refused = $true }
cmd.exe /c rmdir "$shared\src\evil" | Out-Null
if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Recurse -Force }
Remove-Item -LiteralPath $linkTarget -Recurse -Force
if (-not $refused) { throw 'Nova скопировала папку со ссылкой на чужую папку.' }
Remove-Item -LiteralPath $shared -Recurse -Force
Write-Host 'Открытую для всех папку Nova копирует к тебе с правильными правами; папку со ссылками — не копирует.'

# Папка выше папки Nova, где посторонний может удалять вложенное, — тоже проблема (подменят папку целиком).
$outer = Join-Path $env:TEMP ('nova-outer-' + [guid]::NewGuid())
$inner = Join-Path $outer 'Nova'
New-Item -ItemType Directory -Path $inner -Force | Out-Null
$aclI = Get-Acl -LiteralPath $inner
$aclI.SetAccessRuleProtection($true, $true)
Set-Acl -LiteralPath $inner -AclObject $aclI
if (Get-NovaProjectProblem -Root $inner) { throw ('Обычная папка внутри TEMP почему-то считается открытой: {0}' -f (Get-NovaProjectProblem -Root $inner)) }
$aclO = Get-Acl -LiteralPath $outer
$aclO.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-11')), 'FullControl', 'None', 'None', 'Allow')))
Set-Acl -LiteralPath $outer -AclObject $aclO
$outerProblem = Get-NovaProjectProblem -Root $inner
Remove-Item -LiteralPath $outer -Recurse -Force
if ($outerProblem -notlike '*папку Nova целиком*') { throw ('Открытая папка выше папки Nova не замечена: «{0}»' -f $outerProblem) }
Write-Host 'Папка выше папки Nova, где посторонние могут подменить её целиком, замечается.'
Write-Host ('Папка проекта, открытая для всех, распознаётся. Эта папка в CI: {0}' -f $(if (Get-NovaProjectProblem -Root $root) { 'открыта для других' } else { 'закрыта' }))

# 6. Ссылка внутри папки Nova считается проблемой.
$dataDir = Get-NovaDataDir
$target = Join-Path $env:TEMP ('nova-victim-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $target | Out-Null
Set-Content -LiteralPath (Join-Path $target 'secret.txt') -Value 'x'
cmd.exe /c mklink /J "$dataDir\tools-link" "$target" | Out-Null
$innerProblem = Get-NovaTreeProblem -Path $dataDir -Trusted (Get-NovaTrustedSid)
cmd.exe /c rmdir "$dataDir\tools-link" | Out-Null
if ($innerProblem -notlike '*ссылка*') { throw ('Ссылка внутри папки Nova не замечена: {0}' -f $innerProblem) }
Write-Host 'Ссылка внутри папки Nova замечается.'

# 7. Вместо папки Nova подложили ссылку на чужую папку: права той папки не меняются, ссылка убирается.
$saved = $dataDir + '.test-saved'
[System.IO.Directory]::Move($dataDir, $saved)
$sddlBefore = (Get-Acl -LiteralPath $target).Sddl
cmd.exe /c mklink /J "$dataDir" "$target" | Out-Null
& (Get-Module Nova) { $script:DataDirProtected = $false }
$null = Get-NovaDataDir
$sddlAfter = (Get-Acl -LiteralPath $target).Sddl
$stillLink = [bool]((Get-Item -LiteralPath $dataDir -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)
foreach ($aside in @(Get-ChildItem -LiteralPath $env:ProgramData -Directory -Force -Filter 'Nova.untrusted-*')) {
    if ($aside.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { cmd.exe /c rmdir "$($aside.FullName)" | Out-Null }
    else { Remove-Item -LiteralPath $aside.FullName -Recurse -Force }
}
Remove-Item -LiteralPath $dataDir -Recurse -Force
[System.IO.Directory]::Move($saved, $dataDir)
& (Get-Module Nova) { $script:DataDirProtected = $false }
if (-not (Test-Path -LiteralPath (Join-Path $target 'secret.txt'))) { throw 'Файл в чужой папке пропал.' }
Remove-Item -LiteralPath $target -Recurse -Force
if ($sddlAfter -ne $sddlBefore) { throw 'Nova переписала права папки, на которую вела ссылка.' }
if ($stillLink) { throw 'Ссылка вместо папки Nova осталась.' }
Write-Host 'Ссылка вместо папки Nova убирается, права чужой папки не меняются.'

Write-Host 'ТЕСТ ПРОЙДЕН'
