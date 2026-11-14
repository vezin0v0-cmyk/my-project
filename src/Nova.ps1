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
    .\Nova.ps1 -Mode Check        # проверить, готова ли система и что мешает играм
    .\Nova.ps1 -Mode Fps          # замер FPS в игре: до и после Nova
    .\Nova.ps1 -Mode Clean        # освободить место на диске
    .\Nova.ps1 -Mode Startup      # что запускается вместе с Windows
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Preview', 'Apply', 'Undo', 'Measure', 'Check', 'Fps', 'Clean', 'Startup')]
    [string]$Mode = 'Menu',
    [string]$ConfigPath,
    [switch]$Yes,
    [switch]$NoRestorePoint,
    [switch]$PauseAtEnd,
    # Замер FPS: сколько секунд записывать и через сколько начать.
    [ValidateRange(5, 600)][int]$Seconds = 60,
    [ValidateRange(0, 120)][int]$Delay = 10,
    # Очистка без долгих шагов (DISM) — для проверки.
    [switch]$Quick
)

$ErrorActionPreference = 'Stop'

# В ограниченном режиме PowerShell (его включают Smart App Control и некоторые политики) Nova работать не сможет.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host ''
    Write-Host '  Windows запустила PowerShell в ограниченном режиме — так Nova работать не сможет.' -ForegroundColor Red
    Write-Host '  Обычно это «Интеллектуальное управление приложениями» (Smart App Control) или политика организации.' -ForegroundColor Yellow
    Write-Host '  Что делать — в инструкции docs/CLEAN-INSTALL.md, раздел «Если Windows блокирует Nova».' -ForegroundColor Yellow
    if ($PauseAtEnd) { [void](Read-Host '  Нажми Enter, чтобы закрыть') }
    exit 1
}

# Модули — только системные: модуль с тем же именем в «Документах» пользователя не подменит команды Windows.
$env:PSModulePath = (@((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'), (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')) -join ';')
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $projectRoot 'config.json' }
$tweaksPath = Join-Path $PSScriptRoot 'tweaks.json'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NovaClean.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NovaGame.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NovaStartup.psm1') -Force -DisableNameChecking

# Без прав администратора Windows не даст менять системные настройки — перезапускаемся с ними.
if (-not (Test-NovaAdmin)) {
    Write-Host ''
    Write-Host '  Nova нужны права администратора. Windows сейчас спросит разрешение — нажми «Да».' -ForegroundColor Yellow
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-Mode', $Mode, '-ConfigPath', ('"{0}"' -f $ConfigPath), '-PauseAtEnd')
    if ($Yes) { $argumentList += '-Yes' }
    if ($NoRestorePoint) { $argumentList += '-NoRestorePoint' }
    if ($Mode -eq 'Fps') { $argumentList += @('-Seconds', $Seconds, '-Delay', $Delay) }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentList
    } catch {
        Write-Host '  Запуск отменён. Без прав администратора Nova работать не может.' -ForegroundColor Red
    }
    return
}

# Папку Nova не должны менять другие пользователи: Nova выполняет эти файлы с правами администратора.
function Assert-NovaProjectFolder {
    # Только для проверок в GitHub Actions: там рабочая папка открыта для всех.
    if ($env:NOVA_ALLOW_SHARED_FOLDER -eq '1' -and $env:GITHUB_ACTIONS -eq 'true') { return }
    $problem = Get-NovaProjectProblem -Root $projectRoot -ConfigPath $ConfigPath
    if (-not $problem) { return }
    Write-Host ''
    Write-Nova 'Папку Nova могут менять другие пользователи этого компьютера — запускать её с правами администратора небезопасно.' err
    Write-Nova ('Подробно: {0}' -f $problem) dim
    if ($problem -like '*владелец*') {
        Write-Nova 'Папку распаковал другой пользователь. Скачай и распакуй Nova под той учётной записью, из которой запускаешь.' warn
    } else {
        Write-Nova ('Перенеси папку Nova в свою папку пользователя: {0}' -f $env:USERPROFILE) warn
        Write-Nova 'Папки на других дисках (например, D:\) и флешки FAT/exFAT часто открыты для всех.' dim
    }
    throw 'Папка Nova не защищена от других пользователей.'
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
    param([switch]$Interactive)
    $context = $null
    try { $context = Import-NovaSettings } catch { Write-Nova 'Проверяю систему без config.json.' dim }
    $summary = Show-NovaHealth (Get-NovaHealth -Context $context)
    $game = @(Get-NovaGameCheck)
    if ($game.Count -gt 0) {
        [void](Show-NovaHealth $game -Title 'ДЛЯ ИГР: ВАЖНЕЕ ЛЮБЫХ НАСТРОЕК' -NoVerdict)
    }
    # Частоту монитора Nova может включить сама — только из меню, с подтверждением и откатом.
    if ($Interactive -and -not $Yes) {
        foreach ($check in $game) {
            if (-not $check.PSObject.Properties['Fix'] -or -not $check.Fix -or $check.Fix.Kind -ne 'hz') { continue }
            if (Confirm-NovaAction ('Включить {0} Гц вместо {1} Гц ({2})?' -f $check.Fix.Hz, $check.Fix.From, $check.Fix.Name.ToLowerInvariant())) {
                Invoke-NovaHzFix $check.Fix
            }
        }
    }
    if ($summary.Stop -gt 0) { return 1 }
    return 0
}

