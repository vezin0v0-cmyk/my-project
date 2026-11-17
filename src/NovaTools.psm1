# NovaTools.psm1 — помощники на каждый день: что тормозит прямо сейчас, интернет для игр, отчёт для поддержки.
# Здесь Nova в основном смотрит и советует. Сама она может только закрыть программу, которую ты выбрал,
# и сменить DNS — и то после вопроса и с пунктом «вернуть как было».

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -DisableNameChecking

#region Что тормозит прямо сейчас

# Пояснения к частым процессам: по имени файла видно не всё.
$script:ProcessHints = @{
    'msmpeng'               = 'антивирус Windows проверяет файлы — это нормально'
    'mpdefendercoreservice' = 'антивирус Windows'
    'searchindexer'         = 'индексация поиска Windows'
    'searchhost'            = 'поиск в «Пуске»'
    'tiworker'              = 'Windows ставит обновления — дай ей закончить'
    'trustedinstaller'      = 'установщик обновлений Windows'
    'mousocoreworker'       = 'Центр обновления Windows'
    'compattelrunner'       = 'сбор данных о совместимости программ'
    'chrome'                = 'браузер Chrome: каждая вкладка — отдельный процесс'
    'msedge'                = 'браузер Edge: каждая вкладка — отдельный процесс'
    'msedgewebview2'        = 'встроенный браузер внутри других программ'
    'firefox'               = 'браузер Firefox'
    'opera'                 = 'браузер Opera'
    'browser'               = 'Яндекс Браузер'
    'discord'               = 'Discord'
    'steamwebhelper'        = 'окна и магазин Steam'
    'steam'                 = 'Steam'
    'epicgameslauncher'     = 'Epic Games Launcher'
    'obs64'                 = 'OBS: запись или стрим'
    'onedrive'              = 'OneDrive синхронизирует файлы'
    'ms-teams'              = 'Teams'
    'teams'                 = 'Teams'
    'telegram'              = 'Telegram'
    'spotify'               = 'Spotify'
    'wallpaper32'           = 'Wallpaper Engine: живые обои'
    'wallpaper64'           = 'Wallpaper Engine: живые обои'
    'dwm'                   = 'отрисовка окон Windows — это нормально'
    'explorer'              = 'Проводник и панель задач'
    'svchost'               = 'службы Windows'
    'system'                = 'ядро Windows'
    'memory compression'    = 'сжатие памяти: так Windows экономит оперативку'
    'audiodg'               = 'звук Windows'
    'nvcontainer'           = 'программы NVIDIA'
    'radeonsoftware'        = 'программа AMD'
    'powershell'            = 'Nova и другие скрипты PowerShell'
    'vmmem'                 = 'виртуальная машина или WSL'
}
# Части Windows и её защиты: их Nova не закрывает никогда.
$script:ProcessKeep = @('system', 'idle', 'registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsaiso', 'svchost', 'dwm', 'explorer',
    'memory compression', 'fontdrvhost', 'audiodg', 'ctfmon', 'sihost', 'taskhostw', 'runtimebroker', 'searchhost', 'searchindexer', 'startmenuexperiencehost',
    'shellexperiencehost', 'textinputhost', 'conhost', 'openconsole', 'windowsterminal', 'powershell', 'pwsh', 'cmd', 'msmpeng', 'mpdefendercoreservice', 'nissrv',
    'mssense', 'securityhealthservice', 'securityhealthsystray', 'smartscreen', 'tiworker', 'trustedinstaller', 'mousocoreworker', 'wudfhost', 'spoolsv', 'lsm',
    'dllhost', 'wmiprvse', 'vmmem', 'secure system', 'msedgewebview2', 'applicationframehost', 'useroobebroker', 'lockapp', 'logonui')

function Get-NovaProcessHint {
    param([string]$Name)
    $key = ([string]$Name).ToLowerInvariant()
    if ($script:ProcessHints.ContainsKey($key)) { return $script:ProcessHints[$key] }
    return ''
}

