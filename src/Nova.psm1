# Nova.psm1 — движок Nova.
# Читает настройки, показывает, что изменится, применяет изменения и умеет откатывать их назад.
# Работает в Windows PowerShell 5.1 — он встроен в любую Windows 10/11, ничего ставить не нужно.

$ErrorActionPreference = 'Stop'

$script:NovaVersion = '0.3.0'
$script:Categories = [ordered]@{
    privacy     = 'ПРИВАТНОСТЬ'
    interface   = 'ИНТЕРФЕЙС'
    style       = 'ОФОРМЛЕНИЕ NOVA'
    performance = 'СКОРОСТЬ И ИГРЫ'
    system      = 'СИСТЕМА И ФОН'
}
$script:SystemInfo = $null
# Папка проекта (где лежат assets). Задаётся в Get-NovaContext.
$script:NovaRoot = Split-Path -Parent $PSScriptRoot
$script:RegistryKinds = @('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')
$script:ServiceStartups = @('Automatic', 'Manual', 'Disabled')

#region Общее

function Get-NovaVersion { return $script:NovaVersion }

function Write-Nova {
    param(
        [Parameter(Position = 0)][string]$Text = '',
        [Parameter(Position = 1)][ValidateSet('info', 'ok', 'warn', 'err', 'dim', 'title', 'accent')][string]$Kind = 'info'
    )
    $colors = @{ info = 'Gray'; ok = 'Green'; warn = 'Yellow'; err = 'Red'; dim = 'DarkGray'; title = 'Cyan'; accent = 'Magenta' }
    $prefixes = @{ info = '  '; ok = '  + '; warn = '  ! '; err = '  x '; dim = '  '; title = '  '; accent = '  ' }
    Write-Host ($prefixes[$Kind] + $Text) -ForegroundColor $colors[$Kind]
}

