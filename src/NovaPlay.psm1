# NovaPlay.psm1 — режим игры и запуск игр голосом.
# Режим игры — только на время игры: максимальная мощность, без всплывающих уведомлений, обновления Windows
# на паузе, лишние программы закрыты. После игры всё возвращается как было. Если ты сам что-то поменял
# за это время, Nova оставит твоё.
# Игры Nova находит в Steam, Epic Games и Riot и открывает через их же лаунчеры — как ярлык на рабочем столе.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -DisableNameChecking

#region Режим игры

$script:HighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
# Ползунок «Режим питания» (ноутбуки и ПК, где есть только «Сбалансированная»).
$script:OverlayBest = 'ded574b5-45a0-4f42-8737-46345c09c238'
$script:OverlayKnown = @('00000000-0000-0000-0000-000000000000', '961cc777-2547-4f9d-8174-7d86181b8a7a', '3af9b8d9-7c97-431d-ad78-34a8bfea439f', 'ded574b5-45a0-4f42-8737-46345c09c238')
$script:GuidRegex = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:StateKey = 'HKCU\Software\Nova'
$script:StateName = 'GameMode'
# Тот же выключатель, что «Параметры → Система → Уведомления».
$script:ToastKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$script:ToastName = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'
# Те же значения, что пишет кнопка «Приостановить обновления» в Параметрах.
$script:PauseKey = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$script:PauseNames = @('PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime')
$script:PauseTimeRegex = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z'
# Если забыть выключить режим игры, обновления вернутся сами через столько часов.
$script:PauseHours = 12

# Программы, которые часто работают фоном и мешают играм: память, диск, интернет.
# Discord, Steam, Epic и OBS сюда не входят — они нужны во время игры.
$script:BackgroundApps = @(
    @{ Key = 'chrome'; Name = 'Google Chrome' }, @{ Key = 'msedge'; Name = 'Microsoft Edge' }, @{ Key = 'firefox'; Name = 'Firefox' },
    @{ Key = 'opera'; Name = 'Opera' }, @{ Key = 'browser'; Name = 'Яндекс Браузер' }, @{ Key = 'onedrive'; Name = 'OneDrive' },
    @{ Key = 'ms-teams'; Name = 'Teams' }, @{ Key = 'teams'; Name = 'Teams (старый)' }, @{ Key = 'skype'; Name = 'Skype' },
    @{ Key = 'dropbox'; Name = 'Dropbox' }, @{ Key = 'googledrivefs'; Name = 'Google Диск' }, @{ Key = 'yandexdisk2'; Name = 'Яндекс Диск' },
    @{ Key = 'qbittorrent'; Name = 'qBittorrent' }, @{ Key = 'utorrent'; Name = 'uTorrent' }, @{ Key = 'bittorrent'; Name = 'BitTorrent' },
    @{ Key = 'creative cloud'; Name = 'Adobe Creative Cloud' }, @{ Key = 'wallpaper32'; Name = 'Wallpaper Engine' }, @{ Key = 'wallpaper64'; Name = 'Wallpaper Engine' }
)

function Get-NovaUtcText {
    param([datetime]$Time)
    return $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-NovaUtcText {
    param([string]$Text)
    if ($Text -notmatch $script:PauseTimeRegex) { return $null }
    $styles = [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal'
    $time = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Text, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$time)) { return $null }
    return $time
}

# Что записано про режим игры у этого пользователя. Запись мог поменять кто угодно из-под этого пользователя,
# поэтому дальше каждое значение проверяется отдельно.
function Get-NovaGameModeState {
    $v = Get-NovaRegValue -Path $script:StateKey -Name $script:StateName
    if (-not $v.Exists -or $v.Kind -ne 'String') { return $null }
    try { return (ConvertFrom-Json ([string]$v.Value)) } catch { return $null }
}

function Save-NovaGameModeState {
    param($State)
    if ($null -eq $State) { Remove-NovaRegValue -Path $script:StateKey -Name $script:StateName; return }
    Set-NovaRegValue -Path $script:StateKey -Name $script:StateName -Value (ConvertTo-Json -InputObject $State -Compress -Depth 5) -Kind 'String'
}

function Get-NovaPauseBackupPath { return (Join-Path (Join-Path $env:ProgramData 'Nova') 'gamemode-updates.json') }

# Включён ли режим игры (хотя бы его часть).
function Test-NovaGameModeActive {
    return ($null -ne (Get-NovaGameModeState)) -or (Test-Path -LiteralPath (Get-NovaPauseBackupPath) -PathType Leaf)
}

# --- Питание ---

