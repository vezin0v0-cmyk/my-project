<#
.SYNOPSIS
    Nova Центр — окно Nova: настройки с переключателями, игры, голос, обслуживание и обновления.
.DESCRIPTION
    То же, что меню Nova, только в окне. Сами изменения делает обычная Nova (src\Nova.ps1) — окно
    запускает её и показывает ход работы. Нужны права администратора, как и меню.
.EXAMPLE
    .\NovaApp.ps1                          # открыть окно
    .\NovaApp.ps1 -Screenshot C:\shots     # сохранить снимки всех страниц и выйти (для проверки)
#>
[CmdletBinding()]
param(
    [string]$Screenshot
)

$ErrorActionPreference = 'Stop'
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { exit 1 }
$env:PSModulePath = (@((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'), (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')) -join ';')
$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot 'config.json'
$tweaksPath = Join-Path $PSScriptRoot 'tweaks.json'
$novaScript = Join-Path $PSScriptRoot 'Nova.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Import-Module (Join-Path $PSScriptRoot 'Nova.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NovaTools.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NovaPlay.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NovaStartup.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# Права администратора — как у меню Nova. Окно перезапускается с ними; консоль при этом скрыта.
if (-not (Test-NovaAdmin)) {
    try {
        Start-Process -FilePath $psExe -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    } catch {
        [void][Windows.MessageBox]::Show('Nova нужны права администратора. Запусти NovaCenter.cmd ещё раз и нажми «Да».', 'Nova Центр')
    }
    exit 0
}

# Папку Nova не должны менять другие пользователи — иначе запускать её с правами администратора небезопасно.
if (-not ($env:NOVA_ALLOW_SHARED_FOLDER -eq '1' -and $env:GITHUB_ACTIONS -eq 'true')) {
    $folderProblem = Get-NovaProjectProblem -Root $projectRoot -ConfigPath $configPath
    if ($folderProblem) {
        [void][Windows.MessageBox]::Show(("Папку Nova могут менять другие пользователи этого компьютера — запускать её с правами администратора небезопасно.`n`n{0}`n`nОткрой Nova.cmd — она предложит перенести Nova в твою папку." -f $folderProblem), 'Nova Центр', 'OK', 'Warning')
        exit 1
    }
}
[void](Get-NovaDataDir)