# Безопасно читает свойство из JSON-объекта: если его нет — возвращает значение по умолчанию.
function Get-NovaProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Test-NovaAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Папка для резервных копий и логов: C:\ProgramData\Nova
function Get-NovaDataDir {
    $dir = Join-Path $env:ProgramData 'Nova'
    foreach ($sub in @('backups', 'logs')) {
        $path = Join-Path $dir $sub
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    return $dir
}

# Подставляет значения в текст настроек:
# {NovaData} — C:\ProgramData\Nova, {NovaRoot} — папка проекта,
# {WindowsName} — «Windows 11» или «Windows 10», {DisplayVersion} — версия Windows, например 24H2.
function Expand-NovaText {
    param([string]$Text)
    if ($null -eq $Text -or $Text.IndexOf('{') -lt 0) { return $Text }
    if ($null -eq $script:SystemInfo) { $script:SystemInfo = Get-NovaSystemInfo }
    $windowsName = 'Windows 10'
    if ($script:SystemInfo.Build -ge 22000) { $windowsName = 'Windows 11' }
    $result = $Text.Replace('{NovaData}', (Get-NovaDataDir).TrimEnd('\'))
    $result = $result.Replace('{NovaRoot}', $script:NovaRoot.TrimEnd('\'))
    $result = $result.Replace('{WindowsName}', $windowsName)
    return $result.Replace('{DisplayVersion}', [string]$script:SystemInfo.Version)
}

# Путь к файлу из папки проекта (например, assets\wallpaper\nova-dark.jpg).
function Resolve-NovaAsset {
    param([string]$RelativePath)
    return (Join-Path $script:NovaRoot ($RelativePath -replace '/', '\'))
}

# Запуск обычной программы (powercfg, winget). Ошибки программы не роняют скрипт — смотрим код возврата.
function Invoke-NovaNative {
    param([string]$FilePath, [string[]]$ArgumentList = @(), [switch]$Stream)
    $ErrorActionPreference = 'Continue'
    if ($Stream) {
        & $FilePath @ArgumentList | Out-Host
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = '' }
    }
    $output = (& $FilePath @ArgumentList 2>&1 | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
}

function Read-NovaJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Файл не найден: $Path" }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        throw "Ошибка в файле $Path — проверь запятые и кавычки. Подробности: $($_.Exception.Message)"
    }
}

#endregion

#region Реестр

function Split-NovaRegPath {
    param([Parameter(Mandatory)][string]$Path)
    $index = $Path.IndexOf('\')
    if ($index -lt 1) { throw "Неверный путь реестра: $Path" }
    $hiveName = $Path.Substring(0, $index).TrimEnd(':').ToUpperInvariant()
    switch ($hiveName) {
        'HKLM' { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKCU' { $hive = [Microsoft.Win32.RegistryHive]::CurrentUser }
        default { throw "Неизвестный раздел реестра: $hiveName (нужен HKLM или HKCU)" }
    }
    return [pscustomobject]@{ Hive = $hive; HiveName = $hiveName; SubKey = $Path.Substring($index + 1).TrimEnd('\') }
}

# Всегда работаем с 64-битным реестром, даже если PowerShell запущен 32-битный.
function Open-NovaBaseKey {
    param([Microsoft.Win32.RegistryHive]$Hive)
    $view = [Microsoft.Win32.RegistryView]::Default
    if ([Environment]::Is64BitOperatingSystem) { $view = [Microsoft.Win32.RegistryView]::Registry64 }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $view)
}

# "(default)" в настройках — это значение «По умолчанию» раздела.
function ConvertTo-NovaRegName {
    param([string]$Name)
    if ($Name -eq '(default)') { return '' }
    return $Name
}

function Get-NovaRegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $rp = Split-NovaRegPath $Path
    $valueName = ConvertTo-NovaRegName $Name
    $base = Open-NovaBaseKey $rp.Hive
    try {
        $key = $base.OpenSubKey($rp.SubKey, $false)
        if ($null -eq $key) {
            return [pscustomobject]@{ KeyExists = $false; Exists = $false; Kind = $null; Value = $null }
        }
        try {
            if ($key.GetValueNames() -notcontains $valueName) {
                return [pscustomobject]@{ KeyExists = $true; Exists = $false; Kind = $null; Value = $null }
            }
            $kind = $key.GetValueKind($valueName).ToString()
            $value = $key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject]@{ KeyExists = $true; Exists = $true; Kind = $kind; Value = $value }
        } finally {
            $key.Close()
        }
    } finally {
        $base.Close()
    }
}

# Приводит значение из JSON к типу, который ждёт реестр.
function ConvertTo-NovaRegData {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'DWord' {
            $number = [long]$Value
            if ($number -gt [int]::MaxValue) { $number -= 4294967296 }
            return [int]$number
        }
        'QWord' { return [long]$Value }
        'String' { return [string]$Value }
        'ExpandString' { return [string]$Value }
        'MultiString' { return , ([string[]]@($Value)) }
        'Binary' { return , ([byte[]]@($Value)) }
    }
    throw "Неизвестный тип значения реестра: $Kind"
}

function Test-NovaRegValueEqual {
    param($Current, $Target, [string]$Kind)
    switch ($Kind) {
        'MultiString' { return ((@($Current) -join "`n") -ceq (@($Target) -join "`n")) }
        'Binary' { return ((@($Current) -join ',') -eq (@($Target) -join ',')) }
        'DWord' { return ((ConvertTo-NovaRegData $Current 'DWord') -eq (ConvertTo-NovaRegData $Target 'DWord')) }
        'QWord' { return ([long]$Current -eq [long]$Target) }
    }
    return ([string]$Current -ceq [string]$Target)
}

function Format-NovaData {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'MultiString' { return '[' + (@($Value) -join ', ') + ']' }
        'Binary' { return 'hex:' + ((@($Value) | ForEach-Object { '{0:x2}' -f [int]$_ }) -join '') }
        'String' { return '"' + $Value + '"' }
        'ExpandString' { return '"' + $Value + '"' }
    }
    return [string]$Value
}

function Format-NovaRegValue {
    param($State)
    if (-not $State.Exists) { return 'нет' }
    return (Format-NovaData $State.Value $State.Kind)
}

# Находит самый верхний раздел пути, которого ещё нет (его создадим мы — и его же удалим при отмене).
function Get-NovaMissingSubKey {
    param([Microsoft.Win32.RegistryKey]$BaseKey, [string]$SubKey)
    $current = ''
    foreach ($part in ($SubKey -split '\\')) {
        if ($current) { $current = "$current\$part" } else { $current = $part }
        $key = $BaseKey.OpenSubKey($current, $false)
        if ($null -eq $key) { return $current }
        $key.Close()
    }
    return $null
}

function Set-NovaRegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        $Value,
        [Parameter(Mandatory)][string]$Kind,
        [System.Collections.ArrayList]$Journal,
        [string]$Tweak
    )
    $rp = Split-NovaRegPath $Path
    $data = ConvertTo-NovaRegData $Value $Kind
    $base = Open-NovaBaseKey $rp.Hive
    try {
        $missing = Get-NovaMissingSubKey -BaseKey $base -SubKey $rp.SubKey
        if ($missing -and $null -ne $Journal) {
            [void]$Journal.Add([pscustomobject]@{ type = 'keyCreated'; tweak = $Tweak; path = "$($rp.HiveName)\$missing" })
        }
        $key = $base.CreateSubKey($rp.SubKey)
        if ($null -eq $key) { throw "Не удалось открыть раздел $Path" }
        try {
            $key.SetValue((ConvertTo-NovaRegName $Name), $data, [Microsoft.Win32.RegistryValueKind]$Kind)
        } finally {
            $key.Close()
        }
    } finally {
        $base.Close()
    }
}

function Remove-NovaRegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $rp = Split-NovaRegPath $Path
    $base = Open-NovaBaseKey $rp.Hive
    try {
        $key = $base.OpenSubKey($rp.SubKey, $true)
        if ($null -ne $key) {
            try { $key.DeleteValue((ConvertTo-NovaRegName $Name), $false) } finally { $key.Close() }
        }
    } finally {
        $base.Close()
    }
}

function Remove-NovaRegKey {
    param([Parameter(Mandatory)][string]$Path)
    $rp = Split-NovaRegPath $Path
    $base = Open-NovaBaseKey $rp.Hive
    try { $base.DeleteSubKeyTree($rp.SubKey, $false) } finally { $base.Close() }
}

# Значение для файла резервной копии (JSON).
function ConvertTo-NovaJournalValue {
    param($Value, [string]$Kind)
    if ($null -eq $Value) { return $null }
    switch ($Kind) {
        'QWord' { return [string]$Value }
        'Binary' { return , @(@($Value) | ForEach-Object { [int]$_ }) }
        'MultiString' { return , @([string[]]@($Value)) }
    }
    return $Value
}

#endregion

#region Службы, питание

function Get-NovaServiceStartup {
    param([string]$Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) { return $null }
    return $service.StartType.ToString()
}

function Get-NovaActivePowerScheme {
    $result = Invoke-NovaNative 'powercfg.exe' @('/getactivescheme')
    if ($result.Output -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
        return $Matches[0].ToLowerInvariant()
    }
    return $null
}

function Test-NovaPowerSchemeExists {
    param([string]$Guid)
    $result = Invoke-NovaNative 'powercfg.exe' @('/list')
    return ($result.Output -match [regex]::Escape($Guid))
}

function Get-NovaHibernateState {
    $state = Get-NovaRegValue -Path 'HKLM\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
    if ($state.Exists -and [int]$state.Value -ne 0) { return 'on' }
    return 'off'
}

#endregion

#region Обои и файлы

$script:DesktopKey = 'HKCU\Control Panel\Desktop'

function Get-NovaWallpaperTarget {
    param($Action)
    $name = Split-Path -Leaf ([string]$Action.file)
    return (Join-Path (Join-Path (Get-NovaDataDir) 'wallpaper') $name)
}

function Get-NovaCurrentWallpaper {
    $state = Get-NovaRegValue -Path $script:DesktopKey -Name 'Wallpaper'
    if ($state.Exists) { return [string]$state.Value }
    return ''
}

# Ставит обои сразу, без перезагрузки (SystemParametersInfo).
function Set-NovaWallpaper {
    param([string]$Path)
    if (-not ('NovaNative.Desktop' -as [type])) {
        Add-Type -Namespace NovaNative -Name Desktop -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(int uiAction, int uiParam, string pvParam, int fWinIni);
'@
    }
    # SPI_SETDESKWALLPAPER = 0x14, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE = 0x03
    if (-not [NovaNative.Desktop]::SystemParametersInfo(0x14, 0, $Path, 0x03)) {
        throw "Windows не смогла поставить обои: $Path"
    }
}

function Get-NovaFileHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Copy-NovaFile {
    param([string]$From, [string]$To)
    $dir = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $From -Destination $To -Force
}

#endregion

#region Задачи по расписанию

# Состояние задачи: Ready / Disabled / Running … или $null, если такой задачи нет.
function Get-NovaTaskState {
    param([string]$TaskPath, [string]$TaskName)
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $null }
    return $task.State.ToString()
}

