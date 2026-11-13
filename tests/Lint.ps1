# Проверка кода: синтаксис, кодировка, JSON и PSScriptAnalyzer.
# Запуск: .\tests\Lint.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failed = $false

Write-Host '== Синтаксис PowerShell'
$scripts = @(Get-ChildItem -Path $root -Recurse -Include '*.ps1', '*.psm1' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
foreach ($file in $scripts) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors) {
        $failed = $true
        foreach ($e in $errors) { Write-Host ('::error file={0},line={1}::{2}' -f $file.FullName, $e.Extent.StartLineNumber, $e.Message) }
    } else {
        Write-Host ('   ok  {0}' -f $file.Name)
    }
}

Write-Host '== Кодировка (UTF-8 с BOM нужна, чтобы Windows PowerShell 5.1 правильно читал русский текст)'
foreach ($file in $scripts) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom) {
        $failed = $true
        Write-Host ('::error file={0}::Файл должен быть в UTF-8 с BOM' -f $file.FullName)
    } else {
        Write-Host ('   ok  {0}' -f $file.Name)
    }
}

Write-Host '== JSON'
foreach ($file in @(Get-ChildItem -Path $root -Recurse -Filter '*.json' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })) {
    try {
        Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
        Write-Host ('   ok  {0}' -f $file.Name)
    } catch {
        $failed = $true
        Write-Host ('::error file={0}::{1}' -f $file.FullName, $_.Exception.Message)
    }
}

Write-Host '== PSScriptAnalyzer'
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -AllowClobber
}
Import-Module PSScriptAnalyzer
# Write-Host — это намеренно: Nova — консольная программа с цветным выводом.
$excluded = @('PSAvoidUsingWriteHost', 'PSUseShouldProcessForStateChangingFunctions', 'PSUseSingularNouns')
$issues = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'src') -Recurse -ExcludeRule $excluded)
$issues += @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'tests') -Recurse -ExcludeRule $excluded)
foreach ($issue in $issues) {
    $level = 'warning'
    if ($issue.Severity -eq 'Error' -or $issue.Severity -eq 'ParseError') { $level = 'error'; $failed = $true }
    Write-Host ('::{0} file={1},line={2}::{3}: {4}' -f $level, $issue.ScriptPath, $issue.Line, $issue.RuleName, $issue.Message)
}
Write-Host ('   замечаний: {0}' -f $issues.Count)

if ($failed) {
    Write-Host 'Проверка не пройдена.'
    exit 1
}
Write-Host 'Всё чисто.'