# Ждёт подтверждения N секунд. Нет ответа (например, экран погас и ничего не видно) — значит «нет».
function Read-NovaTimedYes {
    param([int]$Seconds = 15)
    try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $left = [int][math]::Ceiling(($end - (Get-Date)).TotalSeconds)
        Write-Host ("`r  Картинка в порядке? Нажми 1, чтобы оставить. Иначе верну как было через {0,2} с " -f $left) -NoNewline -ForegroundColor Yellow
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            Write-Host ''
            return ($key.KeyChar -eq '1')
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host ''
    return $false
}

# Новая частота сначала включается «на время»: если картинка пропала, через 15 секунд всё вернётся,
# а после перезагрузки — тем более. Запоминается, только когда человек подтвердил, что видит экран.
function Invoke-NovaHzFix {
    param($Fix)
    if ((Set-NovaDisplayHz -Device $Fix.Device -Hz $Fix.Hz -Test) -ne 0) {
        Write-Nova 'Windows не разрешает эту частоту для этого монитора — оставляю как есть.' warn
        return
    }
    Write-Nova ('Включаю {0} Гц. Если экран погаснет — ничего не нажимай: через 15 секунд вернётся как было.' -f $Fix.Hz) info
    Start-Sleep -Seconds 2
    if ((Set-NovaDisplayHz -Device $Fix.Device -Hz $Fix.Hz) -ne 0) {
        [void](Restore-NovaDisplay -Device $Fix.Device)
        Write-Nova 'Не получилось переключить частоту — оставил как было.' warn
        return
    }
    if (Read-NovaTimedYes -Seconds 15) {
        if ((Set-NovaDisplayHz -Device $Fix.Device -Hz $Fix.Hz -Persist) -eq 0) {
            Write-Nova ('Готово: {0} работает на {1} Гц. Вернуть можно в «Параметры → Дисплей».' -f $Fix.Name.ToLowerInvariant(), $Fix.Hz) ok
            return
        }
        [void](Restore-NovaDisplay -Device $Fix.Device)
        Write-Nova 'Windows не сохранила новую частоту — вернул прежнюю.' warn
        return
    }
    [void](Restore-NovaDisplay -Device $Fix.Device)
    Write-Nova ('Вернул {0} Гц.' -f $Fix.From) info
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

# Замер FPS в игре. «До» или «после» Nova определяется само: применена ли Nova сейчас.
function Invoke-NovaFpsFlow {
    $applied = @(Get-NovaBackup).Count -gt 0
    $label = 'before'
    $labelText = 'до Nova'
    if ($applied) { $label = 'after'; $labelText = 'после Nova' }
    $runs = @(Read-NovaFpsRuns)
    if (-not $Yes) {
        Write-Host ''
        Write-Nova 'ЗАМЕР FPS В ИГРЕ' title
        Write-Nova 'Nova запишет, как часто игра выдаёт кадры, и посчитает средний FPS и просадки (1% low).' info
        if ($applied) { Write-Nova ('Nova сейчас применена — это будет замер «{0}».' -f $labelText) info }
        else { Write-Nova ('Nova сейчас не применена — это будет замер «{0}».' -f $labelText) info }
        if ($runs.Count -gt 0) {
            Write-Host ''
            Write-Host '  1  Новый замер' -ForegroundColor White
            Write-Host '  2  Сравнить «до» и «после»' -ForegroundColor White
            Write-Host '  3  Стереть все замеры' -ForegroundColor White
            Write-Host '  0  Назад' -ForegroundColor White
            $choice = (Read-Host '  Выбери пункт').Trim()
            if ($choice -eq '2') {
                foreach ($game in @($runs | ForEach-Object { $_.game } | Select-Object -Unique)) { Show-NovaFpsReport -Game $game }
                return 0
            }
            if ($choice -eq '3') {
                if (Confirm-NovaAction 'Стереть все замеры FPS?') { Clear-NovaFpsRuns; Write-Nova 'Замеры стёрты.' ok }
                return 0
            }
            if ($choice -ne '1') { return 0 }
        }
        $problems = @()
        try { $problems = @(Get-NovaGameCheck | Where-Object { $_.Status -eq 'warn' }) } catch { $problems = @() }
        if ($problems.Count -gt 0) {
            Write-Host ''
            Write-Nova 'Сначала главное — это влияет на FPS сильнее любых настроек:' title
            foreach ($p in $problems) {
                Write-Nova ('{0}: {1}' -f $p.Name, $p.Text) warn
                if ($p.Hint) { Write-Nova ('    ' + $p.Hint) dim }
            }
        }
        Write-Host ''
        Write-Nova 'Как мерить честно:' title
        Write-Nova '- одна и та же игра, то же место на карте (лучше встроенный бенчмарк игры) и те же настройки графики;' info
        Write-Nova '- перед замером перезагрузи компьютер и закрой лишние программы;' info
        Write-Nova '- сделай по 3 замера «до» и «после» — Nova сравнит средние и учтёт разброс.' info
    }
    if (-not (Test-NovaPresentMon (Get-NovaPresentMonPath))) {
        Write-Host ''
        Write-Nova 'Для замера нужна программа PresentMon от Intel: бесплатная, с открытым кодом, около 1 МБ.' info
        if (-not (Confirm-NovaAction 'Скачать её с GitHub (github.com/GameTechDev/PresentMon)?')) { return 0 }
        Write-Nova 'Скачиваю и проверяю контрольную сумму...' dim
        [void](Install-NovaPresentMon)
        Write-Nova 'PresentMon готов.' ok
    }
    Write-Host ''
    Write-Nova ('Запусти игру. Когда будешь готов, нажми Enter и сразу переключись в игру (Alt+Tab).') info
    Write-Nova ('Через {0} с начнётся запись на {1} с — играй как обычно. В конце прозвучит сигнал.' -f $Delay, $Seconds) info
    if (-not $Yes) { [void](Read-Host '  Enter — начать') }
    Write-Nova 'Записываю кадры...' dim
    $csv = Invoke-NovaFpsCapture -Seconds $Seconds -Delay $Delay
    try { [Console]::Beep(880, 250); [Console]::Beep(1320, 250) } catch { Write-Verbose 'Нет звука.' }
    $byApp = Read-NovaFpsCsv $csv
    Remove-Item -LiteralPath $csv -Force -ErrorAction SilentlyContinue
    $game = Select-NovaFpsGame $byApp
    if (-not $game) { throw 'Во время записи ни одна игра не рисовала кадры. Игра точно была открыта на экране?' }
    $stats = Get-NovaFpsStats ([double[]]$byApp[$game].ToArray())
    if ($null -eq $stats) { throw ('Слишком мало кадров от {0}, чтобы что-то посчитать. Попробуй мерить дольше.' -f $game) }
    Save-NovaFpsRun ([pscustomobject]@{
            game = $game; label = $label; time = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            avg = $stats.Avg; low1 = $stats.Low1; low01 = $stats.Low01; frames = $stats.Frames; seconds = $stats.Seconds
        })
    Write-Host ''
    Write-Nova ('{0}, замер «{1}»: средний FPS {2}, 1% low {3}, 0.1% low {4} ({5} кадров за {6} с).' -f $game, $labelText, $stats.Avg, $stats.Low1, $stats.Low01, $stats.Frames, $stats.Seconds) ok
    Show-NovaFpsReport -Game $game
    return 0
}

# Автозагрузка: список и выключатель по номеру. Выключенная программа не удаляется.
function Show-NovaStartupList {
    param($Items)
    Write-Host ''
    Write-Nova 'АВТОЗАГРУЗКА — что запускается вместе с Windows' title
    if ($Items.Count -eq 0) { Write-Nova 'Вместе с Windows ничего не запускается.' ok; return }
    $i = 0
    foreach ($it in $Items) {
        $i++
        $state = 'вкл '
        $color = 'Green'
        if ($it.Protected) { $state = 'защ '; $color = 'DarkGray' } elseif (-not $it.Enabled) { $state = 'выкл'; $color = 'DarkGray' }
        $who = ''
        if ($it.Company) { $who = ' — ' + $it.Company }
        $note = ''
        if ($it.Missing) { $note = '  (файла нет — программу, похоже, удалили)' }
        Write-Host ('  {0,2}  [{1}]  {2}{3}{4}' -f $i, $state, $it.Title, $who, $note) -ForegroundColor $color
    }
    $on = @($Items | Where-Object { $_.Enabled -and -not $_.Protected }).Count
    Write-Nova ('Включено: {0}. Чем меньше программ стартует с Windows, тем быстрее она загружается и тем меньше висит в фоне.' -f $on) dim
}

function Invoke-NovaStartupFlow {
    while ($true) {
        $items = @(Get-NovaStartupItem | Sort-Object @{ Expression = { [int][bool]$_.Protected } }, Title)
        Show-NovaStartupList $items
        if ($Yes -or $Mode -ne 'Menu') { return 0 }
        Write-Host ''
        Write-Nova 'Введи номер, чтобы выключить или включить пункт. Пусто или 0 — назад.' info
        Write-Nova 'Выключенная программа не удаляется: её можно открыть вручную, а вернуть — здесь же или в Диспетчере задач → Автозагрузка.' dim
        $choice = (Read-Host '  Номер').Trim()
        if (-not $choice -or $choice -eq '0') { return 0 }
        $n = 0
        if (-not [int]::TryParse($choice, [ref]$n) -or $n -lt 1 -or $n -gt $items.Count) { Write-Nova 'Нет такого номера.' warn; continue }
        $item = $items[$n - 1]
        if ($item.Protected) { Write-Nova ('«{0}» — часть защиты Windows. Nova её не выключает.' -f $item.Title) warn; continue }
        Set-NovaStartupItem -Item $item -Enabled (-not $item.Enabled)
        if ($item.Enabled) { Write-Nova ('«{0}» больше не запускается вместе с Windows.' -f $item.Title) ok }
        else { Write-Nova ('«{0}» снова запускается вместе с Windows.' -f $item.Title) ok }
    }
}

# Голосовые команды открываются в своём окне через Проводник — так они работают
# без прав администратора, как обычная программа.
function Start-NovaVoiceFlow {
    $cmd = Join-Path $projectRoot 'NovaVoice.cmd'
    if (-not (Test-Path -LiteralPath $cmd)) { throw 'Не найден NovaVoice.cmd рядом с Nova.cmd.' }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $cmd)
    Write-Host ''
    Write-Nova 'Открываю «Nova Голос» в отдельном окне. Скажи, например: «Нова, сверни все окна».' ok
    Write-Nova 'Команды и свои бинды — в файле voice.json. Голос работает, пока открыто его окно.' dim
}