#endregion

#region Действия: проверить, применить, отменить

function New-NovaState {
    param([bool]$NeedsChange, [string]$Current, [string]$Target, [string]$Note)
    return [pscustomobject]@{ NeedsChange = $NeedsChange; Current = $Current; Target = $Target; Note = $Note }
}

function Get-NovaActionLabel {
    param($Action)
    switch ($Action.type) {
        'registry' { return "$($Action.path)\$($Action.name)" }
        'service' { return "служба $($Action.name)" }
        'powerScheme' { return 'схема питания' }
        'hibernate' { return 'гибернация' }
        'wallpaper' { return 'обои рабочего стола' }
        'copyFile' { return "файл $(Expand-NovaText $Action.to)" }
        'scheduledTask' { return "задача $($Action.path)$($Action.name)" }
    }
    return [string]$Action.type
}

# Значение для реестра с подставленными путями ({NovaData} и т.п.).
function Get-NovaRegTarget {
    param($Action)
    if (@('String', 'ExpandString') -contains $Action.kind) { return (Expand-NovaText ([string]$Action.value)) }
    return $Action.value
}

# Смотрит, как сейчас настроено, и нужно ли что-то менять.
function Get-NovaActionState {
    param($Action)
    switch ($Action.type) {
        'registry' {
            $state = Get-NovaRegValue -Path $Action.path -Name $Action.name
            $target = Get-NovaRegTarget $Action
            $same = $state.Exists -and ($state.Kind -eq $Action.kind) -and (Test-NovaRegValueEqual $state.Value $target $Action.kind)
            return New-NovaState (-not $same) (Format-NovaRegValue $state) (Format-NovaData $target $Action.kind) ''
        }
        'wallpaper' {
            $target = Get-NovaWallpaperTarget $Action
            $current = Get-NovaCurrentWallpaper
            $same = ($current -eq $target) -and ((Get-NovaFileHash $target) -eq (Get-NovaFileHash (Resolve-NovaAsset $Action.file)))
            $shown = $current
            if (-not $shown) { $shown = 'без обоев' }
            return New-NovaState (-not $same) $shown $target ''
        }
        'scheduledTask' {
            $current = Get-NovaTaskState $Action.path $Action.name
            if ($null -eq $current) { return New-NovaState $false 'нет' 'Disabled' 'задачи нет в этой системе' }
            return New-NovaState ($current -ne 'Disabled') $current 'Disabled' ''
        }
        'copyFile' {
            $to = Expand-NovaText $Action.to
            $same = (Get-NovaFileHash $to) -eq (Get-NovaFileHash (Resolve-NovaAsset $Action.from))
            $current = 'нет'
            if (Test-Path -LiteralPath $to) { $current = 'другая версия' }
            if ($same) { $current = 'есть' }
            return New-NovaState (-not $same) $current 'есть' ''
        }
        'service' {
            $current = Get-NovaServiceStartup $Action.name
            if ($null -eq $current) { return New-NovaState $false 'нет' $Action.startup 'служба не найдена в этой системе' }
            return New-NovaState ($current -ne $Action.startup) $current $Action.startup ''
        }
        'powerScheme' {
            $target = ([string]$Action.guid).ToLowerInvariant()
            if (-not (Test-NovaPowerSchemeExists $target)) { return New-NovaState $false '' $target 'эта схема питания недоступна на этом ПК' }
            $current = Get-NovaActivePowerScheme
            return New-NovaState ($current -ne $target) $current $target ''
        }
        'hibernate' {
            $current = Get-NovaHibernateState
            return New-NovaState ($current -ne $Action.state) $current $Action.state ''
        }
    }
    throw "Неизвестный тип действия: $($Action.type)"
}

