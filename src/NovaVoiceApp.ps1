<#
.SYNOPSIS
    Nova Голос в окне: шар, который слушает, и лента — что Nova услышала и что сделала.
.DESCRIPTION
    Распознавание то же, что в консольном Nova Голос (src\NovaVoice.ps1): прямо на этом компьютере,
    без интернета, звук никуда не отправляется и не сохраняется. Прав администратора не нужно.
.EXAMPLE
    .\NovaVoiceApp.ps1                                     # открыть окно и слушать
    .\NovaVoiceApp.ps1 -Minimized                          # то же, свёрнутым (так его открывает автозагрузка)
    .\NovaVoiceApp.ps1 -Screenshot C:\shots                # снимки окна в разных состояниях (для проверки)
    .\NovaVoiceApp.ps1 -WavFile a.wav -Screenshot C:\shots # распознать запись в окне и снять результат
#>
[CmdletBinding()]
param(
    [switch]$Minimized,
    [string]$WavFile,
    [string]$Screenshot
)

$ErrorActionPreference = 'Stop'
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { exit 1 }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
# Консоль скрыта: если окно не откроется, человек должен увидеть причину, а не тишину.
trap {
    $message = [string]$_.Exception.Message
    if ($message.Length -gt 400) { $message = $message.Substring(0, 400) + '…' }
    if ($Screenshot) { [Console]::Error.WriteLine('Nova Voice: ' + $message); exit 1 }
    try { [void][Windows.MessageBox]::Show(("Nova Голос не открылся: {0}`n`nКонсольный вариант: src\NovaVoice.ps1." -f $message), 'Nova Голос', 'OK', 'Error') } catch { Write-Verbose 'Сообщение не показалось.' }
    exit 1
}
$env:PSModulePath = (@((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'), (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')) -join ';')
$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot 'voice.json'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NovaVoice.psm1') -Force -DisableNameChecking

# Снимки без записи — только внешний вид, ничего не слушаем и не выполняем.
$looksOnly = [bool]$Screenshot -and -not $WavFile

if (-not $looksOnly) {
    # Голос может запускаться при каждом входе в Windows — его файлы не должен мочь подменить другой пользователь.
    if (-not ($env:NOVA_ALLOW_SHARED_FOLDER -eq '1' -and $env:GITHUB_ACTIONS -eq 'true')) {
        $folderProblem = Get-NovaProjectProblem -Root $projectRoot -ConfigPath $configPath
        if ($folderProblem) {
            [void][Windows.MessageBox]::Show(("Папку Nova могут менять другие пользователи этого компьютера — голос оттуда запускать небезопасно.`n`n{0}`n`nПеренеси папку Nova в свою папку, например {1}" -f $folderProblem, $env:USERPROFILE), 'Nova Голос', 'OK', 'Warning')
            exit 1
        }
    }
    # Голосовым командам не нужны права администратора — открываемся обычным окном через Проводник.
    if (-not $Screenshot -and (Test-NovaAdmin)) {
        $lua = Get-NovaRegValue -Path 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
        $alwaysAdmin = ($lua.Exists -and [int]$lua.Value -eq 0) -or ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -like '*-500')
        if (-not $alwaysAdmin) {
            $mark = Get-NovaRegValue -Path 'HKCU\Software\Nova' -Name 'VoiceRelaunch'
            $recent = $false
            if ($mark.Exists) {
                $when = 0L
                if ([long]::TryParse([string]$mark.Value, [ref]$when)) { $recent = ([DateTime]::UtcNow.Ticks - $when) -lt [TimeSpan]::FromMinutes(1).Ticks }
            }
            $relaunch = Join-Path $projectRoot 'NovaVoice.cmd'
            if (-not $WavFile -and -not $recent -and (Test-Path -LiteralPath $relaunch)) {
                Set-NovaRegValue -Path 'HKCU\Software\Nova' -Name 'VoiceRelaunch' -Value ([string][DateTime]::UtcNow.Ticks) -Kind 'String'
                if (Start-NovaAsUser $relaunch) { exit 0 }
            }
            [void][Windows.MessageBox]::Show('Голосовые команды не нужно запускать от имени администратора — так безопаснее. Открой NovaVoice.cmd обычным двойным кликом.', 'Nova Голос', 'OK', 'Information')
            exit 1
        }
    }
    # Одно окно голоса: второй запуск показывает уже открытое (два окна слушали бы микрофон вдвоём).
    if (-not $Screenshot) {
        $script:Single = New-Object Threading.Mutex($false, 'Local\NovaVoice')
        $owned = $false
        try { $owned = $script:Single.WaitOne(0) } catch { $owned = $true }
        if (-not $owned) {
            try { Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.Interaction]::AppActivate('Nova Голос') } catch { Write-Verbose 'Открытое окно не нашлось.' }
            exit 0
        }
    }
}

