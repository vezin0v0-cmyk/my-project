# Проверка замера FPS без игры: расчёты на искусственных кадрах, где ответ известен заранее.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Nova.psm1') -Force -DisableNameChecking

function Assert-Near {
    param([double]$Actual, [double]$Expected, [string]$What)
    if ([math]::Abs($Actual - $Expected) -gt 0.11) { throw ('{0}: ожидалось {1}, получилось {2}' -f $What, $Expected, $Actual) }
    Write-Host ('ok  {0} = {1}' -f $What, $Actual)
}

# 980 кадров по 10 мс и 20 «фризов» по 50 мс.
$times = @(@(1..980 | ForEach-Object { 10.0 }) + @(1..20 | ForEach-Object { 50.0 }))
$stats = Get-NovaFpsStats $times
Assert-Near $stats.Avg 92.6 'средний FPS'
Assert-Near $stats.Low1 20 '1% low'
Assert-Near $stats.Low01 20 '0.1% low'
if ($stats.Frames -ne 1000) { throw 'неверное число кадров' }
if ($null -ne (Get-NovaFpsStats @(16.6, 16.7))) { throw 'по двум кадрам считать нельзя' }

# CSV PresentMon (v1 и v2): игра выбирается сама, системные окна не считаются.
$dir = Join-Path $env:TEMP ('nova-fps-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
$v1 = New-Object System.Collections.Generic.List[string]
$v1.Add('Application,ProcessID,SwapChainAddress,Runtime,SyncInterval,PresentFlags,Dropped,TimeInSeconds,MsBetweenPresents')
for ($i = 0; $i -lt 600; $i++) { $v1.Add(('game.exe,100,0x1,DXGI,0,0,0,{0},6.944' -f ($i * 0.007))) }
for ($i = 0; $i -lt 900; $i++) { $v1.Add(('dwm.exe,200,0x2,DXGI,1,0,0,{0},4.0' -f ($i * 0.004))) }
for ($i = 0; $i -lt 50; $i++) { $v1.Add('chrome.exe,300,0x3,DXGI,1,0,0,0,16.7') }
$v1Path = Join-Path $dir 'v1.csv'
[System.IO.File]::WriteAllLines($v1Path, $v1)
$byApp = Read-NovaFpsCsv $v1Path
$game = Select-NovaFpsGame $byApp
if ($game -ne 'game.exe') { throw ('выбрана не игра, а {0}' -f $game) }
Assert-Near (Get-NovaFpsStats ([double[]]$byApp[$game].ToArray())).Avg 144 'FPS из CSV v1'

$v2Path = Join-Path $dir 'v2.csv'
$v2 = @('Application,ProcessID,SwapChainAddress,PresentRuntime,SyncInterval,PresentFlags,AllowsTearing,PresentMode,FrameType,CPUStartTime,FrameTime,CPUBusy')
$v2 += @(1..400 | ForEach-Object { 'cs2.exe,1,0x1,DXGI,0,0,1,Hardware: Independent Flip,Application,0,4.0,3.0' })
[System.IO.File]::WriteAllLines($v2Path, $v2)
$byApp2 = Read-NovaFpsCsv $v2Path
Assert-Near (Get-NovaFpsStats ([double[]]$byApp2['cs2.exe'].ToArray())).Avg 250 'FPS из CSV v2'
Remove-Item -LiteralPath $dir -Recurse -Force

# Сравнение: разница внутри разброса — «нет разницы», больше разброса — «лучше» или «хуже».
function New-Run([double]$Avg) { [pscustomobject]@{ avg = $Avg; low1 = $Avg * 0.7; low01 = $Avg * 0.5 } }
$before = @((New-Run 100), (New-Run 101), (New-Run 99))
$cases = @(
    @(@((New-Run 100.5), (New-Run 99.8), (New-Run 101)), 'same'),
    @(@((New-Run 102), (New-Run 102.5), (New-Run 101.5)), 'same'),
    @(@((New-Run 110), (New-Run 111), (New-Run 109)), 'better'),
    @(@((New-Run 90), (New-Run 91), (New-Run 89)), 'worse')
)
foreach ($case in $cases) {
    $cmp = Compare-NovaFps -Before $before -After $case[0]
    if ($cmp.avg.Verdict -ne $case[1]) { throw ('ожидался вердикт {0}, а получился {1}' -f $case[1], $cmp.avg.Verdict) }
    Write-Host ('ok  вердикт {0} при {1:+0.0;-0.0}%' -f $cmp.avg.Verdict, ($cmp.avg.Change * 100))
}
# Большой разброс между замерами «съедает» разницу.
$noisy = @((New-Run 80), (New-Run 120), (New-Run 100))
if ((Compare-NovaFps -Before $noisy -After @((New-Run 110))).avg.Verdict -ne 'same') { throw 'при большом разбросе +10% не должно считаться ускорением' }
Write-Host 'ok  большой разброс не выдаётся за ускорение'

# Отчёт печатается без ошибок.
Clear-NovaFpsRuns
foreach ($r in $before) { Save-NovaFpsRun ([pscustomobject]@{ game = 'test.exe'; label = 'before'; time = 'now'; avg = $r.avg; low1 = $r.low1; low01 = $r.low01; frames = 1000; seconds = 10 }) }
foreach ($r in $cases[2][0]) { Save-NovaFpsRun ([pscustomobject]@{ game = 'test.exe'; label = 'after'; time = 'now'; avg = $r.avg; low1 = $r.low1; low01 = $r.low01; frames = 1000; seconds = 10 }) }
Show-NovaFpsReport -Game 'test.exe'
Clear-NovaFpsRuns

Write-Host 'ТЕСТ ЗАМЕРА FPS ПРОЙДЕН'
