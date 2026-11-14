# Проверка «Готовности к играм»: советы на придуманных данных, где ответ известен заранее,
# и прогон на настоящей Windows (здесь — виртуальная машина GitHub без видеокарты).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaGame.psm1') -Force -DisableNameChecking

function Assert-Check {
    param($Check, [string]$Status, [string]$Contains, [string]$What)
    if (-not $Check) { throw ('{0}: совета нет' -f $What) }
    if ($Check.Status -ne $Status) { throw ('{0}: ожидался статус {1}, получился {2} ({3})' -f $What, $Status, $Check.Status, $Check.Text) }
    if ($Contains -and ($Check.Text + ' ' + $Check.Hint) -notlike ('*' + $Contains + '*')) { throw ('{0}: нет «{1}» в «{2} {3}»' -f $What, $Contains, $Check.Text, $Check.Hint) }
    Write-Host ('ok  {0}: {1}' -f $What, $Check.Text)
}

# Производитель видеокарты
$cases = @{ 'PCI\VEN_10DE&DEV_2684' = 'NVIDIA'; 'PCI\VEN_1002&DEV_744C' = 'AMD'; 'PCI\VEN_8086&DEV_A780' = 'Intel'; 'VMBUS\{1234}' = $null; 'PCI\VEN_1414&DEV_5353' = $null; '' = $null }
foreach ($id in $cases.Keys) {
    $got = Get-NovaGpuVendor $id
    if ($got -ne $cases[$id]) { throw ('производитель для «{0}»: ожидался {1}, получился {2}' -f $id, $cases[$id], $got) }
}
Write-Host 'ok  производитель видеокарты по коду устройства'

# Видеокарта
$now = [datetime]'2026-11-14'
Assert-Check (Get-NovaGpuAdvice ([pscustomobject]@{ Name = 'Microsoft Basic Display Adapter'; PnpId = 'PCI\VEN_10DE&DEV_2684'; DriverDate = $null; ErrorCode = 0 }) -Now $now) 'warn' 'nvidia.com' 'нет драйвера NVIDIA'
Assert-Check (Get-NovaGpuAdvice ([pscustomobject]@{ Name = 'Базовый видеоадаптер (Майкрософт)'; PnpId = 'PCI\VEN_1002&DEV_73BF'; DriverDate = $null; ErrorCode = 0 }) -Now $now) 'warn' 'amd.com' 'нет драйвера AMD (русская Windows)'
Assert-Check (Get-NovaGpuAdvice ([pscustomobject]@{ Name = 'NVIDIA GeForce RTX 3060'; PnpId = 'PCI\VEN_10DE&DEV_2503'; DriverDate = [datetime]'2024-03-01'; ErrorCode = 0 }) -Now $now) 'info' 'больше года' 'старый драйвер'
Assert-Check (Get-NovaGpuAdvice ([pscustomobject]@{ Name = 'NVIDIA GeForce RTX 3060'; PnpId = 'PCI\VEN_10DE&DEV_2503'; DriverDate = [datetime]'2026-10-01'; ErrorCode = 0 }) -Now $now) 'ok' 'RTX 3060' 'свежий драйвер'
Assert-Check (Get-NovaGpuAdvice ([pscustomobject]@{ Name = 'Microsoft Hyper-V Video'; PnpId = 'VMBUS\{02780ada}'; DriverDate = $null; ErrorCode = 0 }) -Now $now) 'info' 'виртуальная' 'виртуальная видеокарта'
if (-not (Test-NovaIntegratedGpu ([pscustomobject]@{ Name = 'Intel(R) UHD Graphics 630'; PnpId = 'PCI\VEN_8086&DEV_3E92' }))) { throw 'UHD 630 — встроенная' }
if (Test-NovaIntegratedGpu ([pscustomobject]@{ Name = 'Intel(R) Arc(TM) A770 Graphics'; PnpId = 'PCI\VEN_8086&DEV_56A0' })) { throw 'Arc A770 — отдельная' }
if (-not (Test-NovaIntegratedGpu ([pscustomobject]@{ Name = 'AMD Radeon(TM) Graphics'; PnpId = 'PCI\VEN_1002&DEV_1638' }))) { throw 'Radeon Graphics — встроенная' }
if (Test-NovaIntegratedGpu ([pscustomobject]@{ Name = 'AMD Radeon RX 7800 XT'; PnpId = 'PCI\VEN_1002&DEV_747E' })) { throw 'RX 7800 XT — отдельная' }
if (-not (Test-NovaIntegratedGpu ([pscustomobject]@{ Name = 'AMD Radeon(TM) 780M'; PnpId = 'PCI\VEN_1002&DEV_15BF' }))) { throw 'Radeon 780M — встроенная' }
if (Test-NovaIntegratedGpu ([pscustomobject]@{ Name = 'AMD Radeon RX 7600M XT'; PnpId = 'PCI\VEN_1002&DEV_7480' })) { throw 'RX 7600M XT — отдельная' }
if (-not (Test-NovaIntegratedGpu ([pscustomobject]@{ Name = 'Intel(R) Arc(TM) Graphics'; PnpId = 'PCI\VEN_8086&DEV_7D55' }))) { throw 'Arc Graphics в Core Ultra — встроенная' }
Write-Host 'ok  встроенная или отдельная видеокарта'

