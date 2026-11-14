# NovaStartup.psm1 — автозагрузка: что запускается вместе с Windows, и выключатель для каждого пункта.
# Выключаем так же, как «Диспетчер задач → Автозагрузка»: сама запись остаётся на месте, Windows
# просто её пропускает. Поэтому всё обратимо и видно в Диспетчере задач. Защиту Windows не трогаем.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -DisableNameChecking

$script:Approved = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
# Значок «Безопасность Windows» и сам Защитник. Их Nova не выключает, как и всё остальное, что защищает Windows.
# Узнаём их только по настоящему пути в системной папке и только в разделе HKLM, куда пишут лишь администраторы:
# иначе вирус мог бы назвать себя «SecurityHealth», и Nova не дала бы его выключить.
$script:ProtectedPaths = @(
    (Join-Path $env:SystemRoot 'System32\SecurityHealthSystray.exe'),
    (Join-Path $env:ProgramFiles 'Windows Defender\MSASCuiL.exe'),
    (Join-Path $env:ProgramFiles 'Windows Defender\MSASCui.exe')
) | ForEach-Object { $_.ToLowerInvariant() }

# Текст из реестра и из файлов чужих программ: без управляющих и невидимых символов, не длиннее Max.
function Get-NovaCleanText {
    param([string]$Text, [int]$Max = 80)
    $t = ([string]$Text -replace '[\p{Cc}\p{Cf}]', '').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '…' }
    return $t
}

# Путь на локальном жёстком диске? Сетевые пути (\\сервер\папка, сетевые диски) не трогаем:
# проверка такого пути с правами администратора может надолго подвесить меню.
function Test-NovaLocalPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\') { return $false }
    try { return ((New-Object System.IO.DriveInfo($Path.Substring(0, 1))).DriveType -eq [System.IO.DriveType]::Fixed) } catch { return $false }
}

# Издатель — только из цифровой подписи. То, что программа пишет о себе сама, может быть неправдой.
function Get-NovaSigner {
    param([string]$Path)
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate) { return '' }
        $subject = $sig.SignerCertificate.Subject
        if ($subject -match '(?:^|,\s*)O="?([^",]+)') { return $Matches[1].Trim() }
        if ($subject -match '(?:^|,\s*)CN="?([^",]+)') { return $Matches[1].Trim() }
    } catch { Write-Verbose ('Подпись не прочитана: {0}' -f $Path) }
    return ''
}

function Get-NovaStartupSource {
    return @(
        [pscustomobject]@{ Kind = 'Run'; Machine = $false; Where = 'реестр, этот пользователь'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; Folder = ''; Approved = ('HKCU\{0}\Run' -f $script:Approved) }
        [pscustomobject]@{ Kind = 'Run'; Machine = $true; Where = 'реестр, все пользователи'; Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Folder = ''; Approved = ('HKLM\{0}\Run' -f $script:Approved) }
        [pscustomobject]@{ Kind = 'Run'; Machine = $true; Where = 'реестр, все пользователи (32 бита)'; Path = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Folder = ''; Approved = ('HKLM\{0}\Run32' -f $script:Approved) }
        [pscustomobject]@{ Kind = 'Folder'; Machine = $false; Where = 'папка «Автозагрузка», этот пользователь'; Path = ''; Folder = [Environment]::GetFolderPath('Startup'); Approved = ('HKCU\{0}\StartupFolder' -f $script:Approved) }
        [pscustomobject]@{ Kind = 'Folder'; Machine = $true; Where = 'папка «Автозагрузка», все пользователи'; Path = ''; Folder = [Environment]::GetFolderPath('CommonStartup'); Approved = ('HKLM\{0}\StartupFolder' -f $script:Approved) }
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
                        if ($_.Extension -eq '.lnk') { $sc = Get-NovaShortcutTarget $_.FullName; if ($sc) { $target = $sc } }
                        [pscustomobject]@{ Name = $_.Name; Command = $target }
                    })
        }
        foreach ($e in $entries) {
            $file = Get-NovaCommandFile $e.Command
            $local = [bool]$file -and (Test-NovaLocalPath $file)
            $title = [IO.Path]::GetFileNameWithoutExtension($e.Name)
            $company = ''; $exists = $false
            if ($local -and (Test-Path -LiteralPath $file -PathType Leaf)) {
                $exists = $true
                try {
                    $info = (Get-Item -LiteralPath $file).VersionInfo
                    if ($info.FileDescription -and $info.FileDescription.Trim()) { $title = $info.FileDescription }
                } catch { Write-Verbose ('Нет сведений о {0}' -f $file) }
                $company = Get-NovaSigner $file
            }
            $approved = Get-NovaRegValue -Path $src.Approved -Name $e.Name
            $items.Add([pscustomobject]@{
                    RawName = $e.Name; Name = (Get-NovaCleanText $e.Name); Title = (Get-NovaCleanText $title 60); Company = (Get-NovaCleanText $company 50)
                    Command = $e.Command; File = $file; Where = $src.Where; Approved = $src.Approved
                    Enabled = (Test-NovaStartupEnabled $approved.Value)
                    Signed = [bool]$company; Network = ([bool]$file -and -not $local -and [IO.Path]::IsPathRooted($file))
                    Protected = ($src.Machine -and $exists -and $local -and ($script:ProtectedPaths -contains $file.ToLowerInvariant()) -and [bool]$company)
                    Missing = ($local -and -not $exists)
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
    # В реестр — настоящее имя записи, а не очищенное для показа.
    $name = $Item.RawName; if ($null -eq $name) { $name = $Item.Name }
    Set-NovaRegValue -Path $Item.Approved -Name $name -Kind 'Binary' -Value $bytes
}

Export-ModuleMember -Function *