# Снимок: сколько процессорного времени каждый процесс уже израсходовал и сколько занимает памяти.
function Get-NovaProcessSnapshot {
    $items = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $cpu = 0.0
        try { $total = $p.TotalProcessorTime; if ($null -ne $total) { $cpu = $total.TotalMilliseconds } } catch { $cpu = 0.0 }
        $items[[int]$p.Id] = [pscustomobject]@{ Id = [int]$p.Id; Name = [string]$p.ProcessName; Cpu = [double]$cpu; Mem = [int64]$p.WorkingSet64; Session = [int]$p.SessionId }
    }
    return [pscustomobject]@{ At = [Diagnostics.Stopwatch]::GetTimestamp(); Items = $items }
}

# Из двух снимков — нагрузка по программам. Все процессы одной программы (вкладки браузера) — одной строкой.
function Get-NovaHeavyList {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After, [int]$Cores = [Environment]::ProcessorCount)
    $seconds = ($After.At - $Before.At) / [double][Diagnostics.Stopwatch]::Frequency
    if ($seconds -le 0) { $seconds = 1.0 }
    if ($Cores -lt 1) { $Cores = 1 }
    $groups = @{}
    foreach ($id in $After.Items.Keys) {
        $a = $After.Items[$id]
        $key = $a.Name.ToLowerInvariant()
        if ($key -eq 'idle') { continue }
        $cpu = 0.0
        $b = $Before.Items[$id]
        if ($b -and $b.Name -eq $a.Name) { $cpu = [math]::Max(0.0, $a.Cpu - $b.Cpu) / 1000.0 / $seconds / $Cores * 100.0 }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ Name = $a.Name; Key = $key; Cpu = 0.0; Mem = [int64]0; Count = 0; Ids = New-Object System.Collections.Generic.List[int]; Session = $a.Session }
        }
        $g = $groups[$key]
        $g.Cpu += $cpu; $g.Mem += $a.Mem; $g.Count++; $g.Ids.Add([int]$id)
    }
    return @($groups.Values)
}

# Самые тяжёлые: сначала по процессору, потом по памяти, без повторов.
function Select-NovaHeavyTop {
    param([object[]]$Groups, [int]$Count = 8)
    $picked = New-Object System.Collections.Generic.List[object]
    foreach ($g in @($Groups | Where-Object { $_.Cpu -ge 1 } | Sort-Object Cpu -Descending | Select-Object -First 5)) { $picked.Add($g) }
    foreach ($g in @($Groups | Sort-Object Mem -Descending)) {
        if ($picked.Count -ge $Count) { break }
        if (-not $picked.Contains($g)) { $picked.Add($g) }
    }
    return $picked.ToArray()
}

function Get-NovaMemoryLoad {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $total = [double]$os.TotalVisibleMemorySize; $free = [double]$os.FreePhysicalMemory
        if ($total -le 0) { return $null }
        return [pscustomobject]@{ TotalGB = [math]::Round($total / 1MB, 1); UsedGB = [math]::Round(($total - $free) / 1MB, 1); Percent = [int][math]::Round(100 * ($total - $free) / $total) }
    } catch { return $null }
}

