# NovaMove.psm1 — «Переезд на чистую Windows».
# Перед переустановкой: сохранить список своих программ (через winget) и настройки Nova на флешку.
# После: найти этот список и поставить программы обратно — только из официальных источников winget.
# Файл со списком приходит с флешки, поэтому ему не доверяем: каждая запись проверяется,
# источники из файла не используются, а id программы не может стать параметром winget.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -DisableNameChecking

$script:MoveFolder = 'Nova-переезд'
$script:ListName = 'programmy.json'
$script:IdPattern = '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}\z'
$script:DatePattern = '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}\z'
$script:Sources = @('winget', 'msstore')
$script:MaxApps = 400
$script:MaxBytes = 1MB

# Куда можно сохранить: флешки и внешние диски, потом рабочий стол.
function Get-NovaMoveTarget {
    $list = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction Stop)) {
            if (-not $d.Size) { continue }
            $label = 'флешка'
            # Название флешки задаёт тот, кто её подготовил: без управляющих символов.
            $vol = ([string]$d.VolumeName -replace '[\p{Cc}\p{Cf}]', '').Trim()
            if ($vol.Length -gt 32) { $vol = $vol.Substring(0, 32) }
            if ($vol) { $label = 'флешка «{0}»' -f $vol }
            $list.Add([pscustomobject]@{ Path = $d.DeviceID + '\'; Title = ('{0} ({1})' -f $label, $d.DeviceID); Removable = $true })
        }
        # второй диск (D: и т. п.) переживёт переустановку, если его не форматировать
        foreach ($d in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)) {
            if (-not $d.Size -or $d.DeviceID -eq $env:SystemDrive) { continue }
            $list.Add([pscustomobject]@{ Path = $d.DeviceID + '\'; Title = ('диск {0} (если при переустановке его не форматировать)' -f $d.DeviceID); Removable = $true })
        }
    } catch { Write-Verbose 'Не удалось получить список дисков.' }
    $desk = [Environment]::GetFolderPath('Desktop')
    if ($desk) { $list.Add([pscustomobject]@{ Path = $desk; Title = 'рабочий стол (потом скопируй папку на флешку или в облако)'; Removable = $false }) }
    return $list.ToArray()
}

# Проверка одного пункта списка. Возвращает $null, если пункт плохой.
function ConvertTo-NovaMoveApp {
    param($Item)
    if ($null -eq $Item) { return $null }
    $id = [string](Get-NovaProp $Item 'id' '')
    $src = ([string](Get-NovaProp $Item 'source' 'winget')).ToLowerInvariant()
    if ($id -notmatch $script:IdPattern) { return $null }
    if ($script:Sources -notcontains $src) { return $null }
    $name = [string](Get-NovaProp $Item 'name' '')
    $name = ($name -replace '[\x00-\x1f\x7f]', '').Trim()
    if ($name.Length -gt 80) { $name = $name.Substring(0, 80) }
    return [pscustomobject]@{ Id = $id; Source = $src; Name = $name }
}

# Читает и проверяет файл со списком. Плохие пункты пропускаются и считаются.
function Read-NovaMoveList {
    param([Parameter(Mandatory)][string]$Path)
    $info = Get-Item -LiteralPath $Path -Force
    if ($info.PSIsContainer -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Это не обычный файл.' }
    if ($info.Length -gt $script:MaxBytes) { throw 'Файл со списком слишком большой — это не список Nova.' }
    try { $data = [IO.File]::ReadAllText($info.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { throw 'Файл со списком повреждён.' }
    if ([string](Get-NovaProp $data 'nova' '') -ne 'apps') { throw 'Это не список программ Nova.' }
    $apps = New-Object System.Collections.Generic.List[object]; $bad = 0; $seen = @{}
    foreach ($item in @(Get-NovaProp $data 'apps' @())) {
        $app = ConvertTo-NovaMoveApp $item
        if (-not $app) { $bad++; continue }
        $key = $app.Source + '|' + $app.Id.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if ($apps.Count -ge $script:MaxApps) { $bad++; continue }
        $apps.Add($app)
    }
    # Дату показываем, только если это действительно дата: иначе через неё можно «нарисовать» в окне чужой текст.
    $created = [string](Get-NovaProp $data 'created' '')
    if ($created -notmatch $script:DatePattern) { $created = '' }
    return [pscustomobject]@{ Path = $info.FullName; Created = $created; Apps = $apps.ToArray(); Skipped = $bad }
}

# Список из файла winget export → наш простой формат. Источники берём только известные.
function ConvertFrom-NovaWingetExport {
    param($Export)
    $apps = New-Object System.Collections.Generic.List[object]
    foreach ($src in @(Get-NovaProp $Export 'Sources' @())) {
        $details = Get-NovaProp $src 'SourceDetails'
        $srcName = ([string](Get-NovaProp $details 'Name' '')).ToLowerInvariant()
        foreach ($p in @(Get-NovaProp $src 'Packages' @())) {
            $app = ConvertTo-NovaMoveApp ([pscustomobject]@{ id = (Get-NovaProp $p 'PackageIdentifier' ''); source = $srcName })
            if ($app) { $apps.Add($app) }
        }
    }
    return $apps.ToArray()
}

# Поддерживает ли диск права доступа (NTFS, ReFS). На FAT/exFAT прав и ссылок нет вовсе.
function Test-NovaAclDrive {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = (New-Object System.IO.DriveInfo($Path.Substring(0, 1))).DriveFormat
        return ($fs -eq 'NTFS' -or $fs -eq 'ReFS')
    } catch { return $true }
}

# Новая папка «Nova-переезд». Старую не используем: в ней могли подложить ссылки на системные файлы.
# Откладываем её (переименовывается сама папка или ссылка, а не то, куда она ведёт) и создаём новую,
# в которую пишут только администраторы — так её не подменят, пока Nova пишет.
function New-NovaMoveFolder {
    param([Parameter(Mandatory)][string]$Target)
    $dir = Join-Path $Target $script:MoveFolder
    if (Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
        $aside = '{0}.old-{1}' -f $dir, (Get-Date -Format 'yyyyMMdd-HHmmss')
        [System.IO.Directory]::Move($dir, $aside)
    }
    if (Test-NovaAclDrive $Target) {
        [void][System.IO.Directory]::CreateDirectory($dir, (New-NovaDataDirSecurity))
        # CreateDirectory молча вернёт уже существующую папку или ссылку — поэтому проверяем.
        $problem = Get-NovaPathProblem -Path $dir -Trusted (Get-NovaTrustedSid)
        if ($problem) { throw ('Папку для переезда подменили ({0}). Выбери другое место.' -f $problem) }
    } else {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    return $dir
}

# Сохранить: программы через winget export + копии config.json и voice.json.
function Export-NovaMove {
    param([Parameter(Mandatory)][string]$Target, [string]$ProjectRoot)
    $winget = Get-NovaWingetPath
    if (-not $winget) { throw 'winget не найден. Обнови «Установщик приложений» (App Installer) в Microsoft Store.' }
    # Сначала долгий winget export во временную папку, и только потом — быстрая запись на место.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('nova-export-' + [guid]::NewGuid() + '.json')
    try {
        $run = Invoke-NovaNative $winget @('export', '--output', $tmp, '--accept-source-agreements')
        if (-not (Test-Path -LiteralPath $tmp)) { throw ('winget не смог составить список (код {0}).' -f $run.Code) }
        $apps = @(ConvertFrom-NovaWingetExport ([IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8) | ConvertFrom-Json))
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    $doc = [ordered]@{ nova = 'apps'; version = 1; created = (Get-Date).ToString('yyyy-MM-dd HH:mm'); apps = @($apps | ForEach-Object { [ordered]@{ id = $_.Id; source = $_.Source } }) }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $dir = New-NovaMoveFolder -Target $Target
    $listPath = Join-Path $dir $script:ListName
    Write-NovaNewFile -Path $listPath -Bytes $utf8.GetBytes(($doc | ConvertTo-Json -Depth 5))
    $copied = @()
    if ($ProjectRoot) {
        foreach ($f in @('config.json', 'voice.json')) {
            $src = Join-Path $ProjectRoot $f
            if (Test-Path -LiteralPath $src -PathType Leaf) { Write-NovaNewFile -Path (Join-Path $dir $f) -Bytes ([IO.File]::ReadAllBytes($src)); $copied += $f }
        }
    }
    return [pscustomobject]@{ Folder = $dir; ListPath = $listPath; Apps = $apps; Copied = $copied }
}

# Все сохранённые списки, которые нашлись, — с местом, датой и тем, можно ли им доверять.
# Сами не выбираем «самый свежий»: дату файла может подделать кто угодно. Выбирает человек.
# Список на NTFS, который записал другой пользователь компьютера, не принимается.
function Find-NovaMoveList {
    param([object[]]$Roots)
    if (-not $Roots) {
        $Roots = @(Get-NovaMoveTarget | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Title = ($_.Title -replace ' \(.*$', '') } })
        foreach ($k in @('MyDocuments')) { $p = [Environment]::GetFolderPath($k); if ($p) { $Roots += [pscustomobject]@{ Path = $p; Title = 'Документы' } } }
        $dl = Join-Path $env:USERPROFILE 'Downloads'; if (Test-Path -LiteralPath $dl) { $Roots += [pscustomobject]@{ Path = $dl; Title = 'Загрузки' } }
    }
    $trusted = $null
    $seen = @{}
    $found = @(foreach ($r in $Roots) {
            $dir = Join-Path $r.Path $script:MoveFolder
            $file = Join-Path $dir $script:ListName
            if ($seen.ContainsKey($file.ToLowerInvariant())) { continue }
            $seen[$file.ToLowerInvariant()] = $true
            $item = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            if (-not $item -or $item.PSIsContainer) { continue }
            $problem = ''
            $folder = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            if (($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $problem = 'вместо файла или папки — ссылка'
            } elseif (Test-NovaAclDrive $r.Path) {
                if ($null -eq $trusted) { $trusted = Get-NovaTrustedSid }
                $problem = Get-NovaPathProblem -Path $dir -Trusted $trusted
                if (-not $problem) { $problem = Get-NovaPathProblem -Path $file -Trusted $trusted }
                if ($problem) { $problem = 'записан или может быть изменён другим пользователем' }
            }
            [pscustomobject]@{ Path = $item.FullName; Folder = $dir; Where = $r.Title; Date = $item.LastWriteTime; Trusted = (-not $problem); Problem = $problem }
        })
    return $found
}

# Поставить программы из списка. Источник берём из проверенного пункта, id — только как значение --id.
function Install-NovaMoveApps {
    param([Parameter(Mandatory)]$Apps, [scriptblock]$OnStep)
    $winget = Get-NovaWingetPath
    if (-not $winget) { throw 'winget не найден. Обнови «Установщик приложений» (App Installer) в Microsoft Store.' }
    $res = [pscustomobject]@{ Installed = 0; Already = 0; Failed = 0; FailedIds = @() }
    foreach ($app in @($Apps)) {
        $check = ConvertTo-NovaMoveApp ([pscustomobject]@{ id = $app.Id; source = $app.Source })
        if (-not $check) { $res.Failed++; continue }
        if ($OnStep) { & $OnStep $check }
        $have = Invoke-NovaNative $winget @('list', '--id', $check.Id, '--exact', '--source', $check.Source, '--accept-source-agreements')
        if ($have.Code -eq 0) { $res.Already++; continue }
        $run = Invoke-NovaNative $winget @('install', '--id', $check.Id, '--exact', '--source', $check.Source, '--silent', '--accept-package-agreements', '--accept-source-agreements')
        if ($run.Code -eq 0) { $res.Installed++ } else { $res.Failed++; $res.FailedIds += $check.Id }
    }
    return $res
}

Export-ModuleMember -Function *