# Применяет одно действие. Перед изменением записывает в журнал, как было, — чтобы потом вернуть.
function Invoke-NovaAction {
    param($Action, [System.Collections.ArrayList]$Journal, [string]$Tweak)
    switch ($Action.type) {
        'wallpaper' {
            $target = Get-NovaWallpaperTarget $Action
            $style = Get-NovaRegValue -Path $script:DesktopKey -Name 'WallpaperStyle'
            $tile = Get-NovaRegValue -Path $script:DesktopKey -Name 'TileWallpaper'
            [void]$Journal.Add([pscustomobject]@{
                    type      = 'wallpaper'
                    tweak     = $Tweak
                    path      = (Get-NovaCurrentWallpaper)
                    style     = $(if ($style.Exists) { [string]$style.Value } else { $null })
                    tile      = $(if ($tile.Exists) { [string]$tile.Value } else { $null })
                    installed = $target
                })
            Copy-NovaFile -From (Resolve-NovaAsset $Action.file) -To $target
            # 10 = «Заполнение»: картинка закрывает весь экран без полос.
            Set-NovaRegValue -Path $script:DesktopKey -Name 'WallpaperStyle' -Value '10' -Kind 'String'
            Set-NovaRegValue -Path $script:DesktopKey -Name 'TileWallpaper' -Value '0' -Kind 'String'
            Set-NovaWallpaper -Path $target
            return
        }
        'scheduledTask' {
            $before = Get-NovaTaskState $Action.path $Action.name
            if ($null -eq $before) { return }
            [void]$Journal.Add([pscustomobject]@{ type = 'scheduledTask'; tweak = $Tweak; path = $Action.path; name = $Action.name; state = $before })
            Disable-ScheduledTask -TaskPath $Action.path -TaskName $Action.name | Out-Null
            return
        }
        'copyFile' {
            $to = Expand-NovaText $Action.to
            $backup = $null
            if (Test-Path -LiteralPath $to) {
                $backup = $to + '.nova-backup'
                Copy-Item -LiteralPath $to -Destination $backup -Force
            }
            [void]$Journal.Add([pscustomobject]@{ type = 'copyFile'; tweak = $Tweak; path = $to; backup = $backup })
            Copy-NovaFile -From (Resolve-NovaAsset $Action.from) -To $to
            return
        }
        'registry' {
            $before = Get-NovaRegValue -Path $Action.path -Name $Action.name
            Set-NovaRegValue -Path $Action.path -Name $Action.name -Value (Get-NovaRegTarget $Action) -Kind $Action.kind -Journal $Journal -Tweak $Tweak
            [void]$Journal.Add([pscustomobject]@{
                    type    = 'registry'
                    tweak   = $Tweak
                    path    = $Action.path
                    name    = $Action.name
                    existed = $before.Exists
                    kind    = $before.Kind
                    value   = (ConvertTo-NovaJournalValue $before.Value $before.Kind)
                })
            return
        }
        'service' {
            $before = Get-NovaServiceStartup $Action.name
            if ($null -eq $before) { return }
            [void]$Journal.Add([pscustomobject]@{ type = 'service'; tweak = $Tweak; name = $Action.name; startup = $before })
            Set-Service -Name $Action.name -StartupType $Action.startup
            if ($Action.startup -eq 'Disabled') { Stop-Service -Name $Action.name -Force -ErrorAction SilentlyContinue }
            return
        }
        'powerScheme' {
            $before = Get-NovaActivePowerScheme
            if ($before) { [void]$Journal.Add([pscustomobject]@{ type = 'powerScheme'; tweak = $Tweak; guid = $before }) }
            $result = Invoke-NovaNative 'powercfg.exe' @('/setactive', [string]$Action.guid)
            if ($result.Code -ne 0) { throw "powercfg не смог сменить схему питания: $($result.Output.Trim())" }
            return
        }
        'hibernate' {
            $before = Get-NovaHibernateState
            [void]$Journal.Add([pscustomobject]@{ type = 'hibernate'; tweak = $Tweak; state = $before })
            $result = Invoke-NovaNative 'powercfg.exe' @('/hibernate', [string]$Action.state)
            if ($result.Code -ne 0) { throw "powercfg не смог изменить гибернацию: $($result.Output.Trim())" }
            return
        }
    }
    throw "Неизвестный тип действия: $($Action.type)"
}

# Возвращает одну запись журнала в исходное состояние.
function Undo-NovaEntry {
    param($Entry)
    switch ($Entry.type) {
        'registry' {
            if ($Entry.existed) {
                Set-NovaRegValue -Path $Entry.path -Name $Entry.name -Value $Entry.value -Kind $Entry.kind
            } else {
                Remove-NovaRegValue -Path $Entry.path -Name $Entry.name
            }
            return
        }
        'keyCreated' {
            Remove-NovaRegKey -Path $Entry.path
            return
        }
        'service' {
            if ($script:ServiceStartups -contains $Entry.startup) {
                Set-Service -Name $Entry.name -StartupType $Entry.startup
                if ($Entry.startup -eq 'Automatic') { Start-Service -Name $Entry.name -ErrorAction SilentlyContinue }
            }
            return
        }
        'powerScheme' {
            $result = Invoke-NovaNative 'powercfg.exe' @('/setactive', [string]$Entry.guid)
            if ($result.Code -ne 0) { throw "powercfg не смог вернуть схему питания: $($result.Output.Trim())" }
            return
        }
        'hibernate' {
            $result = Invoke-NovaNative 'powercfg.exe' @('/hibernate', [string]$Entry.state)
            if ($result.Code -ne 0) { throw "powercfg не смог вернуть гибернацию: $($result.Output.Trim())" }
            return
        }
        'wallpaper' {
            foreach ($pair in @(@('WallpaperStyle', $Entry.style), @('TileWallpaper', $Entry.tile))) {
                if ($null -ne $pair[1]) {
                    Set-NovaRegValue -Path $script:DesktopKey -Name $pair[0] -Value $pair[1] -Kind 'String'
                } else {
                    Remove-NovaRegValue -Path $script:DesktopKey -Name $pair[0]
                }
            }
            Set-NovaWallpaper -Path ([string]$Entry.path)
            if ($Entry.installed -and $Entry.installed -ne $Entry.path -and (Test-Path -LiteralPath $Entry.installed)) {
                Remove-Item -LiteralPath $Entry.installed -Force -ErrorAction SilentlyContinue
            }
            return
        }
        'copyFile' {
            if ($Entry.backup -and (Test-Path -LiteralPath $Entry.backup)) {
                Move-Item -LiteralPath $Entry.backup -Destination $Entry.path -Force
            } elseif (Test-Path -LiteralPath $Entry.path) {
                Remove-Item -LiteralPath $Entry.path -Force
            }
            return
        }
        'scheduledTask' {
            if ($Entry.state -ne 'Disabled') { Enable-ScheduledTask -TaskPath $Entry.path -TaskName $Entry.name | Out-Null }
            return
        }
        'appRemoved' { return }
        'appInstalled' { return }
    }
    throw "Неизвестная запись в резервной копии: $($Entry.type)"
}

#endregion

#region Загрузка и проверка настроек