# Советы по снимку нагрузки.
function Get-NovaHeavyAdvice {
    param([object[]]$Groups, $Memory)
    $checks = New-Object System.Collections.Generic.List[object]
    $sum = ($Groups | Measure-Object -Property Cpu -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    $cpuTotal = [math]::Min(100, [math]::Round([double]$sum))
    if ($cpuTotal -ge 85) {
        $checks.Add((New-NovaCheck 'Процессор' 'warn' ('Загружен на {0}%.' -f $cpuTotal) 'В игре сейчас будут подтормаживания. Закрой то, что сверху списка, или подожди, пока Windows закончит свои дела.' 'cpu'))
    } else {
        $checks.Add((New-NovaCheck 'Процессор' 'ok' ('Загружен на {0}%.' -f $cpuTotal) -Id 'cpu'))
    }
    if ($Memory) {
        if ($Memory.Percent -ge 85) {
            $checks.Add((New-NovaCheck 'Память' 'warn' ('Занято {0} из {1} ГБ ({2}%).' -f $Memory.UsedGB, $Memory.TotalGB, $Memory.Percent) 'Памяти почти не осталось — игра начнёт подгружаться с диска и тормозить. Закрой браузер или другие тяжёлые программы.' 'mem'))
        } else {
            $checks.Add((New-NovaCheck 'Память' 'ok' ('Занято {0} из {1} ГБ ({2}%).' -f $Memory.UsedGB, $Memory.TotalGB, $Memory.Percent) -Id 'mem'))
        }
    }
    $byKey = @{}; foreach ($g in $Groups) { $byKey[$g.Key] = $g }
    $browserMem = [int64]0; foreach ($k in @('chrome', 'msedge', 'firefox', 'opera', 'browser')) { if ($byKey.ContainsKey($k)) { $browserMem += $byKey[$k].Mem } }
    if ($browserMem -ge 2GB) {
        $checks.Add((New-NovaCheck 'Браузер' 'info' ('Браузер занимает {0} ГБ памяти.' -f [math]::Round($browserMem / 1GB, 1)) 'Перед игрой закрой лишние вкладки — это самый простой способ освободить память.' 'browser'))
    }
    $updates = 0.0; foreach ($k in @('tiworker', 'trustedinstaller', 'mousocoreworker')) { if ($byKey.ContainsKey($k)) { $updates += $byKey[$k].Cpu } }
    if ($updates -ge 10) {
        $checks.Add((New-NovaCheck 'Обновления' 'info' 'Windows сейчас ставит обновления.' 'Это временно: дай ей закончить, и нагрузка спадёт. Выключать обновления не нужно.' 'updates'))
    }
    if ($byKey.ContainsKey('msmpeng') -and $byKey['msmpeng'].Cpu -ge 15) {
        $checks.Add((New-NovaCheck 'Антивирус' 'info' 'Антивирус Windows проверяет файлы.' 'Обычно это пара минут после включения или установки игры. Не выключай его — просто подожди.' 'defender'))
    }
    if ($byKey.ContainsKey('searchindexer') -and $byKey['searchindexer'].Cpu -ge 10) {
        $checks.Add((New-NovaCheck 'Поиск' 'info' 'Windows индексирует файлы для поиска.' 'Если мешает часто — в config.json есть пункт «Отключить индексацию поиска».' 'search'))
    }
    return $checks.ToArray()
}

# Можно ли закрыть программу. Пустая строка — можно; иначе причина.
function Get-NovaCloseProblem {
    param([Parameter(Mandatory)]$Group)
    if ($script:ProcessKeep -contains $Group.Key) { return 'это часть Windows или её защиты — Nova её не закрывает' }
    $mySession = (Get-Process -Id $PID).SessionId
    $parent = 0
    try { $parent = [int](Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f $PID) -ErrorAction Stop).ParentProcessId } catch { $parent = 0 }
    foreach ($id in $Group.Ids) {
        if ($id -eq $PID -or $id -eq $parent) { return 'это окно самой Nova' }
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if ($p.SessionId -ne $mySession) { return 'эта программа запущена не у тебя (служба или другой пользователь)' }
        $path = ''
        try { $path = [string]$p.Path } catch { $path = '' }
        if ($path -and $path.StartsWith($env:SystemRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'это программа из папки Windows — Nova её не закрывает' }
    }
    return ''
}

# Закрыть по-хорошему (как крестик окна: программа сама спросит про несохранённое) или принудительно.
function Close-NovaProcessGroup {
    param([Parameter(Mandatory)]$Group, [switch]$Force, [int]$WaitSeconds = 6)
    foreach ($id in $Group.Ids) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if ($Force) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        elseif ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() }
    }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $left = @($Group.Ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($left.Count -eq 0) { return 0 }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return $left.Count
}

