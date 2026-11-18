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

# Ярлыки — через IShellLinkW, «родной» юникодный способ Windows. Старый WScript.Shell не сохраняет и не читает
# ярлыки, если в пути есть буквы не из кодировки «для программ без Юникода» (например, «Nova Центр.lnk»
# или папка пользователя «Вася» на Windows с английской настройкой) — пишет «?????» и падает.
$script:ShortcutCode = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
namespace NovaLink {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class CShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    internal interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    public static class Shortcut {
        public static void Save(string path, string target, string arguments, string workDir, string icon, int iconIndex, string description, int showCmd) {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            try {
                link.SetPath(target);
                link.SetArguments(arguments ?? "");
                if (!String.IsNullOrEmpty(workDir)) { link.SetWorkingDirectory(workDir); }
                if (!String.IsNullOrEmpty(icon)) { link.SetIconLocation(icon, iconIndex); }
                if (!String.IsNullOrEmpty(description)) { link.SetDescription(description); }
                link.SetShowCmd(showCmd);
                ((IPersistFile)link).Save(path, true);
            } finally { Marshal.ReleaseComObject(link); }
        }
        // Цель, аргументы, рабочая папка, значок, номер значка, как открывать окно.
        public static string[] Read(string path) {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            try {
                ((IPersistFile)link).Load(path, 0);
                StringBuilder target = new StringBuilder(1024), args = new StringBuilder(2048), dir = new StringBuilder(1024), icon = new StringBuilder(1024);
                int iconIndex, show;
                link.GetPath(target, target.Capacity, IntPtr.Zero, 0);
                link.GetArguments(args, args.Capacity);
                link.GetWorkingDirectory(dir, dir.Capacity);
                link.GetIconLocation(icon, icon.Capacity, out iconIndex);
                link.GetShowCmd(out show);
                return new string[] { target.ToString(), args.ToString(), dir.ToString(), icon.ToString(), iconIndex.ToString(), show.ToString() };
            } finally { Marshal.ReleaseComObject(link); }
        }
    }
}
'@
function Initialize-NovaShortcut { if (-not ('NovaLink.Shortcut' -as [type])) { Add-Type -TypeDefinition $script:ShortcutCode -Language CSharp } }