#region Внешний вид (XAML)

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Nova Центр" Width="1180" Height="760" MinWidth="980" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#0E1015" Foreground="#E8EAF0"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="46" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="Gold" Color="#FFC940"/>
    <SolidColorBrush x:Key="Dim" Color="#8B93A7"/>
    <SolidColorBrush x:Key="Card" Color="#161922"/>
    <SolidColorBrush x:Key="Line" Color="#252A36"/>
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

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#B9BFCD"/>
      <Setter Property="Margin" Value="10,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="8" Background="Transparent" Padding="12,9">
              <Grid>
                <Border x:Name="bar" Width="3" Height="16" CornerRadius="2" Background="#FFC940" HorizontalAlignment="Left" Margin="-12,0,0,0" Visibility="Collapsed"/>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="{TemplateBinding Tag}" FontFamily="{StaticResource Icons}" FontSize="16" Width="28" VerticalAlignment="Center"/>
                  <ContentPresenter VerticalAlignment="Center"/>
                </StackPanel>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1A1E28"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#20252F"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#B9BFCD"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="16" Background="#161922" BorderBrush="#252A36" BorderThickness="1" Padding="14,6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#5A4C1F"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#FFC940"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#FFC940"/>
                <Setter Property="Foreground" Value="#1A1205"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="24" Background="Transparent">
              <Border x:Name="track" CornerRadius="12" Background="#252A36" BorderBrush="#3A4152" BorderThickness="1"/>
              <Ellipse x:Name="knob" Width="16" Height="16" Fill="#AEB4C3" HorizontalAlignment="Left" Margin="4,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#FFC940"/>
                <Setter TargetName="track" Property="BorderBrush" Value="#FFC940"/>
                <Setter TargetName="knob" Property="Fill" Value="#1A1205"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Margin" Value="0,0,4,0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="#1A1205"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="9" Padding="18,9">
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
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="9" Padding="16,9" Background="#1A1E28" BorderBrush="#2C3242" BorderThickness="1">
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

    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,12,12"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="14" Padding="18,16" Background="#161922" BorderBrush="#232835" BorderThickness="1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#7A6422"/><Setter TargetName="b" Property="Background" Value="#1A1E28"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#20252F"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Caption" TargetType="Button">
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Foreground" Value="#B9BFCD"/>
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#22262F"/></Trigger>
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

    <Style x:Key="H1" TargetType="TextBlock"><Setter Property="FontSize" Value="28"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="Foreground" Value="#FFFFFF"/></Style>
    <Style x:Key="Sub" TargetType="TextBlock"><Setter Property="FontSize" Value="14"/><Setter Property="Foreground" Value="#8B93A7"/><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="Margin" Value="0,4,0,0"/></Style>
    <Style x:Key="Ico" TargetType="TextBlock"><Setter Property="FontFamily" Value="{StaticResource Icons}"/><Setter Property="FontSize" Value="22"/><Setter Property="Foreground" Value="#FFC940"/></Style>
    <Style x:Key="TileTitle" TargetType="TextBlock"><Setter Property="FontSize" Value="16"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,12,0,0"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
    <Style x:Key="TileText" TargetType="TextBlock"><Setter Property="FontSize" Value="12.5"/><Setter Property="Foreground" Value="#8B93A7"/><Setter Property="Margin" Value="0,4,0,0"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
  </Window.Resources>

  <Border x:Name="Root" BorderBrush="#262B37" BorderThickness="1" Background="#0E1015">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="46"/><RowDefinition/></Grid.RowDefinitions>

      <!-- заголовок окна -->
      <Border Grid.ColumnSpan="2" Background="#111318">
        <Grid>
          <StackPanel Orientation="Horizontal" Margin="16,0" VerticalAlignment="Center">
            <Image x:Name="LogoImg" Width="20" Height="20"/>
            <TextBlock Text="Nova Центр" Margin="10,0,0,0" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <Border CornerRadius="6" Background="#221D0B" Margin="10,0,0,0" Padding="7,1" VerticalAlignment="Center">
              <TextBlock x:Name="VerText" Foreground="#FFC940" FontSize="12"/>
            </Border>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnMin" Style="{StaticResource Caption}" Content="&#xE921;" AutomationProperties.Name="Свернуть"/>
            <Button x:Name="BtnMax" Style="{StaticResource Caption}" Content="&#xE922;" AutomationProperties.Name="Развернуть"/>
            <Button x:Name="BtnClose" Style="{StaticResource CaptionClose}" Content="&#xE8BB;" AutomationProperties.Name="Закрыть"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- меню слева -->
      <Border Grid.Row="1" Background="#111318" BorderBrush="#1C2029" BorderThickness="0,0,1,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Bottom" Margin="0,0,0,14">
            <TextBlock x:Name="SideStatus" Margin="24,0,16,10" Foreground="#6E7689" FontSize="12" TextWrapping="Wrap"/>
            <RadioButton x:Name="NavAbout" GroupName="nav" Style="{StaticResource Nav}" Tag="&#xE946;" Content="О Nova"/>
          </StackPanel>
          <StackPanel Margin="0,12,0,0">
            <RadioButton x:Name="NavHome" GroupName="nav" Style="{StaticResource Nav}" Tag="&#xE80F;" Content="Главная" IsChecked="True"/>
            <RadioButton x:Name="NavTweaks" GroupName="nav" Style="{StaticResource Nav}" Tag="&#xE713;" Content="Настройки Windows"/>
            <RadioButton x:Name="NavApps" GroupName="nav" Style="{StaticResource Nav}" Tag="&#xE71D;" Content="Приложения"/>
            <RadioButton x:Name="NavGames" GroupName="nav" Style="{StaticResource Nav}" Tag="&#xE7FC;" Content="Игры"/>
            <RadioButton x:Name="NavVoice" GroupName="nav" Style="{StaticResource Nav}" Tag="&#xE720;" Content="Голос"/>
            <RadioButton x:Name="NavTools" GroupName="nav" Style="{StaticResource Nav}" Tag="&#xE90F;" Content="Обслуживание"/>
            <RadioButton x:Name="NavUpdate" GroupName="nav" Style="{StaticResource Nav}" Tag="&#xE895;" Content="Обновления"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <Grid x:Name="Pages" Grid.Row="1" Grid.Column="1">

        <!-- ГЛАВНАЯ -->
        <ScrollViewer x:Name="PageHome" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="28,22,28,28">
            <Border CornerRadius="16" Height="236">
              <Border.Background><ImageBrush x:Name="HeroImg" Stretch="UniformToFill" AlignmentX="Right" Viewbox="0,0.12,0.7,0.76" ViewboxUnits="RelativeToBoundingBox"/></Border.Background>
              <Border CornerRadius="16">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#F50E1015" Offset="0"/><GradientStop Color="#D90E1015" Offset="0.45"/><GradientStop Color="#400E1015" Offset="0.8"/><GradientStop Color="#100E1015" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
                <StackPanel VerticalAlignment="Center" Margin="36,0">
                  <TextBlock Text="NOVA ЦЕНТР" Foreground="#FFC940" FontWeight="Bold" FontSize="12.5"/>
                  <TextBlock Text="Твоя Windows," FontSize="38" FontWeight="Bold" Margin="0,6,0,0"/>
                  <TextBlock Text="настроенная под тебя" FontSize="38" FontWeight="Bold" Foreground="#FFC940" Margin="0,-6,0,0"/>
                  <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                    <Border x:Name="HealthChip" CornerRadius="12" Background="#16301F" Padding="10,4">
                      <TextBlock x:Name="HealthText" Foreground="#7CE0A3" FontSize="12.5"/>
                    </Border>
                    <TextBlock x:Name="SysText" Foreground="#AEB4C3" Margin="12,0,0,0" VerticalAlignment="Center" FontSize="12.5"/>
                  </StackPanel>
                </StackPanel>
              </Border>
            </Border>

            <TextBlock Text="Быстрые действия" FontSize="18" FontWeight="SemiBold" Margin="0,24,0,12"/>
            <UniformGrid Columns="4" Margin="0,0,-12,0">
              <Button x:Name="QApply" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE768;"/><TextBlock Style="{StaticResource TileTitle}" Text="Применить настройки"/><TextBlock Style="{StaticResource TileText}" Text="Всё, что включено в «Настройках Windows»"/></StackPanel></Button>
              <Button x:Name="QGame" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE7FC;"/><TextBlock x:Name="QGameTitle" Style="{StaticResource TileTitle}" Text="Режим игры"/><TextBlock x:Name="QGameText" Style="{StaticResource TileText}" Text="Максимум мощности, без уведомлений"/></StackPanel></Button>
              <Button x:Name="QCheck" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE9D9;"/><TextBlock Style="{StaticResource TileTitle}" Text="Проверить систему"/><TextBlock Style="{StaticResource TileText}" Text="Защита Windows и готовность к играм"/></StackPanel></Button>
              <Button x:Name="QClean" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE74D;"/><TextBlock Style="{StaticResource TileTitle}" Text="Освободить место"/><TextBlock Style="{StaticResource TileText}" Text="Временные файлы и кэши, без риска"/></StackPanel></Button>
            </UniformGrid>

            <TextBlock Text="Nova в сети" FontSize="18" FontWeight="SemiBold" Margin="0,12,0,12"/>
            <UniformGrid Columns="4" Margin="0,0,-12,0">
              <Button x:Name="LSite" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE774;"/><TextBlock Style="{StaticResource TileTitle}" Text="Сайт и инструкция"/><TextBlock Style="{StaticResource TileText}" Text="Всё о Nova и вопросы"/></StackPanel></Button>
              <Button x:Name="LCabinet" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE77B;"/><TextBlock Style="{StaticResource TileTitle}" Text="Кабинет"/><TextBlock Style="{StaticResource TileText}" Text="Сборки и свои голосовые команды"/></StackPanel></Button>
              <Button x:Name="LGitHub" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE943;"/><TextBlock Style="{StaticResource TileTitle}" Text="GitHub"/><TextBlock Style="{StaticResource TileText}" Text="Открытый код Nova"/></StackPanel></Button>
              <Button x:Name="LMail" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE715;"/><TextBlock Style="{StaticResource TileTitle}" Text="Поддержка"/><TextBlock x:Name="MailText" Style="{StaticResource TileText}"/></StackPanel></Button>
            </UniformGrid>

            <Border CornerRadius="14" Background="#161922" BorderBrush="#232835" BorderThickness="1" Padding="22,18" Margin="0,4,0,0">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="Что нового" FontSize="18" FontWeight="SemiBold"/>
                  <Border CornerRadius="6" Background="#221D0B" Margin="10,2,0,0" Padding="7,1" VerticalAlignment="Center"><TextBlock x:Name="NewsVer" Foreground="#FFC940" FontSize="12"/></Border>
                </StackPanel>
                <StackPanel x:Name="NewsList" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- НАСТРОЙКИ WINDOWS и ПРИЛОЖЕНИЯ: один шаблон страницы -->
        <Grid x:Name="PageTweaks" Visibility="Collapsed" Margin="28,22,28,0">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <StackPanel>
            <TextBlock x:Name="TweaksTitle" Style="{StaticResource H1}" Text="Настройки Windows"/>
            <TextBlock x:Name="TweaksSub" Style="{StaticResource Sub}"/>
          </StackPanel>
          <WrapPanel x:Name="CatTabs" Grid.Row="1" Margin="0,16,0,6"/>
          <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,-12,0">
            <StackPanel x:Name="TweakList" Margin="0,0,12,12"/>
          </ScrollViewer>
          <Border Grid.Row="3" BorderBrush="#1C2029" BorderThickness="0,1,0,0" Padding="0,14,0,18" Margin="0,4,0,0">
            <DockPanel>
              <StackPanel x:Name="PresetBar" Orientation="Horizontal" DockPanel.Dock="Left" VerticalAlignment="Center">
                <TextBlock Text="Сборки:" Foreground="#8B93A7" VerticalAlignment="Center" Margin="0,0,0,0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <TextBlock x:Name="DirtyText" Foreground="#FFC940" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <Button x:Name="BtnSave" Style="{StaticResource Ghost}" Content="Сохранить"/>
                <Button x:Name="BtnPreview" Style="{StaticResource Ghost}" Content="Что изменится"/>
                <Button x:Name="BtnApply" Style="{StaticResource Primary}" Content="Применить"/>
              </StackPanel>
            </DockPanel>
          </Border>
        </Grid>

        <!-- ИГРЫ -->
        <ScrollViewer x:Name="PageGames" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="28,22,28,28">
            <TextBlock Style="{StaticResource H1}" Text="Игры"/>
            <TextBlock Style="{StaticResource Sub}" Text="То, что влияет на FPS и пинг сильнее любых настроек. Nova подскажет — решаешь ты."/>
            <Border x:Name="GameModeCard" CornerRadius="16" Margin="0,18,0,16" Padding="26,22" BorderThickness="1" BorderBrush="#3A3216">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#2A2410" Offset="0"/><GradientStop Color="#161922" Offset="0.7"/></LinearGradientBrush>
              </Border.Background>
              <DockPanel>
                <Button x:Name="BtnGameMode" DockPanel.Dock="Right" Style="{StaticResource Primary}" VerticalAlignment="Center" Content="Включить"/>
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Style="{StaticResource Ico}" Text="&#xE7FC;" FontSize="26"/>
                    <TextBlock Text="Режим игры" FontSize="22" FontWeight="Bold" Margin="12,0,0,0" VerticalAlignment="Center"/>
                    <Border x:Name="GameModeChip" CornerRadius="10" Background="#2A2F3C" Margin="12,0,0,0" Padding="9,2" VerticalAlignment="Center"><TextBlock x:Name="GameModeState" FontSize="12" Text="выключен"/></Border>
                  </StackPanel>
                  <TextBlock Style="{StaticResource Sub}" Margin="0,8,0,0" Text="На время игры: максимальная мощность, без всплывающих уведомлений, обновления Windows на паузе. Выключишь — всё как было. Голосом: «Нова, режим игры» и «Нова, игра окончена»."/>
                </StackPanel>
              </DockPanel>
            </Border>
            <UniformGrid Columns="3" Margin="0,0,-12,0">
              <Button x:Name="GDriver" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE7F4;"/><TextBlock Style="{StaticResource TileTitle}" Text="Свежий ли драйвер"/><TextBlock Style="{StaticResource TileText}" Text="Для NVIDIA — сверка с сайтом NVIDIA, для AMD и Intel — по дате"/></StackPanel></Button>
              <Button x:Name="GReady" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE9D9;"/><TextBlock Style="{StaticResource TileTitle}" Text="Готовность к играм"/><TextBlock Style="{StaticResource TileText}" Text="Монитор и его герцы, память, диски, TPM для Valorant и FACEIT"/></StackPanel></Button>
              <Button x:Name="GHeavy" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xEC4A;"/><TextBlock Style="{StaticResource TileTitle}" Text="Что тормозит прямо сейчас"/><TextBlock Style="{StaticResource TileText}" Text="Кто ест процессор и память — и что это за программа"/></StackPanel></Button>
              <Button x:Name="GNet" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE701;"/><TextBlock Style="{StaticResource TileTitle}" Text="Интернет для игр"/><TextBlock Style="{StaticResource TileText}" Text="Пинг до Steam, Riot, FACEIT, Epic и Battle.net, самый быстрый DNS"/></StackPanel></Button>
              <Button x:Name="GFps" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE916;"/><TextBlock Style="{StaticResource TileTitle}" Text="Замер FPS"/><TextBlock Style="{StaticResource TileText}" Text="Честно: до и после Nova, в твоей игре"/></StackPanel></Button>
              <Button x:Name="GVoice" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE720;"/><TextBlock Style="{StaticResource TileTitle}" Text="«Нова, запусти доту»"/><TextBlock Style="{StaticResource TileText}" Text="Игры Steam, Epic и Riot по голосу"/></StackPanel></Button>
            </UniformGrid>
          </StackPanel>
        </ScrollViewer>

        <!-- ГОЛОС -->
        <Grid x:Name="PageVoice" Visibility="Collapsed" Margin="28,22,28,0">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/></Grid.RowDefinitions>
          <StackPanel>
            <TextBlock Style="{StaticResource H1}" Text="Голос"/>
            <TextBlock Style="{StaticResource Sub}" Text="«Нова, …» — речь распознаётся прямо на компьютере, без интернета. Звук никуда не уходит."/>
          </StackPanel>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="-8,16,0,14">
            <Button x:Name="BtnVoiceOpen" Style="{StaticResource Primary}" Content="Открыть Nova Голос"/>
            <Button x:Name="BtnVoiceAuto" Style="{StaticResource Ghost}" Content="Запускать вместе с Windows"/>
            <Button x:Name="BtnVoiceEdit" Style="{StaticResource Ghost}" Content="Свои команды в кабинете"/>
          </StackPanel>
          <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,-12,0">
            <StackPanel x:Name="VoiceList" Margin="0,0,12,20"/>
          </ScrollViewer>
        </Grid>

        <!-- ОБСЛУЖИВАНИЕ -->
        <ScrollViewer x:Name="PageTools" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="28,22,28,28">
            <TextBlock Style="{StaticResource H1}" Text="Обслуживание"/>
            <TextBlock Style="{StaticResource Sub}" Text="Уборка, автозагрузка, отчёт для поддержки — и всегда можно вернуть как было."/>
            <UniformGrid Columns="3" Margin="0,18,-12,0">
              <Button x:Name="TClean" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE74D;"/><TextBlock Style="{StaticResource TileTitle}" Text="Освободить место"/><TextBlock Style="{StaticResource TileText}" Text="Временные файлы, кэши, старые обновления"/></StackPanel></Button>
              <Button x:Name="TUndo" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE7A7;"/><TextBlock Style="{StaticResource TileTitle}" Text="Отменить последний запуск"/><TextBlock Style="{StaticResource TileText}" Text="Вернуть настройки как было до Nova"/></StackPanel></Button>
              <Button x:Name="TCheck" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xEA18;"/><TextBlock Style="{StaticResource TileTitle}" Text="Проверка системы"/><TextBlock Style="{StaticResource TileText}" Text="Антивирус, брандмауэр, UAC, обновления"/></StackPanel></Button>
              <Button x:Name="TStartup" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE7E8;"/><TextBlock Style="{StaticResource TileTitle}" Text="Автозагрузка"/><TextBlock Style="{StaticResource TileText}" Text="Что запускается вместе с Windows"/></StackPanel></Button>
              <Button x:Name="TReport" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE8A5;"/><TextBlock Style="{StaticResource TileTitle}" Text="Отчёт для поддержки"/><TextBlock Style="{StaticResource TileText}" Text="Файл на рабочий стол, без имени и паролей"/></StackPanel></Button>
              <Button x:Name="TMenu" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE756;"/><TextBlock Style="{StaticResource TileTitle}" Text="Классическое меню"/><TextBlock Style="{StaticResource TileText}" Text="Всё то же в консоли, плюс переезд"/></StackPanel></Button>
              <Button x:Name="TShortcut" Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE71B;"/><TextBlock Style="{StaticResource TileTitle}" Text="Ярлык на рабочий стол"/><TextBlock Style="{StaticResource TileText}" Text="Nova Центр со значком Nova"/></StackPanel></Button>
            </UniformGrid>
          </StackPanel>
        </ScrollViewer>

        <!-- ОБНОВЛЕНИЯ -->
        <ScrollViewer x:Name="PageUpdate" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="28,22,28,28">
            <TextBlock Style="{StaticResource H1}" Text="Обновления"/>
            <TextBlock Style="{StaticResource Sub}" Text="Новая версия скачивается с GitHub одним архивом и проверяется. Твои config.json и voice.json остаются как есть."/>
            <Border CornerRadius="16" Background="#161922" BorderBrush="#232835" BorderThickness="1" Padding="26,22" Margin="0,18,0,16">
              <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                  <Button x:Name="BtnCheckUpd" Style="{StaticResource Ghost}" Content="Проверить"/>
                  <Button x:Name="BtnDoUpd" Style="{StaticResource Primary}" Content="Обновить" IsEnabled="False"/>
                </StackPanel>
                <StackPanel>
                  <TextBlock x:Name="UpdTitle" FontSize="22" FontWeight="Bold"/>
                  <TextBlock x:Name="UpdText" Style="{StaticResource Sub}"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <StackPanel x:Name="UpdList"/>
            <Button x:Name="BtnRollback" Style="{StaticResource Ghost}" HorizontalAlignment="Left" Margin="0,12,0,0" Content="Вернуть прошлую версию" Visibility="Collapsed"/>
          </StackPanel>
        </ScrollViewer>

        <!-- О NOVA -->
        <ScrollViewer x:Name="PageAbout" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="28,22,28,28">
            <TextBlock Style="{StaticResource H1}" Text="О Nova"/>
            <TextBlock Style="{StaticResource Sub}" Text="Nova делает Windows такой, как нравится тебе. Windows остаётся обычной Windows — просто настроенной под тебя."/>
            <UniformGrid Columns="2" Margin="0,18,-12,0">
              <Border CornerRadius="14" Background="#161922" BorderBrush="#232835" BorderThickness="1" Padding="20,16" Margin="0,0,12,12"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE7A7;"/><TextBlock Style="{StaticResource TileTitle}" Text="Всё можно вернуть"/><TextBlock Style="{StaticResource TileText}" Text="Перед изменениями — точка восстановления и копия. Любой запуск отменяется одной кнопкой, а то, что ты поменял сам, Nova не трогает."/></StackPanel></Border>
              <Border CornerRadius="14" Background="#161922" BorderBrush="#232835" BorderThickness="1" Padding="20,16" Margin="0,0,12,12"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xEA18;"/><TextBlock Style="{StaticResource TileTitle}" Text="Защита Windows на месте"/><TextBlock Style="{StaticResource TileText}" Text="Антивирус, брандмауэр, контроль учётных записей и обновления безопасности Nova не выключает."/></StackPanel></Border>
              <Border CornerRadius="14" Background="#161922" BorderBrush="#232835" BorderThickness="1" Padding="20,16" Margin="0,0,12,12"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE72E;"/><TextBlock Style="{StaticResource TileTitle}" Text="Ничего не отправляет"/><TextBlock Style="{StaticResource TileText}" Text="Ни отчётов, ни статистики. В интернет — только по твоей просьбе и только за тем, что ты выбрал."/></StackPanel></Border>
              <Border CornerRadius="14" Background="#161922" BorderBrush="#232835" BorderThickness="1" Padding="20,16" Margin="0,0,12,12"><StackPanel><TextBlock Style="{StaticResource Ico}" Text="&#xE943;"/><TextBlock Style="{StaticResource TileTitle}" Text="Открытый код, бесплатно"/><TextBlock Style="{StaticResource TileText}" Text="Nova не содержит Windows и не активирует её — это настройки для твоей лицензионной Windows 10 или 11."/></StackPanel></Border>
            </UniformGrid>
            <TextBlock x:Name="AboutText" Style="{StaticResource Sub}" Margin="0,8,0,0"/>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- окно хода работы -->
      <Grid x:Name="RunOverlay" Grid.RowSpan="2" Grid.ColumnSpan="2" Visibility="Collapsed" Background="#CC07080C">
        <Border Width="760" Height="500" CornerRadius="18" Background="#141720" BorderBrush="#2A2F3C" BorderThickness="1">
          <Grid Margin="30,26">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <DockPanel>
              <Border DockPanel.Dock="Left" Width="64" Height="64" CornerRadius="16" Background="#221D0B" Margin="0,0,18,0">
                <TextBlock x:Name="RunIcon" Style="{StaticResource Ico}" FontSize="30" HorizontalAlignment="Center" VerticalAlignment="Center" Text="&#xE768;"/>
              </Border>
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="RunTitle" FontSize="22" FontWeight="Bold"/>
                <TextBlock x:Name="RunStep" Style="{StaticResource Sub}" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
              </StackPanel>
            </DockPanel>
            <Border x:Name="BarTrack" Grid.Row="1" Height="6" CornerRadius="3" Background="#232837" Margin="0,20,0,16" ClipToBounds="True">
              <Border x:Name="BarFill" Width="180" HorizontalAlignment="Left" CornerRadius="3">
                <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#00FFC940" Offset="0"/><GradientStop Color="#FFFFC940" Offset="0.5"/><GradientStop Color="#00FFC940" Offset="1"/></LinearGradientBrush></Border.Background>
                <Border.RenderTransform><TranslateTransform x:Name="BarMove" X="-180"/></Border.RenderTransform>
              </Border>
            </Border>
            <Border Grid.Row="2" CornerRadius="12" Background="#0E1015" BorderBrush="#1F2430" BorderThickness="1">
              <ScrollViewer x:Name="RunScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="14,10">
                <StackPanel x:Name="RunLog"/>
              </ScrollViewer>
            </Border>
            <DockPanel Grid.Row="3" Margin="0,16,0,0">
              <Button x:Name="RunClose" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Закрыть" IsEnabled="False"/>
              <TextBlock x:Name="RunResult" VerticalAlignment="Center" FontWeight="SemiBold"/>
            </DockPanel>
          </Grid>
        </Border>
      </Grid>

      <!-- всплывающее сообщение -->
      <Border x:Name="Toast" Grid.Row="1" Grid.Column="1" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,24" CornerRadius="12" Background="#1E2330" BorderBrush="#6B5A20" BorderThickness="1" Padding="18,10" Visibility="Collapsed">
        <TextBlock x:Name="ToastText" FontWeight="SemiBold"/>
      </Border>
    </Grid>
  </Border>