function Format-NovaSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($Bytes / 1GB)) }
    return ('{0} МБ' -f [math]::Round($Bytes / 1MB))
}

#endregion

#region Интернет для игр

# Сервисы, до которых меряем пинг. Это ближайшие к тебе серверы сайтов, а не игровые серверы матча:
# пинг в самой игре будет похожим, если серверы игры в том же регионе.
$script:NetTargets = @(
    [pscustomobject]@{ Name = 'Steam'; Host = 'store.steampowered.com' },
    [pscustomobject]@{ Name = 'Riot (Valorant, LoL)'; Host = 'auth.riotgames.com' },
    [pscustomobject]@{ Name = 'FACEIT'; Host = 'www.faceit.com' },
    [pscustomobject]@{ Name = 'Epic Games'; Host = 'store.epicgames.com' },
    [pscustomobject]@{ Name = 'Battle.net'; Host = 'eu.battle.net' },
    [pscustomobject]@{ Name = 'Google'; Host = 'www.google.com' }
)
$script:DnsProviders = @(
    [pscustomobject]@{ Name = 'Cloudflare'; Servers = @('1.1.1.1', '1.0.0.1') },
    [pscustomobject]@{ Name = 'Google'; Servers = @('8.8.8.8', '8.8.4.4') },
    [pscustomobject]@{ Name = 'Яндекс'; Servers = @('77.88.8.8', '77.88.8.1') },
    [pscustomobject]@{ Name = 'Quad9'; Servers = @('9.9.9.9', '149.112.112.112') }
)
$script:DnsTestNames = @('steampowered.com', 'riotgames.com', 'faceit.com', 'epicgames.com', 'battle.net')

function Get-NovaNetTargets { return $script:NetTargets }
function Get-NovaDnsProviders { return $script:DnsProviders }

# Медиана, разброс (джиттер) и потери по замерам. Отрицательное число (или $null) — нет ответа.
function Get-NovaPingStats {
    param([object[]]$Samples)
    $all = @($Samples)
    $ok = @($all | Where-Object { $null -ne $_ -and [double]$_ -ge 0 } | ForEach-Object { [double]$_ })
    $loss = 100
    if ($all.Count -gt 0) { $loss = [int][math]::Round(100.0 * ($all.Count - $ok.Count) / $all.Count) }
    if ($ok.Count -eq 0) { return [pscustomobject]@{ Median = $null; Jitter = $null; Loss = 100; Count = $all.Count } }
    $sorted = @($ok | Sort-Object)
    $mid = [int][math]::Floor($sorted.Count / 2)
    $median = $sorted[$mid]
    if ($sorted.Count % 2 -eq 0) { $median = ($sorted[$mid - 1] + $sorted[$mid]) / 2 }
    $jitter = 0.0
    if ($ok.Count -gt 1) { $sum = 0.0; for ($i = 1; $i -lt $ok.Count; $i++) { $sum += [math]::Abs($ok[$i] - $ok[$i - 1]) }; $jitter = $sum / ($ok.Count - 1) }
    return [pscustomobject]@{ Median = [math]::Round($median); Jitter = [math]::Round($jitter, 1); Loss = $loss; Count = $all.Count }
}

# Время установки соединения TCP — это ровно один «туда-обратно», как у ping, но работает и там, где ping закрыт.
function Measure-NovaTcp {
    param([Parameter(Mandatory)][System.Net.IPAddress]$Address, [int]$Port = 443, [int]$TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient($Address.AddressFamily)
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $ar = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return -1 }
        $client.EndConnect($ar)
        $watch.Stop()
        return [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
    } catch {
        return -1
    } finally {
        $client.Close()
    }
}

