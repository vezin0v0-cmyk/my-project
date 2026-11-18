# Очистка диска: не заходит в подложенные ссылки, удаляет только старое, не трогает чужое.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaClean.psm1') -Force -DisableNameChecking

$base = Join-Path $env:TEMP ('nova-clean-' + [guid]::NewGuid())
$junk = Join-Path $base 'junk'
$victim = Join-Path $base 'victim'
New-Item -ItemType Directory -Path (Join-Path $junk 'sub') -Force | Out-Null
New-Item -ItemType Directory -Path $victim -Force | Out-Null
Set-Content -LiteralPath (Join-Path $junk 'old.tmp') -Value ('x' * 5000)
Set-Content -LiteralPath (Join-Path $junk 'sub\old2.tmp') -Value ('y' * 3000)
Set-Content -LiteralPath (Join-Path $junk 'fresh.tmp') -Value 'новый'
Set-Content -LiteralPath (Join-Path $victim 'important.txt') -Value 'системный файл'
(Get-Item -LiteralPath (Join-Path $junk 'old.tmp')).LastWriteTime = (Get-Date).AddDays(-3)
(Get-Item -LiteralPath (Join-Path $junk 'sub\old2.tmp')).LastWriteTime = (Get-Date).AddDays(-3)
# Подложенная «ссылка на папку» внутри мусора ведёт к важным файлам.
cmd.exe /c mklink /J "$junk\link" "$victim" | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $junk 'link\important.txt'))) { throw 'не удалось создать junction для теста' }

$files = @(Get-NovaCleanFile -Path $junk -Before (Get-Date).AddDays(-1))
$names = @($files | ForEach-Object { $_.Name } | Sort-Object)
if (($names -join ',') -ne 'old.tmp,old2.tmp') { throw ('к удалению отобраны не те файлы: {0}' -f ($names -join ',')) }
Write-Host 'ok  отобраны только старые файлы, ссылка не открывалась'

$freed = Remove-NovaCleanFile -Root $junk -Files $files
if (-not (Test-Path -LiteralPath (Join-Path $victim 'important.txt'))) { throw 'ОЧИСТКА УДАЛИЛА ФАЙЛ ЧЕРЕЗ ССЫЛКУ' }
if (-not (Test-Path -LiteralPath (Join-Path $junk 'link'))) { throw 'ссылку трогать не надо было' }
if (Test-Path -LiteralPath (Join-Path $junk 'old.tmp')) { throw 'старый файл не удалён' }
if (-not (Test-Path -LiteralPath (Join-Path $junk 'fresh.tmp'))) { throw 'свежий файл удалён' }
if ($freed -lt 8000) { throw ('освобождено слишком мало: {0}' -f $freed) }
Write-Host ('ok  удалено {0} байт, файл за ссылкой цел, свежий файл на месте' -f $freed)

# Ссылку подменили уже после отбора файлов: удаление всё равно не идёт через неё.
$files2 = @(Get-NovaCleanFile -Path $junk)
Remove-Item -LiteralPath (Join-Path $junk 'sub') -Recurse -Force -ErrorAction SilentlyContinue
cmd.exe /c rmdir "$junk\link" | Out-Null
New-Item -ItemType Directory -Path (Join-Path $victim 'deep') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $victim 'deep\fresh.tmp') -Value 'чужое'
cmd.exe /c mklink /J "$junk\sub" "$victim\deep" | Out-Null
$planted = [System.IO.FileInfo](Join-Path $junk 'sub\fresh.tmp')
[void](Remove-NovaCleanFile -Root $junk -Files @($files2 + $planted))
if (-not (Test-Path -LiteralPath (Join-Path $victim 'deep\fresh.tmp'))) { throw 'ОЧИСТКА УДАЛИЛА ФАЙЛ ЧЕРЕЗ ПОДМЕНЁННУЮ ПАПКУ' }
Write-Host 'ok  подмена папки на ссылку после отбора не помогает'

cmd.exe /c rmdir "$junk\sub" | Out-Null
Remove-Item -LiteralPath $base -Recurse -Force

$plan = @(Get-NovaCleanPlan -Quick)
foreach ($item in $plan) { Write-Host ('план: {0} — {1}' -f $item.Title, (Format-NovaSize $item.Size)) }
if (@($plan | Where-Object { $_.Id -eq 'temp' }).Count -ne 1) { throw 'в плане нет временных файлов' }
Write-Host 'ТЕСТ ОЧИСТКИ ПРОЙДЕН'