#region Внешний вид (XAML)

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Nova Голос" Width="440" Height="720" MinWidth="380" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#0E1015" Foreground="#E8EAF0"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="46" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#343A4A" Margin="1,0"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Caption" TargetType="ButtonBase">
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Foreground" Value="#B9BFCD"/>
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Width" Value="44"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ButtonBase">
            <Border x:Name="b" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#22262F"/></Trigger>
              <Trigger Property="ToggleButton.IsChecked" Value="True"><Setter Property="Foreground" Value="#FFC940"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CaptionClose" TargetType="Button" BasedOn="{StaticResource Caption}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#C42B1C"/><Setter Property="Foreground" Value="White"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="#1A1205"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="10" Padding="20,10">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFD862" Offset="0"/><GradientStop Color="#F3B021" Offset="1"/></LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="9" Padding="14,8" Background="#1A1E28" BorderBrush="#2C3242" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#6B5A20"/><Setter TargetName="b" Property="Background" Value="#1F2430"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" BorderBrush="#262B37" BorderThickness="1" Background="#0E1015">
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="46"/><RowDefinition/></Grid.RowDefinitions>

      <!-- заголовок окна -->
      <Border Background="#111318">
        <Grid>
          <StackPanel Orientation="Horizontal" Margin="16,0" VerticalAlignment="Center">
            <Image x:Name="LogoImg" Width="20" Height="20"/>
            <TextBlock Text="Nova Голос" Margin="10,0,0,0" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <ToggleButton x:Name="BtnPin" Style="{StaticResource Caption}" Content="&#xE718;" ToolTip="Поверх всех окон (и игр в окне)" AutomationProperties.Name="Поверх всех окон"/>
            <Button x:Name="BtnMin" Style="{StaticResource Caption}" Content="&#xE921;" AutomationProperties.Name="Свернуть"/>
            <Button x:Name="BtnClose" Style="{StaticResource CaptionClose}" Content="&#xE8BB;" AutomationProperties.Name="Закрыть"/>
          </StackPanel>
        </Grid>
      </Border>

      <Grid Grid.Row="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- шар -->
        <Grid x:Name="Orb" Width="230" Height="230" Margin="0,14,0,0" RenderTransformOrigin="0.5,0.5">
          <Grid.RenderTransform><ScaleTransform x:Name="OrbScale" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
          <Ellipse x:Name="Glow" Width="230" Height="230" RenderTransformOrigin="0.5,0.5">
            <Ellipse.RenderTransform><ScaleTransform x:Name="GlowScale" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse x:Name="Ripple" Width="156" Height="156" StrokeThickness="2" RenderTransformOrigin="0.5,0.5" Opacity="0">
            <Ellipse.RenderTransform><ScaleTransform x:Name="RippleScale" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse x:Name="Ring" Width="156" Height="156" StrokeThickness="2"/>
          <Ellipse Width="140" Height="140">
            <Ellipse.Fill>
              <RadialGradientBrush GradientOrigin="0.35,0.3"><GradientStop Color="#2A2614" Offset="0"/><GradientStop Color="#15171E" Offset="1"/></RadialGradientBrush>
            </Ellipse.Fill>
          </Ellipse>
          <TextBlock x:Name="OrbIcon" FontFamily="{StaticResource Icons}" FontSize="46" Text="&#xE720;" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>

        <StackPanel Grid.Row="1" Margin="28,4,28,0">
          <TextBlock x:Name="StatusText" FontSize="26" FontWeight="Bold" Foreground="#FFFFFF" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap"/>
          <TextBlock x:Name="SubText" FontSize="13.5" Foreground="#8B93A7" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,6,0,0"/>
        </StackPanel>

        <Border x:Name="HeardBox" Grid.Row="2" Margin="28,14,28,0" CornerRadius="12" Background="#161922" BorderBrush="#232835" BorderThickness="1" Padding="14,10" Visibility="Collapsed">
          <DockPanel>
            <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE8BD;" Foreground="#6E7689" FontSize="14" Margin="0,2,10,0"/>
            <TextBlock x:Name="HeardText" FontStyle="Italic" Foreground="#C9CEDA" TextWrapping="Wrap"/>
          </DockPanel>
        </Border>

        <Button x:Name="BtnAction" Grid.Row="3" Style="{StaticResource Primary}" HorizontalAlignment="Center" Margin="0,14,0,0" Visibility="Collapsed"/>

        <!-- что Nova сделала -->
        <DockPanel Grid.Row="4" Margin="28,18,20,0">
          <DockPanel DockPanel.Dock="Top" Margin="0,0,8,8">
            <TextBlock x:Name="FeedCount" DockPanel.Dock="Right" Foreground="#6E7689" FontSize="12" VerticalAlignment="Center"/>
            <TextBlock Text="Что я сделала" FontWeight="SemiBold" Foreground="#B9BFCD"/>
          </DockPanel>
          <Grid>
            <TextBlock x:Name="FeedEmpty" Foreground="#5D6476" FontSize="13" TextWrapping="Wrap" Margin="0,4,8,0"/>
            <ScrollViewer x:Name="FeedScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="Feed" Margin="0,0,8,0"/>
            </ScrollViewer>
          </Grid>
        </DockPanel>

        <Border Grid.Row="5" Background="#111318" BorderBrush="#1C2029" BorderThickness="0,1,0,0" Padding="20,12">
          <StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
              <Button x:Name="BtnPause" Style="{StaticResource Ghost}" Content="Пауза"/>
              <Button x:Name="BtnCommands" Style="{StaticResource Ghost}" Content="Все команды"/>
              <Button x:Name="BtnOwn" Style="{StaticResource Ghost}" Margin="0" Content="Свои команды"/>
            </StackPanel>
            <TextBlock Text="Без интернета · звук никуда не уходит и не сохраняется" Foreground="#5D6476" FontSize="11.5" HorizontalAlignment="Center" Margin="0,10,0,0"/>
          </StackPanel>
        </Border>

        <!-- все команды -->
        <Border x:Name="CmdPanel" Grid.RowSpan="6" Background="#0E1015" Visibility="Collapsed">
          <DockPanel Margin="24,16,16,16">
            <DockPanel DockPanel.Dock="Top" Margin="0,0,8,4">
              <Button x:Name="BtnCmdClose" DockPanel.Dock="Right" Style="{StaticResource Ghost}" Margin="0" Content="Назад"/>
              <TextBlock Text="Команды" FontSize="22" FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBlock x:Name="CmdHint" DockPanel.Dock="Top" Foreground="#8B93A7" FontSize="13" TextWrapping="Wrap" Margin="0,0,8,12"/>
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="CmdList" Margin="0,0,8,0"/>
            </ScrollViewer>
          </DockPanel>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