function Measure-NovaPing {
    param([Parameter(Mandatory)][string]$HostName, [int]$Samples = 6)
    $address = $null
    try { $address = @([System.Net.Dns]::GetHostAddresses($HostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }) | Select-Object -First 1 } catch { $address = $null }
    if (-not $address) { return Get-NovaPingStats @(-1) }
    $times = @(for ($i = 0; $i -lt $Samples; $i++) { Measure-NovaTcp -Address $address; Start-Sleep -Milliseconds 150 })
    return Get-NovaPingStats $times
}

# Через что подключён компьютер: кабель или Wi‑Fi, скорость, сила сигнала.
function Get-NovaConnection {
    $route = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric }) | Select-Object -First 1
    if (-not $route) { return $null }
    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $adapter) { return $null }
    $wifi = ([string]$adapter.PhysicalMediaType -match '802\.11') -or ([int]$adapter.NdisPhysicalMedium -eq 9)
    $signal = $null
    if ($wifi) { $signal = Get-NovaWifiSignal }
    return [pscustomobject]@{ Index = [int]$route.InterfaceIndex; Alias = [string]$adapter.InterfaceAlias; Description = [string]$adapter.InterfaceDescription; Guid = [string]$adapter.InterfaceGuid; Wifi = $wifi; Speed = [string]$adapter.LinkSpeed; Signal = $signal }
}

# Сила сигнала Wi‑Fi из netsh. В выводе одна строка с процентами — это и есть сигнал (на любом языке Windows).
function ConvertFrom-NovaWlanText {
    param([string]$Text)
    foreach ($line in ([string]$Text -split "`r?`n")) { if ($line -match ':\s*(\d{1,3})\s*%') { return [int]$Matches[1] } }
    return $null
}
function Get-NovaWifiSignal {
    $result = Invoke-NovaNative (Get-NovaSystemTool 'netsh.exe') @('wlan', 'show', 'interfaces')
    return ConvertFrom-NovaWlanText $result.Output
}

