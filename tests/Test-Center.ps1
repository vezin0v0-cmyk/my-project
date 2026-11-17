# Nova Центр глазами пользователя: окно открывается двойным кликом по NovaCenter.cmd, а тест нажимает кнопки
# через UI Automation (так же их нажимает экранный диктор) и проверяет, что вышло на самом деле:
# config.json, применение и отмена, проверка системы, режим игры, ярлык, обновления, закрытие окна.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaPlay.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

# Короткая сводка для конца проверки на GitHub (если задан файл NOVA_SUMMARY).
function Write-Summary([string]$Text) { Write-Host $Text; if ($env:NOVA_SUMMARY) { Add-Content -LiteralPath $env:NOVA_SUMMARY -Value $Text -Encoding UTF8 } }

$AE = [Windows.Automation.AutomationElement]
$TS = [Windows.Automation.TreeScope]
$script:Win = $null

function Wait-Until([scriptblock]$Condition, [double]$Seconds, [string]$What) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $r = $null
        try { $r = & $Condition } catch { $r = $null }
        if ($r) { return $r }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $until)
    throw ('Не дождался за {0} с: {1}' -f $Seconds, $What)
}
function New-Cond($Property, $Value) { return (New-Object Windows.Automation.PropertyCondition ($Property, $Value)) }
function New-And([object[]]$Conditions) { return (New-Object Windows.Automation.AndCondition (, [Windows.Automation.Condition[]]$Conditions)) }
function Find-Id([string]$Id) { return $script:Win.FindFirst($TS::Descendants, (New-Cond $AE::AutomationIdProperty $Id)) }
function Get-Id([string]$Id, [double]$Seconds = 20) { return (Wait-Until { Find-Id $Id } $Seconds ('элемент «{0}»' -f $Id)) }
function Get-Name([string]$Id) { $e = Find-Id $Id; if ($e) { return [string]$e.Current.Name }; return $null }
function Invoke-El($Element, [string]$What) {
    if (-not $Element.Current.IsEnabled) { throw ('Кнопка «{0}» неактивна' -f $What) }
    $Element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Write-Host ('нажал: {0}' -f $What)
}
function Invoke-Id([string]$Id) { Invoke-El (Get-Id $Id) $Id }
function Open-Page([string]$Nav) {
    (Get-Id $Nav).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Write-Host ('страница: {0}' -f $Nav)
    Start-Sleep -Milliseconds 500
}
function Get-Texts($Under) {
    return @($Under.FindAll($TS::Descendants, (New-Cond $AE::ControlTypeProperty ([Windows.Automation.ControlType]::Text))) | ForEach-Object { [string]$_.Current.Name })
}
function Get-Toggle([string]$Id) {
    return ((Get-Id $Id 10).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On)
}
function Read-Config { return [IO.File]::ReadAllText($script:ConfigPath, [Text.Encoding]::UTF8) }
# Все переключатели config.json: «раздел.ключ» → True/False.
function Get-Switches([string]$Text) {
    $o = ConvertFrom-Json $Text
    $h = @{}
    foreach ($sec in @('tweaks', 'removeApps', 'installApps')) {
        $s = $o.$sec
        if ($s) { foreach ($p in $s.PSObject.Properties) { $h[('{0}.{1}' -f $sec, $p.Name)] = [string]$p.Value } }
    }
    return $h
}
function Get-Changed([string]$Before, [string]$After) {
    $a = Get-Switches $Before; $b = Get-Switches $After
    $keys = @($a.Keys) + @($b.Keys) | Sort-Object -Unique
    return @($keys | Where-Object { -not ($a.ContainsKey($_) -and $b.ContainsKey($_) -and $a[$_] -eq $b[$_]) })
}
# Ждёт, пока config.json изменится, и возвращает новый текст (дочитываем после записи).
function Wait-ConfigChange([string]$Before, [string]$What) {
    [void](Wait-Until { (Read-Config) -ne $Before } 10 $What)
    Start-Sleep -Milliseconds 300
    return (Read-Config)
}