</Window>
'@

#endregion

$win = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($name in @('Root', 'LogoImg', 'VerText', 'BtnMin', 'BtnMax', 'BtnClose', 'SideStatus', 'NavAbout', 'NavHome', 'NavTweaks', 'NavApps', 'NavGames', 'NavVoice', 'NavTools', 'NavUpdate',
        'Pages', 'PageHome', 'HeroImg', 'HealthChip', 'HealthText', 'SysText', 'QApply', 'QGame', 'QGameTitle', 'QGameText', 'QCheck', 'QClean', 'LSite', 'LCabinet', 'LGitHub', 'LMail', 'MailText', 'NewsVer', 'NewsList',
        'PageTweaks', 'TweaksTitle', 'TweaksSub', 'CatTabs', 'TweakList', 'PresetBar', 'DirtyText', 'BtnSave', 'BtnPreview', 'BtnApply',
        'PageGames', 'GameModeChip', 'GameModeState', 'BtnGameMode', 'GDriver', 'GReady', 'GHeavy', 'GNet', 'GFps', 'GVoice',
        'PageVoice', 'BtnVoiceOpen', 'BtnVoiceAuto', 'BtnVoiceEdit', 'VoiceList',
        'PageTools', 'TClean', 'TUndo', 'TCheck', 'TStartup', 'TReport', 'TMenu', 'TShortcut',
        'PageUpdate', 'BtnCheckUpd', 'BtnDoUpd', 'UpdTitle', 'UpdText', 'UpdList', 'BtnRollback', 'PageAbout', 'AboutText',
        'RunOverlay', 'RunIcon', 'RunTitle', 'RunStep', 'BarTrack', 'BarFill', 'BarMove', 'RunScroll', 'RunLog', 'RunClose', 'RunResult', 'Toast', 'ToastText')) {
    $ui[$name] = $win.FindName($name)
    if ($null -eq $ui[$name]) { throw ('В окне нет элемента {0}' -f $name) }
}

