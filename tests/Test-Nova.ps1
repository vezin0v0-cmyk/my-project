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
Remove-Item -LiteralPath $shared -Recurse -Force
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
