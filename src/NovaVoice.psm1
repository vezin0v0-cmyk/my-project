# NovaVoice.psm1 — голосовые команды Nova: «Нова, сверни все окна».
# Речь распознаёт Vosk прямо на компьютере, без интернета: звук никуда не отправляется и не сохраняется.
# Работает в Windows PowerShell 5.1.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -DisableNameChecking

# Движок Vosk (Apache 2.0) и русская модель. Версии и контрольные суммы закреплены:
# скачанный файл должен совпасть байт в байт, иначе Nova его удалит.
$script:Vosk = @{
    EngineUrl    = 'https://github.com/alphacep/vosk-api/releases/download/v0.3.45/vosk-win64-0.3.45.zip'
    EngineSha256 = 'F1DCC9CCA460630F81EA8F71794F69C80BED6556D2A4E6237B5785E1D2DFF34B'
    ModelUrl     = 'https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip'
    ModelSha256  = '961D5FF98A17F4AA6DE69864D0AA71FA5BAC682301D2B5D17A3F24C5C99A46D4'
    ModelName    = 'vosk-model-small-ru-0.22'
    # Файлы движка из архива выше. Сверяются перед каждым запуском: подменённую DLL Nova не загрузит.
    Dlls         = @{
        'libvosk.dll'         = '9331C2F6A32CF77141AF27C9750E79532718F51BBC2E3CEA3C60F14CA4251E4E'
        'libstdc++-6.dll'     = 'A1D96A848A567D7657E152CFE92E2FD62DA412968CC11EC8BDB04BF20EBC5747'
        'libgcc_s_seh-1.dll'  = '201BF8A54EBB490F93EA4BEB20740A483BF67036B90B5720F32D0C746A72D1E9'
        'libwinpthread-1.dll' = '92CAEB8A4EA281C674003462A233F3B445B685B0A6F93EB11254FEDA2DDA9CDE'
    }
}
$script:VoiceActions = @('shutdown', 'restart', 'cancel', 'minimizeAll', 'restoreAll', 'closeWindow', 'closeAll', 'lock', 'volumeUp', 'volumeDown', 'mute')
$script:Pending = $null