function Get-NovaSystemInfo {
    $path = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int](Get-NovaRegValue -Path $path -Name 'CurrentBuild').Value
    $version = (Get-NovaRegValue -Path $path -Name 'DisplayVersion').Value
    $edition = (Get-NovaRegValue -Path $path -Name 'EditionID').Value
    $installType = (Get-NovaRegValue -Path $path -Name 'InstallationType').Value
    $isServer = ($installType -eq 'Server')
    $name = 'Windows 10'
    if ($build -ge 22000) { $name = 'Windows 11' }
    if ($isServer) { $name = 'Windows Server' }
    return [pscustomobject]@{ Name = $name; Build = $build; Version = $version; Edition = $edition; IsServer = $isServer }
}

# Проверяет tweaks.json и config.json на ошибки. Возвращает список проблем (пустой — всё хорошо).
function Test-NovaDefinition {
    param($Config, $Tweaks)
    $problems = New-Object System.Collections.Generic.List[string]
    $ids = @{}
    foreach ($tweak in $Tweaks) {
        $id = Get-NovaProp $tweak 'id'
        if (-not $id) { $problems.Add('tweaks.json: настройка без id'); continue }
        if ($ids.ContainsKey($id)) { $problems.Add("tweaks.json: повторяется id '$id'") }
        $ids[$id] = $true
        if (-not $script:Categories.Contains([string](Get-NovaProp $tweak 'category'))) { $problems.Add("tweaks.json: у '$id' неизвестная категория") }
        if (-not (Get-NovaProp $tweak 'title')) { $problems.Add("tweaks.json: у '$id' нет названия (title)") }
        $actions = @(Get-NovaProp $tweak 'actions' @())
        if ($actions.Count -eq 0) { $problems.Add("tweaks.json: у '$id' нет действий (actions)") }
        foreach ($action in $actions) {
            $type = [string](Get-NovaProp $action 'type')
            if ($type -eq 'registry') {
                if ([string](Get-NovaProp $action 'path') -notmatch '^(HKLM|HKCU)\\.+') { $problems.Add("tweaks.json: у '$id' неверный путь реестра") }
                if (-not (Get-NovaProp $action 'name')) { $problems.Add("tweaks.json: у '$id' не указано имя значения (name)") }
                if ($script:RegistryKinds -notcontains (Get-NovaProp $action 'kind')) { $problems.Add("tweaks.json: у '$id' неверный тип значения (kind)") }
                if ($null -eq $action.PSObject.Properties['value']) { $problems.Add("tweaks.json: у '$id' не указано значение (value)") }
            } elseif ($type -eq 'service') {
                if (-not (Get-NovaProp $action 'name')) { $problems.Add("tweaks.json: у '$id' не указано имя службы") }
                if ($script:ServiceStartups -notcontains (Get-NovaProp $action 'startup')) { $problems.Add("tweaks.json: у '$id' неверный тип запуска службы") }
            } elseif ($type -eq 'powerScheme') {
                if ([string](Get-NovaProp $action 'guid') -notmatch '^[0-9a-fA-F-]{36}$') { $problems.Add("tweaks.json: у '$id' неверный guid схемы питания") }
            } elseif ($type -eq 'hibernate') {
                if (@('on', 'off') -notcontains (Get-NovaProp $action 'state')) { $problems.Add("tweaks.json: у '$id' state должен быть on или off") }
            } elseif ($type -eq 'scheduledTask') {
                if ([string](Get-NovaProp $action 'path') -notmatch '^\\.*\\$') { $problems.Add("tweaks.json: у '$id' путь задачи должен начинаться и заканчиваться на \") }
                if (-not (Get-NovaProp $action 'name')) { $problems.Add("tweaks.json: у '$id' не указано имя задачи") }
            } elseif ($type -eq 'wallpaper') {
                $file = [string](Get-NovaProp $action 'file')
                if (-not $file -or -not (Test-Path -LiteralPath (Resolve-NovaAsset $file))) { $problems.Add("tweaks.json: у '$id' не найден файл обоев '$file'") }
            } elseif ($type -eq 'copyFile') {
                $from = [string](Get-NovaProp $action 'from')
                if (-not $from -or -not (Test-Path -LiteralPath (Resolve-NovaAsset $from))) { $problems.Add("tweaks.json: у '$id' не найден файл '$from'") }
                if ([string](Get-NovaProp $action 'to') -notlike '{NovaData}*') { $problems.Add("tweaks.json: у '$id' файл можно копировать только в {NovaData}") }
            } else {
                $problems.Add("tweaks.json: у '$id' неизвестный тип действия '$type'")
            }
        }
    }

    $toggles = Get-NovaProp $Config 'tweaks'
    if ($null -eq $toggles) {
        $problems.Add('config.json: нет раздела "tweaks"')
    } else {
        foreach ($property in $toggles.PSObject.Properties) {
            if (-not $ids.ContainsKey($property.Name)) { $problems.Add("config.json: неизвестная настройка '$($property.Name)'") }
            if ($property.Value -isnot [bool]) { $problems.Add("config.json: у '$($property.Name)' должно быть true или false") }
        }
    }
    foreach ($section in @('removeApps', 'installApps')) {
        $list = Get-NovaProp $Config $section
        if ($null -eq $list) { continue }
        foreach ($property in $list.PSObject.Properties) {
            if ($property.Value -isnot [bool]) { $problems.Add("config.json: в '$section' у '$($property.Name)' должно быть true или false") }
        }
    }
    $restorePoint = Get-NovaProp $Config 'createRestorePoint' $true
    if ($restorePoint -isnot [bool]) { $problems.Add('config.json: createRestorePoint должно быть true или false') }
    return $problems
}

function Get-NovaContext {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$TweaksPath)
    $script:NovaRoot = Split-Path -Parent (Split-Path -Parent (Resolve-Path -LiteralPath $TweaksPath).ProviderPath)
    $config = Read-NovaJson $ConfigPath
    $tweaksDoc = Read-NovaJson $TweaksPath
    $tweaks = @(Get-NovaProp $tweaksDoc 'tweaks' @())
    $problems = @(Test-NovaDefinition -Config $config -Tweaks $tweaks)
    $script:SystemInfo = Get-NovaSystemInfo
    return [pscustomobject]@{
        Config     = $config
        Tweaks     = $tweaks
        System     = $script:SystemInfo
        Problems   = $problems
        ConfigPath = $ConfigPath
    }
}

#endregion

#region План

function Get-NovaPlan {
    param([Parameter(Mandatory)]$Context)
    $build = $Context.System.Build
    $toggles = Get-NovaProp $Context.Config 'tweaks'
    foreach ($tweak in $Context.Tweaks) {
        $enabled = [bool](Get-NovaProp $toggles $tweak.id $false)
        $minBuild = [int](Get-NovaProp $tweak 'minBuild' 0)
        $maxBuild = [int](Get-NovaProp $tweak 'maxBuild' 0)
        $applicable = ($build -ge $minBuild) -and (($maxBuild -eq 0) -or ($build -le $maxBuild))
        $actions = @()
        if ($enabled -and $applicable) {
            $actions = @(foreach ($action in @($tweak.actions)) {
                    try {
                        $state = Get-NovaActionState $action
                    } catch {
                        $state = New-NovaState $false '' '' ("не удалось проверить: " + $_.Exception.Message)
                    }
                    [pscustomobject]@{ Action = $action; State = $state }
                })
        }
        $needsChange = @($actions | Where-Object { $_.State.NeedsChange }).Count -gt 0
        [pscustomobject]@{
            Id              = $tweak.id
            Title           = $tweak.title
            Category        = $tweak.category
            Enabled         = $enabled
            Applicable      = $applicable
            NeedsChange     = $needsChange
            RestartExplorer = [bool](Get-NovaProp $tweak 'restartExplorer' $false)
            Actions         = $actions
        }
    }
}

function Get-NovaEnabledNames {
    param($Section)
    if ($null -eq $Section) { return @() }
    return @($Section.PSObject.Properties | Where-Object { $_.Value -eq $true } | ForEach-Object { $_.Name })
}

function Get-NovaAppPlan {
    param([Parameter(Mandatory)]$Context)
    $toRemove = @(Get-NovaEnabledNames (Get-NovaProp $Context.Config 'removeApps'))
    $toInstall = @(Get-NovaEnabledNames (Get-NovaProp $Context.Config 'installApps'))

    $installed = @()
    $provisioned = @()
    if ($toRemove.Count -gt 0) {
        try { $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { Write-Nova "Не удалось получить список приложений: $($_.Exception.Message)" warn }
        try { $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { $provisioned = @() }
    }
    $removeItems = @(foreach ($name in $toRemove) {
            $packages = @($installed | Where-Object { $_.Name -like $name })
            $provisionedPackages = @($provisioned | Where-Object { $_.DisplayName -like $name })
            [pscustomobject]@{
                Name        = $name
                Packages    = $packages
                Provisioned = $provisionedPackages
                Present     = (($packages.Count + $provisionedPackages.Count) -gt 0)
            }
        })

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    $installItems = @(foreach ($id in $toInstall) {
            $isInstalled = $false
            if ($winget) {
                $result = Invoke-NovaNative 'winget.exe' @('list', '--id', $id, '--exact', '--accept-source-agreements')
                $isInstalled = ($result.Code -eq 0)
            }
            [pscustomobject]@{ Id = $id; Installed = $isInstalled }
        })

    return [pscustomobject]@{ Remove = $removeItems; Install = $installItems; WingetAvailable = [bool]$winget }
}

function Write-NovaPlanLine {
    param([string]$Mark, [string]$Title, [string]$Status, [string]$Color)
    $line = '  [{0}] {1}' -f $Mark, $Title
    Write-Host ($line.PadRight(60) + ' ') -ForegroundColor $Color -NoNewline
    Write-Host $Status -ForegroundColor $Color
}

# Печатает план на экран и возвращает, сколько всего будет изменено.
function Show-NovaPlan {
    param($Plan, $AppPlan, [switch]$Detailed)
    $tweakCount = 0
    foreach ($category in $script:Categories.Keys) {
        $items = @($Plan | Where-Object { $_.Category -eq $category })
        if ($items.Count -eq 0) { continue }
        Write-Host ''
        Write-Nova $script:Categories[$category] title
        foreach ($item in $items) {
            if (-not $item.Enabled) {
                Write-NovaPlanLine ' ' $item.Title 'выключено в config.json' 'DarkGray'
            } elseif (-not $item.Applicable) {
                Write-NovaPlanLine ' ' $item.Title 'не для этой версии Windows' 'DarkGray'
            } elseif ($item.NeedsChange) {
                $tweakCount++
                Write-NovaPlanLine '+' $item.Title 'будет изменено' 'Green'
                if ($Detailed) {
                    foreach ($entry in @($item.Actions | Where-Object { $_.State.NeedsChange })) {
                        Write-Host ('        {0}: {1} -> {2}' -f (Get-NovaActionLabel $entry.Action), $entry.State.Current, $entry.State.Target) -ForegroundColor DarkGray
                    }
                }
            } else {
                Write-NovaPlanLine '=' $item.Title 'уже настроено' 'Gray'
            }
            foreach ($entry in @($item.Actions | Where-Object { $_.State.Note })) {
                Write-Host ('        ({0})' -f $entry.State.Note) -ForegroundColor DarkYellow
            }
        }
    }

    $removeCount = 0
    $installCount = 0
    if ($null -ne $AppPlan -and @($AppPlan.Remove).Count -gt 0) {
        Write-Host ''
        Write-Nova 'ПРИЛОЖЕНИЯ: УДАЛИТЬ' title
        foreach ($app in $AppPlan.Remove) {
            if ($app.Present) {
                $removeCount++
                Write-NovaPlanLine '+' $app.Name 'будет удалено' 'Green'
            } else {
                Write-NovaPlanLine '=' $app.Name 'не установлено' 'Gray'
            }
        }
    }
    if ($null -ne $AppPlan -and @($AppPlan.Install).Count -gt 0) {
        Write-Host ''
        Write-Nova 'ПРОГРАММЫ: УСТАНОВИТЬ' title
        if (-not $AppPlan.WingetAvailable) {
            Write-Nova 'winget не найден — установка программ будет пропущена. Обнови «Установщик приложений» в Microsoft Store.' warn
        } else {
            foreach ($app in $AppPlan.Install) {
                if ($app.Installed) {
                    Write-NovaPlanLine '=' $app.Id 'уже установлено' 'Gray'
                } else {
                    $installCount++
                    Write-NovaPlanLine '+' $app.Id 'будет установлено' 'Green'
                }
            }
        }
    }

    Write-Host ''
    Write-Nova ('Итого: настроек — {0}, удалить приложений — {1}, установить программ — {2}' -f $tweakCount, $removeCount, $installCount) accent
    return [pscustomobject]@{
        Tweaks  = $tweakCount
        Remove  = $removeCount
        Install = $installCount
        Total   = ($tweakCount + $removeCount + $installCount)
    }
}

#endregion

#region Применение и отмена

function Save-NovaJournal {
    param([string]$Path, $Context, [System.Collections.ArrayList]$Journal, [bool]$RestartExplorer)
    $doc = [pscustomobject]@{
        tool            = 'Nova'
        version         = $script:NovaVersion
        created         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        computer        = $env:COMPUTERNAME
        user            = $env:USERNAME
        windows         = $Context.System
        restartExplorer = $RestartExplorer
        entries         = @($Journal)
    }
    $json = $doc | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Удаляет приложение из Store. Сначала у всех пользователей; если Windows не даёт
# (бывает, когда приложение числится за удалённым или системным профилем) — у текущего.
# Отдельно убирает его из образа, чтобы оно не появилось у новых пользователей.
function Remove-NovaApp {
    param([Parameter(Mandatory)]$App, [int]$Build)
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($package in $App.Packages) {
        $done = $false
        if ($Build -ge 17763) {
            try {
                Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                $done = $true
            } catch {
                $errors.Add($_.Exception.Message.Trim())
            }
        }
        if (-not $done) {
            try {
                Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
            } catch {
                $errors.Add($_.Exception.Message.Trim())
            }
        }
    }
    foreach ($package in $App.Provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
        } catch {
            $errors.Add($_.Exception.Message.Trim())
        }
    }

    # Главное — результат: у текущего пользователя приложения нет и в образе его нет.
    $removed = $true
    if ($errors.Count -gt 0) {
        $leftForUser = @(Get-AppxPackage -Name $App.Name -ErrorAction SilentlyContinue)
        $leftProvisioned = @()
        try {
            $leftProvisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -like $App.Name })
        } catch {
            $errors.Add($_.Exception.Message.Trim())
        }
        $removed = ($leftForUser.Count -eq 0) -and ($leftProvisioned.Count -eq 0)
    }
    return [pscustomobject]@{ Removed = $removed; Errors = @($errors) }
}

function Invoke-NovaApply {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Plan, $AppPlan)
    $backupPath = Join-Path (Get-NovaDataDir) ('backups\backup-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $journal = New-Object System.Collections.ArrayList
    $result = [pscustomobject]@{ Applied = 0; Failed = 0; AppsRemoved = 0; AppsInstalled = 0; RestartExplorer = $false; BackupPath = $null }

    Write-Host ''
    Write-Nova 'Применяю настройки...' title
    foreach ($item in @($Plan | Where-Object { $_.Enabled -and $_.Applicable -and $_.NeedsChange })) {
        $failed = $false
        foreach ($entry in @($item.Actions | Where-Object { $_.State.NeedsChange })) {
            try {
                Invoke-NovaAction -Action $entry.Action -Journal $journal -Tweak $item.Id
            } catch {
                $failed = $true
                Write-Nova ('{0}: {1}' -f $item.Title, $_.Exception.Message) err
            }
        }
        if ($item.RestartExplorer) { $result.RestartExplorer = $true }
        Save-NovaJournal -Path $backupPath -Context $Context -Journal $journal -RestartExplorer $result.RestartExplorer
        if ($failed) { $result.Failed++ } else { $result.Applied++; Write-Nova $item.Title ok }
    }

    if ($null -ne $AppPlan) {
        foreach ($app in @($AppPlan.Remove | Where-Object { $_.Present })) {
            $removal = Remove-NovaApp -App $app -Build $Context.System.Build
            if ($removal.Removed) {
                [void]$journal.Add([pscustomobject]@{ type = 'appRemoved'; name = $app.Name })
                $result.AppsRemoved++
                Write-Nova ('удалено: {0}' -f $app.Name) ok
            } else {
                $result.Failed++
                Write-Nova ('не удалось удалить {0}: {1}' -f $app.Name, ($removal.Errors -join ' / ')) err
            }
        }
        if ($AppPlan.WingetAvailable) {
            foreach ($app in @($AppPlan.Install | Where-Object { -not $_.Installed })) {
                Write-Nova ('устанавливаю {0}...' -f $app.Id) info
                $run = Invoke-NovaNative 'winget.exe' @('install', '--id', $app.Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Stream
                if ($run.Code -eq 0) {
                    [void]$journal.Add([pscustomobject]@{ type = 'appInstalled'; name = $app.Id })
                    $result.AppsInstalled++
                    Write-Nova ('установлено: {0}' -f $app.Id) ok
                } else {
                    $result.Failed++
                    Write-Nova ('не удалось установить {0} (код {1})' -f $app.Id, $run.Code) err
                }
            }
        }
    }

    if ($journal.Count -gt 0) {
        Save-NovaJournal -Path $backupPath -Context $Context -Journal $journal -RestartExplorer $result.RestartExplorer
        $result.BackupPath = $backupPath
    } elseif (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force
    }
    return $result
}

#region Замер «было → стало»

# Сколько всего работает в Windows прямо сейчас.
function Get-NovaMeasurement {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $running = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }).Count
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' }).Count
    $startup = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue).Count
    $apps = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework }).Count
    return [pscustomobject]@{
        time          = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        uptimeMinutes = [int][math]::Round(((Get-Date) - $os.LastBootUpTime).TotalMinutes)
        processes     = @(Get-Process).Count
        services      = $running
        tasks         = $tasks
        memoryMB      = [int][math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)
        totalMB       = [int][math]::Round($os.TotalVisibleMemorySize / 1024)
        startup       = $startup
        apps          = $apps
    }
}

