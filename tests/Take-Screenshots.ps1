# Снимает экран Windows: Проводник, меню «Пуск» и меню правой кнопки на рабочем столе.
# Запускается в GitHub Actions до и после Nova, чтобы показать настоящую разницу.
param(
    [Parameter(Mandatory)][string]$Prefix,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'screenshots')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NovaInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public static void RightClick(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0008, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0010, 0, 0, 0, UIntPtr.Zero);
    }
    public static void Key(byte vk) {
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
    }
}
'@

function Save-Screen {
    param([string]$Name)
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $file = Join-Path $OutDir ('{0}-{1}.png' -f $Prefix, $Name)
        $bitmap.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host ('Снимок: {0} ({1}x{2})' -f $file, $bounds.Width, $bounds.Height)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Close-ExplorerWindows {
    $shell = New-Object -ComObject Shell.Application
    foreach ($window in @($shell.Windows())) {
        try { $window.Quit() } catch { Write-Verbose 'Окно уже закрыто.' }
    }
}

$shell = New-Object -ComObject Shell.Application
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

# 1. Окно Проводника — открывается так, как настроено в системе.
Close-ExplorerWindows
Start-Process explorer.exe
Start-Sleep -Seconds 5
Save-Screen 'explorer'
Close-ExplorerWindows
Start-Sleep -Seconds 1

# 2. Меню «Пуск».
[NovaInput]::Key(0x5B)
Start-Sleep -Seconds 4
Save-Screen 'start'
[NovaInput]::Key(0x1B)
Start-Sleep -Seconds 1

# 3. Меню правой кнопки на рабочем столе.
$shell.MinimizeAll()
Start-Sleep -Seconds 2
[NovaInput]::RightClick([int]($bounds.Width * 0.45), [int]($bounds.Height * 0.3))
Start-Sleep -Seconds 3
Save-Screen 'menu'
[NovaInput]::Key(0x1B)
Start-Sleep -Seconds 1