#region Помощники

$links = @{
    Site    = 'https://vezin0v0-cmyk.github.io/my-project/docs/'
    Cabinet = 'https://vezin0v0-cmyk.github.io/my-project/docs/app.html'
    GitHub  = 'https://github.com/vezin0v0-cmyk/my-project'
}
$brushes = @{}
function Get-Brush([string]$Hex) {
    if (-not $brushes.ContainsKey($Hex)) { $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex)); $b.Freeze(); $brushes[$Hex] = $b }
    return $brushes[$Hex]
}
function New-Text([string]$Text, [double]$Size = 14, [string]$Color = '#E8EAF0', [string]$Weight = 'Normal', [switch]$Wrap) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Get-Brush $Color
    $t.FontWeight = [Windows.FontWeights]::$Weight
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    return $t
}
function Get-Image([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit(); $img.CacheOption = 'OnLoad'; $img.UriSource = New-Object Uri($Path); $img.EndInit(); $img.Freeze()
    return $img
}
function Show-Toast([string]$Text) {
    $ui.ToastText.Text = $Text; $ui.Toast.Visibility = 'Visible'
    $script:ToastTimer.Stop(); $script:ToastTimer.Start()
}
$script:ToastTimer = New-Object Windows.Threading.DispatcherTimer
$script:ToastTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:ToastTimer.Add_Tick({ $ui.Toast.Visibility = 'Collapsed'; $script:ToastTimer.Stop() })

# Ссылки и файлы открываются от имени того, кто за компьютером, — без прав администратора.
function Open-AsUser([string]$Target) {
    if (-not (Start-NovaAsUser $Target)) { Show-Toast ('Открой сам: {0}' -f $Target) }
}

# Плитки (кнопка со значком, заголовком и подписью): экранный диктор читает заголовок и подпись, без значка.
$icoStyle = $win.FindResource('Ico')
function Set-TileName([Windows.Controls.Button]$Button) {
    if (-not ($Button.Content -is [Windows.Controls.Panel])) { return }
    $texts = @($Button.Content.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] -and -not [object]::ReferenceEquals($_.Style, $icoStyle) } |
            ForEach-Object { ($_.Text -replace '\r?\n', '').Trim() } | Where-Object { $_ })
    [Windows.Automation.AutomationProperties]::SetName($Button, ($texts -join '. '))
}

# Плавное появление страницы.
function Show-Page($Page) {
    foreach ($p in @($ui.PageHome, $ui.PageTweaks, $ui.PageGames, $ui.PageVoice, $ui.PageTools, $ui.PageUpdate, $ui.PageAbout)) { $p.Visibility = 'Collapsed' }
    $Page.Visibility = 'Visible'
    $Page.Opacity = 0
    $tt = New-Object Windows.Media.TranslateTransform -ArgumentList @([double]0, [double]10)
    $Page.RenderTransform = $tt
    $dur = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(220))
    $ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'
    $fade = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @([double]0, [double]1, $dur); $fade.EasingFunction = $ease
    $move = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @([double]10, [double]0, $dur); $move.EasingFunction = $ease
    $Page.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $move)
}

#endregion

#region Запуск Nova и окно хода работы

$script:Run = $null
$runTimer = New-Object Windows.Threading.DispatcherTimer
$runTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$colors = @{ Green = '#7CE0A3'; Yellow = '#FFC940'; Red = '#FF7A7A'; DarkGray = '#6E7689'; Cyan = '#7FD4FF'; White = '#FFFFFF'; Gray = '#C9CEDA' }

function Add-RunLine([string]$Color, [string]$Text) {
    if (-not $Text.Trim()) { return }
    $t = New-Text ($Text.TrimEnd() -replace '^  ', '') 13 ($(if ($colors.ContainsKey($Color)) { $colors[$Color] } else { '#C9CEDA' })) -Wrap
    $t.FontFamily = New-Object Windows.Media.FontFamily('Cascadia Mono, Consolas')
    $t.Margin = '0,1,0,1'
    [void]$ui.RunLog.Children.Add($t)
    if ($Color -ne 'DarkGray' -and $Text.Trim().Length -gt 2) { $ui.RunStep.Text = $Text.Trim().TrimStart('+', '!', 'x', ' ') }
    $ui.RunScroll.ScrollToEnd()
}

function Start-BarAnimation {
    $ui.BarFill.Width = 180
    $ui.BarFill.HorizontalAlignment = 'Left'
    $grad = New-Object Windows.Media.LinearGradientBrush
    $grad.StartPoint = '0,0'; $grad.EndPoint = '1,0'
    foreach ($s in @(@('#00FFC940', 0), @('#FFFFC940', 0.5), @('#00FFC940', 1))) { $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString($s[0])), $s[1])) }
    $ui.BarFill.Background = $grad
    $anim = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @([double]-180, [double]720, (New-Object Windows.Duration ([TimeSpan]::FromSeconds(1.4))))
    $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $ui.BarMove.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $anim)
}
function Stop-BarAnimation([bool]$Ok) {
    $ui.BarMove.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null)
    $ui.BarMove.X = 0
    $ui.BarFill.Width = [double]::NaN
    $ui.BarFill.HorizontalAlignment = 'Stretch'
    $ui.BarFill.Background = Get-Brush ($(if ($Ok) { '#3DDC84' } else { '#FF6B6B' }))
}

# Запускает Nova (src\Nova.ps1) с заданным режимом и показывает её вывод в окне. Аргументы — только постоянные строки
# из этого файла; путь к Nova передаётся закодированной командой, поэтому кавычки и апострофы в пути не мешают.
function Start-NovaRun {
    param([string]$Title, [string]$Icon, [string]$Arguments, [scriptblock]$OnDone)
    if ($script:Run) { return }
    $out = Join-Path (Get-NovaBuildDir) ('app-run-{0}.log' -f [DateTime]::UtcNow.Ticks)
    $novaEsc = $novaScript.Replace("'", "''")
    $outEsc = $out.Replace("'", "''")
    $cmd = "& '$novaEsc' $Arguments -EchoFile '$outEsc'; exit `$LASTEXITCODE"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $enc
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $false
    $p = [Diagnostics.Process]::Start($psi)
    # Вопросов в этих режимах нет; ввод закрываем, чтобы случайный вопрос не ждал ответа вечно.
    $p.StandardInput.Close()
    $script:Run = @{ P = $p; Out = $out; Pos = [long]0; OnDone = $OnDone; Rest = '' }
    $ui.RunLog.Children.Clear()
    $ui.RunTitle.Text = $Title
    $ui.RunIcon.Text = $Icon
    $ui.RunStep.Text = 'Запускаю Nova…'
    $ui.RunResult.Text = ''
    $ui.RunClose.IsEnabled = $false
    $ui.RunOverlay.Visibility = 'Visible'
    Start-BarAnimation
    $runTimer.Start()
}

function Read-RunOutput {
    $r = $script:Run
    if (-not $r -or -not (Test-Path -LiteralPath $r.Out)) { return }
    $fs = [IO.File]::Open($r.Out, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -le $r.Pos) { return }
        [void]$fs.Seek($r.Pos, 'Begin')
        $buf = New-Object byte[] ([int][math]::Min(1048576, $fs.Length - $r.Pos))
        $n = $fs.Read($buf, 0, $buf.Length)
        $r.Pos += $n
        $text = $r.Rest + [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        $lines = $text -split "`n"
        $r.Rest = $lines[-1]
        foreach ($line in $lines[0..($lines.Count - 2)]) {
            $parts = $line.Split("`t", 2)
            if ($parts.Count -lt 2) { continue }
            # Рамку-логотип консольного меню в окне не показываем.
            if ($parts[0] -eq 'Magenta') { continue }
            Add-RunLine $parts[0] $parts[1]
        }
    } finally { $fs.Dispose() }
}

