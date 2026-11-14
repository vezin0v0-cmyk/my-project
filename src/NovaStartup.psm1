# NovaStartup.psm1 — автозагрузка: что запускается вместе с Windows, и выключатель для каждого пункта.
# Выключаем так же, как «Диспетчер задач → Автозагрузка»: сама запись остаётся на месте, Windows
# просто её пропускает. Поэтому всё обратимо и видно в Диспетчере задач. Защиту Windows не трогаем.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -DisableNameChecking

$script:Approved = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
# Значок «Безопасность Windows» и сам Защитник. Их Nova не выключает, как и всё остальное, что защищает Windows.
$script:ProtectedNames = @('SecurityHealth', 'Windows Defender', 'WindowsDefender', 'MSASCui', 'MSASCuiL')
$script:ProtectedFiles = @('securityhealthsystray.exe', 'msascuil.exe', 'msascui.exe')

function Get-NovaStartupSource {
    return @(
        [pscustomobject]@{ Kind = 'Run'; Where = 'реестр, этот пользователь'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; Folder = ''; Approved = ('HKCU\{0}\Run' -f $script:Approved) }
        [pscustomobject]@{ Kind = 'Run'; Where = 'реестр, все пользователи'; Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Folder = ''; Approved = ('HKLM\{0}\Run' -f $script:Approved) }
        [pscustomobject]@{ Kind = 'Run'; Where = 'реестр, все пользователи (32 бита)'; Path = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Folder = ''; Approved = ('HKLM\{0}\Run32' -f $script:Approved) }
        [pscustomobject]@{ Kind = 'Folder'; Where = 'папка «Автозагрузка», этот пользователь'; Path = ''; Folder = [Environment]::GetFolderPath('Startup'); Approved = ('HKCU\{0}\StartupFolder' -f $script:Approved) }
        [pscustomobject]@{ Kind = 'Folder'; Where = 'папка «Автозагрузка», все пользователи'; Path = ''; Folder = [Environment]::GetFolderPath('CommonStartup'); Approved = ('HKLM\{0}\StartupFolder' -f $script:Approved) }
    )
}

# Путь к программе из строки запуска: "C:\a b\x.exe" --flag  или  C:\x\y.exe /min.
function Get-NovaCommandFile {
    param([string]$Command)
    if (-not $Command) { return '' }
    $cmd = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($cmd.StartsWith('"')) {
        $end = $cmd.IndexOf('"', 1)
        if ($end -gt 1) { return $cmd.Substring(1, $end - 1) }
        return $cmd.Trim('"')
    }
    $m = [regex]::Match($cmd, '^(.+?\.(exe|cmd|bat|com|vbs|js|ps1|lnk))(\s|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ($cmd -split '\s+')[0]
}

# Включён ли пункт: в StartupApproved нечётный первый байт значит «выключено» (так пишет Диспетчер задач).
function Test-NovaStartupEnabled {
    param($Data)
    $bytes = @($Data)
    if ($bytes.Count -eq 0 -or $null -eq $Data) { return $true }
    return (([int]$bytes[0] -band 1) -eq 0)
}

function Get-NovaShortcutTarget {
    param([string]$Path)
    try {
        $shell = New-Object -ComObject WScript.Shell
        try { return [string]$shell.CreateShortcut($Path).TargetPath } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    } catch {
        return ''
    }
}

function Get-NovaStartupItem {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($src in Get-NovaStartupSource) {
        $entries = @()
        if ($src.Kind -eq 'Run') {
            $rp = Split-NovaRegPath $src.Path
            $base = Open-NovaBaseKey $rp.Hive
            try {
                $key = $base.OpenSubKey($rp.SubKey, $false)
                if ($null -ne $key) {
                    try {
                        $entries = @(foreach ($n in $key.GetValueNames()) {
                                if (-not $n) { continue }
                                [pscustomobject]@{ Name = $n; Command = [string]$key.GetValue($n, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
                            })
                    } finally { $key.Close() }
                }
            } finally { $base.Close() }
        } elseif ($src.Folder -and (Test-Path -LiteralPath $src.Folder)) {
            $entries = @(Get-ChildItem -LiteralPath $src.Folder -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'desktop.ini' } |
                    ForEach-Object {
                        $target = $_.FullName
                        if ($_.Extension -eq '.lnk') { $t = Get-NovaShortcutTarget $_.FullName; if ($t) { $target = $t } }
                        [pscustomobject]@{ Name = $_.Name; Command = $target }
                    })
        }
        foreach ($e in $entries) {
            $file = Get-NovaCommandFile $e.Command
            $title = [IO.Path]::GetFileNameWithoutExtension($e.Name)
            $company = ''
            if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) {
                try {
                    $info = (Get-Item -LiteralPath $file).VersionInfo
                    if ($info.FileDescription -and $info.FileDescription.Trim()) { $title = $info.FileDescription.Trim() }
                    if ($info.CompanyName) { $company = $info.CompanyName.Trim() }
                } catch { Write-Verbose ('Нет сведений о {0}' -f $file) }
            }
            $approved = Get-NovaRegValue -Path $src.Approved -Name $e.Name
            $leaf = ''
            if ($file) { $leaf = [IO.Path]::GetFileName($file).ToLowerInvariant() }
            $items.Add([pscustomobject]@{
                    Name = $e.Name; Title = $title; Company = $company; Command = $e.Command; File = $file
                    Where = $src.Where; Approved = $src.Approved
                    Enabled = (Test-NovaStartupEnabled $approved.Value)
                    Protected = (($script:ProtectedNames -contains $e.Name) -or ($script:ProtectedFiles -contains $leaf))
                    Missing = ($file -and [IO.Path]::IsPathRooted($file) -and -not (Test-Path -LiteralPath $file))
                })
        }
    }
    return $items.ToArray()
}

# Включить или выключить пункт. Пишет то же, что Диспетчер задач: 02 — включено, 03 + время — выключено.
function Set-NovaStartupItem {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][bool]$Enabled)
    if ($Item.Protected -and -not $Enabled) { throw ('«{0}» — часть защиты Windows. Nova её не выключает.' -f $Item.Title) }
    $bytes = New-Object byte[] 12
    if ($Enabled) {
        $bytes[0] = 2
    } else {
        $bytes[0] = 3
        [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($bytes, 4)
    }
    Set-NovaRegValue -Path $Item.Approved -Name $Item.Name -Kind 'Binary' -Value $bytes
}

Export-ModuleMember -Function *
