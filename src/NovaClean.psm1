# NovaClean.psm1 — освобождение места на диске C:.
# Удаляет только то, что Windows сама считает мусором. Ссылки на другие папки (junction/symlink)
# никогда не открываются и не удаляются: иначе через подложенную ссылку чистка с правами
# администратора могла бы стереть системные файлы.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -DisableNameChecking

$script:Reparse = [System.IO.FileAttributes]::ReparsePoint

function Format-NovaSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} МБ' -f ($Bytes / 1MB)) }
    return ('{0:N0} КБ' -f ($Bytes / 1KB))
}

function Get-NovaFreeSpace {
    $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)
    return [double]$drive.FreeSpace
}

# Файлы папки, старше $Before, без захода в ссылки. Папка-ссылка сама тоже пропускается.
function Get-NovaCleanFile {
    param([Parameter(Mandatory)][string]$Path, [datetime]$Before = [datetime]::MaxValue)
    $root = New-Object System.IO.DirectoryInfo($Path)
    if (-not $root.Exists -or ($root.Attributes -band $script:Reparse)) { return @() }
    $result = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $items = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($item in $items) {
            if ($item.Attributes -band $script:Reparse) { continue }
            if ($item -is [System.IO.DirectoryInfo]) { $stack.Push($item) }
            elseif ($item.LastWriteTime -lt $Before) { $result.Add([System.IO.FileInfo]$item) }
        }
    }
    return $result.ToArray()
}

function Measure-NovaCleanFile {
    param([System.IO.FileInfo[]]$Files)
    $sum = 0.0
    foreach ($f in $Files) { $sum += $f.Length }
    return $sum
}