function Get-NovaMeasureFile { return (Join-Path (Get-NovaDataDir) 'measure.json') }

function Read-NovaMeasureData {
    $file = Get-NovaMeasureFile
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return (Read-NovaJson $file)
}

function Save-NovaMeasurement {
    param([Parameter(Mandatory)][ValidateSet('before', 'after')][string]$Label)
    $data = Read-NovaMeasureData
    if ($null -eq $data) { $data = [pscustomobject]@{ before = $null; after = $null } }
    $measurement = Get-NovaMeasurement
    $data.$Label = $measurement
    if ($Label -eq 'before') { $data.after = $null }
    $json = $data | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Get-NovaMeasureFile), $json, (New-Object System.Text.UTF8Encoding($false)))
    return $measurement
}

function Clear-NovaMeasurement {
    $file = Get-NovaMeasureFile
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

# Таблица «было → стало». Зелёным — где стало меньше.
function Show-NovaMeasurement {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $rows = @(
        @('Процессов запущено', 'processes', ''),
        @('Служб работает', 'services', ''),
        @('Задач по расписанию включено', 'tasks', ''),
        @('Занято оперативной памяти', 'memoryMB', ' МБ'),
        @('Программ в автозагрузке', 'startup', ''),
        @('Приложений из Store', 'apps', '')
    )
    Write-Host ''
    Write-Host ('  {0}{1}{2}{3}' -f 'ПАРАМЕТР'.PadRight(34), 'ДО'.PadLeft(10), 'ПОСЛЕ'.PadLeft(10), 'РАЗНИЦА'.PadLeft(12)) -ForegroundColor Cyan
    foreach ($row in $rows) {
        $b = [int](Get-NovaProp $Before $row[1] 0)
        $a = [int](Get-NovaProp $After $row[1] 0)
        $diff = $a - $b
        $color = 'Gray'
        if ($diff -lt 0) { $color = 'Green' } elseif ($diff -gt 0) { $color = 'Yellow' }
        $diffText = '{0:+#;-#;0}{1}' -f $diff, $row[2]
        Write-Host ('  {0}{1}{2}{3}' -f $row[0].PadRight(34), ('{0}{1}' -f $b, $row[2]).PadLeft(10), ('{0}{1}' -f $a, $row[2]).PadLeft(10), $diffText.PadLeft(12)) -ForegroundColor $color
    }
    Write-Host ''
    Write-Nova ('Замер «до»: {0} (после включения прошло {1} мин), «после»: {2} (прошло {3} мин).' -f $Before.time, $Before.uptimeMinutes, $After.time, $After.uptimeMinutes) dim
    Write-Nova 'Память и процессы сильно зависят от того, что открыто. Честнее всего сравнивать сразу после включения, когда ничего не запущено.' dim
}

#endregion

# Резервные копии, которые ещё не отменяли (новые — первыми).
function Get-NovaBackup {
    $dir = Join-Path (Get-NovaDataDir) 'backups'
    return @(Get-ChildItem -LiteralPath $dir -Filter 'backup-*.json' |
            Where-Object { $_.Name -notlike '*.restored.json' } |
            Sort-Object Name -Descending)
}

function Invoke-NovaUndo {
    param([Parameter(Mandatory)][string]$BackupPath)
    $doc = Read-NovaJson $BackupPath
    $entries = @(Get-NovaProp $doc 'entries' @())
    $failed = 0
    # Идём с конца: последнее изменение отменяем первым.
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        try {
            Undo-NovaEntry $entries[$i]
        } catch {
            $failed++
            Write-Nova ('не удалось вернуть {0}: {1}' -f $entries[$i].type, $_.Exception.Message) err
        }
    }
    $removedApps = @($entries | Where-Object { $_.type -eq 'appRemoved' } | ForEach-Object { $_.name })
    $installedApps = @($entries | Where-Object { $_.type -eq 'appInstalled' } | ForEach-Object { $_.name })
    $restoredPath = $BackupPath -replace '\.json$', '.restored.json'
    Move-Item -LiteralPath $BackupPath -Destination $restoredPath -Force
    return [pscustomobject]@{
        Restored        = ($entries.Count - $failed)
        Failed          = $failed
        RestartExplorer = [bool](Get-NovaProp $doc 'restartExplorer' $false)
        RemovedApps     = $removedApps
        InstalledApps   = $installedApps
    }
}

