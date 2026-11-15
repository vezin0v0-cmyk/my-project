# Проверка обновлений: Nova читает только CHANGELOG.md и ничего не скачивает сама.
# Здесь — разбор списка изменений без интернета и сверка с версией программы; в конце — настоящий запрос, если есть сеть.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking

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
Write-Host 'ТЕСТ ОБНОВЛЕНИЙ ПРОЙДЕН'