# Освободить место: показываем, сколько займёт каждый пункт, удаляем только мусор, в конце — итог.
function Invoke-NovaCleanFlow {
    Write-Host ''
    Write-Nova 'ОСВОБОДИТЬ МЕСТО НА ДИСКЕ' title
    $freeBefore = Get-NovaFreeSpace
    Write-Nova ('Свободно сейчас: {0}. Считаю, что можно убрать...' -f (Format-NovaSize $freeBefore)) dim
    $plan = @(Get-NovaCleanPlan -Quick:$Quick)
    Write-Host ''
    foreach ($item in $plan) {
        $size = 'посчитаю после'
        if ($item.Size -gt 0) { $size = Format-NovaSize $item.Size } elseif ($item.Kind -eq 'folder') { $size = 'пусто' }
        Write-Host ('  [+] {0,-40}{1,12}' -f $item.Title, $size) -ForegroundColor White
        Write-Host ('      {0}' -f $item.Note) -ForegroundColor DarkGray
    }
    $hiber = Get-NovaHiberfilSize
    if ($hiber -gt 0) {
        Write-Host ''
        Write-Nova ('Ещё {0} занимает файл гибернации. Освободить его — пункт «Отключить гибернацию» в config.json (вернуть можно).' -f (Format-NovaSize $hiber)) info
    }
    Write-Nova 'Удаляется только мусор: временные файлы, кэши, старые копии обновлений. Твои файлы и программы не трогаю. Вернуть удалённое нельзя — но оно и не нужно.' dim
    if (-not (Confirm-NovaAction 'Освободить место?')) { Write-Nova 'Отменено.' dim; return 0 }
    foreach ($item in $plan) {
        Write-Nova ('{0}...' -f $item.Title) dim
        try {
            $freed = Invoke-NovaCleanItem $item
            if ($freed -gt 0) { Write-Nova ('{0}: освобождено {1}' -f $item.Title, (Format-NovaSize $freed)) ok }
            elseif ($freed -lt 0) { Write-Nova ('{0}: готово' -f $item.Title) ok }
        } catch {
            Write-Nova ('{0}: {1}' -f $item.Title, $_.Exception.Message) warn
        }
    }
    if (-not $Yes) {
        Write-Host ''
        Write-Nova 'Можно сжать системные файлы Windows (CompactOS): обычно ещё 2–4 ГБ. Займёт 10–20 минут, на современных ПК скорость не меняется. Вернуть можно тут же: «compact /compactos:never».' info
        if (Confirm-NovaAction 'Сжать системные файлы?') {
            try { Invoke-NovaCompactOs; Write-Nova 'Системные файлы сжаты.' ok } catch { Write-Nova $_.Exception.Message warn }
        }
    }
    $freeAfter = Get-NovaFreeSpace
    Write-Host ''
    Write-Nova ('Готово! Освобождено: {0}. Свободно теперь: {1}.' -f (Format-NovaSize ([math]::Max(0, $freeAfter - $freeBefore))), (Format-NovaSize $freeAfter)) ok
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
        Write-Host '  6  Проверить систему и готовность к играм' -ForegroundColor White
        Write-Host '  7  Замерить FPS в игре: до и после Nova' -ForegroundColor White
        Write-Host '  8  Голосовые команды: «Нова, сверни все окна»' -ForegroundColor White
        Write-Host '  9  Освободить место на диске' -ForegroundColor White
        Write-Host ' 10  Автозагрузка: что запускается вместе с Windows' -ForegroundColor White
        Write-Host '  0  Выход' -ForegroundColor White
        Write-Host ''
        $choice = (Read-Host '  Выбери пункт').Trim()
        try {
            switch ($choice) {
                '1' { Invoke-NovaPreviewFlow; Wait-NovaKey }
                '2' { [void](Invoke-NovaApplyFlow); Wait-NovaKey }
                '3' { [void](Invoke-NovaUndoFlow); Wait-NovaKey }
                '4' {
                    # Через Проводник — редактор откроется без прав администратора.
                    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $ConfigPath)
                    Write-Nova 'Открываю config.json. Если Windows спросит, чем открыть, — выбери «Блокнот».' dim
                    Start-Sleep -Seconds 2
                }
                '5' { [void](Invoke-NovaMeasureFlow); Wait-NovaKey }
                '6' { [void](Invoke-NovaCheckFlow -Interactive); Wait-NovaKey }
                '7' { [void](Invoke-NovaFpsFlow); Wait-NovaKey }
                '8' { Start-NovaVoiceFlow; Wait-NovaKey }
                '9' { [void](Invoke-NovaCleanFlow); Wait-NovaKey }
                '10' { [void](Invoke-NovaStartupFlow) }
                '0' { return }
            }
        } catch {
            Write-Nova ('Ошибка: {0}' -f $_.Exception.Message) err
            Wait-NovaKey
        }
    }
}