# Частота монитора
function New-Mode([int]$W, [int]$H, [int]$Hz, [int]$Bits = 32, [bool]$Interlaced = $false) {
    [pscustomobject]@{ Width = $W; Height = $H; Hz = $Hz; Bits = $Bits; Interlaced = $Interlaced }
}
$modes = @((New-Mode 1920 1080 60), (New-Mode 1920 1080 120), (New-Mode 1920 1080 144), (New-Mode 1920 1080 240 32 $true), (New-Mode 1280 720 240), (New-Mode 1920 1080 165 16))
$best = Select-NovaBestHz (New-Mode 1920 1080 60) $modes
if ($best -ne 144) { throw ('лучшая частота: ожидалось 144, получилось {0}' -f $best) }
if ($null -ne (Select-NovaBestHz (New-Mode 1920 1080 144) $modes)) { throw 'на 144 Гц советовать нечего' }
if ($null -ne (Select-NovaBestHz (New-Mode 1920 1080 59) @((New-Mode 1920 1080 59), (New-Mode 1920 1080 60)))) { throw '59 и 60 Гц — одно и то же' }
if ($null -ne (Select-NovaBestHz (New-Mode 1920 1080 1) $modes)) { throw 'частота «по умолчанию» (1) — не советуем' }
Write-Host 'ok  лучшая частота: то же разрешение, без чересстрочных режимов и чужой глубины цвета'

$disp = [pscustomobject]@{ Index = 1; Device = '\\.\DISPLAY1'; Adapter = 'NVIDIA GeForce RTX 4070'; AdapterId = 'PCI\VEN_10DE&DEV_2786'; Current = (New-Mode 2560 1440 60); Modes = @((New-Mode 2560 1440 60), (New-Mode 2560 1440 165)) }
$c = Get-NovaDisplayAdvice -Display $disp -Laptop $false -DiscreteGpu 'NVIDIA GeForce RTX 4070'
Assert-Check $c 'warn' '165' 'монитор на 60 Гц, умеет 165'
if (-not $c.Fix -or $c.Fix.Hz -ne 165 -or $c.Fix.From -ne 60 -or $c.Fix.Device -ne '\\.\DISPLAY1') { throw 'нет данных, чтобы включить 165 Гц' }
$igpu = [pscustomobject]@{ Index = 1; Device = '\\.\DISPLAY1'; Adapter = 'Intel(R) UHD Graphics 770'; AdapterId = 'PCI\VEN_8086&DEV_4680'; Current = (New-Mode 1920 1080 60); Modes = @((New-Mode 1920 1080 60)) }
Assert-Check (Get-NovaDisplayAdvice -Display $igpu -Laptop $false -DiscreteGpu 'NVIDIA GeForce RTX 4070') 'warn' 'материнской плате' 'кабель в материнской плате, а не в видеокарте'
$c = Get-NovaDisplayAdvice -Display $igpu -Laptop $true -DiscreteGpu 'NVIDIA GeForce RTX 4070'
if ($c.Text -like '*встроенной*') { throw 'у ноутбука экран всегда на встроенной графике — это не ошибка' }
Assert-Check $c 'ok' '60 Гц' 'ноутбук на 60 Гц'
Assert-Check (Get-NovaDisplayAdvice -Display ([pscustomobject]@{ Index = 2; Device = 'x'; Adapter = 'NVIDIA'; AdapterId = 'PCI\VEN_10DE&DEV_2786'; Current = (New-Mode 1920 1080 60); Modes = @((New-Mode 1920 1080 60)) }) -Laptop $false -DiscreteGpu 'NVIDIA') 'info' 'DisplayPort' 'ПК на 60 Гц: подсказка про кабель'