function Initialize-NovaPowerNative {
    if ('NovaNative.PowerOverlay' -as [type]) { return }
    Invoke-NovaAddType -Arguments @{ Namespace = 'NovaNative'; Name = 'PowerOverlay'; MemberDefinition = @'
[DllImport("powrprof.dll")]
public static extern uint PowerGetEffectiveOverlayScheme(out Guid overlay);
[DllImport("powrprof.dll")]
public static extern uint PowerSetActiveOverlayScheme(Guid overlay);
'@ }
}

function Get-NovaPowerOverlay {
    try {
        Initialize-NovaPowerNative
        $guid = [Guid]::Empty
        if ([NovaNative.PowerOverlay]::PowerGetEffectiveOverlayScheme([ref]$guid) -ne 0) { return $null }
        return $guid.ToString()
    } catch {
        return $null
    }
}

function Set-NovaPowerOverlay {
    param([string]$Guid)
    if ($Guid -notmatch $script:GuidRegex -or $script:OverlayKnown -notcontains $Guid) { return $false }
    try {
        Initialize-NovaPowerNative
        return ([NovaNative.PowerOverlay]::PowerSetActiveOverlayScheme([Guid]$Guid) -eq 0)
    } catch {
        return $false
    }
}

# Максимальная мощность: схема «Высокая производительность», а если её нет — ползунок «Максимальная производительность».
# Возвращает, что было до (чтобы вернуть), или строку: 'already' — и так на максимуме, 'unavailable' — нечем.
function Set-NovaGamePower {
    $active = Get-NovaActivePowerScheme
    if ($active -eq $script:HighPerformance -or $active -eq 'e9a42b02-d5df-448d-aa00-03f14749eb61') { return 'already' }
    if ($active -and (Test-NovaPowerSchemeExists $script:HighPerformance)) {
        $r = Invoke-NovaNative (Get-NovaSystemTool 'powercfg.exe') @('/setactive', $script:HighPerformance)
        if ($r.Code -eq 0) { return [pscustomobject]@{ kind = 'scheme'; before = $active; set = $script:HighPerformance } }
    }
    $overlay = Get-NovaPowerOverlay
    if ($overlay -eq $script:OverlayBest) { return 'already' }
    if ($overlay -and (Set-NovaPowerOverlay $script:OverlayBest)) {
        return [pscustomobject]@{ kind = 'overlay'; before = $overlay; set = $script:OverlayBest }
    }
    return 'unavailable'
}

# Возвращает 'restored', 'kept' (ты сам сменил питание — оставляем) или 'failed'.
function Restore-NovaGamePower {
    param($Power)
    $kind = [string](Get-NovaProp $Power 'kind' '')
    $before = ([string](Get-NovaProp $Power 'before' '')).ToLowerInvariant()
    $set = ([string](Get-NovaProp $Power 'set' '')).ToLowerInvariant()
    if ($before -notmatch $script:GuidRegex -or $set -notmatch $script:GuidRegex) { return 'failed' }
    if ($kind -eq 'scheme') {
        if ((Get-NovaActivePowerScheme) -ne $set) { return 'kept' }
        if (-not (Test-NovaPowerSchemeExists $before)) { return 'failed' }
        $r = Invoke-NovaNative (Get-NovaSystemTool 'powercfg.exe') @('/setactive', $before)
        if ($r.Code -eq 0) { return 'restored' }
        return 'failed'
    }
    if ($kind -eq 'overlay') {
        if ((Get-NovaPowerOverlay) -ne $set) { return 'kept' }
        if (Set-NovaPowerOverlay $before) { return 'restored' }
    }
    return 'failed'
}

# --- Уведомления ---

# Как Windows сейчас относится к уведомлениям: 'Enabled', 'DisabledForUser' (выключены все) и т. п. $null — не узнать.
function Get-NovaToastSetting {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        return [string][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Setting
    } catch {
        return $null
    }
}

# Служба уведомлений этого пользователя перечитывает выключатель после перезапуска. Нужны права администратора;
# чужие службы (других пользователей компьютера) не трогаем.
function Restart-NovaToastService {
    if (-not (Test-NovaAdmin)) { return $false }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $restarted = $false
    foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'WpnUserService[_]%' AND State = 'Running'" -ErrorAction SilentlyContinue)) {
        $proc = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f [int]$svc.ProcessId) -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction SilentlyContinue
        if (-not $owner -or $owner.Sid -ne $me) { continue }
        try { Restart-Service -Name $svc.Name -Force -ErrorAction Stop; $restarted = $true } catch { Write-Verbose ('Служба уведомлений: {0}' -f $_.Exception.Message) }
    }
    return $restarted
}

# Выключает всплывающие уведомления. Возвращает, как было (чтобы вернуть), или $null, если они и так выключены.
function Set-NovaGameToasts {
    $now = Get-NovaRegValue -Path $script:ToastKey -Name $script:ToastName
    $value = $null
    if ($now.Exists) {
        try { $value = [int]$now.Value } catch { $value = 1 }
        if ($value -eq 0) { return $null }
        if ($value -ne 1) { $value = 1 }
    }
    Set-NovaRegValue -Path $script:ToastKey -Name $script:ToastName -Value 0 -Kind 'DWord'
    $applied = (Get-NovaToastSetting) -eq 'DisabledForUser'
    if (-not $applied -and (Restart-NovaToastService)) { $applied = (Get-NovaToastSetting) -eq 'DisabledForUser' }
    return [pscustomobject]@{ exists = [bool]$now.Exists; value = $value; applied = $applied }
}