$exitCode = 0
try {
    # Сначала проверяем саму папку Nova и только потом трогаем что-либо с правами администратора.
    Assert-NovaProjectFolder
    $dataDir = Get-NovaDataDir
} catch {
    Write-Host ''
    Write-Nova ('Ошибка: {0}' -f $_.Exception.Message) err
    if ($PauseAtEnd) { Wait-NovaKey }
    exit 1
}
$logPath = Join-Path $dataDir ('logs\nova-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
# Храним последние 30 логов, чтобы папка не разрасталась.
Get-ChildItem -LiteralPath (Split-Path -Parent $logPath) -Filter 'nova-*.log' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -Skip 29 | Remove-Item -Force -ErrorAction SilentlyContinue
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
        'Fps' { Show-NovaBanner; $exitCode = Invoke-NovaFpsFlow }
        'Clean' { Show-NovaBanner; $exitCode = Invoke-NovaCleanFlow }
        'Startup' { Show-NovaBanner; $exitCode = Invoke-NovaStartupFlow }
    }
} catch {
    Write-Nova ('Ошибка: {0}' -f $_.Exception.Message) err
    $exitCode = 1
} finally {
    if ($transcript) { Stop-Transcript | Out-Null }
}

if ($PauseAtEnd -and $Mode -ne 'Menu') { Wait-NovaKey }
exit $exitCode