# Создаёт ярлык. ShowCmd: 1 — обычное окно, 7 — свёрнутое.
function New-NovaShortcut {
    param(
        [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target,
        [string]$Arguments = '', [string]$WorkingDirectory = '', [string]$Icon = '', [int]$IconIndex = 0,
        [string]$Description = '', [int]$ShowCmd = 1
    )
    Initialize-NovaShortcut
    [NovaLink.Shortcut]::Save($Path, $Target, $Arguments, $WorkingDirectory, $Icon, $IconIndex, $Description, $ShowCmd)
}

function Read-NovaShortcut {
    param([Parameter(Mandatory)][string]$Path)
    Initialize-NovaShortcut
    $r = [NovaLink.Shortcut]::Read($Path)
    return [pscustomobject]@{ Target = $r[0]; Arguments = $r[1]; WorkingDirectory = $r[2]; Icon = $r[3]; IconIndex = [int]$r[4]; ShowCmd = [int]$r[5] }
}

function Get-NovaShortcutTarget {
    param([string]$Path)
    try { return [string](Read-NovaShortcut -Path $Path).Target } catch { return '' }
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
            # Одна «кривая» запись (недопустимые символы в имени или пути) не должна ронять весь список.
            $clean = Get-NovaCleanText $e.Name
            $title = $clean -replace '\.(lnk|exe|bat|cmd|url|vbs|js)$', ''
            $file = ''; $local = $false; $exists = $false; $company = ''
            try {
                $file = Get-NovaCommandFile $e.Command
                $local = [bool]$file -and (Test-NovaLocalPath $file)
                if ($local -and (Test-Path -LiteralPath $file -PathType Leaf)) {
                    $exists = $true
                    try {
                        $info = (Get-Item -LiteralPath $file).VersionInfo
                        if ($info.FileDescription -and $info.FileDescription.Trim()) { $title = $info.FileDescription }
                    } catch { Write-Verbose ('Нет сведений о {0}' -f $file) }
                    $company = Get-NovaSigner $file
                }
            } catch {
                Write-Verbose ('Запись автозагрузки не разобрана: {0}' -f $clean)
                $local = $false; $exists = $false; $company = ''
            }
            $approved = Get-NovaRegValue -Path $src.Approved -Name $e.Name
            $items.Add([pscustomobject]@{
                    RawName = $e.Name; Name = $clean; Title = (Get-NovaCleanText $title 60); Company = (Get-NovaCleanText $company 50)
                    Command = $e.Command; File = $file; Where = $src.Where; Approved = $src.Approved
                    Enabled = (Test-NovaStartupEnabled $approved.Value)
                    Signed = [bool]$company; Network = ([bool]$file -and -not $local -and ($file -match '^(\\\\|[A-Za-z]:\\)'))
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

# Nova Голос вместе с Windows: ярлык в папке «Автозагрузка» этого пользователя, окно свёрнуто.
# Ярлык создаёт и убирает само окно Nova Голос — без прав администратора (src\NovaVoiceStartup.cmd):
# папка «Автозагрузка» принадлежит пользователю, и Nova с правами администратора в неё не пишет.
# Выключить можно там же, в пункте 10 или в Диспетчере задач — это обычная запись автозагрузки.
# Имя латиницей: ярлыки с русским именем Windows Script Host на английской Windows не читает.
$script:VoiceLink = 'Nova Voice.lnk'
$script:VoiceApproved = 'HKCU\{0}\StartupFolder' -f $script:Approved

function Get-NovaVoiceAutostartPath {
    param([string]$Folder = [Environment]::GetFolderPath('Startup'))
    return (Join-Path $Folder $script:VoiceLink)
}

# none — ярлыка нет; on — запускается; disabled — выключен в Диспетчере задач или в пункте 10;
# other — ярлык ведёт на другую копию Nova (например, старую папку после обновления).
function Get-NovaVoiceAutostart {
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Folder = [Environment]::GetFolderPath('Startup'),
        [string]$ApprovedKey = $script:VoiceApproved
    )
    $path = Get-NovaVoiceAutostartPath $Folder
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ State = 'none'; Target = '' } }
    $real = Get-NovaShortcutTarget $path
    if ($real -ine $Target) { return [pscustomobject]@{ State = 'other'; Target = (Get-NovaCleanText $real 200) } }
    $approved = Get-NovaRegValue -Path $ApprovedKey -Name $script:VoiceLink
    if ($approved.Exists -and -not (Test-NovaStartupEnabled $approved.Value)) { return [pscustomobject]@{ State = 'disabled'; Target = $real } }
    return [pscustomobject]@{ State = 'on'; Target = $real }
}

function Remove-NovaVoiceAutostart {
    param([string]$Folder = [Environment]::GetFolderPath('Startup'), [string]$ApprovedKey = $script:VoiceApproved)
    $path = Get-NovaVoiceAutostartPath $Folder
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.PSIsContainer) { throw ('На месте ярлыка «{0}» лежит папка — убери её вручную.' -f $path) }
        Remove-Item -LiteralPath $path -Force
    }
    # Отметка «выключено» от Диспетчера задач иначе пережила бы новый ярлык с тем же именем.
    Remove-NovaRegValue -Path $ApprovedKey -Name $script:VoiceLink
}

function Add-NovaVoiceAutostart {
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Folder = [Environment]::GetFolderPath('Startup'),
        [string]$ApprovedKey = $script:VoiceApproved
    )
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { throw ('Не найден {0}.' -f $Target) }
    Remove-NovaVoiceAutostart -Folder $Folder -ApprovedKey $ApprovedKey
    if (-not (Test-Path -LiteralPath $Folder)) { [void][System.IO.Directory]::CreateDirectory($Folder) }
    $path = Get-NovaVoiceAutostartPath $Folder
    # Окно Nova Голос при входе в Windows открывается свёрнутым — слушает, но не мешает.
    New-NovaShortcut -Path $path -Target $Target -Arguments '-Minimized' -WorkingDirectory (Split-Path -Parent $Target) -Description 'Nova Голос — голосовые команды «Нова, …»' -ShowCmd 7
    return $path
}

# Ярлык автозапуска из Nova 0.8 открывал голос без -Minimized: теперь окно открывалось бы при каждом входе
# развёрнутым. Подправляем такой ярлык на месте — имя то же, отметка «выключено» в Диспетчере задач сохраняется.
function Update-NovaVoiceAutostart {
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Folder = [Environment]::GetFolderPath('Startup')
    )
    $path = Get-NovaVoiceAutostartPath $Folder
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $link = Read-NovaShortcut -Path $path
    if ($link.Target -ine $Target -or $link.Arguments -eq '-Minimized') { return $false }
    New-NovaShortcut -Path $path -Target $Target -Arguments '-Minimized' -WorkingDirectory (Split-Path -Parent $Target) -Description 'Nova Голос — голосовые команды «Нова, …»' -ShowCmd 7
    return $true
}

# Тот ли это пользователь, что сидит за компьютером. Если Nova открыли с паролем другого администратора,
# папка «Автозагрузка» была бы его, а не твоя.
function Test-NovaDesktopUser {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session = (Get-Process -Id $PID).SessionId
    $shells = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
    if ($shells.Count -eq 0) { return $true }
    foreach ($process in $shells) {
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction SilentlyContinue
        if ($owner -and $owner.Sid -eq $me) { return $true }
    }
    return $false
}

Export-ModuleMember -Function *