$runTimer.Add_Tick({
        try {
            Read-RunOutput
            $r = $script:Run
            if ($r -and $r.P.HasExited) {
                Read-RunOutput
                $runTimer.Stop()
                $code = $r.P.ExitCode
                $ok = ($code -eq 0)
                Stop-BarAnimation $ok
                $ui.RunResult.Text = $(if ($ok) { '✓  Всё получилось' } else { 'Есть замечания — подробности выше' })
                $ui.RunResult.Foreground = Get-Brush ($(if ($ok) { '#7CE0A3' } else { '#FFC940' }))
                $ui.RunClose.IsEnabled = $true
                $script:Run = $null
                try { [IO.File]::Delete($r.Out) } catch { Write-Verbose 'Файл хода работы удалится позже.' }
                if ($r.OnDone) { & $r.OnDone $ok }
            }
        } catch {
            $runTimer.Stop()
            $script:Run = $null
            $ui.RunResult.Text = ('Ошибка: {0}' -f (Get-NovaPlainText $_.Exception.Message 200))
            $ui.RunClose.IsEnabled = $true
        }
    })
$ui.RunClose.Add_Click({ $ui.RunOverlay.Visibility = 'Collapsed'; Update-State })

# Консольные режимы, где Nova задаёт вопросы (замер FPS, автозагрузка, меню), — в обычном окне.
function Start-NovaConsole([string]$Arguments) {
    $novaEsc = $novaScript.Replace("'", "''")
    $cmd = "& '$novaEsc' $Arguments"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
}

#endregion

#region Настройки и приложения (config.json)

$categoryNames = [ordered]@{ privacy = 'Приватность'; interface = 'Интерфейс'; style = 'Оформление Nova'; performance = 'Скорость и игры'; system = 'Система и фон' }
$appNames = @{  # те же названия, что в кабинете на сайте (docs/app.html, APP_NAMES)
    'Microsoft.BingNews' = 'Новости'; 'Microsoft.BingWeather' = 'Погода'; 'Microsoft.BingSearch' = 'Поиск Bing'
    'Microsoft.GetHelp' = 'Техподдержка'; 'Microsoft.Getstarted' = 'Советы'; 'Microsoft.MicrosoftSolitaireCollection' = 'Пасьянсы'
    'Microsoft.MicrosoftOfficeHub' = 'Microsoft 365 (Office)'; 'Microsoft.People' = 'Люди'; 'Microsoft.PowerAutomateDesktop' = 'Power Automate'
    'Microsoft.Todos' = 'Microsoft To Do'; 'Microsoft.WindowsFeedbackHub' = 'Центр отзывов'; 'Microsoft.WindowsMaps' = 'Карты'
    'Microsoft.549981C3F5F10' = 'Cortana'; 'Microsoft.Copilot' = 'Copilot'; 'Microsoft.Windows.DevHome' = 'Dev Home'
    'Microsoft.MixedReality.Portal' = 'Портал смешанной реальности'; 'Microsoft.Microsoft3DViewer' = 'Просмотр 3D'; 'Microsoft.SkypeApp' = 'Skype'
    'Clipchamp.Clipchamp' = 'Clipchamp'; 'MSTeams' = 'Teams (новый)'; 'MicrosoftTeams' = 'Teams (старый)'
    'Microsoft.OutlookForWindows' = 'Outlook (новый)'; 'Microsoft.YourPhone' = 'Связь с телефоном'; 'Microsoft.MicrosoftStickyNotes' = 'Записки'
    'Microsoft.ZuneMusic' = 'Медиаплеер'; 'Microsoft.GamingApp' = 'Xbox'; 'Microsoft.XboxGamingOverlay' = 'Xbox Game Bar'
    'MicrosoftCorporationII.MicrosoftFamily' = 'Семья (Microsoft Family)'; 'Microsoft.Office.OneNote' = 'OneNote (старый)'; 'Microsoft.Wallet' = 'Кошелёк'
    'Microsoft.WindowsSoundRecorder' = 'Диктофон'; 'MicrosoftWindows.CrossDevice' = 'Связь с устройствами'; 'microsoft.windowscommunicationsapps' = 'Почта и Календарь'
    'Microsoft.ZuneVideo' = 'Кино и ТВ'; 'Microsoft.BingFinance' = 'Финансы'; 'Microsoft.BingSports' = 'Спорт'
    'Microsoft.Messaging' = 'Сообщения'; 'Microsoft.Print3D' = 'Print 3D'; 'Microsoft.OneConnect' = 'Мобильные тарифы'
    'Microsoft.MSPaint' = 'Paint 3D'; '7zip.7zip' = '7-Zip'; 'VideoLAN.VLC' = 'VLC'
    'Mozilla.Firefox' = 'Firefox'; 'Brave.Brave' = 'Brave'; 'Google.Chrome' = 'Chrome'
    'Valve.Steam' = 'Steam'; 'Discord.Discord' = 'Discord'; 'Telegram.TelegramDesktop' = 'Telegram Desktop'
    'Notepad++.Notepad++' = 'Notepad++'; 'voidtools.Everything' = 'Everything — быстрый поиск файлов'; 'Microsoft.PowerToys' = 'PowerToys'
    'OBSProject.OBSStudio' = 'OBS Studio'; 'Microsoft.VCRedist.2015+.x64' = 'Visual C++ для игр (64 бита)'; 'Microsoft.VCRedist.2015+.x86' = 'Visual C++ для игр (32 бита)'
    'Microsoft.DirectX' = 'DirectX 9 для старых игр'
}
$presets = @(
    @{ Name = 'Игровой ПК'; Tweaks = @{ 'high-performance-power' = $true; 'power-throttling-off' = $true; 'mouse-acceleration-off' = $true; 'background-apps-off' = $true; 'hibernation-off' = $true; 'no-forced-restart' = $true; 'edge-quiet' = $true } }
    @{ Name = 'Ноутбук'; Tweaks = @{ 'high-performance-power' = $false; 'power-throttling-off' = $false; 'background-apps-off' = $true; 'transparency-off' = $true } }
    @{ Name = 'Слабый ПК'; Tweaks = @{ 'fewer-animations' = $true; 'transparency-off' = $true; 'background-apps-off' = $true; 'search-indexing-off' = $true; 'edge-quiet' = $true } }
)

$script:Tweaks = @((Read-NovaJson $tweaksPath).tweaks)
$script:ConfigText = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)
$script:Config = ConvertFrom-Json $script:ConfigText
$script:State = @{ tweaks = @{}; removeApps = @{}; installApps = @{} }
foreach ($sec in @('tweaks', 'removeApps', 'installApps')) {
    $obj = Get-NovaProp $script:Config $sec
    if ($obj) { foreach ($p in $obj.PSObject.Properties) { $script:State[$sec][$p.Name] = [bool]$p.Value } }
}
$script:Dirty = $false
$script:TweakMode = 'tweaks'
$script:Cat = 'privacy'

function Set-Dirty([bool]$Value) {
    $script:Dirty = $Value
    $ui.DirtyText.Text = $(if ($Value) { 'Есть несохранённые изменения' } else { '' })
}

# Записывает переключатели в config.json, меняя в тексте только true/false у нужных ключей —
# всё остальное (порядок, пояснения, отступы) остаётся как было.
function Save-Config {
    $text = $script:ConfigText
    foreach ($sec in @('tweaks', 'removeApps', 'installApps')) {
        $start = $text.IndexOf(('"{0}"' -f $sec))
        if ($start -lt 0) { continue }
        $open = $text.IndexOf('{', $start)
        $close = $text.IndexOf('}', $open)
        if ($open -lt 0 -or $close -lt 0) { continue }
        $block = $text.Substring($open, $close - $open + 1)
        foreach ($k in $script:State[$sec].Keys) {
            $value = $(if ($script:State[$sec][$k]) { 'true' } else { 'false' })
            $pattern = '("' + [regex]::Escape($k) + '"\s*:\s*)(true|false)'
            if ([regex]::IsMatch($block, $pattern)) {
                $block = [regex]::Replace($block, $pattern, ('$1' + $value))
            } elseif ($value -eq 'true') {
                # Новой настройки в файле ещё нет — дописываем в конец раздела.
                $body = $block.Substring(1, $block.Length - 2).TrimEnd()
                $sep = $(if ($body.Trim()) { ',' } else { '' })
                $block = '{' + $body + $sep + "`n    " + (ConvertTo-Json $k) + ': true' + "`n  }"
            }
        }
        $text = $text.Substring(0, $open) + $block + $text.Substring($close + 1)
    }
    [void](ConvertFrom-Json $text)
    [IO.File]::WriteAllText($configPath, $text, (New-Object Text.UTF8Encoding($false)))
    $script:ConfigText = $text
    Set-Dirty $false
}

