# NovaGame.psm1 — «Готовность к играм»: то, что влияет на FPS сильнее любых настроек Windows.
# Драйвер видеокарты, к чему подключён монитор и на какой частоте он работает, оперативная память,
# системный диск и схема питания. Nova здесь только подсказывает. Единственное, что она может
# поменять сама, — частоту монитора, и то с подтверждением и автоматическим возвратом,
# если картинка пропала.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -DisableNameChecking

# Только официальные сайты производителей. «Драйвер-паки» с чужих сайтов — частый источник вирусов.
$script:DriverLinks = @{
    NVIDIA = 'https://www.nvidia.com/Download/index.aspx?lang=ru'
    AMD    = 'https://www.amd.com/en/support/download/drivers.html'
    Intel  = 'https://www.intel.com/content/www/us/en/support/detect.html'
}
$script:PowerSaver = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$script:RuCulture = [Globalization.CultureInfo]'ru-RU'

#region Видеокарта

# Производитель по коду устройства (PCI\VEN_xxxx). Виртуальные видеокарты и удалённый рабочий стол — $null.
function Get-NovaGpuVendor {
    param([string]$PnpId)
    if ($PnpId -notmatch '^PCI\\VEN_([0-9A-Fa-f]{4})') { return $null }
    switch ($Matches[1].ToUpperInvariant()) {
        '10DE' { return 'NVIDIA' }
        '1002' { return 'AMD' }
        '1022' { return 'AMD' }
        '8086' { return 'Intel' }
    }
    return $null
}

function Get-NovaDriverLink {
    param([string]$Vendor)
    if ($Vendor -and $script:DriverLinks.ContainsKey($Vendor)) { return $script:DriverLinks[$Vendor] }
    return ''
}

# Встроенная графика (в процессоре) или отдельная видеокарта. NVIDIA всегда отдельная.
function Test-NovaIntegratedGpu {
    param($Gpu)
    $vendor = Get-NovaGpuVendor $Gpu.PnpId
    # Intel Arc A770/B580 — отдельные видеокарты, а просто «Arc Graphics» — встроенная в Core Ultra.
    if ($vendor -eq 'Intel') { return ($Gpu.Name -notmatch 'Arc\(TM\) [AB]\d{3}|Arc [AB]\d{3}') }
    # Встроенные AMD: «Radeon Graphics», «Radeon Vega 8», «Radeon 780M». Отдельные называются RX ….
    if ($vendor -eq 'AMD') { return ($Gpu.Name -notmatch '\bRX\b' -and $Gpu.Name -match 'Radeon\(TM\) Graphics|Radeon Graphics|Vega \d+|Radeon\(TM\) \d{3}M|Radeon \d{3}M') }
    return $false
}

# Совет по одной видеокарте. $Gpu: Name, PnpId, DriverVersion, DriverDate ([datetime] или $null), ErrorCode.
function Get-NovaGpuAdvice {
    param([Parameter(Mandatory)]$Gpu, [datetime]$Now = (Get-Date))
    $vendor = Get-NovaGpuVendor $Gpu.PnpId
    if (-not $vendor) {
        return (New-NovaCheck 'Видеокарта' 'info' ('{0} — виртуальная или неизвестная видеокарта, проверять нечего.' -f $Gpu.Name) -Id 'gpu')
    }
    $link = Get-NovaDriverLink $vendor
    $basic = ($Gpu.Name -match 'Basic Display|Базовый видеоадаптер') -or ($Gpu.ErrorCode -and [int]$Gpu.ErrorCode -ne 0)
    if ($basic) {
        return (New-NovaCheck 'Видеокарта' 'warn' ('Драйвер видеокарты {0} не установлен: Windows работает на базовом драйвере, игры будут тормозить или не запустятся.' -f $vendor) ('Скачай драйвер с официального сайта: {0}. Не ставь «драйвер-паки» с других сайтов.' -f $link) 'gpu')
    }
    $date = ''
    if ($Gpu.DriverDate) { $date = ([datetime]$Gpu.DriverDate).ToString('d MMMM yyyy', $script:RuCulture) }
    if ($Gpu.DriverDate -and ($Now - [datetime]$Gpu.DriverDate).TotalDays -gt 365) {
        return (New-NovaCheck 'Видеокарта' 'info' ('{0}: драйвер от {1} — ему больше года.' -f $Gpu.Name, $date) ('Новые драйверы часто прибавляют FPS в свежих играх. Официальный сайт: {0}' -f $link) 'gpu')
    }
    $text = $Gpu.Name
    if ($date) { $text = '{0}, драйвер от {1}.' -f $Gpu.Name, $date }
    return (New-NovaCheck 'Видеокарта' 'ok' $text -Id 'gpu')
}

