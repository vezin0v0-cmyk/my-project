# Переезд на чистую Windows: список с флешки — недоверенный файл. Проверяем, что подозрительное не проходит.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaMove.psm1') -Force -DisableNameChecking

function Test-App($id, $source, [bool]$ok) {
    $r = ConvertTo-NovaMoveApp ([pscustomobject]@{ id = $id; source = $source })
    if ([bool]$r -ne $ok) { throw ('«{0}» из «{1}»: ожидалось {2}' -f $id, $source, $(if ($ok) { 'принять' } else { 'отклонить' })) }
}
Test-App 'Valve.Steam' 'winget' $true
Test-App 'Discord.Discord' 'WinGet' $true
Test-App '9NKSQGP7F2NH' 'msstore' $true
Test-App 'Notepad++.Notepad++' 'winget' $true
Test-App '--override' 'winget' $false
Test-App '-h' 'winget' $false
Test-App 'Valve.Steam --override "/S"' 'winget' $false
Test-App 'a;calc' 'winget' $false
Test-App 'a&calc' 'winget' $false
Test-App ('x' * 200) 'winget' $false
Test-App '' 'winget' $false
Test-App 'Valve.Steam' 'evil-source' $false
Test-App 'Valve.Steam' 'https://evil.example/source' $false
$named = ConvertTo-NovaMoveApp ([pscustomobject]@{ id = 'Valve.Steam'; source = 'winget'; name = ('Steam' + [char]27 + '[2J' + "`r`n" + 'fake') })
if ($named.Name -match '[\x00-\x1f]') { throw 'управляющие символы в названии не вычищены' }
Write-Host 'ok  id и источник проверяются: «параметры», команды и чужие источники не проходят'

# Файл из winget export: берём только winget и msstore, свои источники из файла игнорируем.
$export = @'
{"Sources":[
 {"SourceDetails":{"Name":"winget","Argument":"https://cdn.winget.microsoft.com/cache","Type":"Microsoft.PreIndexed.Package"},"Packages":[{"PackageIdentifier":"Valve.Steam"},{"PackageIdentifier":"7zip.7zip"}]},
 {"SourceDetails":{"Name":"msstore","Argument":"https://storeedgefd.dsx.mp.microsoft.com/v9.0","Type":"Microsoft.Rest"},"Packages":[{"PackageIdentifier":"9NKSQGP7F2NH"}]},
 {"SourceDetails":{"Name":"evil","Argument":"https://evil.example/","Type":"Microsoft.Rest"},"Packages":[{"PackageIdentifier":"Evil.Payload"}]}
]}
'@ | ConvertFrom-Json
$apps = @(ConvertFrom-NovaWingetExport $export)
if ($apps.Count -ne 3 -or ($apps | Where-Object Id -eq 'Evil.Payload')) { throw ('из файла winget export взято не то: {0}' -f (($apps | ForEach-Object Id) -join ', ')) }
Write-Host 'ok  из winget export берутся только официальные источники'