# Nova работает в окне: ждём начала и конца, читаем итог и журнал, закрываем окно хода работы.
function Wait-Run([string]$What, [double]$Seconds = 300) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    [void](Wait-Until { $b = Find-Id 'RunClose'; $b -and -not $b.Current.IsEnabled } 20 ('{0}: Nova запустилась' -f $What))
    # Пока Nova работает, меню и плитки под окном хода работы недоступны (Enter не нажмёт их ещё раз).
    if ((Get-Id 'NavHome').Current.IsEnabled) { throw ('{0}: во время работы меню под окном хода работы осталось доступным' -f $What) }
    [void](Wait-Until { $b = Find-Id 'RunClose'; $b -and $b.Current.IsEnabled } $Seconds ('{0}: Nova закончила' -f $What))
    $result = Get-Name 'RunResult'
    $lines = Get-Texts (Get-Id 'RunScroll')
    Write-Host ('--- {0}: «{1}», строк в окне: {2}, {3:N1} с' -f $What, $result, $lines.Count, $t.Elapsed.TotalSeconds)
    foreach ($l in @($lines | Select-Object -First 80)) { Write-Host ('    | ' + $l) }
    if (@($lines | Where-Object { $_ -like '*_____*' }).Count) { throw ('{0}: в окно попала рамка-логотип консоли' -f $What) }
    $bad = @($lines | Where-Object { $_ -like '*Ошибка: *' })
    if ($bad.Count) { throw ('{0}: в окне ошибка — {1}' -f $What, $bad[0]) }
    if ($lines.Count -lt 2) { throw ('{0}: в окне хода работы почти пусто' -f $What) }
    Invoke-Id 'RunClose'
    Start-Sleep -Milliseconds 500
    return [pscustomobject]@{ Result = $result; Lines = $lines; Ok = ($result -like '*Всё получилось*'); Seconds = $t.Elapsed.TotalSeconds }
}
# Окно с вопросом «Да/Нет» от Nova Центра — нажимаем «Да».
function Confirm-Dialog([string]$What) {
    $cond = New-And @((New-Cond $AE::ClassNameProperty '#32770'), (New-Cond $AE::ProcessIdProperty $script:AppPid))
    $dlg = Wait-Until { $d = $AE::RootElement.FindFirst($TS::Children, $cond); if (-not $d) { $d = $script:Win.FindFirst($TS::Descendants, $cond) }; $d } 20 ('вопрос: ' + $What)
    # «Да» в стандартном окне Windows — кнопка с номером 6 (IDYES); ищем именно кнопку.
    $btnCond = New-And @((New-Cond $AE::ControlTypeProperty ([Windows.Automation.ControlType]::Button)), (New-Cond $AE::AutomationIdProperty '6'))
    $yes = $null
    try { $yes = Wait-Until { $dlg.FindFirst($TS::Descendants, $btnCond) } 10 'кнопка «Да»' } catch {
        foreach ($el in @($dlg.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition))) { Write-Host ('  в окне вопроса: {0} «{1}» id={2}' -f $el.Current.ControlType.ProgrammaticName, $el.Current.Name, $el.Current.AutomationId) }
        throw
    }
    $pattern = $null
    if ($yes.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
    } else {
        # Кнопка без «нажатия» через UI Automation — как человек: фокус на «Да» и пробел.
        $yes.SetFocus()
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.SendKeys]::SendWait(' ')
    }
    Write-Host ('нажал: Да — {0}' -f $What)
}
function Assert-RunOk($Run, [string]$What) {
    if (-not $Run.Ok) { throw ('{0}: итог «{1}», а ожидалось «Всё получилось»' -f $What, $Run.Result) }
    $script:Done.Add(('ok  {0}: {1} строк в окне, {2:N0} с' -f $What, $Run.Lines.Count, $Run.Seconds))
}