function New-Row([string]$Title, [string]$Text, [string]$Sec, [string]$Key, [string]$Badge) {
    $card = New-Object Windows.Controls.Border
    $card.CornerRadius = 12; $card.Padding = '18,14'; $card.Margin = '0,0,0,8'
    $card.Background = Get-Brush '#161922'; $card.BorderBrush = Get-Brush '#20242F'; $card.BorderThickness = 1
    $grid = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)
    $left = New-Object Windows.Controls.StackPanel
    $head = New-Object Windows.Controls.StackPanel; $head.Orientation = 'Horizontal'
    [void]$head.Children.Add((New-Text $Title 15 '#FFFFFF' 'SemiBold'))
    if ($Badge) {
        $bd = New-Object Windows.Controls.Border; $bd.CornerRadius = 6; $bd.Background = Get-Brush '#2A2410'; $bd.Padding = '6,0'; $bd.Margin = '8,1,0,0'; $bd.VerticalAlignment = 'Center'
        $bd.Child = (New-Text $Badge 11 '#FFC940'); [void]$head.Children.Add($bd)
    }
    [void]$left.Children.Add($head)
    if ($Text) { $d = New-Text $Text 12.5 '#8B93A7' -Wrap; $d.Margin = '0,4,24,0'; [void]$left.Children.Add($d) }
    [void]$grid.Children.Add($left)
    $sw = New-Object Windows.Controls.CheckBox
    $sw.Style = $win.FindResource('Switch')
    $sw.IsChecked = [bool]$script:State[$Sec][$Key]
    $sw.Tag = @($Sec, $Key)
    [Windows.Automation.AutomationProperties]::SetName($sw, $Title)
    [Windows.Automation.AutomationProperties]::SetAutomationId($sw, ('sw-' + $Key))
    # Checked/Unchecked, а не Click: так переключатель срабатывает и от экранного диктора, а не только от мыши и пробела.
    $onSwitch = { param($s) $script:State[$s.Tag[0]][$s.Tag[1]] = [bool]$s.IsChecked; Set-Dirty $true }
    $sw.Add_Checked($onSwitch); $sw.Add_Unchecked($onSwitch)
    [Windows.Controls.Grid]::SetColumn($sw, 1)
    [void]$grid.Children.Add($sw)
    $card.Child = $grid
    return $card
}

function Update-TweakList {
    $ui.TweakList.Children.Clear()
    if ($script:TweakMode -eq 'tweaks') {
        foreach ($t in @($script:Tweaks | Where-Object { $_.category -eq $script:Cat })) {
            if (-not $script:State.tweaks.ContainsKey($t.id)) { $script:State.tweaks[$t.id] = $false }
            [void]$ui.TweakList.Children.Add((New-Row $t.title $t.description 'tweaks' $t.id ''))
        }
    } else {
        $sec = $script:Cat
        foreach ($k in @($script:State[$sec].Keys | Sort-Object { $(if ($appNames.ContainsKey($_)) { $appNames[$_] } else { $_ }) })) {
            $name = $(if ($appNames.ContainsKey($k)) { $appNames[$k] } else { $k })
            $hint = $(if ($sec -eq 'removeApps') { 'Удалится только у тебя. Вернуть — из Microsoft Store.' } else { 'Поставится через winget с официального источника.' })
            [void]$ui.TweakList.Children.Add((New-Row $name ('{0} · {1}' -f $k, $hint) $sec $k ''))
        }
    }
}

function Update-CatTabs {
    $ui.CatTabs.Children.Clear()
    $items = @()
    if ($script:TweakMode -eq 'tweaks') {
        foreach ($k in $categoryNames.Keys) {
            $count = @($script:Tweaks | Where-Object { $_.category -eq $k }).Count
            $on = @($script:Tweaks | Where-Object { $_.category -eq $k -and $script:State.tweaks[$_.id] }).Count
            $items += , @($k, ('{0}  {1}/{2}' -f $categoryNames[$k], $on, $count))
        }
    } else {
        $items = @(@('removeApps', ('Удалить лишнее  {0}' -f @($script:State.removeApps.Values | Where-Object { $_ }).Count)), @('installApps', ('Установить  {0}' -f @($script:State.installApps.Values | Where-Object { $_ }).Count)))
    }
    foreach ($it in $items) {
        $rb = New-Object Windows.Controls.RadioButton
        $rb.Style = $win.FindResource('Pill'); $rb.GroupName = 'cat'; $rb.Content = $it[1]; $rb.Tag = $it[0]
        $rb.IsChecked = ($it[0] -eq $script:Cat)
        $rb.Add_Checked({ param($s) $script:Cat = [string]$s.Tag; Update-TweakList })
        [void]$ui.CatTabs.Children.Add($rb)
    }
}

function Open-TweaksPage([string]$Mode) {
    $script:TweakMode = $Mode
    if ($Mode -eq 'tweaks') {
        $script:Cat = 'privacy'
        $ui.TweaksTitle.Text = 'Настройки Windows'
        $ui.TweaksSub.Text = 'Включи то, что хочешь, и нажми «Применить». Перед изменениями Nova сделает точку восстановления, а любой запуск можно отменить.'
        $ui.PresetBar.Visibility = 'Visible'
    } else {
        $script:Cat = 'removeApps'
        $ui.TweaksTitle.Text = 'Приложения'
        $ui.TweaksSub.Text = 'Что удалить из предустановленного и что поставить. Удаление — только у тебя, другие учётные записи не затронет.'
        $ui.PresetBar.Visibility = 'Collapsed'
    }
    Update-CatTabs; Update-TweakList
    Show-Page $ui.PageTweaks
}

foreach ($pr in $presets) {
    $b = New-Object Windows.Controls.Button
    $b.Style = $win.FindResource('Ghost'); $b.Content = $pr.Name; $b.Tag = $pr
    $b.Add_Click({
            param($s)
            $changed = 0
            $known = @{}; foreach ($t in $script:Tweaks) { $known[[string]$t.id] = $true }
            foreach ($k in $s.Tag.Tweaks.Keys) { if ($known.ContainsKey($k) -and [bool]$script:State.tweaks[$k] -ne $s.Tag.Tweaks[$k]) { $script:State.tweaks[$k] = $s.Tag.Tweaks[$k]; $changed++ } }
            Set-Dirty ($script:Dirty -or $changed -gt 0); Update-CatTabs; Update-TweakList
            Show-Toast ('Сборка «{0}»: изменено пунктов — {1}' -f $s.Tag.Name, $changed)
        })
    [void]$ui.PresetBar.Children.Add($b)
}

#endregion

#region Состояние: проверка системы, режим игры, обновления, голос

function Update-State {
    try {
        if (Test-NovaGameModeActive) {
            $ui.GameModeState.Text = 'включён'; $ui.GameModeChip.Background = Get-Brush '#1C3A27'; $ui.GameModeState.Foreground = Get-Brush '#7CE0A3'
            $ui.BtnGameMode.Content = 'Выключить и вернуть как было'; $ui.QGameTitle.Text = 'Режим игры: включён'; $ui.QGameText.Text = 'Нажми, чтобы вернуть как было'
        } else {
            $ui.GameModeState.Text = 'выключен'; $ui.GameModeChip.Background = Get-Brush '#2A2F3C'; $ui.GameModeState.Foreground = Get-Brush '#C9CEDA'
            $ui.BtnGameMode.Content = 'Включить'; $ui.QGameTitle.Text = 'Режим игры'; $ui.QGameText.Text = 'Максимум мощности, без уведомлений'
        }
        Set-TileName $ui.QGame
    } catch { Write-Verbose 'Режим игры: состояние неизвестно.' }
}

function Update-Health {
    try {
        $context = $null
        try { $context = Get-NovaContext -ConfigPath $configPath -TweaksPath $tweaksPath } catch { $context = $null }
        $summary = Get-NovaHealthSummary (Get-NovaHealth -Context $context)
        $sys = Get-NovaSystemInfo
        $ui.SysText.Text = ('{0} {1}, сборка {2}' -f $sys.Name, $sys.Version, $sys.Build)
        if ($summary.Stop -gt 0) { $ui.HealthText.Text = 'Есть проблемы — «Проверить систему»'; $ui.HealthChip.Background = Get-Brush '#3A1C1C'; $ui.HealthText.Foreground = Get-Brush '#FF9A9A' }
        elseif ($summary.Warn -gt 0) { $ui.HealthText.Text = ('Замечаний: {0} — «Проверить систему»' -f $summary.Warn); $ui.HealthChip.Background = Get-Brush '#33290F'; $ui.HealthText.Foreground = Get-Brush '#FFC940' }
        else { $ui.HealthText.Text = 'Система готова'; $ui.HealthChip.Background = Get-Brush '#16301F'; $ui.HealthText.Foreground = Get-Brush '#7CE0A3' }
    } catch {
        $ui.HealthText.Text = 'Проверка системы — в «Обслуживании»'
    }
}

# Пункт списка изменений: звёздочка, жирное начало и полный текст с переносами.
function Add-ReleaseItem([Windows.Controls.Panel]$Panel, [object]$Release, [int]$Index, [string]$Top = '0,6,0,0') {
    $full = ''; $head = ''
    if ($Release.Full -and $Index -lt $Release.Full.Count) { $full = [string]$Release.Full[$Index] } else { $full = [string]$Release.Items[$Index] }
    if ($Release.Heads -and $Index -lt $Release.Heads.Count) { $head = [string]$Release.Heads[$Index] }
    $row = New-Object Windows.Controls.DockPanel; $row.Margin = $Top
    $dot = New-Text '✦' 12 '#FFC940'; $dot.Margin = '0,2,10,0'; [Windows.Controls.DockPanel]::SetDock($dot, 'Left')
    [void]$row.Children.Add($dot)
    $t = New-Text '' 13 '#C9CEDA' -Wrap
    if ($head -and $full.StartsWith($head)) {
        $b = New-Object Windows.Documents.Run $head; $b.FontWeight = [Windows.FontWeights]::SemiBold; $b.Foreground = Get-Brush '#FFFFFF'
        [void]$t.Inlines.Add($b)
        [void]$t.Inlines.Add((New-Object Windows.Documents.Run $full.Substring($head.Length)))
    } else { $t.Text = $full }
    [void]$row.Children.Add($t)
    [void]$Panel.Children.Add($row)
}