function Restore-NovaGameToasts {
    param($Toasts)
    $now = Get-NovaRegValue -Path $script:ToastKey -Name $script:ToastName
    if (-not $now.Exists) { return 'kept' }
    try { if ([int]$now.Value -ne 0) { return 'kept' } } catch { return 'kept' }
    if ([bool](Get-NovaProp $Toasts 'exists' $false)) {
        Set-NovaRegValue -Path $script:ToastKey -Name $script:ToastName -Value 1 -Kind 'DWord'
    } else {
        Remove-NovaRegValue -Path $script:ToastKey -Name $script:ToastName
    }
    if ((Get-NovaToastSetting) -eq 'DisabledForUser') { [void](Restart-NovaToastService) }
    return 'restored'
}

# --- Обновления Windows ---

# Пауза обновлений до конца игры (но не дольше 12 часов). Нужны права администратора.
# Если обновления уже на паузе дольше — не трогаем. Возвращает $true, если поставили паузу.
function Set-NovaGameUpdatesPause {
    param([datetime]$Now = (Get-Date), [int]$Hours = $script:PauseHours)
    # Сначала — папка данных Nova: если её создал кто-то другой, Nova отложит её и начнёт с чистой.
    [void](Get-NovaDataDir)
    $backupPath = Get-NovaPauseBackupPath
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) { return $false }
    $until = $Now.ToUniversalTime().AddHours($Hours)
    $current = Get-NovaRegValue -Path $script:PauseKey -Name 'PauseUpdatesExpiryTime'
    if ($current.Exists) {
        $t = ConvertFrom-NovaUtcText ([string]$current.Value)
        if ($t -and $t -ge $until) { return $false }
    }
    $before = [ordered]@{}
    foreach ($name in $script:PauseNames) {
        $v = Get-NovaRegValue -Path $script:PauseKey -Name $name
        $before[$name] = [ordered]@{ exists = [bool]($v.Exists -and $v.Kind -eq 'String'); value = [string]$v.Value }
    }
    $start = Get-NovaUtcText $Now
    $end = Get-NovaUtcText $until
    $doc = [ordered]@{ created = $start; set = $end; before = $before }
    Write-NovaNewFile -Path $backupPath -Bytes ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $doc -Depth 5)))
    foreach ($name in $script:PauseNames) {
        $value = $end
        if ($name -like '*StartTime') { $value = $start }
        Set-NovaRegValue -Path $script:PauseKey -Name $name -Value $value -Kind 'String'
    }
    return $true
}

# Снимает паузу: возвращает значения, которые были до режима игры. 'restored', 'kept', 'none' или 'failed'.
function Restore-NovaGameUpdatesPause {
    $backupPath = Get-NovaPauseBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { return 'none' }
    if (-not (Test-NovaAdmin)) { return 'failed' }
    # Файл — в папке Nova, куда пишут только администраторы (это проверяется здесь же). И всё равно каждое значение проверяем.
    [void](Get-NovaDataDir)
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { return 'none' }
    $doc = $null
    try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($backupPath, [Text.Encoding]::UTF8)) } catch { $doc = $null }
    $result = 'restored'
    $set = [string](Get-NovaProp $doc 'set' '')
    $current = Get-NovaRegValue -Path $script:PauseKey -Name 'PauseUpdatesExpiryTime'
    if ($null -eq $doc -or $set -notmatch $script:PauseTimeRegex) {
        $result = 'failed'
    } elseif (-not $current.Exists -or [string]$current.Value -ne $set) {
        # Паузу поменял ты сам (в Параметрах) — оставляем твою.
        $result = 'kept'
    } else {
        $before = Get-NovaProp $doc 'before'
        foreach ($name in $script:PauseNames) {
            $entry = Get-NovaProp $before $name
            $value = [string](Get-NovaProp $entry 'value' '')
            if ([bool](Get-NovaProp $entry 'exists' $false) -and $value -match $script:PauseTimeRegex) {
                Set-NovaRegValue -Path $script:PauseKey -Name $name -Value $value -Kind 'String'
            } else {
                Remove-NovaRegValue -Path $script:PauseKey -Name $name
            }
        }
    }
    [IO.File]::Delete($backupPath)
    return $result
}

# --- Фоновые программы ---

