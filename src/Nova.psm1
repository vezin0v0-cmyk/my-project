# Nova.psm1 — движок Nova.
# Читает настройки, показывает, что изменится, применяет изменения и умеет откатывать их назад.
# Работает в Windows PowerShell 5.1 — он встроен в любую Windows 10/11, ничего ставить не нужно.

$ErrorActionPreference = 'Stop'

$script:NovaVersion = '0.4.0'
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
    Protect-NovaDataDir $dir
    foreach ($sub in @('backups', 'logs')) {
        $path = Join-Path $dir $sub
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    return $dir
}

# В C:\ProgramData любой пользователь может создавать папки. Nova выполняет оттуда резервные копии
# и программы с правами администратора, поэтому папка должна принадлежать администраторам,
# а менять её могут только они и система. Читать — все (обои и логотип видит обычный пользователь).
$script:DataDirProtected = $false
$script:WriteRights = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'

# Кому можно доверять запись: администраторы, система, TrustedInstaller и тот, кто сейчас запустил Nova.
function Get-NovaTrustedSid {
    return @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
}

function New-NovaDataDirSecurity {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagate = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($pair in @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-18', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($pair[0])
        $rights = [System.Security.AccessControl.FileSystemRights]$pair[1]
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $rights, $inherit, $propagate, 'Allow')))
    }
    return $acl
}

# Причина, по которой путь небезопасен, или пустая строка. Смотрит владельца и всех, кто может писать.
function Get-NovaPathProblem {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Trusted)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($Trusted -notcontains $owner) { return ('{0}: владелец {1}' -f $Path, $acl.Owner) }
        foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            if (($rule.FileSystemRights -band $script:WriteRights) -eq 0) { continue }
            # CREATOR OWNER касается только новых файлов, а их владелец проверяется отдельно.
            if ($rule.IdentityReference.Value -eq 'S-1-3-0') { continue }
            if ($Trusted -notcontains $rule.IdentityReference.Value) { return ('{0}: менять может {1}' -f $Path, $rule.IdentityReference.Value) }
        }
    } catch {
        return ('{0}: не удалось проверить права ({1})' -f $Path, $_.Exception.Message)
    }
    return ''
}

function Get-NovaTreeProblem {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Trusted)
    $problem = Get-NovaPathProblem -Path $Path -Trusted $Trusted
    if ($problem) { return $problem }
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)) {
        $problem = Get-NovaPathProblem -Path $item.FullName -Trusted $Trusted
        if ($problem) { return $problem }
    }
    return ''
}

function Protect-NovaDataDir {
    param([Parameter(Mandatory)][string]$Path)
    if ($script:DataDirProtected -or -not (Test-NovaAdmin)) { return }
    $trusted = Get-NovaTrustedSid
    if (-not (Test-Path -LiteralPath $Path)) {
        # Папка сразу создаётся закрытой — нет момента, когда в неё можно что-то подложить.
        [void][System.IO.Directory]::CreateDirectory($Path, (New-NovaDataDirSecurity))
    } else {
        try { [System.IO.Directory]::SetAccessControl($Path, (New-NovaDataDirSecurity)) } catch { Write-Verbose 'Права не поменялись — проверим ниже.' }
        $problem = Get-NovaTreeProblem -Path $Path -Trusted $trusted
        if ($problem) {
            # Папку создал или изменил кто-то другой. Ничему из неё не доверяем: откладываем и начинаем с чистой.
            $aside = '{0}.untrusted-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -LiteralPath $Path -Destination $aside -Force
            Write-Nova ('Папку {0} создал или изменил не Nova ({1}). Отложила её в {2} и создала новую.' -f $Path, $problem, $aside) warn
            [void][System.IO.Directory]::CreateDirectory($Path, (New-NovaDataDirSecurity))
        }
    }
    $problem = Get-NovaTreeProblem -Path $Path -Trusted $trusted
    if ($problem) { throw ('Папка {0} небезопасна: {1}. Nova остановилась, чтобы через неё нельзя было взломать компьютер.' -f $Path, $problem) }
    $script:DataDirProtected = $true
}

# Папку самой Nova (где Nova.cmd и src) не должны менять другие пользователи: Nova запускается
# с правами администратора и выполняет эти файлы. Например, C:\Nova наследует от диска C:
# право «изменение» для всех пользователей, а флешка FAT/exFAT прав не хранит вовсе.
function Get-NovaProjectProblem {
    param([Parameter(Mandatory)][string]$Root)
    $trusted = Get-NovaTrustedSid
    $paths = @($Root, (Join-Path $Root 'src'), (Join-Path $Root 'config.json'), (Join-Path $Root 'Nova.cmd'))
    $paths += @(Get-ChildItem -LiteralPath (Join-Path $Root 'src') -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $problem = Get-NovaPathProblem -Path $path -Trusted $trusted
        if ($problem) { return $problem }
    }
    return ''
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

# Системные программы — только из System32, а не «первая найденная по PATH».
function Get-NovaSystemTool {
    param([Parameter(Mandatory)][string]$Name)
    return (Join-Path (Join-Path $env:SystemRoot 'System32') $Name)
}

# winget — только настоящий, из защищённой папки пакета «Установщик приложений».
# Ярлык в %LOCALAPPDATA%\Microsoft\WindowsApps может подменить любая программа пользователя.
function Get-NovaWingetPath {
    try {
        $package = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
    } catch {
        return $null
    }
    if ($null -eq $package -or -not $package.InstallLocation) { return $null }
    $exe = Join-Path $package.InstallLocation 'winget.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    if ($exe -notlike (Join-Path $env:ProgramFiles 'WindowsApps\*')) { return $null }
    return $exe
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

# Удаляет раздел, который создала Nova, но только если в нём не осталось значений.
# Если туда успела что-то записать другая программа, раздел остаётся. Возвращает $true, если удалён.
function Remove-NovaRegKeyIfEmpty {
    param([Parameter(Mandatory)][string]$Path)
    $rp = Split-NovaRegPath $Path
    $base = Open-NovaBaseKey $rp.Hive
    try { return (Remove-NovaEmptySubKey -Parent $base -SubKey $rp.SubKey) } finally { $base.Close() }
}

function Remove-NovaEmptySubKey {
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Parent, [Parameter(Mandatory)][string]$SubKey)
    $key = $Parent.OpenSubKey($SubKey, $true)
    if ($null -eq $key) { return $true }
    $empty = $true
    try {
        foreach ($child in @($key.GetSubKeyNames())) {
            if (-not (Remove-NovaEmptySubKey -Parent $key -SubKey $child)) { $empty = $false }
        }
        if ($key.ValueCount -gt 0) { $empty = $false }
    } finally {
        $key.Close()
    }
    if ($empty) { $Parent.DeleteSubKey($SubKey, $false) }
    return $empty
}

# Удаляет раздел, только если в нём нет ни значений, ни подразделов. $true — раздела больше нет.
function Remove-NovaRegKeyIfLeaf {
    param([Parameter(Mandatory)][string]$Path)
    $rp = Split-NovaRegPath $Path
    $base = Open-NovaBaseKey $rp.Hive
    try {
        $key = $base.OpenSubKey($rp.SubKey, $false)
        if ($null -eq $key) { return $true }
        try { $empty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) } finally { $key.Close() }
        if ($empty) { $base.DeleteSubKey($rp.SubKey, $false) }
        return $empty
    } finally {
        $base.Close()
    }
}