function Get-NovaGpu {
    $list = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    return @(foreach ($v in $list) {
            [pscustomobject]@{
                Name = [string]$v.Name; PnpId = [string]$v.PNPDeviceID; DriverVersion = [string]$v.DriverVersion
                DriverDate = $v.DriverDate; ErrorCode = $v.ConfigManagerErrorCode
            }
        })
}

#endregion

#region Монитор

$script:ScreensReady = $false
function Initialize-NovaScreen {
    if ($script:ScreensReady) { return }
    if (-not ('NovaGame.Screens' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace NovaGame {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion; public ushort dmDriverVersion; public ushort dmSize; public ushort dmDriverExtra; public uint dmFields;
        public int dmPositionX; public int dmPositionY; public uint dmDisplayOrientation; public uint dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels; public uint dmBitsPerPel; public uint dmPelsWidth; public uint dmPelsHeight;
        public uint dmDisplayFlags; public uint dmDisplayFrequency; public uint dmICMMethod; public uint dmICMIntent;
        public uint dmMediaType; public uint dmDitherType; public uint dmReserved1; public uint dmReserved2;
        public uint dmPanningWidth; public uint dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    public class Mode { public uint Width; public uint Height; public uint Hz; public uint Bits; public bool Interlaced; }
    public class Display {
        public string DeviceName; public string Adapter; public string AdapterId; public string Monitor; public bool Primary;
        public Mode Current; public List<Mode> Modes = new List<Mode>();
    }
    public static class Screens {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE devMode, IntPtr hwnd, uint flags, IntPtr param);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsEx")]
        static extern int ChangeDisplaySettingsExNull(string deviceName, IntPtr devMode, IntPtr hwnd, uint flags, IntPtr param);

        const int CURRENT = -1;
        const uint ATTACHED = 0x1, PRIMARY = 0x4, MIRRORING = 0x8;
        const uint DM_PELSWIDTH = 0x80000, DM_PELSHEIGHT = 0x100000, DM_DISPLAYFREQUENCY = 0x400000;
        const uint CDS_UPDATEREGISTRY = 0x1, CDS_TEST = 0x2;

        static DEVMODE NewMode() {
            DEVMODE d = new DEVMODE();
            d.dmDeviceName = new string('\0', 32); d.dmFormName = new string('\0', 32);
            d.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            return d;
        }
        static Mode ToMode(DEVMODE d) {
            Mode m = new Mode();
            m.Width = d.dmPelsWidth; m.Height = d.dmPelsHeight; m.Hz = d.dmDisplayFrequency; m.Bits = d.dmBitsPerPel;
            m.Interlaced = (d.dmDisplayFlags & 0x2) != 0;
            return m;
        }
        public static List<Display> List() {
            List<Display> result = new List<Display>();
            for (uint i = 0; i < 64; i++) {
                DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
                if ((dd.StateFlags & ATTACHED) == 0 || (dd.StateFlags & MIRRORING) != 0) continue;
                Display disp = new Display();
                disp.DeviceName = dd.DeviceName; disp.Adapter = dd.DeviceString; disp.AdapterId = dd.DeviceID;
                disp.Primary = (dd.StateFlags & PRIMARY) != 0;
                DISPLAY_DEVICE mon = new DISPLAY_DEVICE();
                mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (EnumDisplayDevices(dd.DeviceName, 0, ref mon, 0)) disp.Monitor = mon.DeviceString;
                DEVMODE cur = NewMode();
                if (EnumDisplaySettings(dd.DeviceName, CURRENT, ref cur)) disp.Current = ToMode(cur);
                for (int m = 0; m < 4096; m++) {
                    DEVMODE dm = NewMode();
                    if (!EnumDisplaySettings(dd.DeviceName, m, ref dm)) break;
                    disp.Modes.Add(ToMode(dm));
                }
                result.Add(disp);
            }
            return result;
        }
        // Меняет только частоту, разрешение остаётся. test — только спросить драйвер, можно ли;
        // persist — запомнить (иначе после перезагрузки вернётся прежняя частота).
        public static int SetHz(string device, uint hz, bool persist, bool test) {
            DEVMODE dm = NewMode();
            if (!EnumDisplaySettings(device, CURRENT, ref dm)) return -100;
            dm.dmDisplayFrequency = hz;
            dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
            uint flags = test ? CDS_TEST : (persist ? CDS_UPDATEREGISTRY : 0u);
            return ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, flags, IntPtr.Zero);
        }
        // Вернуть режим, сохранённый в Windows (отменяет временную смену).
        public static int Reset(string device) {
            return ChangeDisplaySettingsExNull(device, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
        }
    }
}
'@
    }
    $script:ScreensReady = $true
}