$script:ConfigPath = Join-Path $root 'config.json'
$configBackup = [IO.File]::ReadAllBytes($script:ConfigPath)
$lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Nova Центр.lnk'
$hadLnk = Test-Path -LiteralPath $lnkPath
$script:Done = New-Object System.Collections.Generic.List[string]
$appPid = $null
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    # 1. Двойной клик по NovaCenter.cmd.
    Start-Process -FilePath (Join-Path $root 'NovaCenter.cmd') -WorkingDirectory $root
    $winCond = New-And @((New-Cond $AE::NameProperty 'Nova Центр'), (New-Cond $AE::ControlTypeProperty ([Windows.Automation.ControlType]::Window)))
    $script:Win = Wait-Until { $AE::RootElement.FindFirst($TS::Children, $winCond) } 90 'окно «Nova Центр»'
    $appPid = $script:Win.Current.ProcessId
    $script:AppPid = $appPid
    $script:Done.Add(('ok  окно открылось двойным кликом по NovaCenter.cmd за {0:N1} с' -f $watch.Elapsed.TotalSeconds))

    $ver = Get-Name 'VerText'
    if ($ver -ne ('v' + (Get-NovaVersion))) { throw ('В окне версия «{0}», а у Nova {1}' -f $ver, (Get-NovaVersion)) }
    $health = Wait-Until { $h = Get-Name 'HealthText'; if ($h -and $h -ne 'Проверяю систему…') { $h } } 120 'проверка системы на главной'
    if ($health -like 'Проверка системы — в*') { throw ('Проверка системы на главной не сработала: {0}' -f (Find-Id 'HealthText').Current.HelpText) }
    $script:Done.Add(('ok  главная: версия {0}, проверка системы — «{1}»' -f $ver, $health))
    foreach ($tile in @(@('QCheck', 'Проверить систему'), @('QGame', 'Режим игры'), @('BtnClose', 'Закрыть'))) {
        $n = [string](Get-Id $tile[0]).Current.Name
        if (-not $n.StartsWith($tile[1])) { throw ('Экранный диктор прочтёт у «{0}» имя «{1}», а ожидалось «{2}…»' -f $tile[0], $n, $tile[1]) }
    }
    $script:Done.Add('ok  у плиток и кнопок-значков есть имена для экранного диктора')

    # 2. Настройки: переключатели показывают то, что в config.json; один переключили — в файле поменялся ровно он.
    Open-Page 'NavTweaks'
    $text0 = Read-Config
    $cfg = ConvertFrom-Json $text0
    $privacy = @((Read-NovaJson (Join-Path $root 'src\tweaks.json')).tweaks | Where-Object { $_.category -eq 'privacy' })
    if ($privacy.Count -lt 3) { throw 'В разделе «Приватность» слишком мало настроек' }
    foreach ($t in $privacy) {
        $want = [bool]($cfg.tweaks.PSObject.Properties[$t.id] -and $cfg.tweaks.($t.id))
        if ((Get-Toggle ('sw-' + $t.id)) -ne $want) { throw ('Переключатель «{0}» показывает не то, что в config.json' -f $t.title) }
        if ((Get-Id ('sw-' + $t.id)).Current.Name -ne $t.title) { throw ('У переключателя {0} нет понятного имени' -f $t.id) }
    }
    $first = $privacy[0]
    $wasOn = Get-Toggle ('sw-' + $first.id)
    (Get-Id ('sw-' + $first.id)).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    [void](Wait-Until { (Get-Name 'DirtyText') -like 'Есть несохранённые*' } 5 'надпись «Есть несохранённые изменения»')
    Invoke-Id 'BtnSave'
    $text1 = Wait-ConfigChange $text0 'config.json сохранился после «Сохранить»'
    $changed = @(Get-Changed $text0 $text1)
    if ($changed.Count -ne 1 -or $changed[0] -ne ('tweaks.' + $first.id)) { throw ('После одного переключателя в config.json изменилось: {0}' -f ($changed -join ', ')) }
    $l0 = @($text0 -split "`r?`n"); $l1 = @($text1 -split "`r?`n")
    $diffLines = @(for ($i = 0; $i -lt [Math]::Max($l0.Count, $l1.Count); $i++) { if ($l0[$i] -ne $l1[$i]) { $i } })
    if ($l0.Count -ne $l1.Count -or $diffLines.Count -ne 1) { throw ('В config.json поменялось строк: {0} (а должна одна)' -f $diffLines.Count) }
    if ((Get-Name 'DirtyText')) { throw 'После сохранения осталась надпись о несохранённом' }
    $script:Done.Add(('ok  переключатель «{0}» {1} → в config.json изменилась ровно одна строка, пояснения на месте' -f $first.title, $(if ($wasOn) { 'выключен' } else { 'включён' })))

    # 3. Сборка «Игровой ПК».
    $gaming = @('high-performance-power', 'power-throttling-off', 'mouse-acceleration-off', 'background-apps-off', 'hibernation-off', 'no-forced-restart', 'edge-quiet')
    $preset = Wait-Until { $script:Win.FindFirst($TS::Descendants, (New-And @((New-Cond $AE::ControlTypeProperty ([Windows.Automation.ControlType]::Button)), (New-Cond $AE::NameProperty 'Игровой ПК')))) } 10 'кнопка сборки «Игровой ПК»'
    Invoke-El $preset 'Игровой ПК'
    Start-Sleep -Milliseconds 600
    Invoke-Id 'BtnSave'
    $sw1 = Get-Switches $text1
    $expect = @($gaming | Where-Object { $sw1[('tweaks.' + $_)] -ne 'True' } | ForEach-Object { 'tweaks.' + $_ } | Sort-Object)
    $text2 = $text1
    if ($expect.Count) { $text2 = Wait-ConfigChange $text1 'config.json сохранился после сборки' }
    $sw2 = Get-Switches $text2
    foreach ($k in $gaming) { if ($sw2[('tweaks.' + $k)] -ne 'True') { throw ('Сборка «Игровой ПК» не включила {0}' -f $k) } }
    $changed = @(Get-Changed $text1 $text2 | Sort-Object)
    if (($changed -join ',') -ne ($expect -join ',')) { throw ('Сборка поменяла лишнее: {0}' -f ($changed -join ', ')) }
    $script:Done.Add(('ok  сборка «Игровой ПК»: включено пунктов {0}, лишнего не тронуто' -f $expect.Count))

    # 3б. config.json поправили снаружи (Блокнот), а в окне переключили другое — после «Сохранить» есть и то, и другое.
    $ext = $privacy[1]; $own = $privacy[2]
    $extVal = -not [bool]((ConvertFrom-Json $text2).tweaks.($ext.id))
    $outside = [regex]::Replace($text2, ('("' + [regex]::Escape($ext.id) + '"\s*:\s*)(true|false)'), ('${1}' + $(if ($extVal) { 'true' } else { 'false' })))
    [IO.File]::WriteAllText($script:ConfigPath, $outside, (New-Object Text.UTF8Encoding($false)))
    $ownWas = Get-Toggle ('sw-' + $own.id)
    (Get-Id ('sw-' + $own.id)).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    Invoke-Id 'BtnSave'
    $text3 = Wait-ConfigChange $outside 'config.json сохранился после правки снаружи'
    $sw3 = Get-Switches $text3
    if ($sw3[('tweaks.' + $ext.id)] -ne [string]$extVal) { throw ('«Сохранить» затёр правку config.json, сделанную снаружи ({0})' -f $ext.id) }
    if ($sw3[('tweaks.' + $own.id)] -ne [string](-not $ownWas)) { throw ('«Сохранить» не записал переключатель {0}' -f $own.id) }
    $changed = @(Get-Changed $outside $text3)
    if ($changed.Count -ne 1) { throw ('После правки снаружи «Сохранить» поменял лишнее: {0}' -f ($changed -join ', ')) }
    if ((Get-Toggle ('sw-' + $ext.id)) -ne $extVal) { throw 'После сохранения окно не показало правку, сделанную снаружи' }
    $text2 = $text3
    $script:Done.Add('ok  правка config.json снаружи не затирается: «Сохранить» меняет только то, что переключили в окне')

    # 4. Приложения: русские названия и те же переключатели.
    Open-Page 'NavApps'
    $appKey = @((ConvertFrom-Json $text2).removeApps.PSObject.Properties | Where-Object { $_.Name -eq 'Microsoft.BingNews' })
    if ($appKey.Count) {
        $news = Get-Id 'sw-Microsoft.BingNews' 10
        if ($news.Current.Name -ne 'Новости') { throw ('Microsoft.BingNews в окне называется «{0}»' -f $news.Current.Name) }
        if ((Get-Toggle 'sw-Microsoft.BingNews') -ne [bool]$appKey[0].Value) { throw 'Переключатель «Новости» показывает не то, что в config.json' }
    }
    $script:Done.Add('ok  приложения: русские названия, переключатели как в config.json')

    # 5. Применить — настоящая Nova, ход работы в окне.
    Open-Page 'NavTweaks'
    Invoke-Id 'BtnApply'
    Assert-RunOk (Wait-Run 'Применить' 420) 'Применить из окна'
    if ((Read-Config) -ne $text2) { throw '«Применить» без изменений переписал config.json' }

    # 6. Отменить последний запуск — с вопросом «Да/Нет», как у пользователя.
    Open-Page 'NavTools'
    Invoke-Id 'TUndo'
    Confirm-Dialog 'вернуть всё, как было'
    Assert-RunOk (Wait-Run 'Отменить последний запуск' 420) 'Отменить из окна (после вопроса «Да»)'

    # 7. Проверка системы с главной.
    Open-Page 'NavHome'
    Invoke-Id 'QCheck'
    Assert-RunOk (Wait-Run 'Проверка системы' 240) 'Проверить систему с главной'

    # 8. Режим игры: включить и вернуть как было — плитка показывает состояние.
    Invoke-Id 'QGame'
    Assert-RunOk (Wait-Run 'Режим игры: включить' 180) 'Режим игры включён из окна'
    if (-not (Test-NovaGameModeActive)) { throw 'Плитка «Режим игры» не включила режим игры' }
    $tileName = [string](Get-Id 'QGame').Current.Name
    if ($tileName -notlike '*включён*') { throw ('Плитка после включения: «{0}»' -f $tileName) }
    Invoke-Id 'QGame'
    Assert-RunOk (Wait-Run 'Режим игры: выключить' 180) 'Режим игры выключен из окна'
    if (Test-NovaGameModeActive) { throw 'Режим игры остался включён' }
    if (Test-Path -LiteralPath (Join-Path $env:ProgramData 'Nova\gamemode-updates.json')) { throw 'Пауза обновлений осталась после режима игры' }
    if ([string](Get-Id 'QGame').Current.Name -like '*включён*') { throw 'Плитка «Режим игры» не вернулась в «выключен»' }

    # 9. Игры: свежий ли драйвер. 10. Что изменится.
    Open-Page 'NavGames'
    Invoke-Id 'GDriver'
    Assert-RunOk (Wait-Run 'Свежий ли драйвер' 180) 'Свежий ли драйвер'
    Open-Page 'NavTweaks'
    Invoke-Id 'BtnPreview'
    $preview = Wait-Run 'Что изменится' 240
    Assert-RunOk $preview 'Что изменится'
    # Строка плана — целиком: «[+] Название … будет изменено», а не две строки.
    $plan = @($preview.Lines | Where-Object { $_ -match '^\[.\] ' })
    if ($plan.Count -lt 5) { throw ('В «Что изменится» мало строк плана: {0}' -f $plan.Count) }
    if (@($plan | Where-Object { $_.TrimEnd().Length -lt 62 }).Count -gt 0) { throw ('Строка плана разорвана: «{0}»' -f @($plan | Where-Object { $_.TrimEnd().Length -lt 62 })[0]) }

    # 10б. «Остановить» посреди работы: Nova останавливается вместе со всем, что запустила.
    Open-Page 'NavGames'
    Invoke-Id 'GHeavy'
    [void](Wait-Until { $b = Find-Id 'RunStop'; $b -and $b.Current.IsEnabled } 20 '«Остановить» во время работы')
    # «Что тормозит» смотрит на компьютер 3 секунды — останавливаем, пока смотрит.
    Start-Sleep -Milliseconds 300
    Invoke-Id 'RunStop'
    Confirm-Dialog 'остановить Nova'
    [void](Wait-Until { $b = Find-Id 'RunClose'; $b -and $b.Current.IsEnabled } 30 'Nova остановилась')
    $stopped = Get-Name 'RunResult'
    if ($stopped -notlike 'Остановлено*') { throw ('После «Остановить» итог: «{0}»' -f $stopped) }
    Invoke-Id 'RunClose'
    Start-Sleep -Milliseconds 500
    $script:Done.Add('ok  «Остановить» посреди работы: Nova остановилась, окно написало «Остановлено»')

    # 11. Ярлык на рабочий стол.
    Open-Page 'NavTools'
    $n = [string](Get-Id 'TShortcut').Current.Name
    if (-not $n.StartsWith('Ярлык на рабочий стол')) { throw ('Экранный диктор прочтёт у плитки ярлыка «{0}»' -f $n) }
    Invoke-Id 'TShortcut'
    [void](Wait-Until { Test-Path -LiteralPath $lnkPath } 10 'ярлык «Nova Центр» на рабочем столе')
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
    if ($lnk.TargetPath -ne (Join-Path $root 'NovaCenter.cmd')) { throw ('Ярлык ведёт не туда: {0}' -f $lnk.TargetPath) }
    if (-not (Test-Path -LiteralPath ($lnk.IconLocation -replace ',\d+$', ''))) { throw 'У ярлыка нет значка Nova' }
    $script:Done.Add('ok  ярлык «Nova Центр» на рабочем столе ведёт в NovaCenter.cmd, значок Nova')

    # 12. Голос: список команд из voice.json.
    Open-Page 'NavVoice'
    $voice = @(Get-Texts $script:Win | Where-Object { $_ -like '*нова, режим игры*' })
    if (-not $voice.Count) { throw 'На странице «Голос» нет команд из voice.json' }
    $script:Done.Add('ok  голос: команды из voice.json на месте')

    # 13. Обновления: что нового в своей версии, затем «Проверить» на GitHub.
    Open-Page 'NavUpdate'
    if (-not @(Get-Texts $script:Win | Where-Object { $_ -like ('Что нового в версии*') }).Count) { throw 'На странице «Обновления» нет «Что нового»' }
    $title0 = Get-Name 'UpdTitle'
    Invoke-Id 'BtnCheckUpd'
    $title1 = Wait-Until { $x = Get-Name 'UpdTitle'; if ($x -and $x -ne $title0 -and $x -ne 'Проверяю…') { $x } } 60 'ответ GitHub на «Проверить»'
    if ($title1 -like 'Не получилось*') { throw ('«Проверить» не сработал: {0}' -f (Get-Name 'UpdText')) }
    $script:Done.Add(('ok  обновления: «{0}»' -f $title1))

    # 14. Закрыть окно крестиком.
    Invoke-Id 'BtnClose'
    $p = Get-Process -Id $appPid -ErrorAction SilentlyContinue
    if ($p -and -not $p.WaitForExit(20000)) { throw 'Окно не закрылось крестиком' }
    $appPid = $null
    $script:Done.Add('ok  окно закрылось крестиком без вопросов')
} catch {
    # Что окно успело показать: всплывающее сообщение и подсказку проверки системы — для разбора на GitHub.
    if ($script:Win) {
        try { Write-Host ('сообщение в окне: {0}' -f (Get-Name 'ToastText')) } catch { Write-Host 'сообщения в окне нет' }
        try { Write-Host ('проверка системы: {0} / {1}' -f (Get-Name 'HealthText'), (Find-Id 'HealthText').Current.HelpText) } catch { Write-Host 'проверка системы не видна' }
    }
    throw
} finally {
    if ($appPid) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllBytes($script:ConfigPath, $configBackup)
    if (-not $hadLnk -and (Test-Path -LiteralPath $lnkPath)) { Remove-Item -LiteralPath $lnkPath -Force }
    if (Test-NovaGameModeActive) { & (Join-Path $root 'src\Nova.ps1') -Mode Game | Out-Null }
}

Write-Summary ''
Write-Summary ('Nova Центр как у пользователя (нажатия в окне, {0:N0} с):' -f $watch.Elapsed.TotalSeconds)
foreach ($line in $script:Done) { Write-Summary ('  ' + $line) }