function Update-News {
    $ui.NewsList.Children.Clear()
    $log = Join-Path $projectRoot 'CHANGELOG.md'
    if (-not (Test-Path -LiteralPath $log)) { return }
    $rel = @(Read-NovaChangelog ([IO.File]::ReadAllText($log, [Text.Encoding]::UTF8)) | Where-Object { $_.Version }) | Select-Object -First 1
    if (-not $rel) { return }
    $ui.NewsVer.Text = 'v' + $rel.Label
    for ($i = 0; $i -lt [Math]::Min(5, $rel.Items.Count); $i++) { Add-ReleaseItem $ui.NewsList $rel $i }
}

$voiceLabels = @{
    shutdown = 'выключит компьютер через 15 секунд'; restart = 'перезагрузит'; cancel = 'отменит'; minimizeAll = 'свернёт все окна'; restoreAll = 'вернёт окна'; closeWindow = 'закроет окно впереди'
    closeAll = 'закроет все окна'; lock = 'заблокирует компьютер'; volumeUp = 'громче'; volumeDown = 'тише'; mute = 'выключит или включит звук'; playPause = 'пауза или продолжить'
    nextTrack = 'следующий трек'; prevTrack = 'предыдущий трек'; time = 'скажет, который час'; date = 'скажет дату'; battery = 'скажет заряд'; hello = 'поздоровается'
    timer = 'таймер: «… на пять минут»'; timerLeft = 'сколько осталось'; game = 'запустит игру: «… доту», «… игру» — последнюю'; gameMode = 'включит режим игры'; gameModeOff = 'выключит режим игры'
}
function Update-VoiceList {
    $ui.VoiceList.Children.Clear()
    $doc = $null
    try { $doc = Read-NovaJson (Join-Path $projectRoot 'voice.json') } catch { $doc = $null }
    if (-not $doc) { [void]$ui.VoiceList.Children.Add((New-Text 'voice.json не найден.' 14 '#FFC940')); return }
    $wake = [string](Get-NovaProp $doc 'wakeWord' 'нова')
    foreach ($c in @(Get-NovaProp $doc 'commands' @())) {
        $say = @(Get-NovaProp $c 'say' @()) | ForEach-Object { '«{0}, {1}»' -f $wake, $_ }
        $what = ''
        if (Get-NovaProp $c 'do') { $d = [string]$c.do; $what = $(if ($voiceLabels.ContainsKey($d)) { $voiceLabels[$d] } else { $d }) }
        elseif (Get-NovaProp $c 'run') { $what = 'откроет ' + (Get-NovaPlainText ([string]$c.run) 80) }
        elseif (Get-NovaProp $c 'keys') { $what = 'нажмёт ' + (Get-NovaPlainText ([string]$c.keys) 40) }
        $card = New-Object Windows.Controls.Border
        $card.CornerRadius = 12; $card.Padding = '18,12'; $card.Margin = '0,0,0,8'; $card.Background = Get-Brush '#161922'; $card.BorderBrush = Get-Brush '#20242F'; $card.BorderThickness = 1
        $sp = New-Object Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-Text (Get-NovaPlainText ($say -join ' · ') 160) 14.5 '#FFFFFF' 'SemiBold' -Wrap))
        $w = New-Text $what 12.5 '#8B93A7' -Wrap; $w.Margin = '0,3,0,0'; [void]$sp.Children.Add($w)
        $card.Child = $sp
        [void]$ui.VoiceList.Children.Add($card)
    }
}

function Update-UpdatePage([object]$Info) {
    $ui.UpdList.Children.Clear()
    $backups = @()
    try { $backups = @(Get-NovaUpdateBackups) } catch { $backups = @() }
    $ui.BtnRollback.Visibility = $(if ($backups.Count -gt 0) { 'Visible' } else { 'Collapsed' })
    if ($backups.Count -gt 0) { $ui.BtnRollback.Content = ('Вернуть прошлую версию — Nova {0}' -f $backups[0].From) }
    if (-not $Info) {
        $log = Join-Path $projectRoot 'CHANGELOG.md'
        if (Test-Path -LiteralPath $log) {
            $rel = @(Read-NovaChangelog ([IO.File]::ReadAllText($log, [Text.Encoding]::UTF8)) | Where-Object { $_.Version }) | Select-Object -First 1
            if ($rel) {
                [void]$ui.UpdList.Children.Add((New-Text ('Что нового в версии ' + $rel.Label) 16 '#FFC940' 'SemiBold'))
                for ($i = 0; $i -lt $rel.Items.Count; $i++) { Add-ReleaseItem $ui.UpdList $rel $i '0,8,0,0' }
            }
        }
        $ui.UpdTitle.Text = ('У тебя Nova {0}' -f (Get-NovaVersion))
        $ui.UpdText.Text = 'Нажми «Проверить» — Nova прочитает с GitHub список изменений. О тебе ничего не отправляется.'
        $ui.BtnDoUpd.IsEnabled = $false
        return
    }
    if ($Info.IsNewer) {
        $ui.UpdTitle.Text = ('Вышла Nova {0}' -f $Info.Latest)
        $ui.UpdText.Text = ('У тебя {0}. Обновление займёт полминуты, прошлую версию можно вернуть.' -f $Info.Current)
        $ui.BtnDoUpd.IsEnabled = $true
        foreach ($rel in $Info.Releases) {
            [void]$ui.UpdList.Children.Add((New-Text ('Версия ' + $rel.Label) 16 '#FFC940' 'SemiBold'))
            for ($i = 0; $i -lt [Math]::Min(8, $rel.Items.Count); $i++) { Add-ReleaseItem $ui.UpdList $rel $i '0,8,0,0' }
        }
    } else {
        $ui.UpdTitle.Text = ('У тебя последняя версия — Nova {0}' -f $Info.Current)
        $ui.UpdText.Text = 'Как выйдет новая — здесь появится кнопка «Обновить».'
        $ui.BtnDoUpd.IsEnabled = $false
    }
}

#endregion

#region Кнопки

$ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $win.WindowState = $(if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }) })
$ui.BtnClose.Add_Click({ $win.Close() })
# Развёрнутое окно без рамки Windows уходит за края на толщину рамки — компенсируем.
$win.Add_StateChanged({ $ui.Root.Margin = $(if ($win.WindowState -eq 'Maximized') { '7' } else { '0' }); $ui.BtnMax.Content = $(if ($win.WindowState -eq 'Maximized') { [string][char]0xE923 } else { [string][char]0xE922 }) })
$win.Add_Closing({
        param($s, $e)
        if ($script:Run) { $e.Cancel = $true; Show-Toast 'Подожди — Nova ещё работает.'; return }
        if ($script:Dirty) {
            $answer = [Windows.MessageBox]::Show('Сохранить изменения в настройках перед выходом?', 'Nova Центр', 'YesNoCancel', 'Question')
            if ($answer -eq 'Cancel') { $e.Cancel = $true; return }
            if ($answer -eq 'Yes') { Save-Config }
        }
    })

$ui.NavHome.Add_Checked({ Show-Page $ui.PageHome })
$ui.NavTweaks.Add_Checked({ Open-TweaksPage 'tweaks' })
$ui.NavApps.Add_Checked({ Open-TweaksPage 'apps' })
$ui.NavGames.Add_Checked({ Update-State; Show-Page $ui.PageGames })
$ui.NavVoice.Add_Checked({ Update-VoiceList; Show-Page $ui.PageVoice })
$ui.NavTools.Add_Checked({ Show-Page $ui.PageTools })
$ui.NavUpdate.Add_Checked({ Update-UpdatePage $null; Show-Page $ui.PageUpdate })
$ui.NavAbout.Add_Checked({ Show-Page $ui.PageAbout })

function Invoke-Apply {
    if ($script:Dirty) { Save-Config }
    Start-NovaRun -Title 'Применяю настройки' -Icon ([string][char]0xE768) -Arguments '-Mode Apply -Yes' -OnDone { param($ok) Update-Health }
}
$ui.BtnSave.Add_Click({ Save-Config; Show-Toast 'Сохранено в config.json' })
$ui.BtnPreview.Add_Click({ if ($script:Dirty) { Save-Config }; Start-NovaRun -Title 'Что изменится' -Icon ([string][char]0xE890) -Arguments '-Mode Preview' })
$ui.BtnApply.Add_Click({ Invoke-Apply })
$ui.QApply.Add_Click({ Invoke-Apply })
$toggleGame = { Start-NovaRun -Title 'Режим игры' -Icon ([string][char]0xE7FC) -Arguments '-Mode Game' -OnDone { param($ok) Update-State } }
$ui.QGame.Add_Click($toggleGame)
$ui.BtnGameMode.Add_Click($toggleGame)
$check = { Start-NovaRun -Title 'Проверка системы' -Icon ([string][char]0xE9D9) -Arguments '-Mode Check' -OnDone { param($ok) Update-Health } }
$ui.QCheck.Add_Click($check); $ui.TCheck.Add_Click($check); $ui.GReady.Add_Click($check)
$clean = { Start-NovaRun -Title 'Освобождаю место' -Icon ([string][char]0xE74D) -Arguments '-Mode Clean -Yes' }
$ui.QClean.Add_Click($clean); $ui.TClean.Add_Click($clean)
$ui.GDriver.Add_Click({ Start-NovaRun -Title 'Свежий ли драйвер' -Icon ([string][char]0xE7F4) -Arguments '-Mode Driver' })
$ui.GHeavy.Add_Click({ Start-NovaRun -Title 'Что тормозит прямо сейчас' -Icon ([string][char]0xEC4A) -Arguments '-Mode Heavy' })
$ui.GNet.Add_Click({ Start-NovaRun -Title 'Интернет для игр' -Icon ([string][char]0xE701) -Arguments '-Mode Net' })
$ui.GFps.Add_Click({ Start-NovaConsole '-Mode Fps -PauseAtEnd' })
$ui.GVoice.Add_Click({ $ui.NavVoice.IsChecked = $true })
$ui.TUndo.Add_Click({
        if ([Windows.MessageBox]::Show('Вернуть всё, как было до последнего запуска Nova?', 'Nova Центр', 'YesNo', 'Question') -ne 'Yes') { return }
        Start-NovaRun -Title 'Возвращаю как было' -Icon ([string][char]0xE7A7) -Arguments '-Mode Undo -Yes' -OnDone { param($ok) Update-Health }
    })
