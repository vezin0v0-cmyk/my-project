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
    .\Nova.ps1 -Mode Check        # проверить, готова ли система
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Preview', 'Apply', 'Undo', 'Measure', 'Check')]
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

# Проверка системы: версия Windows, перезагрузка после обновлений, место на диске, ноутбук.
function Invoke-NovaCheckFlow {
    $context = $null
    try { $context = Import-NovaSettings } catch { Write-Nova 'Проверяю систему без config.json.' dim }
    $summary = Show-NovaHealth (Get-NovaHealth -Context $context)
    if ($summary.Stop -gt 0) { return 1 }
    return 0
}

# Короткий итог проверки для главного меню.
function Show-NovaHealthLine {
    try {
        $context = $null
        try { $context = Get-NovaContext -ConfigPath $ConfigPath -TweaksPath $tweaksPath } catch { $context = $null }
        $checks = Get-NovaHealth -Context $context
        $summary = Get-NovaHealthSummary $checks
        $system = Get-NovaSystemInfo
        $name = '{0} {1}' -f $system.Name, $system.Version
        if ($summary.Stop -gt 0) {
            Write-Nova ('{0} — Nova не сможет работать, подробности в пункте 6' -f $name) err
        } elseif ($summary.Warn -gt 0) {
            Write-Nova ('{0} — есть замечания ({1}), подробности в пункте 6' -f $name, $summary.Warn) warn
        } else {
            Write-Nova ('{0} — система готова' -f $name) ok
        }
    } catch {
        Write-Nova 'Не удалось проверить систему — пункт 6 покажет подробности.' dim
    }
}

function Invoke-NovaPreviewFlow {
    $context = Import-NovaSettings
    $summary = Show-NovaHealth (Get-NovaHealth -Context $context)
    if ($summary.Stop -gt 0) { throw 'Сначала исправь то, что отмечено красным.' }
    Write-Host ''
    Write-Nova 'Проверяю, что изменится...' dim
    $plan = @(Get-NovaPlan -Context $context)
    $appPlan = Get-NovaAppPlan -Context $context
    [void](Show-NovaPlan -Plan $plan -AppPlan $appPlan -Detailed)
    Write-Nova 'Это только просмотр — в системе ничего не изменено.' dim
}

function Invoke-NovaApplyFlow {
    $context = Import-NovaSettings
    $checks = Get-NovaHealth -Context $context
    $health = Show-NovaHealth $checks -ProblemsOnly
    if ($health.Stop -gt 0) { throw 'Сначала исправь то, что отмечено красным.' }
    if (@($checks | Where-Object { $_.Id -eq 'reboot' -and $_.Status -eq 'warn' }).Count -gt 0) {
        if (-not (Confirm-NovaAction 'Windows ждёт перезагрузки. Всё равно применить сейчас?')) {
            Write-Nova 'Хорошо. Перезагрузи компьютер и запусти Nova снова.' dim
            return 0
        }
    }
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

    if ($null -eq (Get-NovaProp (Read-NovaMeasureData) 'before')) {
        Write-Host ''
        Write-Nova 'Запоминаю, как Windows работает сейчас, — потом сравним «было → стало» (пункт 5 в меню)...' dim
        [void](Save-NovaMeasurement -Label 'before')
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
    Write-Nova 'После перезагрузки открой Nova и выбери 5 — увидишь, что стало с процессами, службами и памятью.' info
    if ($result.Failed -gt 0) { return 1 }
    return 0
}

function Invoke-NovaMeasureFlow {
    Write-Host ''
    Write-Nova 'Считаю процессы, службы, задачи и память...' dim
    $data = Read-NovaMeasureData
    if ($null -eq (Get-NovaProp $data 'before')) {
        $m = Save-NovaMeasurement -Label 'before'
        Write-Nova ('Сейчас: процессов {0}, служб {1}, задач {2}, занято памяти {3} МБ.' -f $m.processes, $m.services, $m.tasks, $m.memoryMB) ok
        Write-Nova 'Это замер «до». Примени Nova, перезагрузи компьютер и замерь снова — увидишь разницу.' info
        return 0
    }
    $after = Save-NovaMeasurement -Label 'after'
    if ($after.uptimeMinutes -lt 3) {
        Write-Nova 'Компьютер включён меньше 3 минут — Windows ещё загружается, цифры будут неточными. Лучше замерить чуть позже.' warn
    }
    Show-NovaMeasurement -Before $data.before -After $after
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
    $entries = @(Get-NovaProp $doc 'entries' @())
    $tweakCount = @($entries | ForEach-Object { Get-NovaProp $_ 'tweak' } | Where-Object { $_ } | Select-Object -Unique).Count
    $appCount = @($entries | Where-Object { $_.type -eq 'appRemoved' -or $_.type -eq 'appInstalled' }).Count
    Write-Host ''
    Write-Nova ('Последний запуск: {0}. Настроек: {1}, приложений: {2}' -f $doc.created, $tweakCount, $appCount) info
    if (-not (Confirm-NovaAction 'Вернуть всё, как было до этого запуска?')) {
        Write-Nova 'Отменено.' dim
        return 0
    }
    $result = Invoke-NovaUndo -BackupPath $latest.FullName
    Clear-NovaMeasurement
    if ($result.RestartExplorer) { Restart-NovaExplorer }
    Write-Host ''
    if ($result.Failed -eq 0) {
        Write-Nova 'Готово! Всё вернулось, как было до этого запуска.' ok
    } else {
        Write-Nova ('Вернуть не удалось: {0} — подробности выше. Остальное возвращено.' -f $result.Failed) warn
    }
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
        Show-NovaHealthLine
        Write-Host ''
        Write-Host '  1  Посмотреть, что изменится (ничего не меняет)' -ForegroundColor White
        Write-Host '  2  Применить настройки' -ForegroundColor White
        Write-Host '  3  Отменить последний запуск' -ForegroundColor White
        Write-Host '  4  Открыть config.json — выбрать, что включать' -ForegroundColor White
        Write-Host '  5  Замерить: было → стало (процессы, службы, память)' -ForegroundColor White
        Write-Host '  6  Проверить систему' -ForegroundColor White
        Write-Host '  0  Выход' -ForegroundColor White
        Write-Host ''
        $choice = (Read-Host '  Выбери пункт').Trim()
        try {
            switch ($choice) {
                '1' { Invoke-NovaPreviewFlow; Wait-NovaKey }
                '2' { [void](Invoke-NovaApplyFlow); Wait-NovaKey }
                '3' { [void](Invoke-NovaUndoFlow); Wait-NovaKey }
                '4' { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $ConfigPath) }
                '5' { [void](Invoke-NovaMeasureFlow); Wait-NovaKey }
                '6' { [void](Invoke-NovaCheckFlow); Wait-NovaKey }
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
        'Measure' { Show-NovaBanner; $exitCode = Invoke-NovaMeasureFlow }
        'Check' { Show-NovaBanner; $exitCode = Invoke-NovaCheckFlow }
    }
} catch {
    Write-Nova ('Ошибка: {0}' -f $_.Exception.Message) err
    $exitCode = 1
} finally {
    if ($transcript) { Stop-Transcript | Out-Null }
}

if ($PauseAtEnd -and $Mode -ne 'Menu') { Wait-NovaKey }
exit $exitCode