# Папка движка — личная: другие пользователи компьютера не могут туда ничего подложить.
# Путь нужен только латиницей (Vosk не открывает файлы по пути с русскими буквами), поэтому, если
# в имени пользователя есть кириллица, берём C:\ProgramData\NovaVoice-<SID> и закрываем её от остальных.
function Get-NovaVoiceDir {
    if ($env:LOCALAPPDATA -match '^[\x20-\x7E]+$') { return (Join-Path $env:LOCALAPPDATA 'NovaVoice') }
    return (Join-Path $env:ProgramData ('NovaVoice-{0}' -f [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
}

# Создаёт папку движка закрытой (менять может только этот пользователь, администраторы и система)
# и проверяет, что её никто не захватил заранее.
function Initialize-NovaVoiceDir {
    $dir = Get-NovaVoiceDir
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $trusted = @($me.Value, 'S-1-5-32-544', 'S-1-5-18')
    if (-not (Test-Path -LiteralPath $dir)) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetOwner($me)
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach ($sid in $trusted) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($sid)), 'FullControl', $inherit, 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        [void][System.IO.Directory]::CreateDirectory($dir, $acl)
    }
    $problem = Get-NovaTreeProblem -Path $dir -Trusted $trusted
    if ($problem) { throw ('Папку движка голоса может менять кто-то ещё ({0}). Удали папку {1} и запусти снова.' -f $problem, $dir) }
    return $dir
}

# Проверяет файлы движка: ровно те DLL, что в оригинальном архиве, байт в байт.
function Test-NovaVoiceDll {
    $engine = Join-Path (Get-NovaVoiceDir) 'engine'
    if (-not (Test-Path -LiteralPath $engine)) { return $false }
    $dlls = @(Get-ChildItem -LiteralPath $engine -Recurse -Force -File -Filter '*.dll' -ErrorAction SilentlyContinue)
    if ($dlls.Count -ne $script:Vosk.Dlls.Count) { return $false }
    foreach ($dll in $dlls) {
        $expected = $script:Vosk.Dlls[$dll.Name]
        if (-not $expected -or (Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash -ne $expected) { return $false }
        if ($dll.DirectoryName -ne (Split-Path -Parent (Get-NovaVoiceEngineDll))) { return $false }
    }
    return $true
}

function Get-NovaVoiceEngineDll {
    $dir = Join-Path (Get-NovaVoiceDir) 'engine'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $dll = Get-ChildItem -LiteralPath $dir -Recurse -Filter 'libvosk.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dll) { return $dll.FullName }
    return $null
}

function Get-NovaVoiceModelDir { return (Join-Path (Join-Path (Get-NovaVoiceDir) 'model') $script:Vosk.ModelName) }

function Test-NovaVoiceEngine {
    return (Test-NovaVoiceDll) -and (Test-Path -LiteralPath (Join-Path (Get-NovaVoiceModelDir) 'am\final.mdl'))
}

function Save-NovaVerifiedZip {
    param([string]$Url, [string]$Sha256, [string]$Destination, [string]$What)
    $temp = Join-Path $env:TEMP ('nova-{0}.zip' -f [guid]::NewGuid())
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $progress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $temp -UseBasicParsing
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw ('Не удалось скачать {0}: {1}. Проверь интернет.' -f $What, $_.Exception.Message)
    } finally {
        $ProgressPreference = $progress
    }
    try {
        if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ne $Sha256) {
            throw ('Скачанный {0} не совпал с оригиналом (контрольная сумма). Файл удалён.' -f $What)
        }
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Expand-Archive -LiteralPath $temp -DestinationPath $Destination -Force
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Install-NovaVoiceEngine {
    [void](Initialize-NovaVoiceDir)
    if (-not (Test-NovaVoiceDll)) {
        Write-Nova 'Скачиваю движок распознавания Vosk (15 МБ)...' dim
        Save-NovaVerifiedZip -Url $script:Vosk.EngineUrl -Sha256 $script:Vosk.EngineSha256 -Destination (Join-Path (Get-NovaVoiceDir) 'engine') -What 'движок Vosk'
    }
    if (-not (Test-Path -LiteralPath (Join-Path (Get-NovaVoiceModelDir) 'am\final.mdl'))) {
        Write-Nova 'Скачиваю русскую модель речи (46 МБ)...' dim
        Save-NovaVerifiedZip -Url $script:Vosk.ModelUrl -Sha256 $script:Vosk.ModelSha256 -Destination (Join-Path (Get-NovaVoiceDir) 'model') -What 'модель речи'
    }
    if (-not (Test-NovaVoiceEngine)) { throw 'Движок распознавания не установился. Попробуй ещё раз.' }
}

# Связь с Windows и Vosk. Компилируется один раз при запуске.
$script:NativeCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace NovaVoice {
    public static class Win {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetDllDirectory(string path);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr LoadLibrary(string path);
        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
        public static bool Held(byte[] keys) { foreach (var k in keys) if ((GetAsyncKeyState(k) & 0x8000) == 0) return false; return true; }
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern bool LockWorkStation();
        [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
        public delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);

        public static string Title(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
        public static string ClassOf(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }

        // Обычные окна программ: видимые, с заголовком, не «дочерние» окна.
        public static IntPtr[] AppWindows() {
            var list = new System.Collections.Generic.List<IntPtr>();
            EnumWindows(delegate (IntPtr h, IntPtr l) {
                if (IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && Title(h).Length > 0) list.Add(h);
                return true;
            }, IntPtr.Zero);
            return list.ToArray();
        }

        public static void Tap(byte[] keys) {
            foreach (var k in keys) keybd_event(k, 0, 0, UIntPtr.Zero);
            for (int i = keys.Length - 1; i >= 0; i--) keybd_event(keys[i], 0, 2, UIntPtr.Zero);
        }
    }

    public static class Vosk {
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern void vosk_set_log_level(int level);
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr vosk_model_new(byte[] path);
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern void vosk_model_free(IntPtr model);
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern int vosk_model_find_word(IntPtr model, byte[] word);
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr vosk_recognizer_new_grm(IntPtr model, float rate, byte[] grammar);
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern void vosk_recognizer_free(IntPtr rec);
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern void vosk_recognizer_reset(IntPtr rec);
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern int vosk_recognizer_accept_waveform(IntPtr rec, byte[] data, int length);
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr vosk_recognizer_result(IntPtr rec);
        [DllImport("libvosk.dll", CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr vosk_recognizer_final_result(IntPtr rec);

        public static byte[] Utf8Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
        public static string FromUtf8(IntPtr p) {
            if (p == IntPtr.Zero) return "";
            int n = 0;
            while (Marshal.ReadByte(p, n) != 0) n++;
            var b = new byte[n];
            Marshal.Copy(p, b, 0, n);
            return Encoding.UTF8.GetString(b);
        }
    }

    // Микрофон через winmm: 16 кГц, моно, 16 бит — то, что ждёт Vosk.
    public sealed class Mic : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct WaveFormat { public ushort Tag; public ushort Channels; public uint Rate; public uint BytesPerSec; public ushort Align; public ushort Bits; public ushort Size; }
        [StructLayout(LayoutKind.Sequential)] struct WaveHdr { public IntPtr Data; public uint Length; public uint Recorded; public IntPtr User; public uint Flags; public uint Loops; public IntPtr Next; public IntPtr Reserved; }
        [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr h, uint device, ref WaveFormat f, IntPtr cb, IntPtr inst, uint flags);
        [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr h, IntPtr hdr, uint size);
        [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr h, IntPtr hdr, uint size);
        [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr h, IntPtr hdr, uint size);
        [DllImport("winmm.dll")] static extern int waveInStart(IntPtr h);
        [DllImport("winmm.dll")] static extern int waveInStop(IntPtr h);
        [DllImport("winmm.dll")] static extern int waveInReset(IntPtr h);
        [DllImport("winmm.dll")] static extern int waveInClose(IntPtr h);
        [DllImport("winmm.dll")] public static extern uint waveInGetNumDevs();

        IntPtr handle;
        readonly IntPtr[] headers;
        readonly IntPtr[] buffers;
        readonly int bufferSize;
        readonly uint hdrSize = (uint)Marshal.SizeOf(typeof(WaveHdr));
        int next;

        public Mic(int count, int bytesPerBuffer) {
            var f = new WaveFormat { Tag = 1, Channels = 1, Rate = 16000, Bits = 16, Align = 2, BytesPerSec = 32000, Size = 0 };
            int r = waveInOpen(out handle, 0xFFFFFFFF, ref f, IntPtr.Zero, IntPtr.Zero, 0);
            if (r != 0) throw new InvalidOperationException("waveInOpen " + r);
            bufferSize = bytesPerBuffer;
            headers = new IntPtr[count];
            buffers = new IntPtr[count];
            for (int i = 0; i < count; i++) {
                buffers[i] = Marshal.AllocHGlobal(bufferSize);
                headers[i] = Marshal.AllocHGlobal((int)hdrSize);
                Queue(i);
            }
            r = waveInStart(handle);
            if (r != 0) throw new InvalidOperationException("waveInStart " + r);
        }

        void Queue(int i) {
            var h = new WaveHdr { Data = buffers[i], Length = (uint)bufferSize };
            Marshal.StructureToPtr(h, headers[i], false);
            waveInPrepareHeader(handle, headers[i], hdrSize);
            waveInAddBuffer(handle, headers[i], hdrSize);
        }

        // Следующий заполненный кусок звука или null, если его ещё нет.
        public byte[] Read() {
            var h = (WaveHdr)Marshal.PtrToStructure(headers[next], typeof(WaveHdr));
            if ((h.Flags & 1) == 0) return null;
            var data = new byte[h.Recorded];
            Marshal.Copy(buffers[next], data, 0, (int)h.Recorded);
            waveInUnprepareHeader(handle, headers[next], hdrSize);
            Queue(next);
            next = (next + 1) % headers.Length;
            return data;
        }

        public void Dispose() {
            if (handle == IntPtr.Zero) return;
            waveInStop(handle);
            waveInReset(handle);
            for (int i = 0; i < headers.Length; i++) {
                waveInUnprepareHeader(handle, headers[i], hdrSize);
                Marshal.FreeHGlobal(headers[i]);
                Marshal.FreeHGlobal(buffers[i]);
            }
            waveInClose(handle);
            handle = IntPtr.Zero;
        }
    }
}
'@

function Initialize-NovaVoiceNative {
    if (-not ('NovaVoice.Vosk' -as [type])) { Add-Type -TypeDefinition $script:NativeCode -Language CSharp }
    if ($script:VoiceLoaded) { return }
    # Перед загрузкой ещё раз сверяем все DLL движка: подменённые файлы не загружаем.
    if (-not (Test-NovaVoiceDll)) { throw 'Файлы движка голоса изменены или повреждены. Запусти Nova Голос снова — он скачает их заново.' }
    $dll = Get-NovaVoiceEngineDll
    # Системные DLL загружаем до того, как добавить папку движка в поиск, а сам движок — по полному пути.
    [void][NovaVoice.Mic]::waveInGetNumDevs()
    [void][NovaVoice.Win]::GetForegroundWindow()
    [void][NovaVoice.Win]::SetDllDirectory((Split-Path -Parent $dll))
    if ([NovaVoice.Win]::LoadLibrary($dll) -eq [IntPtr]::Zero) { throw 'Не удалось загрузить движок распознавания.' }
    $script:VoiceLoaded = $true
}

# Настройки из voice.json: фраза → действие. Ошибки в файле — понятным списком.
function Read-NovaVoiceConfig {
    param([Parameter(Mandatory)][string]$Path)
    $doc = Read-NovaJson $Path
    $problems = New-Object System.Collections.Generic.List[string]
    $wake = ([string](Get-NovaProp $doc 'wakeWord' 'нова')).Trim().ToLowerInvariant()
    if ($wake -notmatch '^[а-яё]+$') { $problems.Add('voice.json: wakeWord — одно слово русскими буквами') }
    $delay = [int](Get-NovaProp $doc 'delaySeconds' 15)
    if ($delay -lt 5 -or $delay -gt 120) { $problems.Add('voice.json: delaySeconds — от 5 до 120 секунд') }
    $pushToTalk = [string](Get-NovaProp $doc 'pushToTalk' '')
    $pushKeys = $null
    if ($pushToTalk) {
        $pushKeys = ConvertTo-NovaVoiceKeys $pushToTalk
        if ($null -eq $pushKeys) { $problems.Add("voice.json: непонятная клавиша pushToTalk '$pushToTalk'") }
    }
    $commands = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-NovaProp $doc 'commands' @())) {
        $say = @(@(Get-NovaProp $item 'say' @()) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() -replace '\s+', ' ' } | Where-Object { $_ })
        $do = [string](Get-NovaProp $item 'do' '')
        $run = [string](Get-NovaProp $item 'run' '')
        $keys = [string](Get-NovaProp $item 'keys' '')
        $label = ($say -join ' / ')
        if ($say.Count -eq 0) { $problems.Add('voice.json: у команды нет фраз (say)'); continue }
        foreach ($phrase in $say) { if ($phrase -notmatch '^[а-яё ]+$') { $problems.Add("voice.json: «$phrase» — только русские буквы и пробелы") } }
        $kinds = @(@($do, $run, $keys) | Where-Object { $_ }).Count
        if ($kinds -ne 1) { $problems.Add("voice.json: у «$label» должно быть одно из do, run или keys"); continue }
        if ($do -and $script:VoiceActions -notcontains $do) { $problems.Add("voice.json: у «$label» неизвестное действие '$do'") }
        if ($keys -and $null -eq (ConvertTo-NovaVoiceKeys $keys)) { $problems.Add("voice.json: у «$label» непонятные клавиши '$keys'") }
        $commands.Add([pscustomobject]@{ Say = $say; Do = $do; Run = $run; Keys = $keys; Label = $say[0] })
    }
    return [pscustomobject]@{ WakeWord = $wake; Delay = $delay; PushToTalk = $pushToTalk; PushKeys = $pushKeys; Commands = $commands.ToArray(); Problems = $problems.ToArray() }
}

# Все фразы, которые слушает распознаватель. Фразы без «Нова» тоже в списке — чтобы распознать
# и спокойно пропустить, а не принять за похожую команду.
function Get-NovaVoiceGrammar {
    param($Config)
    $phrases = New-Object System.Collections.Generic.List[string]
    $phrases.Add($Config.WakeWord)
    foreach ($command in $Config.Commands) {
        foreach ($say in $command.Say) { $phrases.Add(('{0} {1}' -f $Config.WakeWord, $say)); $phrases.Add($say) }
    }
    $phrases.Add('[unk]')
    return @($phrases | Select-Object -Unique)
}

# Находит в распознанном тексте команды, перед которыми сказано «Нова».
function Resolve-NovaVoiceText {
    param([string]$Text, $Config)
    $words = @(([string]$Text).Trim().ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    $found = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $words.Count) {
        if ($words[$i] -ne $Config.WakeWord) { $i++; continue }
        $best = $null
        $bestLength = 0
        foreach ($command in $Config.Commands) {
            foreach ($say in $command.Say) {
                $parts = @($say -split ' ')
                if ($i + $parts.Count -ge $words.Count) { continue }
                $match = $true
                for ($k = 0; $k -lt $parts.Count; $k++) { if ($words[$i + 1 + $k] -ne $parts[$k]) { $match = $false; break } }
                if ($match -and $parts.Count -gt $bestLength) { $best = $command; $bestLength = $parts.Count }
            }
        }
        if ($best) { $found.Add($best); $i += 1 + $bestLength } else { $i++ }
    }
    return $found.ToArray()
}

$script:VirtualKeys = @{
    ctrl = 0x11; shift = 0x10; alt = 0x12; win = 0x5B; esc = 0x1B; tab = 0x09; enter = 0x0D; space = 0x20
    printscreen = 0x2C; delete = 0x2E; home = 0x24; end = 0x23; up = 0x26; down = 0x28; left = 0x25; right = 0x27
}
function ConvertTo-NovaVoiceKeys {
    param([string]$Keys)
    $codes = New-Object System.Collections.Generic.List[byte]
    foreach ($part in (([string]$Keys).ToLowerInvariant() -split '\+')) {
        $p = $part.Trim()
        if ($script:VirtualKeys.ContainsKey($p)) { $codes.Add([byte]$script:VirtualKeys[$p]) }
        elseif ($p -match '^[a-z0-9]$') { $codes.Add([byte][char]$p.ToUpperInvariant()) }
        elseif ($p -match '^f([1-9]|1[0-2])$') { $codes.Add([byte](0x6F + [int]$Matches[1])) }
        else { return $null }
    }
    if ($codes.Count -eq 0) { return $null }
    return , $codes.ToArray()
}

# Окно самой Nova Голос не трогаем.
function Test-NovaVoiceOwnWindow {
    param([IntPtr]$Handle)
    return ($Handle -eq [NovaVoice.Win]::GetConsoleWindow()) -or ([NovaVoice.Win]::Title($Handle) -like '*Nova Голос*')
}

function Close-NovaVoiceWindows {
    $skip = @('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd')
    $closed = 0
    foreach ($h in [NovaVoice.Win]::AppWindows()) {
        if ($skip -contains [NovaVoice.Win]::ClassOf($h) -or (Test-NovaVoiceOwnWindow $h)) { continue }
        [void][NovaVoice.Win]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        $closed++
    }
    return $closed
}

# Выполняет команду. С -DryRun только говорит, что сделала бы (для проверки).
function Invoke-NovaVoiceCommand {
    param([Parameter(Mandatory)]$Command, $Config, [switch]$DryRun)
    $delay = $Config.Delay
    if ($Command.Run) {
        if (-not $DryRun) { Start-Process -FilePath $Command.Run }
        return ('открываю {0}' -f $Command.Run)
    }
    if ($Command.Keys) {
        if (-not $DryRun) { [NovaVoice.Win]::Tap((ConvertTo-NovaVoiceKeys $Command.Keys)) }
        return ('нажимаю {0}' -f $Command.Keys)
    }
    switch ($Command.Do) {
        # Выключение и перезагрузка ждут сами, а потом просят Windows выключиться обычным способом:
        # с задержкой shutdown.exe закрывает программы принудительно, и несохранённое пропало бы.
        'shutdown' {
            if (-not $DryRun) { Set-NovaVoicePending 'shutdown' $delay }
            return ('выключу компьютер через {0} с — «{1}, отмена» отменит. Программы успеют спросить про сохранение' -f $delay, $Config.WakeWord)
        }
        'restart' {
            if (-not $DryRun) { Set-NovaVoicePending 'restart' $delay }
            return ('перезагружу через {0} с — «{1}, отмена» отменит' -f $delay, $Config.WakeWord)
        }
        'cancel' {
            $script:Pending = $null
            return 'отменено'
        }
        'closeAll' {
            if (-not $DryRun) { Set-NovaVoicePending 'closeAll' $delay }
            return ('закрою все окна через {0} с — «{1}, отмена» отменит. Несохранённое программы спросят сохранить' -f $delay, $Config.WakeWord)
        }
        'minimizeAll' { if (-not $DryRun) { (New-Object -ComObject Shell.Application).MinimizeAll() }; return 'сворачиваю все окна' }
        'restoreAll' { if (-not $DryRun) { (New-Object -ComObject Shell.Application).UndoMinimizeAll() }; return 'возвращаю окна' }
        'closeWindow' {
            if (-not $DryRun) {
                $h = [NovaVoice.Win]::GetForegroundWindow()
                if ($h -eq [IntPtr]::Zero -or (Test-NovaVoiceOwnWindow $h)) { return 'это окно Nova Голос — его не закрываю' }
                [void][NovaVoice.Win]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            }
            return 'закрываю окно'
        }
        'lock' { if (-not $DryRun) { [void][NovaVoice.Win]::LockWorkStation() }; return 'блокирую компьютер' }
        'volumeUp' { if (-not $DryRun) { 1..5 | ForEach-Object { [NovaVoice.Win]::Tap([byte[]]@(0xAF)) } }; return 'громче' }
        'volumeDown' { if (-not $DryRun) { 1..5 | ForEach-Object { [NovaVoice.Win]::Tap([byte[]]@(0xAE)) } }; return 'тише' }
        'mute' { if (-not $DryRun) { [NovaVoice.Win]::Tap([byte[]]@(0xAD)) }; return 'звук вкл/выкл' }
    }
    return ''
}

function Set-NovaVoicePending {
    param([string]$Action, [int]$Seconds)
    $script:Pending = [pscustomobject]@{ Action = $Action; Deadline = (Get-Date).AddSeconds($Seconds) }
    try { [Console]::Beep(660, 200) } catch { Write-Verbose 'Нет звука.' }
}

function Get-NovaVoicePending { return $script:Pending }

# Отложенная команда: выполняем, когда вышло время и её не отменили.
function Invoke-NovaVoicePending {
    if ($null -eq $script:Pending -or (Get-Date) -lt $script:Pending.Deadline) { return $null }
    $action = $script:Pending.Action
    $script:Pending = $null
    $shutdown = Join-Path (Join-Path $env:SystemRoot 'System32') 'shutdown.exe'
    switch ($action) {
        'closeAll' { return ('закрыла окон: {0}' -f (Close-NovaVoiceWindows)) }
        'shutdown' { & $shutdown /s /t 0; return 'выключаю компьютер' }
        'restart' { & $shutdown /r /t 0; return 'перезагружаю компьютер' }
    }
    return $null
}

function Open-NovaVoiceModel {
    Initialize-NovaVoiceNative
    [NovaVoice.Vosk]::vosk_set_log_level(-1)
    $model = [NovaVoice.Vosk]::vosk_model_new([NovaVoice.Vosk]::Utf8Z((Get-NovaVoiceModelDir)))
    if ($model -eq [IntPtr]::Zero) { throw 'Не удалось загрузить модель речи.' }
    return $model
}

# Слова, которых нет в словаре модели: фразы с ними не распознаются, поэтому их надо заменить.
function Get-NovaVoiceUnknownWord {
    param([IntPtr]$Model, [string[]]$Words)
    return @($Words | Where-Object { $_ -and $_ -ne '[unk]' } | Select-Object -Unique |
            Where-Object { [NovaVoice.Vosk]::vosk_model_find_word($Model, [NovaVoice.Vosk]::Utf8Z($_)) -lt 0 })
}

function Get-NovaVoiceConfigWord {
    param($Config)
    return @(@($Config.WakeWord) + @($Config.Commands | ForEach-Object { $_.Say } | ForEach-Object { $_ -split ' ' }) | Select-Object -Unique)
}

function New-NovaVoiceRecognizer {
    param($Config)
    $model = Open-NovaVoiceModel
    $unknown = @(Get-NovaVoiceUnknownWord -Model $model -Words (Get-NovaVoiceConfigWord $Config))
    if ($unknown -contains $Config.WakeWord) {
        [NovaVoice.Vosk]::vosk_model_free($model)
        throw ('Модель не знает слово «{0}». Выбери другое wakeWord в voice.json.' -f $Config.WakeWord)
    }
    # Фразы с незнакомыми словами выкидываем целиком: иначе Vosk молча обрежет их и начнёт путать команды.
    $phrases = @(Get-NovaVoiceGrammar $Config | Where-Object {
            $phrase = $_
            $phrase -eq '[unk]' -or @($phrase -split ' ' | Where-Object { $unknown -contains $_ }).Count -eq 0
        })
    $grammar = ConvertTo-Json -InputObject $phrases -Compress
    $rec = [NovaVoice.Vosk]::vosk_recognizer_new_grm($model, 16000.0, [NovaVoice.Vosk]::Utf8Z($grammar))
    if ($rec -eq [IntPtr]::Zero) { [NovaVoice.Vosk]::vosk_model_free($model); throw 'Не удалось запустить распознавание.' }
    return [pscustomobject]@{ Model = $model; Rec = $rec; Unknown = $unknown }
}

function Remove-NovaVoiceRecognizer {
    param($Recognizer)
    if ($null -eq $Recognizer) { return }
    [NovaVoice.Vosk]::vosk_recognizer_free($Recognizer.Rec)
    [NovaVoice.Vosk]::vosk_model_free($Recognizer.Model)
}

function Get-NovaVoiceResultText {
    param([IntPtr]$Json)
    $text = (ConvertFrom-Json ([NovaVoice.Vosk]::FromUtf8($Json))).text
    return ([string]$text).Trim()
}

# Распознаёт WAV-файл (16 кГц, моно, 16 бит). Для проверки без микрофона.
function Invoke-NovaVoiceFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'RIFF') { throw 'Это не WAV-файл.' }
    if ([BitConverter]::ToInt32($bytes, 24) -ne 16000 -or [BitConverter]::ToInt16($bytes, 22) -ne 1 -or [BitConverter]::ToInt16($bytes, 34) -ne 16) {
        throw 'Нужен WAV 16 кГц, моно, 16 бит.'
    }
    $r = New-NovaVoiceRecognizer $Config
    $texts = New-Object System.Collections.Generic.List[string]
    try {
        $chunk = 8000
        for ($pos = 44; $pos -lt $bytes.Length; $pos += $chunk) {
            $n = [math]::Min($chunk, $bytes.Length - $pos)
            $piece = New-Object byte[] $n
            [Array]::Copy($bytes, $pos, $piece, 0, $n)
            if ([NovaVoice.Vosk]::vosk_recognizer_accept_waveform($r.Rec, $piece, $n) -ne 0) {
                $t = Get-NovaVoiceResultText ([NovaVoice.Vosk]::vosk_recognizer_result($r.Rec))
                if ($t) { $texts.Add($t) }
            }
        }
        $t = Get-NovaVoiceResultText ([NovaVoice.Vosk]::vosk_recognizer_final_result($r.Rec))
        if ($t) { $texts.Add($t) }
    } finally {
        Remove-NovaVoiceRecognizer $r
    }
    $text = ($texts -join ' ').Trim()
    $commands = @(Resolve-NovaVoiceText -Text $text -Config $Config)
    return [pscustomobject]@{ Text = $text; Commands = $commands }
}