# Отмена «создала раздел»: идём от разделов из настроек Nova вверх до созданного и убираем пустые.
# Чужие разделы и значения не трогаем — даже если они лежат внутри созданного Nova.
function Remove-NovaCreatedKey {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Known)
    $top = Get-NovaRegPathKey $Path
    $chains = @($Known | Where-Object { $_ -eq $top -or $_.StartsWith($top + '\') } | Sort-Object -Unique | Sort-Object { $_.Length } -Descending)
    foreach ($chain in $chains) {
        $current = $chain
        while ($true) {
            if (-not (Remove-NovaRegKeyIfLeaf $current)) { break }
            if ($current -eq $top) { break }
            $current = $current.Substring(0, $current.LastIndexOf('\'))
        }
    }
    return -not (Get-NovaRegValue -Path $top -Name '__nova_probe__').KeyExists
}

# Путь реестра в одном виде: HKLM\путь в нижнем регистре — чтобы сравнивать.
function Get-NovaRegPathKey {
    param([string]$Path)
    $rp = Split-NovaRegPath $Path
    return ('{0}\{1}' -f $rp.HiveName, $rp.SubKey).ToLowerInvariant()
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

# «Автоматически (отложенный запуск)» Windows PowerShell показывает просто как Automatic — смотрим в реестре.
function Get-NovaServiceDelayed {
    param([string]$Name)
    $value = Get-NovaRegValue -Path ('HKLM\SYSTEM\CurrentControlSet\Services\{0}' -f $Name) -Name 'DelayedAutostart'
    return ($value.Exists -and [int]$value.Value -eq 1)
}

function Get-NovaActivePowerScheme {
    $result = Invoke-NovaNative (Get-NovaSystemTool 'powercfg.exe') @('/getactivescheme')
    if ($result.Output -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
        return $Matches[0].ToLowerInvariant()
    }
    return $null
}

function Test-NovaPowerSchemeExists {
    param([string]$Guid)
    $result = Invoke-NovaNative (Get-NovaSystemTool 'powercfg.exe') @('/list')
    return ($result.Output -match [regex]::Escape($Guid))
}

function Get-NovaHibernateState {
    $state = Get-NovaRegValue -Path 'HKLM\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
    if ($state.Exists -and [int]$state.Value -ne 0) { return 'on' }
    return 'off'
}

#endregion

#region OneDrive

# Где OneDrive и вошёл ли в него пользователь. Удаляем, только если не вошёл — чтобы не потерять файлы.
function Get-NovaOneDriveInfo {
    $uninstall = $null
    foreach ($root in @('HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
            'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe')) {
        $state = Get-NovaRegValue -Path $root -Name 'UninstallString'
        if ($state.Exists -and $state.Value) { $uninstall = [string]$state.Value; break }
    }
    $signedIn = $false
    $accounts = Get-NovaRegValue -Path 'HKCU\Software\Microsoft\OneDrive\Accounts\Personal' -Name 'UserEmail'
    if ($accounts.Exists -and $accounts.Value) { $signedIn = $true }
    if (-not $signedIn) {
        $base = Open-NovaBaseKey ([Microsoft.Win32.RegistryHive]::CurrentUser)
        try {
            $key = $base.OpenSubKey('Software\Microsoft\OneDrive\Accounts', $false)
            if ($null -ne $key) {
                try {
                    foreach ($name in $key.GetSubKeyNames()) {
                        if ($name -like 'Business*') {
                            $email = Get-NovaRegValue -Path ("HKCU\Software\Microsoft\OneDrive\Accounts\$name") -Name 'UserEmail'
                            if ($email.Exists -and $email.Value) { $signedIn = $true }
                        }
                    }
                } finally { $key.Close() }
            }
        } finally { $base.Close() }
    }
    return [pscustomobject]@{ Installed = [bool]$uninstall; Uninstall = $uninstall; SignedIn = $signedIn }
}

function Remove-NovaOneDrive {
    param([Parameter(Mandatory)][string]$UninstallString)
    if ($UninstallString -match '^\s*"([^"]+)"\s*(.*)$') {
        $exe = $Matches[1]; $arguments = $Matches[2]
    } else {
        $index = $UninstallString.IndexOf(' /')
        if ($index -lt 0) { $exe = $UninstallString.Trim(); $arguments = '/uninstall' } else { $exe = $UninstallString.Substring(0, $index).Trim(); $arguments = $UninstallString.Substring($index + 1) }
    }
    if (-not (Test-Path -LiteralPath $exe)) { throw "Не найден установщик OneDrive: $exe" }
    # Установщик лежит в папке пользователя, и Nova запустит его с правами администратора.
    # Поэтому копируем его в защищённую папку Nova и запускаем копию, только если её подписала Microsoft.
    $tools = Join-Path (Get-NovaDataDir) 'tools'
    if (-not (Test-Path -LiteralPath $tools)) { New-Item -ItemType Directory -Path $tools -Force | Out-Null }
    $copy = Join-Path $tools 'OneDriveSetup.exe'
    Copy-Item -LiteralPath $exe -Destination $copy -Force
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $copy
        if ($signature.Status -ne 'Valid' -or [string]$signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw 'установщик OneDrive не подписан Microsoft — не запускаю его'
        }
        Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $process = Start-Process -FilePath $copy -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 0) { throw "Удаление OneDrive завершилось с кодом $($process.ExitCode)" }
    } finally {
        Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
    }
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
        'oneDrive' { return 'OneDrive' }
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
        'oneDrive' {
            $info = Get-NovaOneDriveInfo
            if (-not $info.Installed) { return New-NovaState $false 'не установлен' 'удалён' '' }
            if ($info.SignedIn) { return New-NovaState $false 'установлен' 'удалён' 'ты вошёл в OneDrive — не трогаем, чтобы не потерять файлы' }
            return New-NovaState $true 'установлен' 'удалён' ''
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
        'oneDrive' {
            $info = Get-NovaOneDriveInfo
            if (-not $info.Installed -or $info.SignedIn) { return }
            Remove-NovaOneDrive -UninstallString $info.Uninstall
            # Как и приложения из Store: при отмене подскажем, откуда поставить заново.
            [void]$Journal.Add([pscustomobject]@{ type = 'appRemoved'; tweak = $Tweak; name = 'OneDrive' })
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
            [void]$Journal.Add([pscustomobject]@{ type = 'service'; tweak = $Tweak; name = $Action.name; startup = $before; delayed = (Get-NovaServiceDelayed $Action.name) })
            Set-Service -Name $Action.name -StartupType $Action.startup
            if ($Action.startup -eq 'Disabled') { Stop-Service -Name $Action.name -Force -ErrorAction SilentlyContinue }
            return
        }
        'powerScheme' {
            $before = Get-NovaActivePowerScheme
            if ($before) { [void]$Journal.Add([pscustomobject]@{ type = 'powerScheme'; tweak = $Tweak; guid = $before }) }
            $result = Invoke-NovaNative (Get-NovaSystemTool 'powercfg.exe') @('/setactive', [string]$Action.guid)
            if ($result.Code -ne 0) { throw "powercfg не смог сменить схему питания: $($result.Output.Trim())" }
            return
        }
        'hibernate' {
            $before = Get-NovaHibernateState
            [void]$Journal.Add([pscustomobject]@{ type = 'hibernate'; tweak = $Tweak; state = $before })
            $result = Invoke-NovaNative (Get-NovaSystemTool 'powercfg.exe') @('/hibernate', [string]$Action.state)
            if ($result.Code -ne 0) { throw "powercfg не смог изменить гибернацию: $($result.Output.Trim())" }
            return
        }
    }
    throw "Неизвестный тип действия: $($Action.type)"
}

# Возвращает одну запись журнала в исходное состояние.
function Undo-NovaEntry {
    param($Entry, $Allowed)
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
            $known = @()
            if ($Allowed) { $known = @($Allowed.keys) } else { $known = @(Get-NovaRegPathKey $Entry.path) }
            if (-not (Remove-NovaCreatedKey -Path $Entry.path -Known $known)) {
                Write-Nova ('раздел {0} оставлен: в нём есть настройки других программ' -f $Entry.path) dim
            }
            return
        }
        'service' {
            if ($script:ServiceStartups -contains $Entry.startup) {
                Set-Service -Name $Entry.name -StartupType $Entry.startup
                if ($Entry.startup -eq 'Automatic' -and [bool](Get-NovaProp $Entry 'delayed' $false) -and -not (Get-NovaServiceDelayed $Entry.name)) {
                    $result = Invoke-NovaNative (Get-NovaSystemTool 'sc.exe') @('config', [string]$Entry.name, 'start=', 'delayed-auto')
                    if ($result.Code -ne 0) { throw "не удалось вернуть отложенный запуск службы $($Entry.name)" }
                }
                if ($Entry.startup -eq 'Automatic') { Start-Service -Name $Entry.name -ErrorAction SilentlyContinue }
            }
            return
        }
        'powerScheme' {
            $result = Invoke-NovaNative (Get-NovaSystemTool 'powercfg.exe') @('/setactive', [string]$Entry.guid)
            if ($result.Code -ne 0) { throw "powercfg не смог вернуть схему питания: $($result.Output.Trim())" }
            return
        }
        'hibernate' {
            $result = Invoke-NovaNative (Get-NovaSystemTool 'powercfg.exe') @('/hibernate', [string]$Entry.state)
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

# Защиту Windows Nova не трогает никогда: антивирус, брандмауэр, контроль учётных записей,
# SmartScreen, обновления и центр безопасности. Если такое окажется в tweaks.json (по ошибке или
# если файл подменили), Nova откажется работать. Единственное исключение — «Целостность памяти»:
# её пользователь выключает сам отдельным пунктом с предупреждением.
$script:ProtectedRegistry = @('windows defender', 'microsoft antimalware', 'windowsfirewall', 'firewallpolicy', 'smartscreen',
    'policies\system|enablelua', 'policies\system|consentpromptbehavioradmin', 'policies\system|promptonsecuredesktop',
    '|noautoupdate', '|disablewindowsupdateaccess', '|setdisableuxwuaccess', '|donotconnecttowindowsupdateinternetlocations',
    'deviceguard', 'control\lsa|', 'securityhealth', 'windows security', 'memory management|featuresettingsoverride')
$script:ProtectedServices = @('windefend', 'wdnissvc', 'sense', 'mpssvc', 'bfe', 'wuauserv', 'waasmedicsvc', 'usosvc', 'securityhealthservice',
    'wscsvc', 'sgrmbroker', 'cryptsvc', 'trustedinstaller', 'bits', 'appidsvc', 'eventlog')
$script:ProtectedTasks = @('\microsoft\windows\windows defender\', '\microsoft\windows\updateorchestrator\', '\microsoft\windows\windowsupdate\',
    '\microsoft\windows\waasmedic\')
$script:SecurityExceptions = @('memory-integrity-off')

# Причина, по которой действие трогает защиту Windows, или пустая строка.
function Get-NovaProtectedReason {
    param($Action)
    $type = [string](Get-NovaProp $Action 'type')
    if ($type -eq 'registry') {
        $target = ('{0}|{1}' -f (Get-NovaProp $Action 'path'), (Get-NovaProp $Action 'name')).ToLowerInvariant()
        foreach ($pattern in $script:ProtectedRegistry) { if ($target.Contains($pattern)) { return 'реестр защиты Windows' } }
    } elseif ($type -eq 'service') {
        if ($script:ProtectedServices -contains ([string](Get-NovaProp $Action 'name')).ToLowerInvariant()) { return 'служба защиты или обновлений Windows' }
    } elseif ($type -eq 'scheduledTask') {
        $path = ([string](Get-NovaProp $Action 'path')).ToLowerInvariant()
        foreach ($prefix in $script:ProtectedTasks) { if ($path.StartsWith($prefix)) { return 'задача защиты или обновлений Windows' } }
    }
    return ''
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
            $protected = Get-NovaProtectedReason $action
            if ($protected -and $script:SecurityExceptions -notcontains $id) { $problems.Add("tweaks.json: '$id' трогает защиту Windows ($protected) — Nova так не делает") }
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
            } elseif ($type -eq 'oneDrive') {
                Write-Verbose 'Для OneDrive параметры не нужны.'
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

    $winget = Get-NovaWingetPath
    $installItems = @(foreach ($id in $toInstall) {
            $isInstalled = $false
            if ($winget) {
                $result = Invoke-NovaNative $winget @('list', '--id', $id, '--exact', '--accept-source-agreements')
                $isInstalled = ($result.Code -eq 0)
            }
            [pscustomobject]@{ Id = $id; Installed = $isInstalled }
        })

    return [pscustomobject]@{ Remove = $removeItems; Install = $installItems; WingetAvailable = [bool]$winget; Winget = $winget }
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
            # Сохраняем после каждого действия: если окно закроют посередине, отменить можно будет всё сделанное.
            if ($journal.Count -gt 0) { Save-NovaJournal -Path $backupPath -Context $Context -Journal $journal -RestartExplorer $result.RestartExplorer }
        }
        if ($item.RestartExplorer) { $result.RestartExplorer = $true }
        if ($journal.Count -gt 0) { Save-NovaJournal -Path $backupPath -Context $Context -Journal $journal -RestartExplorer $result.RestartExplorer }
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
                $run = Invoke-NovaNative $AppPlan.Winget @('install', '--id', $app.Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Stream
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

# Что вообще может менять Nova: всё из tweaks.json плюс обои. Отмена трогает только это,
# поэтому даже подменённый файл резервной копии не заставит Nova изменить что-то постороннее.
function Get-NovaAllowedTargets {
    param($Tweaks)
    $allowed = @{ registry = @{}; keys = New-Object System.Collections.Generic.List[string]; service = @{}; task = @{}; file = @{} }
    foreach ($tweak in @($Tweaks)) {
        foreach ($action in @($tweak.actions)) {
            switch ($action.type) {
                'registry' {
                    $key = Get-NovaRegPathKey $action.path
                    $allowed.registry[('{0}|{1}' -f $key, $action.name).ToLowerInvariant()] = $true
                    $allowed.keys.Add($key)
                }
                'service' { $allowed.service[([string]$action.name).ToLowerInvariant()] = $true }
                'scheduledTask' { $allowed.task[('{0}{1}' -f $action.path, $action.name).ToLowerInvariant()] = $true }
                'copyFile' { $allowed.file[[System.IO.Path]::GetFullPath((Expand-NovaText $action.to)).ToLowerInvariant()] = $true }
            }
        }
    }
    $allowed.wallpaper = @{}
    foreach ($tweak in @($Tweaks)) {
        foreach ($action in @($tweak.actions | Where-Object { $_.type -eq 'wallpaper' })) {
            $allowed.wallpaper[[System.IO.Path]::GetFullPath((Get-NovaWallpaperTarget $action)).ToLowerInvariant()] = $true
        }
    }
    $desktop = Get-NovaRegPathKey $script:DesktopKey
    foreach ($name in @('WallpaperStyle', 'TileWallpaper')) { $allowed.registry[('{0}|{1}' -f $desktop, $name).ToLowerInvariant()] = $true }
    return $allowed
}

# Возвращает причину, по которой запись нельзя выполнять, или пустую строку, если всё в порядке.
function Test-NovaJournalEntry {
    param($Entry, $Allowed)
    try {
        switch ([string]$Entry.type) {
            'registry' {
                $id = ('{0}|{1}' -f (Get-NovaRegPathKey $Entry.path), $Entry.name).ToLowerInvariant()
                if (-not $Allowed.registry.ContainsKey($id)) { return 'этого значения нет в настройках Nova' }
                if ($Entry.existed -and $script:RegistryKinds -notcontains [string]$Entry.kind) { return 'неизвестный тип значения' }
                return ''
            }
            'keyCreated' {
                $key = Get-NovaRegPathKey $Entry.path
                if (@($key.Split('\')).Count -lt 3) { return 'слишком общий раздел реестра' }
                foreach ($known in $Allowed.keys) { if ($known -eq $key -or $known.StartsWith($key + '\')) { return '' } }
                return 'этого раздела нет в настройках Nova'
            }
            'service' {
                if (-not $Allowed.service.ContainsKey(([string]$Entry.name).ToLowerInvariant())) { return 'этой службы нет в настройках Nova' }
                return ''
            }
            'scheduledTask' {
                if (-not $Allowed.task.ContainsKey(('{0}{1}' -f $Entry.path, $Entry.name).ToLowerInvariant())) { return 'этой задачи нет в настройках Nova' }
                return ''
            }
            'copyFile' {
                # GetFullPath убирает трюки вроде «папка\..\..\Windows».
                $path = [System.IO.Path]::GetFullPath([string]$Entry.path).ToLowerInvariant()
                if (-not $Allowed.file.ContainsKey($path)) { return 'этого файла нет в настройках Nova' }
                if ($Entry.backup -and [System.IO.Path]::GetFullPath([string]$Entry.backup).ToLowerInvariant() -ne ($path + '.nova-backup')) { return 'неожиданная копия файла' }
                return ''
            }
            'wallpaper' {
                if ($Entry.installed -and -not $Allowed.wallpaper.ContainsKey([System.IO.Path]::GetFullPath([string]$Entry.installed).ToLowerInvariant())) { return 'обои Nova лежат не там, куда их кладёт Nova' }
                return ''
            }
            'powerScheme' {
                if ([string]$Entry.guid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return 'неверная схема питания' }
                return ''
            }
            'hibernate' {
                if (@('on', 'off') -notcontains [string]$Entry.state) { return 'неверное состояние гибернации' }
                return ''
            }
            'appRemoved' { return '' }
            'appInstalled' { return '' }
        }
    } catch {
        return ('не удалось проверить запись: {0}' -f $_.Exception.Message)
    }
    return 'неизвестный тип записи'
}

function Invoke-NovaUndo {
    param([Parameter(Mandatory)][string]$BackupPath, $Tweaks)
    if ($null -eq $Tweaks) {
        $Tweaks = @(Get-NovaProp (Read-NovaJson (Join-Path $script:NovaRoot 'src\tweaks.json')) 'tweaks' @())
    }
    $allowed = Get-NovaAllowedTargets $Tweaks
    $doc = Read-NovaJson $BackupPath
    $entries = @(Get-NovaProp $doc 'entries' @())
    $failed = 0
    # Идём с конца: последнее изменение отменяем первым.
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $problem = Test-NovaJournalEntry -Entry $entries[$i] -Allowed $allowed
        if ($problem) {
            $failed++
            Write-Nova ('пропускаю запись {0}: {1}' -f $entries[$i].type, $problem) err
            continue
        }
        try {
            Undo-NovaEntry -Entry $entries[$i] -Allowed $allowed
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
    # Windows сама перезапускает Проводник. Ждём до 10 секунд.
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { return }
    }
    # Если не перезапустила — запускаем с правами обычного пользователя, а не администратора:
    # иначе весь рабочий стол и всё, что из него открывают, получили бы права администратора.
    & (Get-NovaSystemTool 'runas.exe') /trustlevel:0x20000 explorer.exe | Out-Null
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

#region Замер FPS

# PresentMon — бесплатная программа Intel с открытым кодом (github.com/GameTechDev/PresentMon).
# Ею меряют FPS в обзорах видеокарт. Версия и контрольная сумма закреплены здесь:
# скачанный файл должен совпасть байт в байт, иначе Nova его удалит и не запустит.
$script:PresentMon = @{
    Version = '2.6.0'
    Url     = 'https://github.com/GameTechDev/PresentMon/releases/download/v2.6.0/PresentMon-2.6.0-x64.exe'
    Sha256  = 'B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF'
}

# Программы, которые рисуют кадры, но игрой не являются.
$script:FpsIgnore = @('dwm.exe', 'explorer.exe', 'shellexperiencehost.exe', 'startmenuexperiencehost.exe', 'searchhost.exe',
    'searchapp.exe', 'textinputhost.exe', 'lockapp.exe', 'applicationframehost.exe', 'powershell.exe', 'pwsh.exe', 'conhost.exe',
    'windowsterminal.exe', 'openconsole.exe', 'msedgewebview2.exe', 'steamwebhelper.exe', 'nvidia overlay.exe', 'nvcontainer.exe',
    'gamebar.exe', 'gamebarftserver.exe', 'widgets.exe', 'phoneexperiencehost.exe', 'presentmon-2.6.0-x64.exe', '<error>', '')

function Get-NovaPresentMonPath {
    return (Join-Path (Get-NovaDataDir) ('tools\PresentMon-{0}-x64.exe' -f $script:PresentMon.Version))
}

function Test-NovaPresentMon {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $script:PresentMon.Sha256)
}

function Install-NovaPresentMon {
    $path = Get-NovaPresentMonPath
    if (Test-NovaPresentMon $path) { return $path }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $temp = $path + '.download'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $progress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $script:PresentMon.Url -OutFile $temp -UseBasicParsing
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw ('Не удалось скачать PresentMon: {0}. Проверь интернет.' -f $_.Exception.Message)
    } finally {
        $ProgressPreference = $progress
    }
    if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ne $script:PresentMon.Sha256) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw 'Скачанный PresentMon не совпал с оригиналом (контрольная сумма). Файл удалён, ничего не запущено.'
    }
    Move-Item -LiteralPath $temp -Destination $path -Force
    return $path
}

# Записывает кадры всех программ и возвращает путь к CSV.
function Invoke-NovaFpsCapture {
    param([int]$Seconds = 60, [int]$Delay = 10)
    $exe = Install-NovaPresentMon
    $dir = Join-Path (Get-NovaDataDir) 'fps'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $csv = Join-Path $dir ('capture-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $arguments = @('--output_file', $csv, '--delay', [string]$Delay, '--timed', [string]$Seconds, '--terminate_after_timed',
        '--stop_existing_session', '--session_name', 'NovaFps', '--no_console_stats', '--v1_metrics')
    $run = Invoke-NovaNative $exe $arguments
    if (-not (Test-Path -LiteralPath $csv)) {
        throw ('PresentMon не записал ни одного кадра (код {0}). Игра точно была открыта во время замера?' -f $run.Code)
    }
    return $csv
}

# Время между кадрами (мс) для каждой программы из CSV PresentMon.
function Read-NovaFpsCsv {
    param([Parameter(Mandatory)][string]$Path)
    $byApp = @{}
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    foreach ($row in (Import-Csv -LiteralPath $Path)) {
        $raw = $row.MsBetweenPresents
        if ($null -eq $raw) { $raw = $row.FrameTime }
        $value = 0.0
        if (-not [double]::TryParse([string]$raw, [Globalization.NumberStyles]::Float, $invariant, [ref]$value)) { continue }
        $app = [string]$row.Application
        if (-not $byApp.ContainsKey($app)) { $byApp[$app] = New-Object System.Collections.Generic.List[double] }
        $byApp[$app].Add($value)
    }
    return $byApp
}

# Средний FPS, 1% low и 0.1% low по времени кадров.
# 1% low — FPS, медленнее которого был только 1% кадров: это и есть «фризы» и подлагивания.
function Get-NovaFpsStats {
    param([double[]]$FrameTimes)
    $valid = @($FrameTimes | Where-Object { $_ -gt 0 -and $_ -lt 1000 })
    if ($valid.Count -lt 30) { return $null }
    $sum = 0.0
    foreach ($t in $valid) { $sum += $t }
    $sorted = [double[]]@($valid | Sort-Object)
    $at = {
        param([double]$Share)
        $index = [int][math]::Ceiling($Share * $sorted.Count) - 1
        $sorted[[math]::Max(0, [math]::Min($sorted.Count - 1, $index))]
    }
    return [pscustomobject]@{
        Frames  = $valid.Count
        Seconds = [math]::Round($sum / 1000, 1)
        Avg     = [math]::Round(1000.0 * $valid.Count / $sum, 1)
        Low1    = [math]::Round(1000.0 / (& $at 0.99), 1)
        Low01   = [math]::Round(1000.0 / (& $at 0.999), 1)
    }
}

# Какая программа — игра: больше всего кадров среди всего, что не системное.
function Select-NovaFpsGame {
    param($ByApp)
    $best = $null
    foreach ($app in $ByApp.Keys) {
        if ($script:FpsIgnore -contains $app.ToLowerInvariant()) { continue }
        if ($null -eq $best -or $ByApp[$app].Count -gt $ByApp[$best].Count) { $best = $app }
    }
    return $best
}

function Get-NovaFpsFile { return (Join-Path (Get-NovaDataDir) 'fps.json') }

function Read-NovaFpsRuns {
    $path = Get-NovaFpsFile
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-NovaProp (Read-NovaJson $path) 'runs' @())
}

function Save-NovaFpsRun {
    param([Parameter(Mandatory)]$Run)
    $runs = @(Read-NovaFpsRuns) + @($Run)
    $json = [pscustomobject]@{ runs = $runs } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Get-NovaFpsFile), $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Clear-NovaFpsRuns {
    $path = Get-NovaFpsFile
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

# Сравнение «до» и «после» для одной игры. Разницу считаем настоящей, только если она больше,
# чем разброс между замерами (и не меньше 3%): иначе это обычная случайность.
function Compare-NovaFps {
    param([object[]]$Before, [object[]]$After)
    $mean = {
        param($list, $name)
        $s = 0.0
        foreach ($r in $list) { $s += [double]$r.$name }
        $s / [math]::Max(1, @($list).Count)
    }
    $spread = {
        param($list, $name)
        if (@($list).Count -lt 2) { return 0.0 }
        $values = @($list | ForEach-Object { [double]$_.$name })
        $m = ($values | Measure-Object -Average).Average
        if ($m -le 0) { return 0.0 }
        (($values | Measure-Object -Maximum).Maximum - ($values | Measure-Object -Minimum).Minimum) / $m
    }
    $result = [ordered]@{}
    foreach ($metric in @('avg', 'low1', 'low01')) {
        $b = & $mean $Before $metric
        $a = & $mean $After $metric
        $floor = 0.03
        if ($metric -ne 'avg') { $floor = 0.05 }
        $noise = [math]::Max($floor, [math]::Max((& $spread $Before $metric), (& $spread $After $metric)))
        $change = 0.0
        if ($b -gt 0) { $change = ($a - $b) / $b }
        $verdict = 'same'
        if ($change -gt $noise) { $verdict = 'better' } elseif ($change -lt -$noise) { $verdict = 'worse' }
        $result[$metric] = [pscustomobject]@{ Before = [math]::Round($b, 1); After = [math]::Round($a, 1); Change = $change; Noise = $noise; Verdict = $verdict }
    }
    return [pscustomobject]$result
}

function Show-NovaFpsReport {
    param([string]$Game)
    $runs = @(Read-NovaFpsRuns | Where-Object { $_.game -eq $Game })
    $before = @($runs | Where-Object { $_.label -eq 'before' })
    $after = @($runs | Where-Object { $_.label -eq 'after' })
    Write-Host ''
    Write-Nova ('FPS: {0}' -f $Game) title
    if ($before.Count -eq 0 -or $after.Count -eq 0) {
        Write-Nova ('Замеров «до Nova»: {0}, «после Nova»: {1}. Для сравнения нужны оба.' -f $before.Count, $after.Count) info
        return
    }
    $cmp = Compare-NovaFps -Before $before -After $after
    Write-Host ('  {0,-14}{1,14}{2,14}{3,11}' -f '', ('до ({0})' -f $before.Count), ('после ({0})' -f $after.Count), 'разница')
    foreach ($row in @(@('avg', 'Средний FPS'), @('low1', '1% low'), @('low01', '0.1% low'))) {
        $m = $cmp.($row[0])
        $color = 'Gray'
        if ($m.Verdict -eq 'better') { $color = 'Green' } elseif ($m.Verdict -eq 'worse') { $color = 'Red' }
        Write-Host ('  {0,-14}{1,14}{2,14}{3,10:+0.0;-0.0;0.0}%' -f $row[1], $m.Before, $m.After, ($m.Change * 100)) -ForegroundColor $color
    }
    Write-Host ''
    $avg = $cmp.avg
    $pct = [math]::Round([math]::Abs($avg.Change) * 100, 1)
    $noise = [math]::Round($avg.Noise * 100, 1)
    switch ($avg.Verdict) {
        'better' { Write-Nova ('Средний FPS вырос на {0}% — это больше разброса между замерами ({1}%). Ускорение настоящее.' -f $pct, $noise) ok }
        'worse' { Write-Nova ('Средний FPS упал на {0}%. Если так и останется — отмени Nova (пункт 3) или выключи игровые пункты в config.json.' -f $pct) warn }
        default { Write-Nova ('Разницы в среднем FPS нет: {0}% — меньше разброса между замерами ({1}%). Честно: в этой игре на этом ПК Nova на средний FPS не влияет.' -f $pct, $noise) info }
    }
    if ($cmp.low1.Verdict -eq 'better') { Write-Nova ('Зато просадки стали меньше: 1% low вырос на {0}%.' -f [math]::Round($cmp.low1.Change * 100, 1)) ok }
    if ($cmp.low1.Verdict -eq 'worse') { Write-Nova ('Просадки стали сильнее: 1% low упал на {0}%.' -f [math]::Round([math]::Abs($cmp.low1.Change) * 100, 1)) warn }
    if ($before.Count -lt 3 -or $after.Count -lt 3) { Write-Nova 'Для точности сделай по 3 замера «до» и «после» в одном и том же месте игры.' dim }
}

#endregion

#region Проверка системы

# Одна строчка проверки. Status: ok — всё хорошо, info — к сведению, warn — лучше поправить, stop — Nova не запустится.
function New-NovaCheck {
    param([string]$Name, [ValidateSet('ok', 'info', 'warn', 'stop')][string]$Status, [string]$Text, [string]$Hint = '', [string]$Id = '')
    return [pscustomobject]@{ Id = $Id; Name = $Name; Status = $Status; Text = $Text; Hint = $Hint }
}

# Проверяет, готова ли Windows к Nova: версия, перезагрузка после обновлений, место на диске, ноутбук и т. д.
function Get-NovaHealth {
    param($Context)
    $config = $null
    $tweaks = @()
    if ($Context) { $config = $Context.Config; $tweaks = @($Context.Tweaks) }
    $toggles = Get-NovaProp $config 'tweaks'
    $checks = New-Object System.Collections.Generic.List[object]

    # Windows
    $sys = Get-NovaSystemInfo
    $label = '{0} {1}, сборка {2}' -f $sys.Name, $sys.Version, $sys.Build
    if ($sys.Build -lt 10240) {
        $checks.Add((New-NovaCheck 'Windows' 'stop' ($label + ' — Nova работает только на Windows 10 и 11.') -Id 'windows'))
    } elseif ($sys.IsServer) {
        $checks.Add((New-NovaCheck 'Windows' 'warn' ($label + ' — это серверная Windows.') 'Nova рассчитана на Windows 10/11: часть настроек здесь не сработает.' 'windows'))
    } elseif ($sys.Build -lt 19044) {
        $checks.Add((New-NovaCheck 'Windows' 'warn' ($label + ' — устаревшая версия.') 'Обнови Windows через «Параметры → Центр обновления Windows» и запусти Nova снова.' 'windows'))
    } elseif ($sys.Build -lt 22000) {
        $checks.Add((New-NovaCheck 'Windows' 'info' ($label + '. Обычная поддержка Windows 10 закончилась.') 'Если компьютер подходит для Windows 11, лучше поставить её — она получает обновления безопасности.' 'windows'))
    } else {
        $checks.Add((New-NovaCheck 'Windows' 'ok' $label -Id 'windows'))
    }

    # Редакция Home: часть политик работает только на Pro
    if ($sys.Edition -like 'Core*' -and [bool](Get-NovaProp $toggles 'security-updates-only' $false)) {
        $checks.Add((New-NovaCheck 'Редакция' 'warn' 'Windows Home: пункт «Только обновления безопасности» здесь не сработает.' 'Он работает на Pro и выше. Выключи его в config.json или просто пропусти — остальное применится.' 'edition'))
    }

    # Перезагрузка после обновлений
    $cbs = Get-NovaRegValue -Path 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -Name 'Nova'
    $wu = Get-NovaRegValue -Path 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -Name 'Nova'
    if ($cbs.KeyExists -or $wu.KeyExists) {
        $checks.Add((New-NovaCheck 'Перезагрузка' 'warn' 'Windows ждёт перезагрузки после обновлений.' 'Перезагрузи компьютер и запусти Nova снова — так настройки лягут надёжнее.' 'reboot'))
    } else {
        $checks.Add((New-NovaCheck 'Перезагрузка' 'ok' 'Не нужна.' -Id 'reboot'))
    }

    # Место на системном диске
    try {
        $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        $freeGB = [math]::Round([double]$drive.FreeSpace / 1GB, 1)
        $diskName = 'Диск ' + $env:SystemDrive
        if ($freeGB -lt 2) {
            $checks.Add((New-NovaCheck $diskName 'stop' ('Свободно всего {0} ГБ.' -f $freeGB) 'Освободи место: «Параметры → Система → Память → Временные файлы». Нужно хотя бы 2 ГБ.' 'disk'))
        } elseif ($freeGB -lt 10) {
            $checks.Add((New-NovaCheck $diskName 'warn' ('Свободно {0} ГБ — маловато.' -f $freeGB) 'Точке восстановления и обновлениям нужно место. Почисти временные файлы.' 'disk'))
        } else {
            $checks.Add((New-NovaCheck $diskName 'ok' ('Свободно {0} ГБ.' -f $freeGB) -Id 'disk'))
        }
    } catch {
        $checks.Add((New-NovaCheck 'Диск' 'info' 'Не удалось узнать, сколько места свободно.' -Id 'disk'))
    }

    # Насколько система свежая
    $installed = Get-NovaRegValue -Path 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'InstallDate'
    if ($installed.Exists -and [int64]$installed.Value -gt 0) {
        $date = [DateTimeOffset]::FromUnixTimeSeconds([int64]$installed.Value).LocalDateTime
        $days = [int][math]::Floor(((Get-Date) - $date).TotalDays)
        if ($days -le 7) {
            $checks.Add((New-NovaCheck 'Установка' 'ok' 'Windows установлена недавно — лучшее время для Nova.' -Id 'fresh'))
        } else {
            $checks.Add((New-NovaCheck 'Установка' 'info' ('Windows установлена или крупно обновлялась {0}.' -f $date.ToString('d MMMM yyyy', [Globalization.CultureInfo]'ru-RU')) 'Nova работает и на такой системе. На чистой Windows разница заметнее всего.' 'fresh'))
        }
    }

    # Nova уже запускали
    $backups = @(Get-NovaBackup)
    if ($backups.Count -gt 0) {
        $checks.Add((New-NovaCheck 'Nova' 'info' ('Nova уже применялась на этом компьютере (запусков: {0}).' -f $backups.Count) 'Новый запуск изменит только то, что ещё не настроено. Отменять можно по одному запуску.' 'nova'))
    }

    # Ноутбук: настройки, которые быстрее сажают батарею
    try {
        $battery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
    } catch {
        $battery = @()
    }
    if ($battery.Count -gt 0) {
        $hungry = @(foreach ($id in @('high-performance-power', 'power-throttling-off')) {
                if ([bool](Get-NovaProp $toggles $id $false)) {
                    $t = $tweaks | Where-Object { $_.id -eq $id } | Select-Object -First 1
                    if ($t) { $t.title } else { $id }
                }
            })
        if ($hungry.Count -gt 0) {
            $checks.Add((New-NovaCheck 'Ноутбук' 'warn' ('Включено то, что быстрее сажает батарею: {0}.' -f ($hungry -join ', ')) 'Если важна батарея — выключи эти пункты в config.json.' 'battery'))
        } else {
            $checks.Add((New-NovaCheck 'Ноутбук' 'ok' 'Настройки, которые сажают батарею, выключены.' -Id 'battery'))
        }
    }

    # Защита Windows. Nova её не выключает, но предупредит, если что-то уже выключено.
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.AntivirusEnabled -and $mp.RealTimeProtectionEnabled) {
            $checks.Add((New-NovaCheck 'Антивирус' 'ok' 'Microsoft Defender работает.' -Id 'antivirus'))
        } else {
            $other = @()
            try { $other = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | Where-Object { $_.displayName -notlike '*Defender*' }) } catch { $other = @() }
            if ($other.Count -gt 0) {
                $checks.Add((New-NovaCheck 'Антивирус' 'ok' ('Работает {0}.' -f $other[0].displayName) -Id 'antivirus'))
            } else {
                $checks.Add((New-NovaCheck 'Антивирус' 'warn' 'Защита в реальном времени выключена.' 'Включи её: «Безопасность Windows → Защита от вирусов и угроз». Nova её не трогает.' 'antivirus'))
            }
        }
    } catch {
        Write-Verbose 'Defender недоступен — пропускаем.'
    }
    try {
        $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        if ($off.Count -gt 0) {
            $checks.Add((New-NovaCheck 'Брандмауэр' 'warn' ('Выключен для сетей: {0}.' -f ($off -join ', ')) 'Включи его: «Безопасность Windows → Брандмауэр и защита сети». Nova его не трогает.' 'firewall'))
        } else {
            $checks.Add((New-NovaCheck 'Брандмауэр' 'ok' 'Включён.' -Id 'firewall'))
        }
    } catch {
        Write-Verbose 'Брандмауэр недоступен — пропускаем.'
    }
    $lua = Get-NovaRegValue -Path 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
    if ($lua.Exists -and [int]$lua.Value -eq 0) {
        $checks.Add((New-NovaCheck 'Контроль учётных записей' 'warn' 'UAC выключен: любая программа получает права администратора без вопроса.' 'Включи его: Пуск → «Изменение параметров контроля учётных записей».' 'uac'))
    }
    $wu = Get-NovaServiceStartup 'wuauserv'
    if ($wu -eq 'Disabled') {
        $checks.Add((New-NovaCheck 'Обновления' 'warn' 'Служба обновлений Windows отключена — исправления безопасности не придут.' 'Похоже, это сделала другая программа. Nova обновления не отключает.' 'updates'))
    }

    # Установка программ: нужен winget и интернет
    $installApps = Get-NovaProp $config 'installApps'
    $wanted = @()
    if ($installApps) { $wanted = @($installApps.PSObject.Properties | Where-Object { $_.Value -eq $true }) }
    if ($wanted.Count -gt 0) {
        if (-not (Get-NovaWingetPath)) {
            $checks.Add((New-NovaCheck 'Программы' 'warn' 'winget не найден — программы из списка installApps не установятся.' 'Обнови «Установщик приложений» (App Installer) в Microsoft Store.' 'winget'))
        } elseif (-not [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) {
            $checks.Add((New-NovaCheck 'Программы' 'warn' 'Нет подключения к сети — программы из installApps не скачаются.' 'Подключись к интернету перед применением.' 'winget'))
        } else {
            $checks.Add((New-NovaCheck 'Программы' 'ok' ('Установлю программ: {0}.' -f $wanted.Count) -Id 'winget'))
        }
    }

    return $checks.ToArray()
}

function Get-NovaHealthSummary {
    param($Checks)
    $stop = @($Checks | Where-Object { $_.Status -eq 'stop' }).Count
    $warn = @($Checks | Where-Object { $_.Status -eq 'warn' }).Count
    return [pscustomobject]@{ Stop = $stop; Warn = $warn; Ready = ($stop -eq 0) }
}

function Show-NovaHealth {
    param($Checks, [switch]$ProblemsOnly)
    Write-Host ''
    Write-Nova 'ПРОВЕРКА СИСТЕМЫ' title
    $shown = 0
    foreach ($check in $Checks) {
        if ($ProblemsOnly -and ($check.Status -eq 'ok' -or $check.Status -eq 'info')) { continue }
        $shown++
        $line = '{0}: {1}' -f $check.Name, $check.Text
        switch ($check.Status) {
            'ok' { Write-Nova $line ok }
            'info' { Write-Nova ('i ' + $line) info }
            'warn' { Write-Nova $line warn }
            'stop' { Write-Nova $line err }
        }
        if ($check.Hint -and $check.Status -ne 'ok') { Write-Nova ('    ' + $check.Hint) dim }
    }
    if ($ProblemsOnly -and $shown -eq 0) { Write-Nova 'Всё в порядке.' ok }
    $summary = Get-NovaHealthSummary $Checks
    if ($summary.Stop -gt 0) {
        Write-Nova 'Nova не сможет работать, пока это не исправлено.' err
    } elseif (-not $ProblemsOnly -and $summary.Warn -eq 0) {
        Write-Nova 'Система готова к Nova.' ok
    }
    return $summary
}

#endregion

Export-ModuleMember -Function *
