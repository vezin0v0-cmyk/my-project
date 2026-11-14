# Автозагрузка: разбор строк запуска, выключатель как в Диспетчере задач, защита Windows не выключается.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaStartup.psm1') -Force -DisableNameChecking

$notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
$cases = [ordered]@{
    '"C:\Program Files\Discord\Update.exe" --processStart Discord.exe' = 'C:\Program Files\Discord\Update.exe'
    'C:\Windows\System32\notepad.exe /min'                            = 'C:\Windows\System32\notepad.exe'
    'C:\Program Files (x86)\Steam\steam.exe -silent'                  = 'C:\Program Files (x86)\Steam\steam.exe'
    '%windir%\system32\SecurityHealthSystray.exe'                     = (Join-Path $env:windir 'system32\SecurityHealthSystray.exe')
    ''                                                                = ''
}
foreach ($cmd in $cases.Keys) {
    $got = Get-NovaCommandFile $cmd
    if ($got -ne $cases[$cmd]) { throw ('строка «{0}»: ожидалось «{1}», получилось «{2}»' -f $cmd, $cases[$cmd], $got) }
}
Write-Host 'ok  путь к программе из строки запуска'

if (-not (Test-NovaStartupEnabled $null)) { throw 'нет отметки — значит включено' }
if (-not (Test-NovaStartupEnabled ([byte[]]@(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))) { throw '02 — включено' }
if (Test-NovaStartupEnabled ([byte[]]@(3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8))) { throw '03 — выключено' }
if (Test-NovaStartupEnabled ([byte[]]@(7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))) { throw '07 — выключено' }
Write-Host 'ok  отметки Диспетчера задач читаются правильно'

$run = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
$approvedRun = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$approvedFolder = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
$startup = [Environment]::GetFolderPath('Startup')
if (-not (Test-Path -LiteralPath $startup)) { New-Item -ItemType Directory -Path $startup -Force | Out-Null }
$lnk = Join-Path $startup 'NovaTest.lnk'
$names = @('NovaTestApp', 'NovaTestShield', 'NovaTestGone')
try {
    Set-NovaRegValue -Path $run -Name 'NovaTestApp' -Kind 'String' -Value ('"{0}" /nova-test' -f $notepad)
    Set-NovaRegValue -Path $run -Name 'NovaTestShield' -Kind 'ExpandString' -Value '%windir%\system32\SecurityHealthSystray.exe'
    Set-NovaRegValue -Path $run -Name 'NovaTestGone' -Kind 'String' -Value 'C:\NovaNowhere\gone.exe /background'
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = $notepad
    $sc.Save()

    $items = @(Get-NovaStartupItem)
    foreach ($it in $items) { Write-Host ('   [{0}] {1} — {2} ({3})' -f $(if ($it.Protected) { 'защита' } elseif ($it.Enabled) { 'вкл' } else { 'выкл' }), $it.Title, $it.Company, $it.Where) }

    $app = $items | Where-Object Name -eq 'NovaTestApp'
    if (-not $app -or -not $app.Enabled -or $app.File -ne $notepad -or $app.Protected) { throw 'тестовая программа не найдена или неверно разобрана' }
    if ($app.Company -notlike '*Microsoft*') { throw ('издатель блокнота: {0}' -f $app.Company) }
    Set-NovaStartupItem -Item $app -Enabled $false
    $bytes = @((Get-NovaRegValue -Path $approvedRun -Name 'NovaTestApp').Value)
    if ($bytes.Count -ne 12 -or $bytes[0] -ne 3) { throw ('выключение записано не так, как в Диспетчере задач: {0}' -f ($bytes -join ',')) }
    if ((@(Get-NovaStartupItem) | Where-Object Name -eq 'NovaTestApp').Enabled) { throw 'после выключения пункт всё ещё включён' }
    if (-not (Get-NovaRegValue -Path $run -Name 'NovaTestApp').Exists) { throw 'сама запись автозапуска должна остаться на месте' }
    Set-NovaStartupItem -Item $app -Enabled $true
    if (@((Get-NovaRegValue -Path $approvedRun -Name 'NovaTestApp').Value)[0] -ne 2) { throw 'включение записано неверно' }
    if (-not (@(Get-NovaStartupItem) | Where-Object Name -eq 'NovaTestApp').Enabled) { throw 'после включения пункт выключен' }
    Write-Host 'ok  выключить и включить программу из реестра (запись остаётся, меняется только отметка)'

    $link = @(Get-NovaStartupItem) | Where-Object Name -eq 'NovaTest.lnk'
    if (-not $link -or $link.File -ne $notepad) { throw ('ярлык в папке автозагрузки не найден или цель не та: {0}' -f $link.File) }
    Set-NovaStartupItem -Item $link -Enabled $false
    if ((@(Get-NovaStartupItem) | Where-Object Name -eq 'NovaTest.lnk').Enabled) { throw 'ярлык не выключился' }
    if (-not (Test-Path -LiteralPath $lnk)) { throw 'ярлык должен остаться на месте' }
    Write-Host 'ok  ярлык в папке «Автозагрузка»: выключается, файл остаётся'

    $shield = @(Get-NovaStartupItem) | Where-Object Name -eq 'NovaTestShield'
    if (-not $shield.Protected) { throw 'значок «Безопасность Windows» должен быть под защитой' }
    $refused = $false
    try { Set-NovaStartupItem -Item $shield -Enabled $false } catch { $refused = $true }
    if (-not $refused -or (Get-NovaRegValue -Path $approvedRun -Name 'NovaTestShield').Exists) { throw 'защиту Windows выключить нельзя' }
    Write-Host 'ok  «Безопасность Windows» выключить нельзя'

    $gone = @(Get-NovaStartupItem) | Where-Object Name -eq 'NovaTestGone'
    if (-not $gone.Missing) { throw 'программа, которой нет на диске, должна быть помечена' }
    Write-Host 'ok  помечены записи удалённых программ'
} finally {
    foreach ($n in $names) {
        Remove-NovaRegValue -Path $run -Name $n
        Remove-NovaRegValue -Path $approvedRun -Name $n
    }
    Remove-NovaRegValue -Path $approvedFolder -Name 'NovaTest.lnk'
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
}
if (@(Get-NovaStartupItem | Where-Object { $_.Name -like 'NovaTest*' }).Count -ne 0) { throw 'тестовые записи не убраны' }
Write-Host 'ТЕСТ АВТОЗАГРУЗКИ ПРОЙДЕН'