# Чтение списка с «флешки».
$dir = Join-Path $env:TEMP ('nova-move-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $good = Join-Path $dir 'good.json'
    [IO.File]::WriteAllText($good, '{"nova":"apps","version":1,"created":"2026-11-14 12:00","apps":[{"id":"Valve.Steam","source":"winget"},{"id":"valve.steam","source":"winget"},{"id":"--override","source":"winget"},{"id":"Discord.Discord","source":"evil"},{"id":"9NKSQGP7F2NH","source":"msstore"}]}')
    $list = Read-NovaMoveList -Path $good
    if (@($list.Apps).Count -ne 2 -or $list.Skipped -ne 2) { throw ('список: программ {0}, пропущено {1} (ждали 2 и 2)' -f @($list.Apps).Count, $list.Skipped) }
    Write-Host 'ok  список с флешки: повторы убраны, подозрительные записи пропущены'

    $refused = 0
    $notNova = Join-Path $dir 'other.json'; [IO.File]::WriteAllText($notNova, '{"apps":[{"id":"Valve.Steam","source":"winget"}]}')
    try { [void](Read-NovaMoveList -Path $notNova) } catch { $refused++ }
    $broken = Join-Path $dir 'broken.json'; [IO.File]::WriteAllText($broken, '{"nova":"apps", "apps": [')
    try { [void](Read-NovaMoveList -Path $broken) } catch { $refused++ }
    $huge = Join-Path $dir 'huge.json'; [IO.File]::WriteAllText($huge, '{"nova":"apps","apps":[],"pad":"' + ('x' * 1100000) + '"}')
    try { [void](Read-NovaMoveList -Path $huge) } catch { $refused++ }
    if ($refused -ne 3) { throw ('чужой, битый или огромный файл принят ({0} из 3 отклонено)' -f $refused) }
    Write-Host 'ok  чужой, повреждённый и слишком большой файлы не принимаются'

    $many = Join-Path $dir 'many.json'
    $items = (1..450 | ForEach-Object { '{"id":"Pkg.N' + $_ + '","source":"winget"}' }) -join ','
    [IO.File]::WriteAllText($many, '{"nova":"apps","apps":[' + $items + ']}')
    $big = Read-NovaMoveList -Path $many
    if (@($big.Apps).Count -ne 400) { throw ('лимит списка не сработал: {0}' -f @($big.Apps).Count) }
    Write-Host 'ok  не больше 400 программ за раз'

    # Настоящий winget export, если winget есть на этой машине.
    # Папка для сохранения: старая (и ссылка вместо неё) откладывается, по ссылке ничего не пишется.
    $victim = Join-Path $dir 'victim'; New-Item -ItemType Directory -Path $victim | Out-Null
    $t1 = Join-Path $dir 't1'; New-Item -ItemType Directory -Path $t1 | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $t1 'Nova-переезд') -Target $victim | Out-Null
    $made = New-NovaMoveFolder -Target $t1
    if ((Get-Item -LiteralPath $made -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'новая папка — ссылка' }
    if (-not (Get-ChildItem -LiteralPath $t1 -Force | Where-Object { $_.Name -like 'Nova-переезд.old-*' })) { throw 'прежняя папка-ссылка не отложена' }
    Write-NovaNewFile -Path (Join-Path $made 'programmy.json') -Bytes ([Text.Encoding]::UTF8.GetBytes('{"nova":"apps","created":"2026-11-14 12:00","apps":[{"id":"Valve.Steam","source":"winget"}]}'))
    if (Test-Path -LiteralPath (Join-Path $victim 'programmy.json')) { throw 'Nova написала по подложенной ссылке' }
    $p = Get-NovaPathProblem -Path $made -Trusted (Get-NovaTrustedSid)
    if ($p) { throw ('новая папка не закрыта: {0}' -f $p) }
    Write-Host 'ok  папка для переезда: ссылка отложена, новая закрыта, по ссылке ничего не записано'
    $twice = $false
    try { Write-NovaNewFile -Path (Join-Path $made 'programmy.json') -Bytes ([byte[]]@(1, 2, 3)) } catch { $twice = $true }
    if (-not $twice) { throw 'существующий файл перезаписан' }
    Write-Host 'ok  существующий файл не перезаписывается'

    # Поиск: список, который может менять другой пользователь, не принимается.
    $t2 = Join-Path $dir 't2'; $bad = Join-Path $t2 'Nova-переезд'
    New-Item -ItemType Directory -Path $bad -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $bad 'programmy.json'), '{"nova":"apps","apps":[{"id":"Evil.Tool","source":"winget"}]}')
    $acl = Get-Acl -LiteralPath $bad
    $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $bad -AclObject $acl
    $found = @(Find-NovaMoveList -Roots @([pscustomobject]@{ Path = $t1; Title = 'свой' }, [pscustomobject]@{ Path = $t2; Title = 'чужой' }))
    $mine = $found | Where-Object Where -eq 'свой'; $theirs = $found | Where-Object Where -eq 'чужой'
    if ($found.Count -ne 2 -or -not $mine.Trusted -or $theirs.Trusted) { throw ('поиск списков: {0}' -f (($found | ForEach-Object { '{0}={1}' -f $_.Where, $_.Trusted }) -join ', ')) }
    Write-Host 'ok  список, который может менять другой пользователь, помечен и не выбирается'

    $fake = Join-Path $dir 'fake.json'
    [IO.File]::WriteAllText($fake, ('{"nova":"apps","created":"2026-11-14 12:00' + [char]27 + '[2J fake USB","apps":[]}'))
    if ((Read-NovaMoveList -Path $fake).Created -ne '') { throw 'поддельная дата показана' }
    if ((Read-NovaMoveList -Path (Join-Path $made 'programmy.json')).Created -ne '2026-11-14 12:00') { throw 'настоящая дата потерялась' }
    Write-Host 'ok  дата из списка показывается, только если это действительно дата'

    foreach ($n in @('*', 'Microsoft.*', '-h', 'a b', '--override')) { if (Test-NovaAppName $n) { throw ('имя «{0}» в config.json принято' -f $n) } }
    foreach ($n in @('Microsoft.BingNews', 'Notepad++.Notepad++', '7zip.7zip', 'MicrosoftCorporationII.MicrosoftFamily')) { if (-not (Test-NovaAppName $n)) { throw ('нормальное имя «{0}» не принято' -f $n) } }
    Write-Host 'ok  config.json: «*» и «параметры» вместо имён не принимаются'

    [void](Find-NovaMoveList)
    if (Get-NovaWingetPath) {
        $saved = $null
        try { $saved = Export-NovaMove -Target $dir -ProjectRoot $root } catch { Write-Host ('::warning::winget export на этой машине не сработал: {0}' -f $_.Exception.Message) }
        if ($saved) {
            $back = Read-NovaMoveList -Path $saved.ListPath
            if ($back.Skipped -ne 0) { throw 'наш же список читается с ошибками' }
            if ($saved.Copied -notcontains 'config.json') { throw 'config.json не сохранён рядом со списком' }
            Write-Host ('ok  winget export: сохранено программ {0}, рядом {1}' -f @($back.Apps).Count, ($saved.Copied -join ', '))
        }
    } else {
        Write-Host 'i   winget на этой машине нет — настоящий export не проверяю'
    }
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'ТЕСТ ПЕРЕЕЗДА ПРОЙДЕН'