#endregion

$win = [Windows.Markup.XamlReader]::Parse($xaml)
$work = [Windows.SystemParameters]::WorkArea
$win.Height = [Math]::Max($win.MinHeight, [Math]::Min($win.Height, $work.Height - 40))
$ui = @{}
foreach ($name in @('Root', 'LogoImg', 'BtnPin', 'BtnMin', 'BtnClose', 'Orb', 'OrbScale', 'Glow', 'GlowScale', 'Ripple', 'RippleScale', 'Ring', 'OrbIcon',
        'StatusText', 'SubText', 'HeardBox', 'HeardText', 'BtnAction', 'FeedCount', 'FeedEmpty', 'FeedScroll', 'Feed',
        'BtnPause', 'BtnCommands', 'BtnOwn', 'CmdPanel', 'BtnCmdClose', 'CmdHint', 'CmdList')) {
    $ui[$name] = $win.FindName($name)
    if ($null -eq $ui[$name]) { throw ('В окне нет элемента {0}' -f $name) }
}

#region Помощники

$brushes = @{}
function Get-Brush([string]$Hex) {
    if (-not $brushes.ContainsKey($Hex)) { $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex)); $b.Freeze(); $brushes[$Hex] = $b }
    return $brushes[$Hex]
}
function Get-Color([string]$Hex) { return [Windows.Media.Color]([Windows.Media.ColorConverter]::ConvertFromString($Hex)) }
function New-Text([string]$Text, [double]$Size = 14, [string]$Color = '#E8EAF0', [string]$Weight = 'Normal', [switch]$Wrap) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Get-Brush $Color
    $t.FontWeight = [Windows.FontWeights]::$Weight
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    return $t
}
function New-Anim([double]$From, [double]$To, [double]$Seconds, [switch]$Forever, [switch]$Reverse) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @($From, $To, (New-Object Windows.Duration ([TimeSpan]::FromSeconds($Seconds))))
    $ease = New-Object Windows.Media.Animation.SineEase; $ease.EasingMode = 'EaseInOut'; $a.EasingFunction = $ease
    if ($Forever) { $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever }
    if ($Reverse) { $a.AutoReverse = $true }
    return $a
}
function Get-Upper([string]$Text) { if (-not $Text) { return $Text }; return $Text.Substring(0, 1).ToUpperInvariant() + $Text.Substring(1) }