# Перезапускает Проводник, чтобы изменения панели задач и меню применились сразу.
function Restart-NovaExplorer {
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { return }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

# Точка восстановления Windows — запасной вариант, если что-то пойдёт совсем не так.
function New-NovaRestorePoint {
    $frequencyPath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $frequencyName = 'SystemRestorePointCreationFrequency'
    $before = Get-NovaRegValue -Path $frequencyPath -Name $frequencyName
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        # Windows разрешает одну точку в сутки — на время создания снимаем это ограничение.
        Set-NovaRegValue -Path $frequencyPath -Name $frequencyName -Value 0 -Kind 'DWord'
        Checkpoint-Computer -Description 'Nova: перед изменениями' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        return $true
    } catch {
        Write-Nova ('Точку восстановления создать не удалось: {0}' -f $_.Exception.Message) warn
        return $false
    } finally {
        try {
            if ($before.Exists) {
                Set-NovaRegValue -Path $frequencyPath -Name $frequencyName -Value $before.Value -Kind $before.Kind
            } else {
                Remove-NovaRegValue -Path $frequencyPath -Name $frequencyName
            }
        } catch {
            Write-Nova 'Не удалось вернуть настройку частоты точек восстановления.' warn
        }
    }
}

#endregion

Export-ModuleMember -Function *