$ui.TStartup.Add_Click({ Start-NovaConsole '-Mode Menu'; Show-Toast 'Открываю меню Nova — выбери пункт 10' })
$ui.TReport.Add_Click({ Start-NovaRun -Title 'Отчёт для поддержки' -Icon ([string][char]0xE8A5) -Arguments '-Mode Report' })
$ui.TMenu.Add_Click({ Start-NovaConsole '-Mode Menu' })
$ui.TShortcut.Add_Click({
        try {
            $desktop = [Environment]::GetFolderPath('Desktop')
            $shell = New-Object -ComObject WScript.Shell
            $lnk = $shell.CreateShortcut((Join-Path $desktop 'Nova Центр.lnk'))
            $lnk.TargetPath = (Join-Path $projectRoot 'NovaCenter.cmd')
            $lnk.WorkingDirectory = $projectRoot
            $lnk.IconLocation = (Join-Path $projectRoot 'assets\nova.ico') + ',0'
            $lnk.WindowStyle = 7
            $lnk.Description = 'Nova Центр'
            $lnk.Save()
            Show-Toast 'Ярлык «Nova Центр» — на рабочем столе'
        } catch { Show-Toast ('Не получилось: {0}' -f (Get-NovaPlainText $_.Exception.Message 120)) }
    })
$ui.LSite.Add_Click({ Open-AsUser $links.Site })
$ui.LCabinet.Add_Click({ Open-AsUser $links.Cabinet })
$ui.LGitHub.Add_Click({ Open-AsUser $links.GitHub })
$ui.LMail.Add_Click({ Open-AsUser ('mailto:{0}?subject=Nova' -f (Get-NovaSupportEmail)) })
$ui.BtnVoiceOpen.Add_Click({ Open-AsUser (Join-Path $projectRoot 'NovaVoice.cmd') })
$ui.BtnVoiceAuto.Add_Click({ Open-AsUser (Join-Path $PSScriptRoot 'NovaVoiceStartup.cmd') })
$ui.BtnVoiceEdit.Add_Click({ Open-AsUser ($links.Cabinet + '#voice') })
$ui.BtnCheckUpd.Add_Click({
        try { Update-UpdatePage (Get-NovaUpdateInfo) } catch { $ui.UpdTitle.Text = 'Не получилось проверить'; $ui.UpdText.Text = (Get-NovaPlainText $_.Exception.Message 200) }
    })
$ui.BtnDoUpd.Add_Click({
        Start-NovaRun -Title 'Обновляю Nova' -Icon ([string][char]0xE895) -Arguments '-Mode SelfUpdate' -OnDone {
            param($ok)
            if (-not $ok) { return }
            $ui.RunResult.Text = 'Готово — открываю новую Nova'
            Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
            $win.Close()
        }
    })
$ui.BtnRollback.Add_Click({
        if ([Windows.MessageBox]::Show('Вернуть прошлую версию Nova? config.json и voice.json не изменятся.', 'Nova Центр', 'YesNo', 'Question') -ne 'Yes') { return }
        Start-NovaRun -Title 'Возвращаю прошлую версию' -Icon ([string][char]0xE7A7) -Arguments '-Mode Rollback' -OnDone {
            param($ok)
            if (-not $ok) { return }
            Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
            $win.Close()
        }
    })

#endregion

#region Первое заполнение

$logo = Get-Image (Join-Path $projectRoot 'assets\nova.png')
if ($logo) { $ui.LogoImg.Source = $logo; $win.Icon = $logo }
$hero = Get-Image (Join-Path $projectRoot 'assets\wallpaper\nova-dark.jpg')
if ($hero) { $ui.HeroImg.ImageSource = $hero }
$ui.VerText.Text = 'v' + (Get-NovaVersion)
$mailParts = (Get-NovaSupportEmail).Split('@')
$ui.MailText.Inlines.Clear()
$ui.MailText.Inlines.Add((New-Object Windows.Documents.Run $mailParts[0]))
$ui.MailText.Inlines.Add((New-Object Windows.Documents.LineBreak))
$ui.MailText.Inlines.Add((New-Object Windows.Documents.Run ('@' + $mailParts[1])))
$ui.SideStatus.Text = ('Nova {0} · всё можно вернуть' -f (Get-NovaVersion))
$ui.AboutText.Text = ('Nova {0}. Вопросы, ошибки и идеи: {1}' -f (Get-NovaVersion), (Get-NovaSupportEmail))
$ui.HealthText.Text = 'Проверяю систему…'; $ui.HealthChip.Background = Get-Brush '#22262F'; $ui.HealthText.Foreground = Get-Brush '#C9CEDA'
foreach ($tile in @('QApply', 'QCheck', 'QClean', 'LSite', 'LCabinet', 'LGitHub', 'LMail', 'GDriver', 'GReady', 'GHeavy', 'GNet', 'GFps', 'GVoice', 'TClean', 'TUndo', 'TCheck', 'TStartup', 'TReport', 'TMenu', 'TShortcut')) { Set-TileName $ui[$tile] }
Update-State
Update-News
Update-UpdatePage $null

# Окно появляется плавно.
$win.Opacity = 0
$win.Add_ContentRendered({
        [void]$win.Dispatcher.BeginInvoke([Action] { Update-Health }, [Windows.Threading.DispatcherPriority]::Background)
        $a = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @([double]0, [double]1, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(260))))
        $win.BeginAnimation([Windows.Window]::OpacityProperty, $a)
    })

#endregion

# Снимки всех страниц (для проверки на GitHub): рисуем окно в картинки и выходим.
if ($Screenshot) {
    if (-not (Test-Path -LiteralPath $Screenshot)) { New-Item -ItemType Directory -Path $Screenshot -Force | Out-Null }
    $win.Opacity = 1
    $win.Width = 1280; $win.Height = 800
    $win.WindowStartupLocation = 'Manual'; $win.Left = 0; $win.Top = 0
    $win.ShowActivated = $false
    Update-Health
    $win.Show()
    $shots = @(
        @('01-glavnaya', { $ui.NavHome.IsChecked = $true; Show-Page $ui.PageHome }),
        @('02-nastroyki', { $ui.NavTweaks.IsChecked = $true }),
        @('03-prilozheniya', { $ui.NavApps.IsChecked = $true }),
        @('04-igry', { $ui.NavGames.IsChecked = $true }),
        @('05-golos', { $ui.NavVoice.IsChecked = $true }),
        @('06-obsluzhivanie', { $ui.NavTools.IsChecked = $true }),
        @('07-obnovleniya', { $ui.NavUpdate.IsChecked = $true }),
        @('08-o-nova', { $ui.NavAbout.IsChecked = $true }),
        @('09-hod-raboty', {
                $ui.NavTweaks.IsChecked = $true
                $ui.RunLog.Children.Clear(); $ui.RunTitle.Text = 'Применяю настройки'; $ui.RunIcon.Text = [string][char]0xE768
                foreach ($l in @(@('Green', '  + Минимум телеметрии'), @('Green', '  + Без рекламного идентификатора'), @('Green', '  + Тёмная тема'), @('DarkGray', '  Создаю точку восстановления Windows…'), @('Yellow', '  ! Windows ждёт перезагрузки'), @('Green', '  + Игры в приоритете у планировщика'))) { Add-RunLine $l[0] $l[1] }
                $ui.RunOverlay.Visibility = 'Visible'; Stop-BarAnimation $true; $ui.RunResult.Text = '✓  Всё получилось'; $ui.RunResult.Foreground = Get-Brush '#7CE0A3'; $ui.RunClose.IsEnabled = $true
            })
    )
    foreach ($s in $shots) {
        & $s[1]
        # Даём анимациям закончиться и окну перерисоваться.
        $until = (Get-Date).AddMilliseconds(700)
        while ((Get-Date) -lt $until) { $win.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Background); Start-Sleep -Milliseconds 30 }
        foreach ($p in @($ui.PageHome, $ui.PageTweaks, $ui.PageGames, $ui.PageVoice, $ui.PageTools, $ui.PageUpdate, $ui.PageAbout)) { $p.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); if ($p.Visibility -eq 'Visible') { $p.Opacity = 1; $p.RenderTransform = $null } }
        $win.UpdateLayout()
        $w = [int]$ui.Root.ActualWidth; $h = [int]$ui.Root.ActualHeight
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($ui.Root)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create((Join-Path $Screenshot ('nova-center-{0}.png' -f $s[0])))
        try { $enc.Save($fs) } finally { $fs.Dispose() }
        Write-Host ('снимок: {0}' -f $s[0])
    }
    $ui.RunOverlay.Visibility = 'Collapsed'
    $script:Dirty = $false
    $win.Close()
    exit 0
}

[void]$win.ShowDialog()