#endregion

#region Шар: цвет и движение

# Цвет шара: свечение вокруг, кольцо и значок микрофона.
function Set-OrbColor([string]$Hex, [double]$GlowAlpha = 0.45) {
    $c = Get-Color $Hex
    $glow = New-Object Windows.Media.RadialGradientBrush
    $inner = [Windows.Media.Color]::FromArgb([byte](255 * $GlowAlpha), $c.R, $c.G, $c.B)
    $mid = [Windows.Media.Color]::FromArgb([byte](90 * $GlowAlpha), $c.R, $c.G, $c.B)
    $outer = [Windows.Media.Color]::FromArgb(0, $c.R, $c.G, $c.B)
    $glow.GradientStops.Add((New-Object Windows.Media.GradientStop ($inner, 0.45)))
    $glow.GradientStops.Add((New-Object Windows.Media.GradientStop ($mid, 0.7)))
    $glow.GradientStops.Add((New-Object Windows.Media.GradientStop ($outer, 1)))
    $ui.Glow.Fill = $glow
    $ui.Ring.Stroke = Get-Brush $Hex
    $ui.Ripple.Stroke = Get-Brush $Hex
    $ui.OrbIcon.Foreground = Get-Brush $Hex
}

# Дыхание шара, пока Nova слушает, и расходящиеся круги.
function Start-OrbPulse([double]$Seconds = 1.8) {
    $breath = New-Anim 0.9 1.06 $Seconds -Forever -Reverse
    $ui.GlowScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $breath)
    $ui.GlowScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $breath)
    $grow = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @([double]1, [double]1.42, (New-Object Windows.Duration ([TimeSpan]::FromSeconds($Seconds * 1.3))))
    $grow.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $fade = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @([double]0.7, [double]0, (New-Object Windows.Duration ([TimeSpan]::FromSeconds($Seconds * 1.3))))
    $fade.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $ui.RippleScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $grow)
    $ui.RippleScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $grow)
    $ui.Ripple.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
}
function Stop-OrbPulse {
    foreach ($prop in @([Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty)) {
        $ui.GlowScale.BeginAnimation($prop, $null); $ui.RippleScale.BeginAnimation($prop, $null)
    }
    $ui.Ripple.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $ui.GlowScale.ScaleX = 1; $ui.GlowScale.ScaleY = 1; $ui.Ripple.Opacity = 0
}
# Короткая вспышка: Nova услышала команду.
function Invoke-OrbFlash([double]$To = 1.1) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @([double]1, $To, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(170))))
    $a.AutoReverse = $true
    $ui.OrbScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $a)
    $ui.OrbScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $a)
}

#endregion

#region Состояния окна

$script:State = ''
$script:Wake = 'нова'
$script:Example = 'сверни все окна'

function Set-Action([string]$Text) {
    if ($Text) { $ui.BtnAction.Content = $Text; $ui.BtnAction.Visibility = 'Visible' } else { $ui.BtnAction.Visibility = 'Collapsed' }
}

function Set-VoiceState([string]$State, [string]$Message) {
    $script:State = $State
    Stop-OrbPulse
    $ui.BtnPause.IsEnabled = $true
    $ui.BtnPause.Content = 'Пауза'
    Set-Action ''
    switch ($State) {
        'starting' {
            Set-OrbColor '#8B93A7' 0.25; Start-OrbPulse 1.1
            $ui.StatusText.Text = 'Запускаю…'; $ui.SubText.Text = 'Загружаю распознавание речи — пара секунд.'
            $ui.BtnPause.IsEnabled = $false
        }
        'need-engine' {
            Set-OrbColor '#FFC940' 0.22
            $ui.StatusText.Text = 'Нужен движок распознавания'
            $ui.SubText.Text = 'Один раз скачать бесплатный движок Vosk и русскую модель (~60 МБ) с официальных серверов. Дальше голос работает без интернета.'
            Set-Action 'Скачать и начать'
            $ui.BtnPause.IsEnabled = $false
        }
        'engine' {
            Set-OrbColor '#FFC940' 0.3; Start-OrbPulse 0.9
            $ui.StatusText.Text = 'Скачиваю…'; $ui.SubText.Text = 'Движок и русская модель, около 60 МБ. Это один раз.'
            $ui.BtnPause.IsEnabled = $false
        }
        'listening' {
            Set-OrbColor '#FFC940' 0.45; Start-OrbPulse 1.8
            $ui.StatusText.Text = 'Слушаю'
            $ui.SubText.Text = ('Скажи: «{0}, {1}»' -f (Get-Upper $script:Wake), $script:Example)
        }
        'paused' {
            Set-OrbColor '#6E7689' 0.18
            $ui.StatusText.Text = 'На паузе'; $ui.SubText.Text = 'Микрофон выключен — Nova ничего не слышит.'
            $ui.BtnPause.Content = 'Слушать'
        }
        'error' {
            Set-OrbColor '#FF6B6B' 0.3
            $ui.StatusText.Text = 'Не получилось'; $ui.SubText.Text = $Message
            Set-Action 'Попробовать снова'
            $ui.BtnPause.IsEnabled = $false
        }
        'done' {
            Set-OrbColor '#7CE0A3' 0.35
            $ui.StatusText.Text = 'Готово'; $ui.SubText.Text = 'Запись распознана — ниже, что Nova сделала бы.'
            $ui.BtnPause.IsEnabled = $false
        }
    }
}

