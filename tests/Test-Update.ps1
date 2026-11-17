# Проверка обновлений: список изменений (CHANGELOG.md) и обновление одной кнопкой.
# Здесь — разбор списка изменений без интернета, установка из подложенных архивов (в том числе злых) во временную
# папку и откат назад; в конце — настоящие запросы к GitHub, если есть сеть.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaTools.psm1') -Force -DisableNameChecking

# Номера версий: «0.5» и «0.5.0» равны, мусор не принимается.
if ((ConvertTo-NovaVersion '0.5') -ne (ConvertTo-NovaVersion '0.5.0')) { throw '0.5 и 0.5.0 должны быть одной версией' }
if (-not ((ConvertTo-NovaVersion '0.10') -gt (ConvertTo-NovaVersion '0.9'))) { throw '0.10 должна быть новее 0.9' }
foreach ($bad in @('', 'v0.5', '0.5.0.1', '1', '0.5-beta', '99999.1', ('0.5' + [char]27), "0.5`n1.0")) {
    if ($null -ne (ConvertTo-NovaVersion $bad)) { throw ('«{0}» принято как номер версии' -f $bad) }
}
Write-Host 'ok  номера версий: 0.5 = 0.5.0, 0.10 > 0.9, мусор не принимается'

# Свой CHANGELOG.md: верхняя версия совпадает с версией программы.
$own = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'), [Text.Encoding]::UTF8)
$releases = @(Read-NovaChangelog $own)
if ($releases.Count -lt 2) { throw ('в CHANGELOG.md нашлось версий: {0}' -f $releases.Count) }
if ($releases[0].Version -ne (ConvertTo-NovaVersion (Get-NovaVersion))) { throw ('CHANGELOG.md начинается с {0}, а у программы {1} — допиши список изменений' -f $releases[0].Label, (Get-NovaVersion)) }
if ($releases[0].Items.Count -eq 0) { throw 'у последней версии в CHANGELOG.md нет пунктов' }
$same = Get-NovaUpdateInfo -Changelog $own
if ($same.IsNewer) { throw 'свой же CHANGELOG.md считается «новой версией»' }
Write-Host ('ok  CHANGELOG.md совпадает с программой: {0}, пунктов {1}' -f $releases[0].Label, $releases[0].Items.Count)

# Новая версия: показываются только версии новее своей, сверху самая новая; текст очищен.
$esc = [char]27
$fake = @"
# Что нового в Nova

## 9.1 — когда-нибудь
### В программе
- **Жирное** и ``код`` без разметки
- Опасный текст $esc[2J$esc]0;hacked$([char]7) без управляющих символов
- $('x' * 400)

## 9.0.3 — раньше
- Пункт девятой версии

## 0.1 — давно
- Старое
"@
$info = Get-NovaUpdateInfo -Changelog $fake
if (-not $info.IsNewer -or $info.Latest -ne '9.1' -or $info.Releases.Count -ne 2 -or $info.Releases[0].Label -ne '9.1') { throw ('новая версия найдена неверно: {0}, {1}' -f $info.Latest, $info.Releases.Count) }
$items = @($info.Releases[0].Items)
if ($items[0] -ne 'Жирное и код без разметки') { throw ('разметка не убрана: {0}' -f $items[0]) }
if ($items[1] -match '[\p{Cc}\p{Cf}]') { throw 'управляющие символы из списка изменений попали бы в консоль' }
if ($items[2].Length -gt 160) { throw ('длинный пункт не обрезан: {0}' -f $items[2].Length) }
if ($info.DownloadPage -ne (Get-NovaUpdateSource).DownloadPage) { throw 'ссылка на скачивание взялась не из Nova' }
Write-Host 'ok  новая версия найдена; разметка, управляющие символы и длинные строки вычищены'

# Чужой или пустой ответ — ошибка, а не «у тебя последняя версия».
foreach ($junk in @('', '<html>404: Not Found</html>', "## v2.0`n- x", "## 0.5.0.1`n- x")) {
    $failed = $false
    try { [void](Get-NovaUpdateInfo -Changelog $junk) } catch { $failed = $true }
    if (-not $failed) { throw ('ответ «{0}» принят как список изменений' -f $junk) }
}
# Более старая версия на сервере — это не «обновление».
$older = Get-NovaUpdateInfo -Changelog "## 0.1`n- старое"
if ($older.IsNewer) { throw 'старая версия на сервере принята за новую' }
Write-Host 'ok  пустой, чужой или старый ответ не выдаётся за обновление'