# Какие из «фоновых» программ сейчас открыты у тебя. Формат — как у «Что тормозит»: Name, Key, Ids, Mem.
function Get-NovaBackgroundApps {
    $session = (Get-Process -Id $PID).SessionId
    $found = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($app in $script:BackgroundApps) {
        $procs = @(Get-Process -Name $app.Key -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
        if ($procs.Count -eq 0 -or $seen.ContainsKey($app.Key)) { continue }
        $seen[$app.Key] = $true
        $ids = New-Object System.Collections.Generic.List[int]
        $mem = [int64]0
        $path = ''
        foreach ($p in $procs) {
            $ids.Add([int]$p.Id)
            $mem += [int64]$p.WorkingSet64
            if (-not $path) { try { $path = [string]$p.Path } catch { $path = '' } }
        }
        $found.Add([pscustomobject]@{ Name = $app.Name; Key = $app.Key; Ids = $ids; Mem = $mem; Count = $ids.Count; Path = $path })
    }
    return $found.ToArray()
}

# Программу, закрытую на время игры, можно открыть снова. Путь берём из записи пользователя,
# поэтому принимаем только обычный .exe на этом компьютере — и открываем его от имени пользователя.
function Test-NovaReopenPath {
    param([string]$Path)
    if (-not $Path -or $Path.Length -gt 260 -or $Path -match '[\p{Cc}\p{Cf}"<>|*?%]') { return $false }
    if ($Path -notmatch '^[A-Za-z]:\\.+\.exe\z' -or $Path -match '(^|\\)\.{1,2}(\\|\z)' -or $Path.IndexOf(':', 2) -ge 0) { return $false }
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

# --- Всё вместе ---

# Включает режим игры. -Updates — ещё и пауза обновлений (только с правами администратора).
# -Toasts:$false — не трогать уведомления (например, если Nova открыта другим пользователем, а не тем, кто играет).
function Start-NovaGameMode {
    param([switch]$Updates, [bool]$Toasts = $true, [object[]]$ClosedApps = @())
    $old = Get-NovaGameModeState
    $state = [ordered]@{ started = (Get-NovaUtcText (Get-Date)); power = $null; toasts = $null; apps = @() }
    if ($old) { foreach ($k in @('started', 'power', 'toasts', 'apps')) { $v = Get-NovaProp $old $k; if ($null -ne $v) { $state[$k] = $v } } }
    $result = [ordered]@{ Power = 'already'; Toasts = 'skip'; ToastsApplied = $true; Updates = 'skip' }
    if ($null -eq $state['power']) {
        $power = Set-NovaGamePower
        if ($power -is [string]) { $result.Power = $power } else { $state['power'] = $power; $result.Power = 'set' }
    } else { $result.Power = 'set' }
    if ($Toasts) {
        if ($null -eq $state['toasts']) {
            $t = Set-NovaGameToasts
            if ($t) { $state['toasts'] = $t; $result.Toasts = 'set'; $result.ToastsApplied = [bool]$t.applied } else { $result.Toasts = 'already' }
        } else { $result.Toasts = 'set' }
    }
    if ($Updates -and (Test-NovaAdmin)) {
        if (Set-NovaGameUpdatesPause) { $result.Updates = 'set' } elseif (Test-Path -LiteralPath (Get-NovaPauseBackupPath)) { $result.Updates = 'set' } else { $result.Updates = 'already' }
    }
    $apps = @(@($state['apps']) + @($ClosedApps) | Where-Object { $_ -and (Test-NovaReopenPath ([string](Get-NovaProp $_ 'path' ''))) })
    $state['apps'] = @($apps | Select-Object -First 20)
    Save-NovaGameModeState $state
    return [pscustomobject]$result
}

# Выключает режим игры: возвращает питание, уведомления и обновления. Программы снова не открывает —
# это решает человек (Reopen — список того, что было закрыто).
function Stop-NovaGameMode {
    $state = Get-NovaGameModeState
    $result = [ordered]@{ Power = 'none'; Toasts = 'none'; Updates = 'none'; Reopen = @() }
    if ($state) {
        $power = Get-NovaProp $state 'power'
        if ($power) { $result.Power = Restore-NovaGamePower $power }
        $toasts = Get-NovaProp $state 'toasts'
        if ($toasts) { $result.Toasts = Restore-NovaGameToasts $toasts }
        $result.Reopen = @(@(Get-NovaProp $state 'apps' @()) | Where-Object { $_ -and (Test-NovaReopenPath ([string](Get-NovaProp $_ 'path' ''))) })
        Save-NovaGameModeState $null
    }
    if (Test-Path -LiteralPath (Get-NovaPauseBackupPath) -PathType Leaf) {
        if (Test-NovaAdmin) { $result.Updates = Restore-NovaGameUpdatesPause } else { $result.Updates = 'waiting' }
    }
    return [pscustomobject]$result
}

# Короткий ответ для голоса и окна.
function Get-NovaGameModeText {
    param($Result, [switch]$Off)
    if ($Off) {
        $parts = @()
        if ($Result.Power -eq 'restored') { $parts += 'питание как было' } elseif ($Result.Power -eq 'kept') { $parts += 'питание ты поменял сам — оставила' }
        if ($Result.Toasts -eq 'restored') { $parts += 'уведомления включены' }
        if ($Result.Updates -eq 'restored') { $parts += 'обновления снова идут' }
        if ($Result.Updates -eq 'waiting') { $parts += ('обновления вернутся сами через несколько часов или в меню Nova, пункт 16') }
        if ($parts.Count -eq 0) { return 'режим игры выключен' }
        return ('режим игры выключен: {0}' -f ($parts -join ', '))
    }
    $parts = @()
    if ($Result.Power -eq 'set') { $parts += 'максимальная мощность' } elseif ($Result.Power -eq 'already') { $parts += 'питание и так на максимуме' }
    if ($Result.Toasts -eq 'set' -or $Result.Toasts -eq 'already') { $parts += 'уведомления выключены' }
    if ($Result.Updates -eq 'set' -or $Result.Updates -eq 'already') { $parts += 'обновления на паузе' }
    return ('режим игры включён: {0}' -f ($parts -join ', '))
}

#endregion

#region Игры: Steam, Epic Games, Riot

# Как игры называют вслух. Фразы со словами, которых нет в словаре голосовой модели, Nova Голос сама
# пропустит, поэтому вариантов несколько. Название — регулярное выражение по имени игры в лаунчере.
$script:GameWords = @(
    @{ Match = '^Counter-Strike 2$|^Counter-Strike: Global Offensive$'; Words = @('контру', 'контра', 'кс', 'контр страйк') }
    @{ Match = '^Dota 2$'; Words = @('доту', 'дота', 'дотку') }
    @{ Match = '^PUBG'; Words = @('пабджи') }
    @{ Match = '^Grand Theft Auto V'; Words = @('гта', 'гта пять') }
    @{ Match = '^Apex Legends'; Words = @('апекс') }
    @{ Match = '^Rust$'; Words = @('раст') }
    @{ Match = '^Valheim$'; Words = @('викингов') }
    @{ Match = '^The Sims'; Words = @('симс') }
    @{ Match = '^Cyberpunk 2077'; Words = @('киберпанк') }
    @{ Match = '^The Witcher 3'; Words = @('ведьмака', 'ведьмак') }
    @{ Match = '^War Thunder$'; Words = @('тундру', 'вар тандер') }
    @{ Match = '^Battlefield'; Words = @('поле боя') }
    @{ Match = '^ELDEN RING'; Words = @('кольцо') }
    @{ Match = "^Tom Clancy's Rainbow Six"; Words = @('радугу', 'радуга', 'осаду') }
    @{ Match = '^Rocket League'; Words = @('рокет лигу', 'рокет') }
    @{ Match = '^Destiny 2'; Words = @('дестини', 'судьбу') }
    @{ Match = '^Call of Duty'; Words = @('кол оф дьюти') }
    @{ Match = '^Phasmophobia'; Words = @('призраков') }
    @{ Match = '^Marvel Rivals'; Words = @('марвел') }
    @{ Match = '^Lost Ark'; Words = @('лост арк') }
    @{ Match = '^The Elder Scrolls V: Skyrim'; Words = @('скайрим') }
    @{ Match = '^Fallout'; Words = @('фоллаут', 'фаллаут') }
    @{ Match = '^Red Dead Redemption 2'; Words = @('ред дед', 'рдр') }
    @{ Match = '^Hunt: Showdown'; Words = @('хант', 'охоту') }
    @{ Match = '^THE FINALS'; Words = @('финал') }
    @{ Match = '^Project Zomboid'; Words = @('зомби') }
    @{ Match = '^ARK: Survival'; Words = @('арк', 'ковчег') }
    @{ Match = '^Hearts of Iron IV'; Words = @('сердца железа') }
    @{ Match = "^Sid Meier's Civilization"; Words = @('цивилизацию') }
    @{ Match = '^Fortnite$'; Words = @('фортнайт') }
    @{ Match = '^VALORANT$'; Words = @('валик') }
    @{ Match = '^League of Legends$'; Words = @('лигу легенд', 'лол') }
    @{ Match = '^Euro Truck Simulator 2'; Words = @('дальнобойщиков', 'фуры', 'евро трак') }
    @{ Match = '^Dead by Daylight'; Words = @('маньяка', 'дед бай') }
    @{ Match = "^Garry's Mod"; Words = @('гаррис мод') }
    @{ Match = '^Stardew Valley'; Words = @('ферму') }
    @{ Match = '^Lethal Company'; Words = @('летал компани') }
    @{ Match = '^Path of Exile'; Words = @('путь изгнанника') }
    @{ Match = '^World of Tanks'; Words = @('танки', 'танчики') }
    @{ Match = '^World of Warships'; Words = @('корабли', 'кораблики') }
    @{ Match = '^S\.T\.A\.L\.K\.E\.R\.'; Words = @('сталкер', 'сталкера') }
    @{ Match = '^Metro'; Words = @('метро') }
    @{ Match = '^Mafia'; Words = @('мафию') }
    @{ Match = '^Deep Rock Galactic'; Words = @('дип рок', 'гномов') }
    @{ Match = '^Left 4 Dead 2'; Words = @('лефт фор дед') }
    @{ Match = '^Portal 2'; Words = @('портал') }
    @{ Match = '^Geometry Dash'; Words = @('геометрию') }
    @{ Match = '^Forza Horizon'; Words = @('горизонт') }
    @{ Match = '^Need for Speed'; Words = @('нфс', 'нид фор спид') }
    @{ Match = '^DayZ$'; Words = @('дейзи', 'дэйзи') }
    @{ Match = '^Squad$'; Words = @('сквад', 'отряд') }
    @{ Match = '^Black Myth: Wukong'; Words = @('обезьяну') }
    @{ Match = '^Hogwarts Legacy'; Words = @('хогвартс') }
    @{ Match = '^Hollow Knight'; Words = @('холлоу найт', 'рыцаря') }
    @{ Match = '^Cities: Skylines'; Words = @('города') }
    @{ Match = '^Factorio'; Words = @('фабрику') }
    @{ Match = '^The Forest$|^Sons Of The Forest'; Words = @('лес', 'форест') }
    @{ Match = '^7 Days to Die'; Words = @('семь дней') }
    @{ Match = '^Raft$'; Words = @('плот') }
    @{ Match = '^Resident Evil'; Words = @('резидент') }
    @{ Match = "^Assassin's Creed"; Words = @('ассасина', 'ассасин') }
    @{ Match = '^Far Cry'; Words = @('фар край') }
    @{ Match = '^Mount & Blade'; Words = @('маунт') }
    @{ Match = '^Kingdom Come'; Words = @('кингдом', 'королевство') }
    @{ Match = '^Atomic Heart'; Words = @('атомное сердце') }
    @{ Match = '^Detroit: Become Human'; Words = @('детройт') }
)
# Служебное Steam — не игры.
$script:SteamSkip = '^(Steamworks Common Redistributables|Steam Linux Runtime|Proton|SteamVR|Steam Controller Configs|Spacewar)'

function Get-NovaGameWordList { return $script:GameWords }

function Get-NovaGameWords {
    param([string]$Name)
    foreach ($entry in $script:GameWords) {
        if ($Name -match $entry.Match) { return @($entry.Words) }
    }
    return @()
}

# Текст из файла лаунчера — для показа: без управляющих символов и не длиннее 80 знаков.
function Get-NovaGameName {
    param([string]$Name)
    $n = (([string]$Name -replace '[\p{Cc}\p{Cf}]', '') -replace '\s+', ' ').Trim()
    if ($n.Length -gt 80) { $n = $n.Substring(0, 79) + '…' }
    return $n
}

function New-NovaGame {
    param([string]$Name, [string]$Store, [string]$Id, [string]$Uri = '', [string]$Exe = '', [string]$Arguments = '', [long]$LastPlayed = 0, [string]$Manifest = '')
    $clean = Get-NovaGameName $Name
    return [pscustomobject]@{ Name = $clean; Store = $Store; Id = $Id; Uri = $Uri; Exe = $Exe; Arguments = $Arguments; LastPlayed = $LastPlayed; Manifest = $Manifest; Words = @(Get-NovaGameWords $clean) }
}

# Небольшой текстовый файл лаунчера (не больше MaxBytes) — или $null.
function Read-NovaSmallText {
    param([string]$Path, [int]$MaxBytes = 262144)
    try {
        $info = New-Object System.IO.FileInfo($Path)
        if (-not $info.Exists -or $info.Length -gt $MaxBytes) { return $null }
        return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    } catch {
        return $null
    }
}

# Значение «"ключ"  "значение"» из файла Steam (.acf, .vdf). Обратные косые в Steam удвоены.
function Get-NovaVdfValue {
    param([string]$Text, [string]$Key)
    $m = [regex]::Match([string]$Text, ('(?m)^\s*"{0}"\s+"((?:[^"\\]|\\.)*)"' -f [regex]::Escape($Key)), 'IgnoreCase')
    if (-not $m.Success) { return $null }
    return ($m.Groups[1].Value -replace '\\\\', '\')
}

function Get-NovaSteamPath {
    foreach ($place in @(@('HKCU\Software\Valve\Steam', 'SteamPath'), @('HKLM\SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'), @('HKLM\SOFTWARE\Valve\Steam', 'InstallPath'))) {
        $v = Get-NovaRegValue -Path $place[0] -Name $place[1]
        if ($v.Exists -and [string]$v.Value) {
            $path = ([string]$v.Value) -replace '/', '\'
            if ($path -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $path -PathType Container)) { return $path.TrimEnd('\') }
        }
    }
    return $null
}

# Игры Steam: папки библиотек из libraryfolders.vdf, в каждой — appmanifest_<номер>.acf.
function Get-NovaSteamGames {
    param([string]$SteamPath = (Get-NovaSteamPath))
    if (-not $SteamPath) { return @() }
    $libraries = New-Object System.Collections.Generic.List[string]
    $libraries.Add($SteamPath)
    foreach ($vdf in @((Join-Path $SteamPath 'steamapps\libraryfolders.vdf'), (Join-Path $SteamPath 'config\libraryfolders.vdf'))) {
        $text = Read-NovaSmallText $vdf
        if (-not $text) { continue }
        foreach ($m in [regex]::Matches($text, '(?m)^\s*"(?:path|\d+)"\s+"((?:[^"\\]|\\.)*)"')) {
            $p = ($m.Groups[1].Value -replace '\\\\', '\').TrimEnd('\')
            if ($p -match '^[A-Za-z]:\\' -and -not ($libraries -contains $p)) { $libraries.Add($p) }
        }
    }
    $games = New-Object System.Collections.Generic.List[object]
    $ids = @{}
    foreach ($lib in $libraries) {
        $apps = Join-Path $lib 'steamapps'
        if (-not (Test-Path -LiteralPath $apps -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue | Select-Object -First 500)) {
            $text = Read-NovaSmallText $file.FullName 65536
            if (-not $text) { continue }
            $id = Get-NovaVdfValue $text 'appid'
            $name = Get-NovaVdfValue $text 'name'
            $flags = 0
            [void][int]::TryParse([string](Get-NovaVdfValue $text 'StateFlags'), [ref]$flags)
            if ($id -notmatch '^\d{1,10}\z' -or -not $name -or $ids.ContainsKey($id)) { continue }
            # 4 — игра полностью установлена.
            if (($flags -band 4) -eq 0 -or $id -eq '228980' -or $name -match $script:SteamSkip) { continue }
            $last = 0L
            [void][long]::TryParse([string](Get-NovaVdfValue $text 'LastPlayed'), [ref]$last)
            $ids[$id] = $true
            $games.Add((New-NovaGame -Name $name -Store 'Steam' -Id $id -Uri ('steam://rungameid/{0}' -f $id) -LastPlayed $last -Manifest $file.FullName))
        }
    }
    return $games.ToArray()
}

# Игры Epic Games: файлы *.item в папке лаунчера (JSON).
function Get-NovaEpicGames {
    param([string]$ManifestDir = (Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'))
    if (-not $ManifestDir -or -not (Test-Path -LiteralPath $ManifestDir -PathType Container)) { return @() }
    $games = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $ManifestDir -Filter '*.item' -File -ErrorAction SilentlyContinue | Select-Object -First 300)) {
        $text = Read-NovaSmallText $file.FullName 1048576
        if (-not $text) { continue }
        $doc = $null
        try { $doc = ConvertFrom-Json $text } catch { continue }
        $name = [string](Get-NovaProp $doc 'DisplayName' '')
        $app = [string](Get-NovaProp $doc 'AppName' '')
        $ns = [string](Get-NovaProp $doc 'CatalogNamespace' '')
        $item = [string](Get-NovaProp $doc 'CatalogItemId' '')
        $main = [string](Get-NovaProp $doc 'MainGameAppName' $app)
        $categories = @(Get-NovaProp $doc 'AppCategories' @())
        if (-not $name -or $app -notmatch '^[A-Za-z0-9_.-]{1,100}\z' -or $ns -notmatch '^[A-Za-z0-9]{1,64}\z' -or $item -notmatch '^[A-Za-z0-9]{1,64}\z') { continue }
        if ([bool](Get-NovaProp $doc 'bIsIncompleteInstall' $false) -or ($main -and $main -ne $app)) { continue }
        if ($categories.Count -gt 0 -and $categories -notcontains 'games') { continue }
        $uri = 'com.epicgames.launcher://apps/{0}%3A{1}%3A{2}?action=launch&silent=true' -f $ns, $item, $app
        $games.Add((New-NovaGame -Name $name -Store 'Epic' -Id $app -Uri $uri))
    }
    return $games.ToArray()
}

# Riot Client и его игры (Valorant, League of Legends). Где лежит клиент — из файла самого Riot.
function Get-NovaRiotGames {
    param([string]$RiotData = (Join-Path $env:ProgramData 'Riot Games'))
    if (-not $RiotData -or -not (Test-Path -LiteralPath $RiotData -PathType Container)) { return @() }
    $doc = $null
    try { $doc = ConvertFrom-Json (Read-NovaSmallText (Join-Path $RiotData 'RiotClientInstalls.json') 65536) } catch { $doc = $null }
    $exe = ''
    foreach ($key in @('rc_default', 'rc_live')) {
        $p = ([string](Get-NovaProp $doc $key '')) -replace '/', '\'
        if ((Get-NovaRiotExeProblem $p) -eq '') { $exe = $p; break }
    }
    if (-not $exe) { return @() }
    $games = New-Object System.Collections.Generic.List[object]
    foreach ($product in @(@('valorant', 'VALORANT'), @('league_of_legends', 'League of Legends'))) {
        if (-not (Test-Path -LiteralPath (Join-Path $RiotData ('Metadata\{0}.live' -f $product[0])) -PathType Container)) { continue }
        $games.Add((New-NovaGame -Name $product[1] -Store 'Riot' -Id $product[0] -Exe $exe -Arguments ('--launch-product={0} --launch-patchline=live' -f $product[0])))
    }
    return $games.ToArray()
}

function Get-NovaRiotExeProblem {
    param([string]$Path)
    if (-not $Path -or $Path.Length -gt 260 -or $Path -match '[\p{Cc}\p{Cf}"<>|*?%~]') { return 'непонятный путь' }
    if ($Path -notmatch '^[A-Za-z]:\\.+\\RiotClientServices\.exe\z' -or $Path -match '(^|\\)\.{1,2}(\\|\z)' -or $Path.IndexOf(':', 2) -ge 0) { return 'это не Riot Client' }
    try {
        if ((New-Object System.IO.DriveInfo($Path.Substring(0, 1))).DriveType -eq [System.IO.DriveType]::Network) { return 'сетевой диск' }
    } catch { return 'нет такого диска' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'файла нет' }
    return ''
}

# Все найденные игры. Ошибка в одном лаунчере не мешает остальным.
function Get-NovaGames {
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($finder in @('Get-NovaSteamGames', 'Get-NovaEpicGames', 'Get-NovaRiotGames')) {
        try { foreach ($g in @(& $finder)) { $all.Add($g) } } catch { Write-Verbose ('{0}: {1}' -f $finder, $_.Exception.Message) }
    }
    return @($all.ToArray() | Sort-Object Name)
}

# Последняя игра, в которую играли (Steam помнит время). Время перечитываем — оно меняется, пока голос открыт.
function Get-NovaLastGame {
    param([object[]]$Games)
    $best = $null
    $bestTime = 0L
    foreach ($g in @($Games | Where-Object { $_.Store -eq 'Steam' })) {
        $time = [long]$g.LastPlayed
        if ($g.Manifest) {
            $text = Read-NovaSmallText $g.Manifest 65536
            $t = 0L
            if ($text -and [long]::TryParse([string](Get-NovaVdfValue $text 'LastPlayed'), [ref]$t)) { $time = $t }
        }
        if ($time -gt $bestTime) { $best = $g; $bestTime = $time }
    }
    return $best
}

# Можно ли запускать: только ссылки лаунчеров строго известного вида и сам Riot Client с его параметрами.
function Get-NovaGameLaunchProblem {
    param($Game)
    $uri = [string](Get-NovaProp $Game 'Uri' '')
    $exe = [string](Get-NovaProp $Game 'Exe' '')
    if ($uri) {
        if ($uri -match '^steam://rungameid/\d{1,10}\z') { return '' }
        if ($uri -match '^com\.epicgames\.launcher://apps/[A-Za-z0-9]{1,64}%3A[A-Za-z0-9]{1,64}%3A[A-Za-z0-9_.-]{1,100}\?action=launch&silent=true\z') { return '' }
        return 'непонятная ссылка на игру'
    }
    if ($exe) {
        $why = Get-NovaRiotExeProblem $exe
        if ($why) { return ('Riot Client: {0}' -f $why) }
        if ([string](Get-NovaProp $Game 'Arguments' '') -notmatch '^--launch-product=(valorant|league_of_legends) --launch-patchline=live\z') { return 'непонятные параметры запуска' }
        return ''
    }
    return 'не знаю, как запустить эту игру'
}

# Запускает игру как обычный ярлык. -AsUser — из Nova с правами администратора: через Проводник,
# чтобы игра и лаунчер не получили права администратора.
function Start-NovaGame {
    param([Parameter(Mandatory)]$Game, [switch]$AsUser)
    $why = Get-NovaGameLaunchProblem $Game
    if ($why) { throw $why }
    if ($Game.Uri) {
        if ($AsUser) {
            if (-not (Start-NovaAsUser $Game.Uri)) { throw 'Проводник не запущен — открой игру сам.' }
            return
        }
        Start-Process -FilePath $Game.Uri
        return
    }
    if ($AsUser) { throw 'Riot-игры открой сам — из Nova с правами администратора их не запускаю.' }
    Start-Process -FilePath $Game.Exe -ArgumentList $Game.Arguments
}

#endregion

Export-ModuleMember -Function *