# После команды на пару секунд показываем, что сделано, потом снова «Слушаю».
$script:BackTimer = New-Object Windows.Threading.DispatcherTimer
$script:BackTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:BackTimer.Add_Tick({ $script:BackTimer.Stop(); if ($script:State -eq 'listening') { Set-VoiceState 'listening' } })

function Show-Heard([string]$Text, [switch]$Ignored) {
    $ui.HeardBox.Visibility = 'Visible'
    $ui.HeardText.Text = ('«{0}»' -f $Text)
    $ui.HeardText.Foreground = Get-Brush ($(if ($Ignored) { '#6E7689' } else { '#E8EAF0' }))
    if ($Ignored -and $script:State -eq 'listening') {
        $ui.SubText.Text = ('Слышу, но без «{0}» в начале не выполняю.' -f $script:Wake)
        $script:BackTimer.Stop(); $script:BackTimer.Start()
    }
}

$script:FeedTotal = 0
function Add-FeedCard([string]$Kind, [string]$Title, [string]$Text) {
    $ui.FeedEmpty.Visibility = 'Collapsed'
    $icon = @{ ok = @([string][char]0xE73E, '#7CE0A3'); warn = @([string][char]0xE7BA, '#FFC940'); err = @([string][char]0xEA39, '#FF7A7A') }[$Kind]
    $card = New-Object Windows.Controls.Border
    $card.CornerRadius = 12; $card.Padding = '14,10'; $card.Margin = '0,0,0,8'
    $card.Background = Get-Brush '#161922'; $card.BorderBrush = Get-Brush '#20242F'; $card.BorderThickness = 1
    $dock = New-Object Windows.Controls.DockPanel
    $ico = New-Text $icon[0] 16 $icon[1]; $ico.FontFamily = $win.FindResource('Icons'); $ico.Margin = '0,2,12,0'
    [Windows.Controls.DockPanel]::SetDock($ico, 'Left'); [void]$dock.Children.Add($ico)
    $time = New-Text (Get-Date -Format 'HH:mm') 11.5 '#5D6476'; $time.Margin = '10,2,0,0'
    [Windows.Controls.DockPanel]::SetDock($time, 'Right'); [void]$dock.Children.Add($time)
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $Title 14 '#FFFFFF' 'SemiBold' -Wrap))
    if ($Text) { $t = New-Text $Text 12.5 '#8B93A7' -Wrap; $t.Margin = '0,2,0,0'; [void]$sp.Children.Add($t) }
    [void]$dock.Children.Add($sp)
    $card.Child = $dock
    [Windows.Automation.AutomationProperties]::SetName($card, ($Title + $(if ($Text) { ' — ' + $Text } else { '' })))
    $ui.Feed.Children.Insert(0, $card)
    while ($ui.Feed.Children.Count -gt 40) { $ui.Feed.Children.RemoveAt($ui.Feed.Children.Count - 1) }
    $script:FeedTotal++
    $ui.FeedCount.Text = ('{0} за сеанс' -f $script:FeedTotal)
    $ui.FeedScroll.ScrollToTop()
    # Появление карточки — мягко.
    $card.Opacity = 0
    $card.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 0 1 0.25))
}