# Слушает микрофон, пока окно открыто.
function Start-NovaVoiceListener {
    param([Parameter(Mandatory)]$Config)
    Initialize-NovaVoiceNative
    if ([NovaVoice.Mic]::waveInGetNumDevs() -eq 0) { throw 'Не найден микрофон. Подключи его и запусти снова.' }
    $r = New-NovaVoiceRecognizer $Config
    if ($r.Unknown.Count -gt 0) {
        Write-Nova ('Модель не знает слова: {0}. Фразы с ними не сработают — замени их в voice.json.' -f ($r.Unknown -join ', ')) warn
    }
    $mic = $null
    try {
        $mic = New-Object -TypeName NovaVoice.Mic -ArgumentList 8, 3200
        $holding = $false
        Write-Nova ('Слушаю. Скажи, например: «{0}, сверни все окна». Закрыть — Ctrl+C или крестик окна.' -f $Config.WakeWord) ok
        if ($Config.PushToTalk) { Write-Nova ('Команды слышу, только пока зажато: {0}.' -f $Config.PushToTalk) info }
        while ($true) {
            $data = $mic.Read()
            if ($null -eq $data) {
                $done = Invoke-NovaVoicePending
                if ($done) { Write-Nova $done ok }
                Start-Sleep -Milliseconds 30
                continue
            }
            if ($data.Length -eq 0) { continue }
            # Режим «говорю, только пока держу клавишу»: без клавиши звук сразу выбрасываем.
            if ($Config.PushKeys) {
                if (-not [NovaVoice.Win]::Held($Config.PushKeys)) {
                    if ($holding) { [NovaVoice.Vosk]::vosk_recognizer_reset($r.Rec); $holding = $false }
                    continue
                }
                $holding = $true
            }
            if ([NovaVoice.Vosk]::vosk_recognizer_accept_waveform($r.Rec, $data, $data.Length) -eq 0) { continue }
            $text = Get-NovaVoiceResultText ([NovaVoice.Vosk]::vosk_recognizer_result($r.Rec))
            if (-not $text -or $text -eq '[unk]') { continue }
            $commands = @(Resolve-NovaVoiceText -Text $text -Config $Config)
            if ($commands.Count -eq 0) {
                if ($text -notmatch '^(\[unk\]\s*)+$') { Write-Nova ('слышу «{0}» — без «{1}» не выполняю' -f $text, $Config.WakeWord) dim }
                continue
            }
            foreach ($command in $commands) {
                try {
                    Write-Nova ('«{0}» → {1}' -f $command.Label, (Invoke-NovaVoiceCommand -Command $command -Config $Config)) ok
                } catch {
                    Write-Nova ('«{0}»: {1}' -f $command.Label, $_.Exception.Message) err
                }
            }
        }
    } finally {
        if ($mic) { $mic.Dispose() }
        Remove-NovaVoiceRecognizer $r
    }
}

Export-ModuleMember -Function *