# Удаляет файлы по одному. Перед удалением ещё раз проверяет, что ни файл, ни папки над ним
# (до корня очистки) не стали ссылками. Занятые программами файлы пропускает.
function Remove-NovaCleanFile {
    param([Parameter(Mandatory)][string]$Root, [System.IO.FileInfo[]]$Files)
    $freed = 0.0
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    foreach ($file in $Files) {
        try {
            $file.Refresh()
            if (-not $file.Exists -or ($file.Attributes -band $script:Reparse)) { continue }
            $safe = $true
            $dir = $file.Directory
            while ($null -ne $dir -and $dir.FullName.TrimEnd('\').Length -ge $rootFull.Length) {
                $dir.Refresh()
                if ($dir.Attributes -band $script:Reparse) { $safe = $false; break }
                if ($dir.FullName.TrimEnd('\') -eq $rootFull) { break }
                $dir = $dir.Parent
            }
            if (-not $safe) { continue }
            $length = $file.Length
            if ($file.IsReadOnly) { $file.IsReadOnly = $false }
            $file.Delete()
            $freed += $length
        } catch {
            Write-Verbose ('Пропускаю {0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
    }
    # Пустые папки внутри (не сам корень и не ссылки).
    $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $rootInfo = New-Object System.IO.DirectoryInfo($Root)
    if ($rootInfo.Exists -and -not ($rootInfo.Attributes -band $script:Reparse)) {
        $stack.Push($rootInfo)
        while ($stack.Count -gt 0) {
            $d = $stack.Pop()
            try { foreach ($sub in $d.GetDirectories()) { if (-not ($sub.Attributes -band $script:Reparse)) { $dirs.Add($sub); $stack.Push($sub) } } } catch { continue }
        }
        foreach ($d in @($dirs | Sort-Object { $_.FullName.Length } -Descending)) {
            try { if (@($d.GetFileSystemInfos()).Count -eq 0) { $d.Delete($false) } } catch { Write-Verbose 'Папка занята.' }
        }
    }
    return $freed
}

# Что можно почистить. Folder — папки, которые Nova чистит сама; Run — особые действия Windows.
function Get-NovaCleanPlan {
    param([switch]$Quick)
    $dayAgo = (Get-Date).AddDays(-1)
    $items = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Id, $Title, $Note, $Folders, $Before)
        $files = @()
        foreach ($folder in $Folders) { $files += @(Get-NovaCleanFile -Path $folder -Before $Before) }
        $items.Add([pscustomobject]@{ Id = $Id; Title = $Title; Note = $Note; Folders = $Folders; Before = $Before; Size = (Measure-NovaCleanFile $files); Kind = 'folder' })
    }
    & $add 'temp' 'Временные файлы программ' 'старше суток' @($env:TEMP) $dayAgo
    & $add 'update-cache' 'Скачанные файлы обновлений' 'Windows скачает заново, если понадобится' @((Join-Path $env:SystemRoot 'SoftwareDistribution\Download')) $dayAgo
    # Только папки, куда не могут писать другие пользователи компьютера.
    & $add 'dumps' 'Отчёты о сбоях' 'нужны только разработчикам' @((Join-Path $env:SystemRoot 'Minidump'), (Join-Path $env:LOCALAPPDATA 'CrashDumps')) ([datetime]::MaxValue)
    & $add 'thumbnails' 'Кэш эскизов в Проводнике' 'Windows создаст заново' @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')) ([datetime]::MaxValue)
    # В кэше эскизов чистим только сами эскизы.
    $thumb = $items | Where-Object { $_.Id -eq 'thumbnails' }
    $thumbFiles = @(Get-NovaCleanFile -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') | Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' })
    $thumb.Size = Measure-NovaCleanFile $thumbFiles
    $items.Add([pscustomobject]@{ Id = 'delivery'; Title = 'Кэш раздачи обновлений'; Note = 'файлы оптимизации доставки'; Size = 0.0; Kind = 'delivery' })
    if (-not $Quick) {
        $items.Add([pscustomobject]@{ Id = 'components'; Title = 'Старые версии системных компонентов'; Note = 'DISM, займёт несколько минут; обычно 0,5–3 ГБ'; Size = 0.0; Kind = 'dism' })
    }
    return $items.ToArray()
}

function Invoke-NovaCleanItem {
    param([Parameter(Mandatory)]$Item)
    switch ($Item.Kind) {
        'folder' {
            $freed = 0.0
            foreach ($folder in $Item.Folders) {
                $files = @(Get-NovaCleanFile -Path $folder -Before $Item.Before)
                if ($Item.Id -eq 'thumbnails') { $files = @($files | Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' }) }
                if ($Item.Id -eq 'update-cache') {
                    # Служба обновлений держит файлы — останавливаем её на время и запускаем обратно.
                    $wu = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
                    $wasRunning = $wu -and $wu.Status -eq 'Running'
                    if ($wasRunning) { Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue }
                    try { $freed += Remove-NovaCleanFile -Root $folder -Files $files }
                    finally { if ($wasRunning) { Start-Service -Name wuauserv -ErrorAction SilentlyContinue } }
                } else {
                    $freed += Remove-NovaCleanFile -Root $folder -Files $files
                }
            }
            return $freed
        }
        'delivery' {
            if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue | Out-Null
            }
            return -1
        }
        'dism' {
            $dism = Get-NovaSystemTool 'dism.exe'
            $run = Invoke-NovaNative $dism @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/Quiet') -Stream
            if ($run.Code -ne 0) { throw ('DISM завершился с кодом {0}' -f $run.Code) }
            return -1
        }
    }
    return 0
}

# Сжатие системных файлов (CompactOS): освобождает 2–4 ГБ, на современных ПК незаметно.
function Invoke-NovaCompactOs {
    param([switch]$Undo)
    $state = 'always'
    if ($Undo) { $state = 'never' }
    $run = Invoke-NovaNative (Get-NovaSystemTool 'compact.exe') @(('/compactos:{0}' -f $state)) -Stream
    if ($run.Code -ne 0) { throw ('compact завершился с кодом {0}' -f $run.Code) }
}

function Get-NovaHiberfilSize {
    $path = Join-Path $env:SystemDrive 'hiberfil.sys'
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        return [double]$item.Length
    } catch {
        return 0.0
    }
}

Export-ModuleMember -Function *