function Get-NovaDisplay {
    Initialize-NovaScreen
    $i = 0
    return @(foreach ($d in [NovaGame.Screens]::List()) {
            $i++
            $cur = $null
            if ($d.Current) { $cur = [pscustomobject]@{ Width = [int]$d.Current.Width; Height = [int]$d.Current.Height; Hz = [int]$d.Current.Hz; Bits = [int]$d.Current.Bits } }
            [pscustomobject]@{
                Index = $i; Device = $d.DeviceName; Adapter = $d.Adapter; AdapterId = $d.AdapterId; Monitor = $d.Monitor; Primary = $d.Primary
                Current = $cur
                Modes = @(foreach ($m in $d.Modes) { [pscustomobject]@{ Width = [int]$m.Width; Height = [int]$m.Height; Hz = [int]$m.Hz; Bits = [int]$m.Bits; Interlaced = [bool]$m.Interlaced } })
            }
        })
}

# Самая высокая частота при том же разрешении, если она заметно выше текущей. Иначе $null.
# Частоты 0 и 1 означают «по умолчанию у оборудования» — тогда не советуем ничего.
function Select-NovaBestHz {
    param($Current, $Modes)
    if (-not $Current -or $Current.Hz -le 1) { return $null }
    $same = @($Modes | Where-Object { $_.Width -eq $Current.Width -and $_.Height -eq $Current.Height -and $_.Bits -eq $Current.Bits -and -not $_.Interlaced -and $_.Hz -gt 1 })
    if ($same.Count -eq 0) { return $null }
    $best = [int](($same | Measure-Object -Property Hz -Maximum).Maximum)
    if ($best -gt $Current.Hz + 1) { return $best }
    return $null
}

# Совет по одному монитору. $DiscreteGpu — название отдельной видеокарты, если она есть.
function Get-NovaDisplayAdvice {
    param([Parameter(Mandatory)]$Display, [bool]$Laptop, [string]$DiscreteGpu = '')
    $name = 'Монитор {0}' -f $Display.Index
    if (-not $Display.Current -or $Display.Current.Hz -le 1) { return $null }
    $res = '{0}×{1}, {2} Гц' -f $Display.Current.Width, $Display.Current.Height, $Display.Current.Hz
    # Частая ошибка на ПК: кабель монитора воткнут в материнскую плату, а не в видеокарту.
    $vendor = Get-NovaGpuVendor $Display.AdapterId
    $onIntegrated = $vendor -and (Test-NovaIntegratedGpu ([pscustomobject]@{ Name = $Display.Adapter; PnpId = $Display.AdapterId }))
    if (-not $Laptop -and $DiscreteGpu -and $onIntegrated) {
        return (New-NovaCheck $name 'warn' ('{0} подключён к встроенной графике ({1}), а не к видеокарте {2}.' -f $res, $Display.Adapter, $DiscreteGpu) 'Переткни кабель монитора из разъёма на материнской плате (рядом с USB) в разъём видеокарты (ниже, горизонтальный ряд). Иначе игры идут через слабую встроенную графику.' 'display')
    }
    $best = Select-NovaBestHz $Display.Current $Display.Modes
    if ($best) {
        $check = New-NovaCheck $name 'warn' ('{0}, а монитор умеет {1} Гц.' -f $res, $best) ('Nova может включить {0} Гц — в меню, пункт 6. Или вручную: Параметры → Система → Дисплей → Расширенные параметры дисплея → Частота обновления.' -f $best) 'display'
        $check | Add-Member -NotePropertyName Fix -NotePropertyValue ([pscustomobject]@{ Kind = 'hz'; Device = $Display.Device; Hz = $best; From = $Display.Current.Hz; Name = $name })
        return $check
    }
    $hint = ''
    if ($Display.Current.Hz -le 60 -and -not $Laptop) {
        $hint = 'Если на коробке монитора написано 144 Гц или больше, а здесь только 60 — подключи его кабелем DisplayPort (или HDMI 2.0+) прямо в видеокарту.'
    }
    $check = New-NovaCheck $name 'ok' ('{0} — максимум, который видит Windows.' -f $res) $hint 'display'
    if ($hint) { $check.Status = 'info' }
    return $check
}