# «Что нового» при первом запуске новой версии: только версии между прошлой и своей.
$mine = Get-NovaVersion
$log = "## 9.9`n- будущее`n`n## $mine`n- своё`n`n## 0.2`n- старое`n`n## 0.1`n- самое старое"
$news = @(Get-NovaWhatsNew -Seen '0.1' -Changelog $log)
if ($news.Count -ne 2 -or $news[0].Label -ne $mine -or $news[1].Label -ne '0.2') { throw ('«что нового» с 0.1: {0}' -f (($news | ForEach-Object Label) -join ', ')) }
foreach ($seen in @('', $mine, '99.0', 'мусор', ('0.1' + [char]27))) {
    if (@(Get-NovaWhatsNew -Seen $seen -Changelog $log).Count -ne 0) { throw ('«что нового» показано для «{0}»' -f $seen) }
}
Write-Host 'ok  «что нового» после обновления: только версии между прошлой и своей; первый запуск и мусор — без новостей'

# Настоящий запрос к GitHub — если сеть есть. Без сети тест не падает.
$source = Get-NovaUpdateSource
if ($source.ChangelogUrl -notlike 'https://raw.githubusercontent.com/*' -or $source.DownloadPage -notlike 'https://*') { throw 'адреса обновлений должны быть https' }
try {
    $live = Get-NovaUpdateInfo
    Write-Host ('ok  GitHub: последняя версия {0}, у нас {1}' -f $live.Latest, $live.Current)
} catch {
    Write-Host ('::warning::Проверить обновления на GitHub не получилось: {0}' -f $_.Exception.Message)
}
# --- Обновление одной кнопкой ---
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$utf8 = New-Object Text.UTF8Encoding($false)
function New-TestZip([string]$Path, [System.Collections.IDictionary]$Entries) {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries.Keys) {
            $entry = $zip.CreateEntry($name)
            $stream = $entry.Open()
            try {
                $value = $Entries[$name]
                if ($value -is [int]) {
                    # Столько мегабайт нулей: в архиве почти ничего не весят.
                    $chunk = New-Object byte[] 1048576
                    for ($i = 0; $i -lt $value; $i++) { $stream.Write($chunk, 0, $chunk.Length) }
                } else {
                    $bytes = $utf8.GetBytes([string]$value)
                    $stream.Write($bytes, 0, $bytes.Length)
                }
            } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose(); $fs.Dispose() }
}
function Get-TreeHash([string]$Dir) {
    $full = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\')
    return ((Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object FullName | ForEach-Object { '{0}={1}' -f $_.FullName.Substring($full.Length), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n")
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('nova-upd-' + [Guid]::NewGuid().ToString('N'))
$project = Join-Path $work 'Nova'
$backups = Join-Path $work 'backups'
New-Item -ItemType Directory -Path (Join-Path $project 'src'), (Join-Path $project 'assets'), $backups -Force | Out-Null
try {
    $files = [ordered]@{
        'Nova.cmd' = 'old cmd'; 'README.md' = 'same readme'; 'config.json' = '{"mine":true}'; 'voice.json' = '{"mine":true}'
        'src\Nova.ps1' = 'old ps1'; 'src\Nova.psm1' = "`$script:NovaVersion = '0.7.0'"; 'src\Old.psm1' = 'stale'; 'assets\wall.jpg' = 'my wallpaper'
    }
    foreach ($k in $files.Keys) { [IO.File]::WriteAllText((Join-Path $project $k), $files[$k], $utf8) }
    $original = Get-TreeHash $project

    $good = Join-Path $work 'good.zip'
    New-TestZip $good ([ordered]@{
            'my-project-x/' = ''; 'my-project-x/Nova.cmd' = 'new cmd'; 'my-project-x/README.md' = 'same readme'
            'my-project-x/src/' = ''; 'my-project-x/src/Nova.ps1' = 'new ps1'; 'my-project-x/src/Nova.psm1' = "# engine`r`n`$script:NovaVersion = '9.9.9'`r`n"
            'my-project-x/src/New.psm1' = 'new module'; 'my-project-x/assets/new.png' = 'png'
            'my-project-x/config.json' = '{"theirs":true}'; 'my-project-x/voice.json' = '{"theirs":true}'; 'my-project-x/tests/Evil.ps1' = 'not needed'
        })
    $package = Read-NovaUpdatePackage -ZipPath $good
    $paths = (@($package.Files | ForEach-Object { $_.Path } | Sort-Object) -join ',')
    if ($package.Version -ne '9.9.9') { throw ('версия из архива: {0}' -f $package.Version) }
    if ($paths -ne 'assets/new.png,Nova.cmd,README.md,src/New.psm1,src/Nova.ps1,src/Nova.psm1') { throw ('из архива взяты не те файлы: {0}' -f $paths) }
    $result = Install-NovaUpdate -Package $package -Root $project -BackupRoot $backups -Current '0.7.0'
    if ($result.Added -ne 2 -or $result.Replaced -ne 3 -or $result.Removed -ne 1) { throw ('обновление: новых {0}, заменено {1}, убрано {2}' -f $result.Added, $result.Replaced, $result.Removed) }
    if ([IO.File]::ReadAllText((Join-Path $project 'config.json')) -ne '{"mine":true}' -or [IO.File]::ReadAllText((Join-Path $project 'voice.json')) -ne '{"mine":true}') { throw 'обновление тронуло config.json или voice.json' }
    if ((Test-Path (Join-Path $project 'src\Old.psm1')) -or -not (Test-Path (Join-Path $project 'src\New.psm1')) -or (Test-Path (Join-Path $project 'tests'))) { throw 'обновление: не те файлы в src или лишняя папка tests' }
    if ([IO.File]::ReadAllText((Join-Path $project 'assets\wall.jpg')) -ne 'my wallpaper') { throw 'обновление тронуло твои файлы в assets' }
    if ([IO.File]::ReadAllText((Join-Path $project 'Nova.cmd')) -ne 'new cmd') { throw 'Nova.cmd не обновился' }
    Write-Host 'ok  обновление из архива: файлы программы новые, config.json, voice.json и твои обои не тронуты, лишнее не распаковано'

    $saved = @(Get-NovaUpdateBackups -BackupRoot $backups)
    if ($saved.Count -ne 1 -or $saved[0].From -ne '0.7.0' -or $saved[0].To -ne '9.9.9') { throw 'копия прошлой версии не найдена' }
    [void](Restore-NovaUpdate -Backup $saved[0] -Root $project)
    if ((Get-TreeHash $project) -ne $original) { throw 'после отката папка Nova не такая, как была' }
    if (@(Get-NovaUpdateBackups -BackupRoot $backups).Count -ne 0) { throw 'копию после отката можно вернуть второй раз' }
    Write-Host 'ok  откат: папка Nova снова байт в байт как до обновления'

    # Не новее своей — не ставим.
    $threw = $false
    try { [void](Install-NovaUpdate -Package $package -Root $project -BackupRoot $backups -Current '9.9.9') } catch { $threw = $true }
    if (-not $threw) { throw 'та же версия поставлена как обновление' }

    # Злые архивы: каждый должен быть отвергнут целиком, а папка Nova — остаться как была.
    # Ключи в @{} не различают регистр — для «A.ps1» и «a.ps1» нужен словарь, который различает.
    $twins = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    $twins.Add('my-project-x/src/A.ps1', 'x')
    $twins.Add('my-project-x/src/a.ps1', 'y')
    $evil = [ordered]@{
        'выход из папки'      = [ordered]@{ '../evil.txt' = 'x'; 'my-project-x/src/Nova.psm1' = "`$script:NovaVersion = '9.9.9'" }
        'выход через src'     = [ordered]@{ 'my-project-x/src/../../evil.ps1' = 'x' }
        'обратная косая'      = [ordered]@{ 'my-project-x/src\evil.ps1' = 'x' }
        'двоеточие'           = [ordered]@{ 'my-project-x/src/evil.ps1:stream' = 'x' }
        'две верхние папки'   = [ordered]@{ 'a/src/Nova.psm1' = 'x'; 'b/src/Nova.ps1' = 'x' }
        'без движка'          = [ordered]@{ 'my-project-x/Nova.cmd' = 'x'; 'my-project-x/src/Nova.ps1' = 'x' }
        'без версии'          = [ordered]@{ 'my-project-x/Nova.cmd' = 'x'; 'my-project-x/src/Nova.ps1' = 'x'; 'my-project-x/src/Nova.psm1' = 'no version' }
        'одно имя дважды'     = $twins
        'бомба из нулей'      = [ordered]@{ 'my-project-x/src/zeros.bin' = 25 }
        'управляющий символ'  = [ordered]@{ ('my-project-x/src/ev' + [char]27 + 'il.ps1') = 'x' }
        'точка в конце имени' = [ordered]@{ 'my-project-x/src/evil.ps1.' = 'x' }
    }
    $n = 0
    foreach ($name in $evil.Keys) {
        $n++
        $zipPath = Join-Path $work ('evil{0}.zip' -f $n)
        New-TestZip $zipPath $evil[$name]
        $threw = $false
        try { [void](Read-NovaUpdatePackage -ZipPath $zipPath) } catch { $threw = $true; Write-Host ('    {0}: {1}' -f $name, $_.Exception.Message) }
        if (-not $threw) { throw ('злой архив «{0}» принят' -f $name) }
    }
    if ((Get-TreeHash $project) -ne $original) { throw 'злые архивы что-то поменяли в папке Nova' }
    Write-Host ('ok  злые архивы отвергнуты целиком: {0}' -f ($evil.Keys -join ', '))

    # Папка src подменена ссылкой на другое место — обновлять туда Nova не будет.
    $elsewhere = Join-Path $work 'elsewhere'
    Rename-Item -LiteralPath (Join-Path $project 'src') -NewName 'src-real'
    New-Item -ItemType Directory -Path $elsewhere | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $project 'src') -Target $elsewhere | Out-Null
    $threw = $false
    try { [void](Install-NovaUpdate -Package $package -Root $project -BackupRoot $backups -Current '0.7.0') } catch { $threw = $true; Write-Host ('    ссылка: {0}' -f $_.Exception.Message) }
    if (-not $threw -or @(Get-ChildItem -LiteralPath $elsewhere).Count -ne 0) { throw 'обновление прошло сквозь ссылку' }
    [IO.Directory]::Delete((Join-Path $project 'src'))
    Rename-Item -LiteralPath (Join-Path $project 'src-real') -NewName 'src'
    Write-Host 'ok  ссылка вместо папки src: обновление отказалось, в чужое место ничего не записано'
} finally {
    $link = Join-Path $project 'src'
    if ((Test-Path -LiteralPath $link) -and ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { [IO.Directory]::Delete($link) }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# Настоящий архив с GitHub: скачивается, проходит проверку, версия в нём — как у программы (ставить нечего).
try {
    $zip = Save-NovaUpdateZip
    try { $live = Read-NovaUpdatePackage -ZipPath $zip } finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    Write-Host ('ok  архив с GitHub: Nova {0}, файлов программы {1}' -f $live.Version, @($live.Files).Count)
    if (@($live.Files | Where-Object { $_.Path -eq 'config.json' -or $_.Path -eq 'voice.json' }).Count -gt 0) { throw 'из настоящего архива взяты бы config.json или voice.json' }
    if ((ConvertTo-NovaVersion $live.Version) -le (ConvertTo-NovaVersion (Get-NovaVersion))) {
        $threw = $false
        try { [void](Install-NovaUpdate -Package $live -Root $root -BackupRoot $env:TEMP) } catch { $threw = $true }
        if (-not $threw) { throw 'архив той же версии поставлен как обновление' }
    }
} catch {
    if ($_.Exception.Message -like '*взяты бы*' -or $_.Exception.Message -like '*поставлен*') { throw }
    Write-Host ('::warning::Скачать архив с GitHub не получилось: {0}' -f $_.Exception.Message)
}
Write-Host 'ТЕСТ ОБНОВЛЕНИЙ ПРОЙДЕН'