# Память
function New-Stick([int]$Gb, [int]$Mhz, [int]$Type = 26) { [pscustomobject]@{ Capacity = [double]$Gb * 1GB; Speed = $Mhz; Type = $Type } }
$r = @(Get-NovaMemoryAdvice -Modules @((New-Stick 16 2133)) -Laptop $false)
if ($r.Count -ne 2 -or -not ($r | Where-Object Id -eq 'ram-xmp') -or -not ($r | Where-Object Id -eq 'ram-channel')) { throw ('одна планка DDR4 2133: ждали XMP и одноканальный режим, получили {0}' -f (($r | ForEach-Object Id) -join ', ')) }
Write-Host ('ok  одна планка DDR4 2133: {0}' -f $r[0].Text)
$r = @(Get-NovaMemoryAdvice -Modules @((New-Stick 16 2133)) -Laptop $true)
Assert-Check $r[0] 'ok' '16 ГБ' 'ноутбук: про BIOS и планки не советуем'
$r = @(Get-NovaMemoryAdvice -Modules @((New-Stick 8 3200), (New-Stick 8 3200)) -Laptop $false)
Assert-Check $r[0] 'ok' '2 планки' '2×8 DDR4 3200'
$r = @(Get-NovaMemoryAdvice -Modules @((New-Stick 16 4800 34), (New-Stick 16 4800 34)) -Laptop $false)
Assert-Check $r[0] 'info' 'EXPO' 'DDR5 4800 — базовая частота'
$r = @(Get-NovaMemoryAdvice -Modules @((New-Stick 4 2400), (New-Stick 2 2400)) -Laptop $false)
Assert-Check ($r | Where-Object Id -eq 'ram') 'warn' '16 ГБ' '6 ГБ — мало'
if ((Get-NovaPlural 1 'планка' 'планки' 'планок') -ne 'планка' -or (Get-NovaPlural 3 'планка' 'планки' 'планок') -ne 'планки' -or (Get-NovaPlural 11 'планка' 'планки' 'планок') -ne 'планок') { throw 'склонение' }

# Диск
Assert-Check (Get-NovaDiskAdvice ([pscustomobject]@{ FriendlyName = 'ST1000DM010'; MediaType = 'HDD'; BusType = 'SATA' })) 'warn' 'SSD' 'Windows на HDD'
Assert-Check (Get-NovaDiskAdvice ([pscustomobject]@{ FriendlyName = 'Samsung 980'; MediaType = 'SSD'; BusType = 'NVMe' })) 'ok' 'NVMe' 'Windows на NVMe'
if ($null -ne (Get-NovaDiskAdvice ([pscustomobject]@{ FriendlyName = 'Virtual Disk'; MediaType = 'Unspecified'; BusType = 'SAS' }))) { throw 'неизвестный тип диска — без совета' }
Write-Host 'ok  неизвестный тип диска — без совета'

# Настоящая Windows: ничего не падает, все статусы понятные.
Write-Host ''
Write-Host '== Эта машина'
foreach ($g in @(Get-NovaGpu)) { Write-Host ('   видеокарта: {0} | {1} | драйвер {2}' -f $g.Name, $g.PnpId, $g.DriverVersion) }
$displays = @(Get-NovaDisplay)
foreach ($d in $displays) {
    $cur = '-'
    if ($d.Current) { $cur = '{0}x{1} {2} Гц' -f $d.Current.Width, $d.Current.Height, $d.Current.Hz }
    Write-Host ('   монитор {0}: {1} на {2} ({3}), режимов: {4}' -f $d.Index, $d.Monitor, $d.Adapter, $cur, $d.Modes.Count)
    if ($d.Current -and $d.Current.Hz -gt 1) {
        $code = Set-NovaDisplayHz -Device $d.Device -Hz $d.Current.Hz -Test
        Write-Host ('   проверка смены частоты на текущую (без смены): код {0}' -f $code)
    }
}
$all = @(Get-NovaGameCheck)
foreach ($c in $all) {
    if (@('ok', 'info', 'warn') -notcontains $c.Status) { throw ('странный статус {0}' -f $c.Status) }
    Write-Host ('   [{0}] {1}: {2}' -f $c.Status, $c.Name, $c.Text)
}
if ($all.Count -eq 0) { throw 'проверка для игр ничего не нашла даже про память' }
Write-Host 'ok  проверка для игр работает на настоящей Windows'

# Ссылки на драйверы ведут на живые официальные страницы (сайты иногда не пускают роботов — тогда только предупреждение).
foreach ($v in @('NVIDIA', 'AMD', 'Intel')) {
    $url = Get-NovaDriverLink $v
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Method Head -MaximumRedirection 5 -TimeoutSec 20 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        Write-Host ('ok  {0}: {1} -> {2}' -f $v, $url, $resp.StatusCode)
    } catch {
        Write-Host ('::warning::{0}: не удалось открыть {1}: {2}' -f $v, $url, $_.Exception.Message)
    }
}
Write-Host 'ТЕСТ ГОТОВНОСТИ К ИГРАМ ПРОЙДЕН'