function Set-NovaDisplayHz {
    param([Parameter(Mandatory)][string]$Device, [Parameter(Mandatory)][int]$Hz, [switch]$Test, [switch]$Persist)
    Initialize-NovaScreen
    return [NovaGame.Screens]::SetHz($Device, [uint32]$Hz, [bool]$Persist, [bool]$Test)
}

function Restore-NovaDisplay {
    param([Parameter(Mandatory)][string]$Device)
    Initialize-NovaScreen
    return [NovaGame.Screens]::Reset($Device)
}

#endregion

#region Память, диск, питание

# $Modules: Capacity (байты), Speed (рабочая частота, МГц), Type (SMBIOSMemoryType: 24 DDR3, 26 DDR4, 34 DDR5).
function Get-NovaMemoryAdvice {
    param($Modules, [bool]$Laptop)
    $mods = @($Modules | Where-Object { $_.Capacity -gt 0 })
    if ($mods.Count -eq 0) { return @() }
    $gb = [int][math]::Round(($mods | Measure-Object -Property Capacity -Sum).Sum / 1GB)
    $speeds = @($mods | Where-Object { $_.Speed -gt 0 } | ForEach-Object { [int]$_.Speed })
    $speed = 0
    if ($speeds.Count) { $speed = ($speeds | Measure-Object -Minimum).Minimum }
    $type = switch ([int]$mods[0].Type) { 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } default { '' } }
    $sticks = '{0} {1}' -f $mods.Count, (Get-NovaPlural $mods.Count 'планка' 'планки' 'планок')
    $parts = @(('{0} ГБ' -f $gb))
    if ($type) { $parts += $type }
    if ($speed) { $parts += ('{0} МГц' -f $speed) }
    $parts += $sticks
    $summary = $parts -join ', '
    $result = New-Object System.Collections.Generic.List[object]
    if ($gb -lt 8) {
        $result.Add((New-NovaCheck 'Память' 'warn' ('{0} — мало для современных игр.' -f $summary) 'Для игр сегодня нужно хотя бы 16 ГБ. Это заметнее любых настроек.' 'ram'))
    }
    if (-not $Laptop) {
        $base = ($type -eq 'DDR4' -and $speed -gt 0 -and $speed -le 2666) -or ($type -eq 'DDR5' -and $speed -gt 0 -and $speed -le 4800)
        if ($base) {
            $result.Add((New-NovaCheck 'Память' 'info' ('{0} — работает на базовой частоте {1}.' -f $summary, $type) 'Если на планках или в описании написано больше (например, 3200 или 6000 МГц), включи в BIOS профиль XMP (Intel) или EXPO/DOCP (AMD). В играх это даёт заметно больше FPS. Nova в BIOS не заходит.' 'ram-xmp'))
        }
        if ($mods.Count -eq 1) {
            $result.Add((New-NovaCheck 'Память' 'info' ('{0} — одна планка работает в одноканальном режиме.' -f $summary) 'Вторая такая же планка (две по 8 ГБ вместо одной на 16) обычно заметно прибавляет FPS в играх, которые упираются в процессор.' 'ram-channel'))
        }
    }
    if ($result.Count -eq 0) { $result.Add((New-NovaCheck 'Память' 'ok' ($summary + '.') -Id 'ram')) }
    return $result.ToArray()
}

function Get-NovaPlural {
    param([int]$N, [string]$One, [string]$Few, [string]$Many)
    $n10 = $N % 10; $n100 = $N % 100
    if ($n10 -eq 1 -and $n100 -ne 11) { return $One }
    if ($n10 -ge 2 -and $n10 -le 4 -and ($n100 -lt 12 -or $n100 -gt 14)) { return $Few }
    return $Many
}