function Get-NovaNetAdvice {
    param($Connection, [object[]]$Results)
    $checks = New-Object System.Collections.Generic.List[object]
    if (-not $Connection) { $checks.Add((New-NovaCheck 'Интернет' 'stop' 'Нет подключения к интернету.' 'Проверь кабель или Wi‑Fi.' 'net')); return $checks.ToArray() }
    if ($Connection.Wifi) {
        if ($null -ne $Connection.Signal -and $Connection.Signal -lt 50) {
            $checks.Add((New-NovaCheck 'Wi‑Fi' 'warn' ('Сигнал {0}% — слабый.' -f $Connection.Signal) 'Из‑за слабого сигнала пинг скачет и бывают потери. Для игр лучше кабель; если нельзя — поставь компьютер ближе к роутеру или переключись на 5 ГГц.' 'wifi'))
        } else {
            $text = 'Подключение по Wi‑Fi.'
            if ($null -ne $Connection.Signal) { $text = 'Wi‑Fi, сигнал {0}%.' -f $Connection.Signal }
            $checks.Add((New-NovaCheck 'Wi‑Fi' 'info' $text 'Для игр кабель всегда стабильнее Wi‑Fi: меньше скачков пинга.' 'wifi'))
        }
    } else {
        $checks.Add((New-NovaCheck 'Подключение' 'ok' ('По кабелю{0} — лучший вариант для игр.' -f $(if ($Connection.Speed) { ', ' + $Connection.Speed } else { '' })) -Id 'wire'))
    }
    $reached = @($Results | Where-Object { $null -ne $_.Stats.Median })
    if ($reached.Count -eq 0) {
        $checks.Add((New-NovaCheck 'Пинг' 'warn' 'Ни один игровой сервис не ответил.' 'Проверь интернет, VPN или настройки брандмауэра.' 'ping'))
        return $checks.ToArray()
    }
    $best = @($reached | Sort-Object { $_.Stats.Median }) | Select-Object -First 1
    $ms = $best.Stats.Median
    if ($ms -le 40) { $checks.Add((New-NovaCheck 'Пинг' 'ok' ('{0} мс до ближайшего сервиса ({1}).' -f $ms, $best.Name) -Id 'ping')) }
    elseif ($ms -le 90) { $checks.Add((New-NovaCheck 'Пинг' 'info' ('{0} мс до ближайшего сервиса ({1}).' -f $ms, $best.Name) 'Нормально для большинства игр. Для соревновательных лучше меньше 40 мс.' 'ping')) }
    else { $checks.Add((New-NovaCheck 'Пинг' 'warn' ('{0} мс — высокий.' -f $ms) 'Закрой загрузки и торренты, проверь, не включён ли VPN. Если не помогает — звони провайдеру.' 'ping')) }
    $jitter = (@($reached | ForEach-Object { $_.Stats.Jitter }) | Measure-Object -Maximum).Maximum
    if ($jitter -ge 15) { $checks.Add((New-NovaCheck 'Стабильность' 'warn' ('Пинг скачет на {0} мс.' -f [math]::Round($jitter)) 'Обычно виноваты Wi‑Fi или загрузки (Steam, торренты, обновления). На время игры поставь их на паузу.' 'jitter')) }
    else { $checks.Add((New-NovaCheck 'Стабильность' 'ok' ('Пинг ровный (скачки до {0} мс).' -f [math]::Round($jitter)) -Id 'jitter')) }
    $lossy = @($reached | Where-Object { $_.Stats.Loss -ge 20 })
    if ($lossy.Count -gt 0) { $checks.Add((New-NovaCheck 'Потери' 'warn' ('Часть ответов теряется ({0}).' -f (($lossy | ForEach-Object { $_.Name }) -join ', ')) 'В игре это видно как «телепорты» и рывки. Кабель вместо Wi‑Fi обычно решает.' 'loss')) }
    return $checks.ToArray()
}

# DNS: какой сейчас и откуда (от роутера сам или вписан вручную).
function Get-NovaDnsCurrent {
    param([Parameter(Mandatory)][int]$Index)
    $servers = @((Get-DnsClientServerAddress -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ })
    $static = $false
    $adapter = Get-NetAdapter -InterfaceIndex $Index -ErrorAction SilentlyContinue
    if ($adapter) {
        $value = Get-NovaRegValue -Path ('HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{0}' -f $adapter.InterfaceGuid) -Name 'NameServer'
        $static = $value.Exists -and -not [string]::IsNullOrWhiteSpace([string]$value.Value)
    }
    return [pscustomobject]@{ Servers = $servers; Static = $static }
}

function Measure-NovaDns {
    param([Parameter(Mandatory)][string]$Server, [string[]]$Names = $script:DnsTestNames)
    $times = @(foreach ($name in $Names) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            try {
                Resolve-DnsName -Name $name -Server $Server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Out-Null
                [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
            } catch { -1 }
        })
    return Get-NovaPingStats $times
}

# Только настоящие адреса IP: в DNS нельзя вписать что попало.
function Test-NovaIpAddress {
    param([string]$Text)
    $ip = $null
    return ([System.Net.IPAddress]::TryParse([string]$Text, [ref]$ip) -and $ip.ToString() -eq [string]$Text)
}

function Get-NovaDnsBackupPath { return (Join-Path (Get-NovaDataDir) 'dns-backup.json') }

