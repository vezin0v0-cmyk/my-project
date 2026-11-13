<#
.SYNOPSIS
    Nova — делает Windows 10/11 такой, как нравится тебе.

.DESCRIPTION
    Убирает рекламу, слежку и лишние приложения, настраивает внешний вид и скорость.
    Что включать, выбирается в config.json. Перед изменениями Nova сохраняет, как было,
    поэтому любой запуск можно отменить из меню.

.EXAMPLE
    .\Nova.ps1                    # меню
    .\Nova.ps1 -Mode Preview      # только посмотреть, что изменится
    .\Nova.ps1 -Mode Apply -Yes   # применить без вопросов
    .\Nova.ps1 -Mode Undo -Yes    # отменить последний запуск
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Preview', 'Apply', 'Undo')]
    [string]$Mode = 'Menu',
    [string]$ConfigPath,
    [switch]$Yes,
    [switch]$NoRestorePoint,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $projectRoot 'config.json' }
$tweaksPath = Join-Path $PSScriptRoot 'tweaks.json'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -Force -DisableNameChecking

# Без прав администратора Windows не даст менять системные настройки — перезапускаемся с ними.
if (-not (Test-NovaAdmin)) {
    Write-Host ''
    Write-Host '  Nova нужны права администратора. Windows сейчас спросит разрешение — нажми «Да».' -ForegroundColor Yellow
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-Mode', $Mode, '-ConfigPath', ('"{0}"' -f $ConfigPath), '-PauseAtEnd')
    if ($Yes) { $argumentList += '-Yes' }
    if ($NoRestorePoint) { $argumentList += '-NoRestorePoint' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentList
    } catch {
        Write-Host '  Запуск отменён. Без прав администратора Nova работать не может.' -ForegroundColor Red
    }
    return
}

function Show-NovaBanner {
    param([switch]$Clear)
    if ($Clear) {
        try { Clear-Host } catch { Write-Verbose 'Не удалось очистить экран.' }
    }
    Write-Host ''
    Write-Host '   _   _  _____  _   _  ___ ' -ForegroundColor Magenta
    Write-Host '  | \ | ||  _  || | | |/ _ \' -ForegroundColor Magenta
    Write-Host '  |  \| || | | || | | / /_\ \' -ForegroundColor Magenta
    Write-Host '  | . ` || | | || | | |  _  |' -ForegroundColor Magenta
    Write-Host '  | |\  |\ \_/ /\ \_/ / | | |' -ForegroundColor Magenta
    Write-Host '  \_| \_/ \___/  \___/\_| |_/' -ForegroundColor Magenta
    Write-Host ''
    Write-Nova ('Nova {0} — твоя Windows, настроенная под тебя' -f (Get-NovaVersion)) dim
}

function Confirm-NovaAction {
    param([string]$Question)
    if ($Yes) { return $true }
    Write-Host ''
    $answer = Read-Host ('  {0}  1 — да, 0 — нет' -f $Question)
    return ($answer.Trim() -eq '1')
}

function Wait-NovaKey {
    Write-Host ''
    [void](Read-Host '  Нажми Enter, чтобы продолжить')
}

function Import-NovaSettings {
    $context = Get-NovaContext -ConfigPath $ConfigPath -TweaksPath $tweaksPath
    if ($context.Problems.Count -gt 0) {
        Write-Host ''
        Write-Nova 'В настройках есть ошибки — исправь их и запусти Nova снова:' err
        foreach ($problem in $context.Problems) { Write-Nova $problem warn }
        throw 'Настройки содержат ошибки.'
    }
    return $context
}

function Show-NovaSystem {
    param($Context)
    $system = $Context.System
    Write-Nova ('Система: {0} {1}, сборка {2} ({3})' -f $system.Name, $system.Version, $system.Build, $system.Edition) dim
    if ($system.Build -lt 10240) { throw 'Nova работает только на Windows 10 и Windows 11.' }
    if ($system.IsServer) { Write-Nova 'Это Windows Server. Nova рассчитана на Windows 10/11 — часть настроек может не сработать.' warn }
}

function Invoke-NovaPreviewFlow {
    $context = Import-NovaSettings
    Show-NovaSystem $context
    Write-Host ''
    Write-Nova 'Проверяю, что изменится...' dim
    $plan = @(Get-NovaPlan -Context $context)
    $appPlan = Get-NovaAppPlan -Context $context
    [void](Show-NovaPlan -Plan $plan -AppPlan $appPlan -Detailed)
    Write-Nova 'Это только просмотр — в системе ничего не изменено.' dim
}