# $Disk: FriendlyName, MediaType (HDD/SSD/SCM/Unspecified), BusType (NVMe, SATA, ...).
function Get-NovaDiskAdvice {
    param($Disk)
    if (-not $Disk) { return $null }
    $label = 'Диск ' + $env:SystemDrive
    if ([string]$Disk.MediaType -eq 'HDD') {
        return (New-NovaCheck $label 'warn' ('Windows стоит на жёстком диске (HDD): {0}.' -f $Disk.FriendlyName) 'Самое заметное ускорение всего компьютера — SSD, даже недорогой. Игры тоже ставь на SSD: быстрее загрузки и меньше подтормаживаний.' 'ssd')
    }
    if ([string]$Disk.MediaType -eq 'SSD' -or [string]$Disk.MediaType -eq 'SCM') {
        $kind = 'SSD'
        if ([string]$Disk.BusType -eq 'NVMe') { $kind = 'SSD NVMe' }
        return (New-NovaCheck $label 'ok' ('{0}: {1}.' -f $kind, $Disk.FriendlyName) -Id 'ssd')
    }
    return $null
}

function Get-NovaSystemDisk {
    $letter = $env:SystemDrive.TrimEnd(':')
    $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$partition.DiskNumber } | Select-Object -First 1
    if (-not $disk) { return $null }
    return [pscustomobject]@{ FriendlyName = $disk.FriendlyName; MediaType = [string]$disk.MediaType; BusType = [string]$disk.BusType }
}

#endregion

# Все проверки «для игр». Каждая часть сама по себе: если одна не сработала, остальные покажутся.
function Get-NovaGameCheck {
    $checks = New-Object System.Collections.Generic.List[object]
    $laptop = $false
    try { $laptop = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { $laptop = $false }

    $gpus = @()
    try { $gpus = @(Get-NovaGpu) } catch { Write-Verbose ('Видеокарты: {0}' -f $_.Exception.Message) }
    $physical = @($gpus | Where-Object { Get-NovaGpuVendor $_.PnpId })
    $discrete = @($physical | Where-Object { -not (Test-NovaIntegratedGpu $_) })
    $integrated = @($physical | Where-Object { Test-NovaIntegratedGpu $_ })
    foreach ($gpu in $gpus) {
        # Встроенную графику рядом с отдельной видеокартой не проверяем: игры идут не на ней.
        if ($discrete.Count -gt 0 -and (Test-NovaIntegratedGpu $gpu) -and -not ($gpu.Name -match 'Basic Display|Базовый видеоадаптер')) { continue }
        $checks.Add((Get-NovaGpuAdvice $gpu))
    }
    $dGpuName = ''
    if ($discrete.Count -gt 0) { $dGpuName = $discrete[0].Name }
    if ($laptop -and $discrete.Count -gt 0 -and $integrated.Count -gt 0) {
        $checks.Add((New-NovaCheck 'Две видеокарты' 'info' ('В ноутбуке встроенная {0} и отдельная {1}.' -f $integrated[0].Name, $dGpuName) 'Игры должны идти на отдельной. Проверь: Параметры → Система → Дисплей → Графика → выбери игру → «Высокая производительность». И играй с подключённой зарядкой.' 'hybrid'))
    }

    try {
        foreach ($display in @(Get-NovaDisplay)) {
            $advice = Get-NovaDisplayAdvice -Display $display -Laptop $laptop -DiscreteGpu $dGpuName
            if ($advice) { $checks.Add($advice) }
        }
    } catch { Write-Verbose ('Мониторы: {0}' -f $_.Exception.Message) }

    try {
        $mods = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop | ForEach-Object {
                $speed = $_.ConfiguredClockSpeed
                if (-not $speed) { $speed = $_.Speed }
                [pscustomobject]@{ Capacity = [double]$_.Capacity; Speed = [int]$speed; Type = [int]$_.SMBIOSMemoryType }
            })
        foreach ($c in @(Get-NovaMemoryAdvice -Modules $mods -Laptop $laptop)) { $checks.Add($c) }
    } catch { Write-Verbose ('Память: {0}' -f $_.Exception.Message) }

    try {
        $disk = Get-NovaDiskAdvice (Get-NovaSystemDisk)
        if ($disk) { $checks.Add($disk) }
    } catch { Write-Verbose ('Диск: {0}' -f $_.Exception.Message) }

    try {
        if ((Get-NovaActivePowerScheme) -eq $script:PowerSaver) {
            $checks.Add((New-NovaCheck 'Питание' 'warn' 'Включена схема «Экономия энергии» — процессор работает медленнее.' 'Включи «Сбалансированная»: Панель управления → Электропитание. Или пункт Nova «Высокая производительность».' 'power'))
        }
    } catch { Write-Verbose ('Питание: {0}' -f $_.Exception.Message) }

    return $checks.ToArray()
}

Export-ModuleMember -Function *