# Сменить DNS. Как было до самой первой смены — запоминаем, чтобы вернуть одной кнопкой.
function Set-NovaDns {
    param([Parameter(Mandatory)][int]$Index, [Parameter(Mandatory)][string[]]$Servers)
    foreach ($s in $Servers) { if (-not (Test-NovaIpAddress $s)) { throw ('«{0}» — не адрес DNS-сервера.' -f $s) } }
    $adapter = Get-NetAdapter -InterfaceIndex $Index -ErrorAction Stop
    $backup = Get-NovaDnsBackupPath
    if (-not (Test-Path -LiteralPath $backup)) {
        $now = Get-NovaDnsCurrent -Index $Index
        $doc = [pscustomobject]@{ index = $Index; guid = [string]$adapter.InterfaceGuid; alias = [string]$adapter.InterfaceAlias; static = $now.Static; servers = @($now.Servers) }
        [System.IO.File]::WriteAllText($backup, ($doc | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    }
    Set-DnsClientServerAddress -InterfaceIndex $Index -ServerAddresses $Servers -ErrorAction Stop
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

function Get-NovaDnsBackup {
    $path = Get-NovaDnsBackupPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# Вернуть DNS как было до Nova.
function Restore-NovaDns {
    $doc = Get-NovaDnsBackup
    if (-not $doc) { throw 'Nova DNS не меняла — возвращать нечего.' }
    $index = [int]$doc.index
    $adapter = Get-NetAdapter -InterfaceIndex $index -ErrorAction SilentlyContinue
    if (-not $adapter -or [string]$adapter.InterfaceGuid -ne [string]$doc.guid) { throw 'Сетевой адаптер, на котором меняли DNS, не найден.' }
    $servers = @($doc.servers | ForEach-Object { [string]$_ } | Where-Object { $_ })
    foreach ($s in $servers) { if (-not (Test-NovaIpAddress $s)) { throw 'В сохранённой копии DNS странный адрес — не возвращаю.' } }
    if ([bool]$doc.static -and $servers.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $servers -ErrorAction Stop
    } else {
        Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction Stop
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-NovaDnsBackupPath) -Force
}

# Какой DNS лучше текущего: заметно быстрее и без потерь. $null — менять не нужно.
function Select-NovaBetterDns {
    param($Current, [object[]]$Providers, [int]$Margin = 15)
    $good = @($Providers | Where-Object { $null -ne $_.Stats.Median -and $_.Stats.Loss -eq 0 } | Sort-Object { $_.Stats.Median })
    if ($good.Count -eq 0) { return $null }
    $best = $good[0]
    if ($null -eq $Current -or $null -eq $Current.Median -or $Current.Loss -gt 0) { return $best }
    if ($best.Stats.Median + $Margin -le $Current.Median) { return $best }
    return $null
}

#endregion

#region Отчёт для поддержки

# Убираем из отчёта то, что не нужно поддержке: имя пользователя, имя компьютера, папку профиля, почту.
function Protect-NovaReportText {
    param([string]$Text, [string]$UserName = $env:USERNAME, [string]$ComputerName = $env:COMPUTERNAME, [string]$UserProfile = [Environment]::GetFolderPath('UserProfile'))
    $t = [string]$Text
    if ($UserProfile -and $UserProfile.Length -ge 4) { $t = $t -ireplace [regex]::Escape($UserProfile), '%USERPROFILE%' }
    if ($UserName -and $UserName.Length -ge 2) { $t = $t -ireplace [regex]::Escape($UserName), '<пользователь>' }
    if ($ComputerName -and $ComputerName.Length -ge 2) { $t = $t -ireplace [regex]::Escape($ComputerName), '<компьютер>' }
    $t = $t -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<почта>'
    return $t
}

function Get-NovaReportHardware {
    $lines = New-Object System.Collections.Generic.List[string]
    try { foreach ($c in @(Get-CimInstance Win32_Processor -ErrorAction Stop)) { $lines.Add(('Процессор: {0}' -f ([string]$c.Name).Trim())) } } catch { $lines.Add('Процессор: не удалось узнать') }
    try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; $lines.Add(('Память: {0} ГБ' -f [math]::Round([double]$cs.TotalPhysicalMemory / 1GB))) } catch { $lines.Add('Память: не удалось узнать') }
    try {
        foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            $date = ''; if ($v.DriverDate) { $date = ([datetime]$v.DriverDate).ToString('yyyy-MM-dd') }
            $lines.Add(('Видеокарта: {0}, драйвер {1} от {2}, {3} Гц' -f $v.Name, $v.DriverVersion, $date, $v.CurrentRefreshRate))
        }
    } catch { $lines.Add('Видеокарта: не удалось узнать') }
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        $lines.Add(('Диск {0}: свободно {1} из {2} ГБ' -f $env:SystemDrive, [math]::Round([double]$d.FreeSpace / 1GB, 1), [math]::Round([double]$d.Size / 1GB)))
    } catch { $lines.Add('Диск: не удалось узнать') }
    return $lines.ToArray()
}

# Собрать отчёт и положить файлом (по умолчанию — на рабочий стол). Возвращает путь.
function New-NovaSupportReport {
    param([string]$Folder = [Environment]::GetFolderPath('Desktop'), [object[]]$Checks = @(), [string]$LogFolder, [string]$CurrentLog)
    $info = Get-NovaSystemInfo
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Nova — отчёт для поддержки')
    $lines.Add(('Создан: {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm')))
    $lines.Add(('Nova: {0}' -f (Get-NovaVersion)))
    $lines.Add(('Windows: {0} {1}, сборка {2}, {3}' -f $info.Name, $info.Version, $info.Build, $info.Edition))
    foreach ($l in (Get-NovaReportHardware)) { $lines.Add($l) }
    $lines.Add('')
    $lines.Add('— Проверка системы —')
    $marks = @{ ok = '[ok]'; info = '[i] '; warn = '[!] '; stop = '[X] ' }
    foreach ($c in $Checks) { $lines.Add(('{0} {1}: {2}' -f $marks[[string]$c.Status], $c.Name, $c.Text)) }
    if ($LogFolder -and (Test-Path -LiteralPath $LogFolder)) {
        $logs = @(Get-ChildItem -LiteralPath $LogFolder -Filter 'nova-*.log' -File -ErrorAction SilentlyContinue | Where-Object { -not $CurrentLog -or $_.FullName -ne $CurrentLog } | Sort-Object Name -Descending)
        if ($logs.Count -gt 0) {
            $lines.Add('')
            $lines.Add(('— Последний запуск Nova ({0}), конец лога —' -f $logs[0].Name))
            foreach ($l in @(Get-Content -LiteralPath $logs[0].FullName -Tail 60 -Encoding UTF8 -ErrorAction SilentlyContinue)) { $lines.Add([string]$l) }
        }
    }
    # Личное убираем из собранного, а адрес поддержки дописываем уже после этого.
    $text = Protect-NovaReportText ($lines -join "`r`n")
    $text += "`r`n`r`n" + ('Отправь этот файл на {0} и в двух словах опиши, что случилось.' -f (Get-NovaSupportEmail))
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { $Folder = [Environment]::GetFolderPath('MyDocuments') }
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { throw 'Не нашла ни рабочего стола, ни «Документов», куда положить отчёт.' }
    $path = $null
    foreach ($n in @('') + @(2..20 | ForEach-Object { ' ({0})' -f $_ })) {
        $candidate = Join-Path $Folder ('Nova — отчёт для поддержки{0}.txt' -f $n)
        if (-not (Test-Path -LiteralPath $candidate)) { $path = $candidate; break }
    }
    if (-not $path) { throw 'На рабочем столе уже 20 отчётов Nova — удали старые.' }
    $bytes = (New-Object System.Text.UTF8Encoding($true)).GetPreamble() + [Text.Encoding]::UTF8.GetBytes($text)
    Write-NovaNewFile -Path $path -Bytes ([byte[]]$bytes)
    return $path
}

#endregion

Export-ModuleMember -Function *
