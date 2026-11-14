# Автозагрузка: разбор строк запуска, выключатель как в Диспетчере задач, защиту Windows нельзя ни выключить, ни подделать.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaStartup.psm1') -Force -DisableNameChecking

$notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
$shieldExe = Join-Path $env:SystemRoot 'System32\SecurityHealthSystray.exe'
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
if (Test-NovaLocalPath '\\192.0.2.1\share\x.exe') { throw 'сетевой путь принят за локальный' }
if (-not (Test-NovaLocalPath $notepad)) { throw 'системный диск не принят за локальный' }
$esc = 'A' + [char]27 + '[2J' + [char]0x202E + 'B' + "`r`n"
# ESC, U+202E и перевод строки убираются; «[2J» без ESC — просто безобидные буквы.
if ((Get-NovaCleanText $esc) -ne 'A[2JB') { throw ('управляющие символы не вычищены: «{0}»' -f (Get-NovaCleanText $esc)) }
Write-Host 'ok  сетевые пути и управляющие символы распознаются'

if (-not (Test-NovaStartupEnabled $null)) { throw 'нет отметки — значит включено' }
if (-not (Test-NovaStartupEnabled ([byte[]]@(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))) { throw '02 — включено' }
if (Test-NovaStartupEnabled ([byte[]]@(3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8))) { throw '03 — выключено' }
if (Test-NovaStartupEnabled ([byte[]]@(7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))) { throw '07 — выключено' }
Write-Host 'ok  отметки Диспетчера задач читаются правильно'

$run = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
$runLM = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$approvedRun = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$approvedRunLM = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$approvedFolder = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
$startup = [Environment]::GetFolderPath('Startup')
if (-not (Test-Path -LiteralPath $startup)) { New-Item -ItemType Directory -Path $startup -Force | Out-Null }
$lnk = Join-Path $startup 'NovaTest.lnk'
$escName = 'NovaTestEsc' + [char]27 + '[31m' + [char]0x202E
$names = @('NovaTestApp', 'NovaTestShield', 'SecurityHealth', 'NovaTestGone', 'NovaTestNet', $escName)
try {
    Set-NovaRegValue -Path $run -Name 'NovaTestApp' -Kind 'String' -Value ('"{0}" /nova-test' -f $notepad)
    Set-NovaRegValue -Path $run -Name 'NovaTestShield' -Kind 'ExpandString' -Value '%windir%\system32\SecurityHealthSystray.exe'
    Set-NovaRegValue -Path $run -Name 'SecurityHealth' -Kind 'String' -Value ('"{0}"' -f $notepad)
    Set-NovaRegValue -Path $run -Name 'NovaTestGone' -Kind 'String' -Value 'C:\NovaNowhere\gone.exe /background'
    Set-NovaRegValue -Path $run -Name 'NovaTestNet' -Kind 'String' -Value '\\192.0.2.1\share\x.exe'
    Set-NovaRegValue -Path $run -Name $escName -Kind 'String' -Value ('"{0}"' -f $notepad)
    Set-NovaRegValue -Path $runLM -Name 'NovaTestShieldLM' -Kind 'ExpandString' -Value '%windir%\system32\SecurityHealthSystray.exe'
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk); $sc.TargetPath = $notepad; $sc.Save()

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $items = @(Get-NovaStartupItem)
    $watch.Stop()
    foreach ($it in $items) { Write-Host ('   [{0}] {1} — {2} ({3})' -f $(if ($it.Protected) { 'защита' } elseif ($it.Enabled) { 'вкл' } else { 'выкл' }), $it.Title, $(if ($it.Company) { $it.Company } else { 'без подписи' }), $it.Where) }
    if ($watch.Elapsed.TotalSeconds -gt 10) { throw ('список строился {0:N1} с — сетевой путь подвесил проверку' -f $watch.Elapsed.TotalSeconds) }
    $net = $items | Where-Object RawName -eq 'NovaTestNet'
    if (-not $net.Network -or $net.Missing) { throw 'запуск из сети должен быть помечен и не проверяться' }
    Write-Host ('ok  сетевой путь не трогается, список за {0:N1} с' -f $watch.Elapsed.TotalSeconds)

    $app = $items | Where-Object RawName -eq 'NovaTestApp'
    if (-not $app -or -not $app.Enabled -or $app.File -ne $notepad -or $app.Protected) { throw 'тестовая программа не найдена или неверно разобрана' }
    if ($app.Company -notlike '*Microsoft*' -or -not $app.Signed) { throw ('издатель блокнота по подписи: «{0}»' -f $app.Company) }
    Set-NovaStartupItem -Item $app -Enabled $false
    $bytes = @((Get-NovaRegValue -Path $approvedRun -Name 'NovaTestApp').Value)
    if ($bytes.Count -ne 12 -or $bytes[0] -ne 3) { throw ('выключение записано не так, как в Диспетчере задач: {0}' -f ($bytes -join ',')) }
    if ((@(Get-NovaStartupItem) | Where-Object RawName -eq 'NovaTestApp').Enabled) { throw 'после выключения пункт всё ещё включён' }
    if (-not (Get-NovaRegValue -Path $run -Name 'NovaTestApp').Exists) { throw 'сама запись автозапуска должна остаться на месте' }
    Set-NovaStartupItem -Item $app -Enabled $true
    if (@((Get-NovaRegValue -Path $approvedRun -Name 'NovaTestApp').Value)[0] -ne 2) { throw 'включение записано неверно' }
    Write-Host 'ok  выключить и включить программу из реестра (запись остаётся, меняется только отметка); издатель — по подписи'

    $link = @(Get-NovaStartupItem) | Where-Object RawName -eq 'NovaTest.lnk'
    if (-not $link -or $link.File -ne $notepad) { throw ('ярлык в папке автозагрузки не найден или цель не та: {0}' -f $link.File) }
    Set-NovaStartupItem -Item $link -Enabled $false
    if ((@(Get-NovaStartupItem) | Where-Object RawName -eq 'NovaTest.lnk').Enabled) { throw 'ярлык не выключился' }
    if (-not (Test-Path -LiteralPath $lnk)) { throw 'ярлык должен остаться на месте' }
    Write-Host 'ok  ярлык в папке «Автозагрузка»: выключается, файл остаётся'

    $items = @(Get-NovaStartupItem)
    $real = $items | Where-Object RawName -eq 'NovaTestShieldLM'
    if (-not $real.Protected) { throw 'настоящий значок «Безопасность Windows» в HKLM должен быть под защитой' }
    $refused = $false
    try { Set-NovaStartupItem -Item $real -Enabled $false } catch { $refused = $true }
    if (-not $refused -or (Get-NovaRegValue -Path $approvedRunLM -Name 'NovaTestShieldLM').Exists) { throw 'защиту Windows выключить нельзя' }
    $fakeName = $items | Where-Object RawName -eq 'SecurityHealth' | Where-Object { $_.Where -like '*этот пользователь*' }
    $fakeUser = $items | Where-Object RawName -eq 'NovaTestShield'
    if ($fakeName.Protected -or $fakeUser.Protected) { throw 'запись пользователя с именем или путём «Безопасности Windows» не должна получать защиту' }
    Write-Host 'ok  «Безопасность Windows» выключить нельзя, а подделать её защиту — тоже'

    $escItem = $items | Where-Object RawName -eq $escName
    if (-not $escItem -or $escItem.Name -match '[\p{Cc}\p{Cf}]' -or $escItem.Title -match '[\p{Cc}\p{Cf}]') { throw 'управляющие символы попали в показ' }
    Set-NovaStartupItem -Item $escItem -Enabled $false
    if (-not (Get-NovaRegValue -Path $approvedRun -Name $escName).Exists) { throw 'отметка записана не под настоящим именем записи' }
    Write-Host ('ok  имя с управляющими символами показано как «{0}», а в реестр записано настоящее' -f $escItem.Name)

    $gone = $items | Where-Object RawName -eq 'NovaTestGone'
    if (-not $gone.Missing -or $gone.Signed) { throw 'программа, которой нет на диске, должна быть помечена' }
    Write-Host 'ok  помечены записи удалённых программ'
} finally {
    foreach ($n in $names) {
        Remove-NovaRegValue -Path $run -Name $n
        Remove-NovaRegValue -Path $approvedRun -Name $n
    }
    Remove-NovaRegValue -Path $runLM -Name 'NovaTestShieldLM'
    Remove-NovaRegValue -Path $approvedRunLM -Name 'NovaTestShieldLM'
    Remove-NovaRegValue -Path $approvedFolder -Name 'NovaTest.lnk'
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
}
if (@(Get-NovaStartupItem | Where-Object { $_.RawName -like 'NovaTest*' }).Count -ne 0) { throw 'тестовые записи не убраны' }
Write-Host 'ТЕСТ АВТОЗАГРУЗКИ ПРОЙДЕН'
