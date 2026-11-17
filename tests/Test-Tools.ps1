# Проверка помощников 0.6: что тормозит прямо сейчас, интернет для игр, отчёт для поддержки.
# Расчёты — на придуманных данных, где ответ известен заранее; остальное — на настоящей Windows.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\NovaTools.psm1') -Force -DisableNameChecking

function Assert-Status {
    param([object[]]$Checks, [string]$Id, [string]$Status, [string]$What)
    $c = @($Checks | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if (-not $c) { throw ('{0}: нет совета «{1}»' -f $What, $Id) }
    if ($c.Status -ne $Status) { throw ('{0}: ожидался {1}, получился {2} ({3})' -f $What, $Status, $c.Status, $c.Text) }
    Write-Host ('ok  {0}: {1}' -f $What, $c.Text)
}

# --- Пинг: медиана, скачки, потери
$s = Get-NovaPingStats @(20, 22, 21, 23, 20)
if ($s.Median -ne 21 -or $s.Loss -ne 0 -or $s.Jitter -ne 2) { throw ('пинг: {0} мс, скачки {1}, потери {2}' -f $s.Median, $s.Jitter, $s.Loss) }
$s = Get-NovaPingStats @(30, -1, 40, -1)
if ($s.Median -ne 35 -or $s.Loss -ne 50) { throw ('пинг с потерями: {0} мс, потери {1}%' -f $s.Median, $s.Loss) }
$s = Get-NovaPingStats @(-1, -1)
if ($null -ne $s.Median -or $s.Loss -ne 100) { throw 'нет ответа должно давать 100% потерь' }
Write-Host 'ok  пинг: медиана, скачки и потери считаются верно'

# --- Сила сигнала Wi‑Fi из netsh (английская и русская Windows)
$en = "    Name                   : Wi-Fi`r`n    State                  : connected`r`n    Signal                 : 42%`r`n    Profile                : Home"
$ru = "    Имя                    : Беспроводная сеть`r`n    Сигнал                 : 87 %`r`n"
if ((ConvertFrom-NovaWlanText $en) -ne 42 -or (ConvertFrom-NovaWlanText $ru) -ne 87 -or $null -ne (ConvertFrom-NovaWlanText 'There is no wireless interface')) { throw 'сигнал Wi‑Fi не разобран' }
Write-Host 'ok  сигнал Wi‑Fi читается на любом языке Windows'

# --- Советы по интернету
$good = [pscustomobject]@{ Median = 18; Jitter = 2.0; Loss = 0 }
$wire = [pscustomobject]@{ Wifi = $false; Speed = '1 Gbps'; Signal = $null }
$weak = [pscustomobject]@{ Wifi = $true; Speed = '144 Mbps'; Signal = 35 }
$a = Get-NovaNetAdvice -Connection $wire -Results @([pscustomobject]@{ Name = 'Steam'; Stats = $good })
Assert-Status $a 'wire' 'ok' 'кабель'
Assert-Status $a 'ping' 'ok' 'низкий пинг'
$a = Get-NovaNetAdvice -Connection $weak -Results @([pscustomobject]@{ Name = 'Steam'; Stats = [pscustomobject]@{ Median = 120; Jitter = 35.0; Loss = 25 } })
Assert-Status $a 'wifi' 'warn' 'слабый Wi‑Fi'
Assert-Status $a 'ping' 'warn' 'высокий пинг'
Assert-Status $a 'jitter' 'warn' 'пинг скачет'
Assert-Status $a 'loss' 'warn' 'потери'
Assert-Status (Get-NovaNetAdvice -Connection $null -Results @()) 'net' 'stop' 'нет интернета'

# --- DNS: менять, только если заметно быстрее и без потерь; адреса — только настоящие
$prov = @([pscustomobject]@{ Name = 'A'; Servers = @('1.1.1.1'); Stats = [pscustomobject]@{ Median = 12; Loss = 0 } }, [pscustomobject]@{ Name = 'B'; Servers = @('8.8.8.8'); Stats = [pscustomobject]@{ Median = 8; Loss = 40 } })
if ((Select-NovaBetterDns -Current ([pscustomobject]@{ Median = 60; Loss = 0 }) -Providers $prov).Name -ne 'A') { throw 'DNS: не выбран самый быстрый без потерь' }
if ($null -ne (Select-NovaBetterDns -Current ([pscustomobject]@{ Median = 20; Loss = 0 }) -Providers $prov)) { throw 'DNS: предлагает сменить ради 8 мс' }
foreach ($ok in @('1.1.1.1', '77.88.8.8', '2606:4700:4700::1111')) { if (-not (Test-NovaIpAddress $ok)) { throw ('«{0}» не принят как адрес' -f $ok) } }
foreach ($bad in @('1.1.1', '8.8.8.8; calc', 'dns.google', '', '8.8.8.8 ')) { if (Test-NovaIpAddress $bad) { throw ('«{0}» принят как адрес DNS' -f $bad) } }
Write-Host 'ok  DNS: меняем только на заметно более быстрый, адреса проверяются'

# --- Что тормозит: нагрузка по программам из двух снимков
$f = [double][Diagnostics.Stopwatch]::Frequency
$b = [pscustomobject]@{ At = [int64]0; Items = @{
        1 = [pscustomobject]@{ Id = 1; Name = 'chrome'; Cpu = 1000.0; Mem = [int64]500MB; Session = 1 }
        2 = [pscustomobject]@{ Id = 2; Name = 'chrome'; Cpu = 0.0; Mem = [int64]700MB; Session = 1 }
        3 = [pscustomobject]@{ Id = 3; Name = 'game'; Cpu = 0.0; Mem = [int64]3GB; Session = 1 }
        0 = [pscustomobject]@{ Id = 0; Name = 'Idle'; Cpu = 0.0; Mem = [int64]0; Session = 0 } } }
$a2 = [pscustomobject]@{ At = [int64]($f * 2); Items = @{
        1 = [pscustomobject]@{ Id = 1; Name = 'chrome'; Cpu = 2000.0; Mem = [int64]500MB; Session = 1 }
        2 = [pscustomobject]@{ Id = 2; Name = 'chrome'; Cpu = 1000.0; Mem = [int64]700MB; Session = 1 }
        3 = [pscustomobject]@{ Id = 3; Name = 'game'; Cpu = 4000.0; Mem = [int64]3GB; Session = 1 }
        0 = [pscustomobject]@{ Id = 0; Name = 'Idle'; Cpu = 9999.0; Mem = [int64]0; Session = 0 } } }
$groups = @(Get-NovaHeavyList -Before $b -After $a2 -Cores 4)
$chrome = $groups | Where-Object { $_.Key -eq 'chrome' }
$game = $groups | Where-Object { $_.Key -eq 'game' }
if ($groups.Count -ne 2 -or $chrome.Count -ne 2 -or [math]::Round($chrome.Cpu) -ne 25 -or [math]::Round($game.Cpu) -ne 50 -or $chrome.Mem -ne 1200MB) { throw ('нагрузка посчитана неверно: chrome {0}% ×{1}, game {2}%' -f $chrome.Cpu, $chrome.Count, $game.Cpu) }
$top = @(Select-NovaHeavyTop $groups 8)
if ($top[0].Key -ne 'game') { throw 'сверху списка должна быть самая тяжёлая программа' }
$adv = Get-NovaHeavyAdvice -Groups $groups -Memory ([pscustomobject]@{ TotalGB = 8; UsedGB = 7.5; Percent = 94 })
Assert-Status $adv 'mem' 'warn' 'памяти мало'
Write-Host 'ok  нагрузка по программам: вкладки браузера вместе, Idle не считается'

# --- Закрыть можно только своё и не системное
if (-not (Get-NovaCloseProblem -Group ([pscustomobject]@{ Key = 'svchost'; Name = 'svchost'; Ids = @(4) }))) { throw 'svchost можно было бы закрыть' }
if ((Get-NovaCloseProblem -Group ([pscustomobject]@{ Key = 'x'; Name = 'x'; Ids = @($PID) })) -notlike '*самой Nova*') { throw 'Nova закрыла бы сама себя' }
$pingOut = Join-Path $env:TEMP ('nova-ping-' + [guid]::NewGuid() + '.txt')
$probe = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\PING.EXE') -ArgumentList '-n', '300', '127.0.0.1' -NoNewWindow -RedirectStandardOutput $pingOut -PassThru
if ((Get-NovaCloseProblem -Group ([pscustomobject]@{ Key = 'ping'; Name = 'PING'; Ids = @($probe.Id) })) -notlike '*папки Windows*') { throw 'программу из папки Windows можно было бы закрыть' }
$grp = [pscustomobject]@{ Key = 'ping'; Name = 'PING'; Ids = @($probe.Id) }
$left = Close-NovaProcessGroup -Group $grp -WaitSeconds 1
if ($left -ne 1) { throw 'окна нет — по-хорошему не закрывается, а Nova сказала, что закрыла' }
if ((Close-NovaProcessGroup -Group $grp -Force -WaitSeconds 5) -ne 0) { throw 'принудительно не закрылось' }
Remove-Item -LiteralPath $pingOut -Force -ErrorAction SilentlyContinue
Write-Host 'ok  закрыть: части Windows и сама Nova — нельзя; сначала по-хорошему, потом по просьбе — принудительно'

# --- Настоящая нагрузка на этой машине
$snap1 = Get-NovaProcessSnapshot; Start-Sleep -Seconds 1; $snap2 = Get-NovaProcessSnapshot
$real = @(Get-NovaHeavyList -Before $snap1 -After $snap2)
if ($real.Count -lt 10) { throw ('процессов подозрительно мало: {0}' -f $real.Count) }
Write-Host ('ok  снимок нагрузки на этой машине: программ {0}, память {1}%' -f $real.Count, (Get-NovaMemoryLoad).Percent)

# --- Отчёт для поддержки: без имени пользователя, компьютера и почты
$t = Protect-NovaReportText -Text 'C:\Users\Vadim\Desktop vadim@mail.ru VADIM-PC user Vadim' -UserName 'Vadim' -ComputerName 'VADIM-PC' -UserProfile 'C:\Users\Vadim'
if ($t -match 'Vadim|VADIM|mail\.ru') { throw ('в отчёте осталось личное: {0}' -f $t) }
$dir = Join-Path $env:TEMP ('nova-report-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
$logs = Join-Path $dir 'logs'; New-Item -ItemType Directory -Path $logs | Out-Null
[System.IO.File]::WriteAllText((Join-Path $logs 'nova-20261117-120000.log'), ("Запуск от $env:USERNAME на $env:COMPUTERNAME`r`nОшибка: тест"), (New-Object System.Text.UTF8Encoding($false)))
$checks = @((New-NovaCheck 'Антивирус' 'ok' 'Включён.' -Id 'av'))
$r1 = New-NovaSupportReport -Folder $dir -Checks $checks -LogFolder $logs
$r2 = New-NovaSupportReport -Folder $dir -Checks $checks -LogFolder $logs
$text = [System.IO.File]::ReadAllText($r1, [Text.Encoding]::UTF8)
if ($text -notmatch 'Nova — отчёт для поддержки' -or $text -notmatch 'Ошибка: тест' -or $text -notmatch [regex]::Escape((Get-NovaSupportEmail))) { throw 'в отчёте не всё' }
if ($text -match [regex]::Escape($env:USERNAME) -or $text -match [regex]::Escape($env:COMPUTERNAME)) { throw 'в отчёте имя пользователя или компьютера' }
if ($r2 -notlike '*(2).txt') { throw 'второй отчёт затёр бы первый' }
Remove-Item -LiteralPath $dir -Recurse -Force
Write-Host 'ok  отчёт для поддержки: всё нужное есть, имени, компьютера и почты нет, старый не затирается'

# --- Интернет на этой машине
$conn = Get-NovaConnection
if (-not $conn) { throw 'подключение к интернету не найдено' }
$ping = Measure-NovaPing -HostName 'www.google.com' -Samples 3
if ($null -eq $ping.Median) { Write-Host '::warning::google.com did not answer on port 443' } else { Write-Host ('ok  пинг до google.com: {0} мс' -f $ping.Median) }
$dnsSpeed = Measure-NovaDns -Server '1.1.1.1' -Names @('github.com')
Write-Host ('i   DNS 1.1.1.1 отвечает за {0} мс' -f $dnsSpeed.Median)

# --- DNS: сменить и вернуть ровно как было; подменённая копия ничего не меняет
$backupPath = Get-NovaDnsBackupPath
if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
$was = Get-NovaDnsCurrent -Index $conn.Index
Set-NovaDns -Index $conn.Index -Servers @('1.1.1.1', '1.0.0.1')
$now = Get-NovaDnsCurrent -Index $conn.Index
if ($now.Servers[0] -ne '1.1.1.1' -or -not $now.Static) { throw ('DNS не сменился: {0}' -f ($now.Servers -join ', ')) }
Set-NovaDns -Index $conn.Index -Servers @('8.8.8.8')
Restore-NovaDns
$back = Get-NovaDnsCurrent -Index $conn.Index
if (($back.Servers -join ',') -ne ($was.Servers -join ',') -or $back.Static -ne $was.Static) { throw ('DNS не вернулся: было {0} ({1}), стало {2} ({3})' -f ($was.Servers -join ','), $was.Static, ($back.Servers -join ','), $back.Static) }
if (Test-Path -LiteralPath $backupPath) { throw 'копия DNS осталась после возврата' }
$fake = [pscustomobject]@{ index = $conn.Index; guid = $conn.Guid; alias = 'x'; static = $true; servers = @('6.6.6.6; calc') }
[System.IO.File]::WriteAllText($backupPath, ($fake | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
$refused = $false
try { Restore-NovaDns } catch { $refused = $true }
Remove-Item -LiteralPath $backupPath -Force
if (-not $refused) { throw 'подменённая копия DNS принята' }
if (((Get-NovaDnsCurrent -Index $conn.Index).Servers -join ',') -ne ($was.Servers -join ',')) { throw 'подменённая копия поменяла DNS' }
Write-Host 'ok  DNS: смена и возврат ровно как было; подменённая копия не принимается'

Write-Host 'ТЕСТ ПОМОЩНИКОВ ПРОЙДЕН'