function Add-CommandRow([string]$Say, [string]$What) {
    $row = New-Object Windows.Controls.Border
    $row.CornerRadius = 10; $row.Padding = '14,9'; $row.Margin = '0,0,0,6'; $row.Background = Get-Brush '#161922'
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text ('«{0}»' -f (Get-Upper $Say)) 14 '#FFFFFF' 'SemiBold' -Wrap))
    if ($What) { $w = New-Text $What 12.5 '#8B93A7' -Wrap; $w.Margin = '0,2,0,0'; [void]$sp.Children.Add($w) }
    $row.Child = $sp
    [void]$ui.CmdList.Children.Add($row)
}

#endregion

#region Распознавание в фоне

# Слушает отдельный поток со своими модулями. Всё, что он пишет и сообщает, приходит сюда очередью.
$script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:Ps = $null
$script:Rs = $null
$script:Handle = $null

$listenScript = @'
param([string]$Src, [string]$ConfigPath, [string]$WavFile, $Queue)
$ErrorActionPreference = 'Stop'
$global:NovaVoiceEvents = $Queue
function global:Write-Host {
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $Separator = ' ', [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray, [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black)
    $text = (@($Object) | ForEach-Object { [string]$_ }) -join [string]$Separator
    $global:NovaVoiceEvents.Enqueue(("line`t{0}`t{1}" -f $ForegroundColor, ($text -replace '[\r\n\t]+', ' ').Trim()))
}
try {
    Import-Module (Join-Path $Src 'Nova.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $Src 'NovaVoice.psm1') -Force -DisableNameChecking
    $config = Read-NovaVoiceConfig -Path $ConfigPath
    foreach ($problem in @($config.Problems)) { Send-NovaVoiceEvent 'warn' $problem }
    if ($config.Fatal) { throw 'В voice.json есть ошибки — исправь их (подробности ниже) и нажми «Попробовать снова».' }
    if (@($config.Commands).Count -eq 0) { throw 'В voice.json не осталось ни одной рабочей команды.' }
    Send-NovaVoiceCommandList -Config $config
    if (-not (Test-NovaVoiceEngine)) {
        Send-NovaVoiceEvent 'engine' ''
        Install-NovaVoiceEngine
    }
    if ($WavFile) {
        Send-NovaVoiceEvent 'listen' $config.WakeWord
        $result = Invoke-NovaVoiceFile -Path $WavFile -Config $config
        if (@($result.Commands).Count -eq 0) {
            Send-NovaVoiceEvent 'ignored' $result.Text
        } else {
            Send-NovaVoiceEvent 'heard' $result.Text
            foreach ($command in $result.Commands) { Send-NovaVoiceEvent 'done' @($command.Label, (Invoke-NovaVoiceCommand -Command $command -Config $config -DryRun)) }
        }
        Send-NovaVoiceEvent 'end' 'wav'
    } else {
        Start-NovaVoiceListener -Config $config
    }
} catch {
    $Queue.Enqueue(("error`t{0}" -f ([string]$_.Exception.Message -replace '[\r\n\t]+', ' ')))
}
'@

function Start-Listening {
    Stop-Listening
    $ui.CmdList.Children.Clear()
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($listenScript).AddArgument($PSScriptRoot).AddArgument($configPath).AddArgument([string]$WavFile).AddArgument($script:Queue)
    $script:Rs = $rs; $script:Ps = $ps
    $script:Handle = $ps.BeginInvoke()
    Set-VoiceState 'starting'
}

# Останавливает распознавание и отпускает микрофон.
function Stop-Listening {
    $ps = $script:Ps; $rs = $script:Rs
    $script:Ps = $null; $script:Rs = $null; $script:Handle = $null
    if ($ps) {
        try { $ps.Stop() } catch { Write-Verbose 'Поток голоса уже остановлен.' }
        try { $ps.Dispose() } catch { Write-Verbose 'Поток голоса уже убран.' }
    }
    if ($rs) { try { $rs.Dispose() } catch { Write-Verbose 'Поток голоса уже закрыт.' } }
    # То, что поток успел прислать перед остановкой, больше не нужно.
    $item = $null
    while ($script:Queue.TryDequeue([ref]$item)) { }
}

function Receive-VoiceEvent([string]$Item) {
    $parts = $Item.Split("`t")
    $kind = $parts[0]
    $a = $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
    $b = $(if ($parts.Count -gt 2) { $parts[2] } else { '' })
    switch ($kind) {
        'line' {
            $text = $b.Trim().TrimStart('+', '!', 'x', ' ')
            if (-not $text) { return }
            if ($script:State -eq 'engine' -and $a -ne 'Red') { $ui.SubText.Text = $text; return }
            if ($a -eq 'Yellow') { Add-FeedCard 'warn' $text '' }
        }
        'warn' { Add-FeedCard 'warn' 'voice.json' $a }
        'cmd' {
            Add-CommandRow $a $b
            if ($a -like '*сверни все окна*') { $script:Example = 'сверни все окна' }
        }
        'engine' { Set-VoiceState 'engine' }
        'listen' { if ($a) { $script:Wake = $a }; $ui.CmdHint.Text = ('Начинай с «{0}». Свои фразы — в кабинете на сайте или в voice.json.' -f (Get-Upper $script:Wake)); Set-VoiceState 'listening' }
        'heard' { Show-Heard $a; Invoke-OrbFlash 1.05 }
        'ignored' { Show-Heard $a -Ignored }
        'done' {
            Invoke-OrbFlash 1.12
            if ($b) { Add-FeedCard 'ok' ('«{0}»' -f $a) (Get-Upper $b) } else { Add-FeedCard 'ok' (Get-Upper $a) '' }
            if ($script:State -eq 'listening') {
                $ui.StatusText.Text = $(if ($b) { Get-Upper $b } else { 'Готово' })
                $ui.SubText.Text = $(if ($b) { ('«{0}, {1}»' -f (Get-Upper $script:Wake), $a) } else { Get-Upper $a })
                $script:BackTimer.Stop(); $script:BackTimer.Start()
            }
        }
        'fail' { Add-FeedCard 'err' ('«{0}»' -f $a) $b }
        'error' { Stop-Listening; Set-VoiceState 'error' $a }
        'end' { Set-VoiceState 'done' }
    }
}

# Разбирает очередь и следит, жив ли поток распознавания.
function Invoke-VoicePump {
    $item = $null
    $n = 0
    while ($n -lt 60 -and $script:Queue.TryDequeue([ref]$item)) { $n++; Receive-VoiceEvent $item }
    if ($script:Handle -and $script:Handle.IsCompleted -and $script:Queue.IsEmpty) {
        $ps = $script:Ps
        $problem = ''
        try { [void]$ps.EndInvoke($script:Handle) } catch { $problem = $_.Exception.Message }
        if (-not $problem -and $ps.Streams.Error.Count -gt 0) { $problem = $ps.Streams.Error[0].Exception.Message }
        Stop-Listening
        if ($script:State -notin @('error', 'done', 'paused')) {
            Set-VoiceState 'error' $(if ($problem) { Get-NovaPlainText $problem 300 } else { 'Голос остановился. Нажми «Попробовать снова».' })
        }
    }
}
$pump = New-Object Windows.Threading.DispatcherTimer
$pump.Interval = [TimeSpan]::FromMilliseconds(120)
$pump.Add_Tick({ try { Invoke-VoicePump } catch { Set-VoiceState 'error' (Get-NovaPlainText $_.Exception.Message 300) } })

#endregion

#region Кнопки

$ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.BtnClose.Add_Click({ $win.Close() })
$ui.BtnPin.Add_Checked({ $win.Topmost = $true })
$ui.BtnPin.Add_Unchecked({ $win.Topmost = $false })
$ui.BtnPause.Add_Click({
        if ($script:State -eq 'paused') { Start-Listening } else { Stop-Listening; Set-VoiceState 'paused' }
    })
$ui.BtnAction.Add_Click({ Start-Listening })
$ui.BtnCommands.Add_Click({ $ui.CmdPanel.Visibility = 'Visible' })
$ui.BtnCmdClose.Add_Click({ $ui.CmdPanel.Visibility = 'Collapsed' })
$ui.BtnOwn.Add_Click({ if (-not (Start-NovaAsUser 'https://vezin0v0-cmyk.github.io/my-project/docs/app.html#voice')) { Write-Verbose 'Ссылка не открылась.' } })
$win.Add_Closing({ $pump.Stop(); Stop-Listening })
$win.Dispatcher.Add_UnhandledException({
        param($s, $e)
        $e.Handled = $true
        $inner = $e.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        Add-FeedCard 'err' 'Что-то пошло не так' (Get-NovaPlainText $inner.Message 200)
    })

#endregion

#region Первое заполнение

$logoPath = Join-Path $projectRoot 'assets\nova.png'
if (Test-Path -LiteralPath $logoPath) {
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit(); $img.CacheOption = 'OnLoad'; $img.UriSource = New-Object Uri($logoPath); $img.EndInit(); $img.Freeze()
    $ui.LogoImg.Source = $img; $win.Icon = $img
}
$ui.FeedEmpty.Text = 'Пока ничего. Скажи «Нова, …» — здесь появится, что я сделала.'
$ui.CmdHint.Text = 'Начинай с «Нова». Свои фразы — в кабинете на сайте или в voice.json.'
if ($Minimized) { $win.WindowState = 'Minimized' }

#endregion

# Снимки окна (для проверки на GitHub и для сайта): без микрофона — состояния на примерах,
# с -WavFile — настоящее распознавание записи в окне.
if ($Screenshot) {
    if (-not (Test-Path -LiteralPath $Screenshot)) { New-Item -ItemType Directory -Path $Screenshot -Force | Out-Null }
    $win.WindowStartupLocation = 'Manual'; $win.Left = 0; $win.Top = 0
    $win.Width = 440; $win.Height = 720
    $win.ShowActivated = $false
    $win.Show()
    function Save-Shot([string]$Name) {
        $until = (Get-Date).AddMilliseconds(900)
        while ((Get-Date) -lt $until) { $win.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Background); Start-Sleep -Milliseconds 30 }
        # Карточки появляются плавно — для снимка показываем их сразу.
        foreach ($c in $ui.Feed.Children) { $c.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $c.Opacity = 1 }
        $win.UpdateLayout()
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$ui.Root.ActualWidth), ([int]$ui.Root.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($ui.Root)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create((Join-Path $Screenshot ('nova-voice-{0}.png' -f $Name)))
        try { $enc.Save($fs) } finally { $fs.Dispose() }
        Write-Host ('снимок: {0}' -f $Name)
    }
    $code = 0
    if ($WavFile) {
        Start-Listening
        $until = (Get-Date).AddMinutes(4)
        while ((Get-Date) -lt $until -and $script:State -notin @('done', 'error')) {
            Invoke-VoicePump
            $win.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Background)
            Start-Sleep -Milliseconds 100
        }
        Invoke-VoicePump
        Save-Shot 'zapis'
        # Что окно показало — текстом (UTF-8) рядом со снимком, для проверки.
        $report = New-Object System.Collections.Generic.List[string]
        $report.Add(('state: {0}' -f $script:State))
        $report.Add(('status: {0} / {1}' -f $ui.StatusText.Text, $ui.SubText.Text))
        $report.Add(('heard: {0}' -f $ui.HeardText.Text))
        foreach ($c in @($ui.Feed.Children)) { $report.Add(('feed: {0}' -f [Windows.Automation.AutomationProperties]::GetName($c))) }
        $report.Add(('commands: {0}' -f $ui.CmdList.Children.Count))
        [IO.File]::WriteAllLines((Join-Path $Screenshot 'nova-voice-zapis.txt'), $report.ToArray(), (New-Object Text.UTF8Encoding($false)))
        foreach ($line in $report) { Write-Host $line }
        if ($script:State -ne 'done') { $code = 1 }
    } else {
        # Те же события, что присылает распознавание, — окно разбирает их так же, как настоящие.
        $global:NovaVoiceEvents = $script:Queue
        try { Send-NovaVoiceCommandList -Config (Read-NovaVoiceConfig -Path $configPath) } catch { Write-Host ('список команд: {0}' -f $_.Exception.Message) }
        foreach ($e in @("listen`tнова", "heard`tнова режим игры", "done`tрежим игры`tвключаю режим игры", "done`tсверни все окна`tсворачиваю все окна",
                "done`tкоторый час`tсейчас двадцать один сорок", "heard`tнова громче", "done`tгромче`tгромче")) { $script:Queue.Enqueue($e) }
        Invoke-VoicePump
        $script:BackTimer.Stop()
        $ui.StatusText.Text = 'Громче'; $ui.SubText.Text = '«Нова, громче»'
        Save-Shot '01-slushayu'
        Set-VoiceState 'listening'
        Save-Shot '02-zhdu'
        $ui.CmdPanel.Visibility = 'Visible'
        Save-Shot '03-komandy'
        $ui.CmdPanel.Visibility = 'Collapsed'
        Set-VoiceState 'need-engine'
        Save-Shot '04-dvizhok'
        Set-VoiceState 'error' 'Не найден микрофон. Подключи его и нажми «Попробовать снова».'
        Save-Shot '05-net-mikrofona'
        $global:NovaVoiceEvents = $null
    }
    Stop-Listening
    $win.Close()
    exit $code
}

$pump.Start()
# Loaded — и когда окно открывается свёрнутым (автозагрузка).
$win.Add_Loaded({ if (Test-NovaVoiceEngine) { Start-Listening } else { Set-VoiceState 'need-engine' } })
[void]$win.ShowDialog()
Stop-Listening
if ($script:Single) { try { $script:Single.ReleaseMutex() } catch { Write-Verbose 'Отметка «окно открыто» уже снята.' } }