function Invoke-NovaApplyFlow {
    $context = Import-NovaSettings
    Show-NovaSystem $context
    Write-Host ''
    Write-Nova 'Проверяю, что изменится...' dim
    $plan = @(Get-NovaPlan -Context $context)
    $appPlan = Get-NovaAppPlan -Context $context
    $summary = Show-NovaPlan -Plan $plan -AppPlan $appPlan
    if ($summary.Total -eq 0) {
        Write-Nova 'Всё уже настроено — менять нечего.' ok
        return 0
    }
    if (-not (Confirm-NovaAction 'Применить эти изменения?')) {
        Write-Nova 'Отменено. Ничего не изменено.' dim
        return 0
    }

    $wantRestorePoint = (-not $NoRestorePoint) -and [bool](Get-NovaProp $context.Config 'createRestorePoint' $true)
    if ($wantRestorePoint) {
        Write-Host ''
        Write-Nova 'Создаю точку восстановления Windows (это может занять минуту)...' dim
        if (New-NovaRestorePoint) {
            Write-Nova 'Точка восстановления создана.' ok
        } elseif (-not (Confirm-NovaAction 'Продолжить без точки восстановления? Отменить изменения всё равно можно будет через меню Nova.')) {
            Write-Nova 'Отменено. Ничего не изменено.' dim
            return 0
        }
    }

    $result = Invoke-NovaApply -Context $context -Plan $plan -AppPlan $appPlan
    if ($result.RestartExplorer) {
        Write-Nova 'Перезапускаю Проводник, чтобы изменения появились сразу...' dim
        Restart-NovaExplorer
    }

    Write-Host ''
    Write-Nova ('Готово! Настроек применено: {0}, удалено приложений: {1}, установлено программ: {2}.' -f $result.Applied, $result.AppsRemoved, $result.AppsInstalled) ok
    if ($result.Failed -gt 0) { Write-Nova ('С ошибками: {0} — подробности выше.' -f $result.Failed) warn }
    if ($result.BackupPath) { Write-Nova ('Как было до изменений, сохранено в {0}' -f $result.BackupPath) dim }
    Write-Nova 'Чтобы всё точно применилось, перезагрузи компьютер.' info
    if ($result.Failed -gt 0) { return 1 }
    return 0
}

function Invoke-NovaUndoFlow {
    $backups = @(Get-NovaBackup)
    if ($backups.Count -eq 0) {
        Write-Host ''
        Write-Nova 'Отменять нечего — Nova ещё ничего не менял (или всё уже отменено).' dim
        return 0
    }
    $latest = $backups[0]
    $doc = Read-NovaJson $latest.FullName
    $count = @($doc.entries).Count
    Write-Host ''
    Write-Nova ('Последний запуск: {0}, изменений: {1}' -f $doc.created, $count) info
    if (-not (Confirm-NovaAction 'Вернуть всё, как было до этого запуска?')) {
        Write-Nova 'Отменено.' dim
        return 0
    }
    $result = Invoke-NovaUndo -BackupPath $latest.FullName
    if ($result.RestartExplorer) { Restart-NovaExplorer }
    Write-Host ''
    Write-Nova ('Готово! Возвращено изменений: {0}.' -f $result.Restored) ok
    if ($result.RemovedApps.Count -gt 0) {
        Write-Nova 'Удалённые приложения вернуть автоматически нельзя — при желании поставь их заново из Microsoft Store:' warn
        foreach ($name in $result.RemovedApps) { Write-Nova $name dim }
    }
    if ($result.InstalledApps.Count -gt 0) {
        Write-Nova 'Установленные программы остались — удалить их можно в «Параметры → Приложения»:' warn
        foreach ($name in $result.InstalledApps) { Write-Nova $name dim }
    }
    if ($backups.Count -gt 1) { Write-Nova ('Есть ещё более ранние запуски ({0}) — их можно отменить так же.' -f ($backups.Count - 1)) dim }
    Write-Nova 'Перезагрузи компьютер, чтобы всё точно вернулось.' info
    if ($result.Failed -gt 0) { return 1 }
    return 0
}

function Start-NovaMenu {
    while ($true) {
        Show-NovaBanner -Clear
        Write-Host ''
        Write-Host '  1  Посмотреть, что изменится (ничего не меняет)' -ForegroundColor White
        Write-Host '  2  Применить настройки' -ForegroundColor White
        Write-Host '  3  Отменить последний запуск' -ForegroundColor White
        Write-Host '  4  Открыть config.json — выбрать, что включать' -ForegroundColor White
        Write-Host '  0  Выход' -ForegroundColor White
        Write-Host ''
        $choice = (Read-Host '  Выбери пункт').Trim()
        try {
            switch ($choice) {
                '1' { Invoke-NovaPreviewFlow; Wait-NovaKey }
                '2' { [void](Invoke-NovaApplyFlow); Wait-NovaKey }
                '3' { [void](Invoke-NovaUndoFlow); Wait-NovaKey }
                '4' { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $ConfigPath) }
                '0' { return }
            }
        } catch {
            Write-Nova ('Ошибка: {0}' -f $_.Exception.Message) err
            Wait-NovaKey
        }
    }
}

$exitCode = 0
$logPath = Join-Path (Get-NovaDataDir) ('logs\nova-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$transcript = $false
try {
    Start-Transcript -LiteralPath $logPath -ErrorAction Stop | Out-Null
    $transcript = $true
} catch {
    $transcript = $false
}

try {
    switch ($Mode) {
        'Menu' { Start-NovaMenu }
        'Preview' { Show-NovaBanner; Invoke-NovaPreviewFlow }
        'Apply' { Show-NovaBanner; $exitCode = Invoke-NovaApplyFlow }
        'Undo' { Show-NovaBanner; $exitCode = Invoke-NovaUndoFlow }
    }
} catch {
    Write-Nova ('Ошибка: {0}' -f $_.Exception.Message) err
    $exitCode = 1
} finally {
    if ($transcript) { Stop-Transcript | Out-Null }
}

if ($PauseAtEnd -and $Mode -ne 'Menu') { Wait-NovaKey }
exit $exitCode
