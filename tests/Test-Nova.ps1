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

# 1. Подменённая резервная копия: чужое значение реестра не должно записаться.
$probeKey = 'HKCU\Software\NovaTamperTest'
$fake = [pscustomobject]@{
    tool    = 'Nova'
    entries = @(
        [pscustomobject]@{ type = 'registry'; path = $probeKey; name = 'Owned'; existed = $true; kind = 'String'; value = 'hacked' },
        [pscustomobject]@{ type = 'keyCreated'; path = 'HKCU\Software\Microsoft' },
        [pscustomobject]@{ type = 'service'; name = 'EventLog'; startup = 'Disabled' }
    )
}
$fakePath = Join-Path $backups 'backup-test-tamper.json'
[System.IO.File]::WriteAllText($fakePath, ($fake | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
$tamper = Invoke-NovaUndo -BackupPath $fakePath
Remove-Item -LiteralPath ($fakePath -replace '\.json$', '.restored.json') -Force -ErrorAction SilentlyContinue
if ((Get-NovaRegValue -Path $probeKey -Name 'Owned').Exists) { throw 'Подменённая резервная копия записала чужое значение в реестр.' }
if (-not (Get-NovaRegValue -Path 'HKCU\Software\Microsoft' -Name '__nova_probe__').KeyExists) { throw 'Подменённая резервная копия удалила раздел реестра.' }
if ((Get-NovaServiceStartup 'EventLog') -eq 'Disabled') { throw 'Подменённая резервная копия отключила службу.' }
if ($tamper.Failed -ne 2) { throw ('Ожидалось 2 пропущенные записи, а пропущено {0}.' -f $tamper.Failed) }
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

Write-Host 'ТЕСТ ПРОЙДЕН'
