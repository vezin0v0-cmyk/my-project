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
                'service' { $snapshot["service|$($action.name)"] = [string](Get-NovaServiceStartup $action.name) }
                'powerScheme' { $snapshot['power'] = [string](Get-NovaActivePowerScheme) }
                'hibernate' { $snapshot['hibernate'] = Get-NovaHibernateState }
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
Write-Host 'ТЕСТ ПРОЙДЕН'
