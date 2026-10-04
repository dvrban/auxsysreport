#Requires -Version 5.1
<#
.SYNOPSIS
    T0.3 - PSScriptAnalyzer s baselineom: postojeći nalazi su zabilježeni, novi ruše build.

.DESCRIPTION
    Analizira sastavljenu skriptu (dist\) i src\deep\DeepScan.ps1 (dijete-skripta je u izvornom alatu običan tekst, pa je PSSA inače ne vidi)
    s pravilima iz PSScriptAnalyzerSettings.psd1. Nalaz se ne prepoznaje po broju retka (pomiče se pri svakoj izmjeni), nego po ključu
    "datoteka | pravilo | funkcija | poruka"; baseline (tests\pssa-baseline.json) bilježi broj nalaza po ključu.
      * više nalaza od baselinea za neki ključ = NOVI nalaz, povratni kod 1,
      * manje = popravljeno: ispisuje se napomena; -UpdateBaseline spušta baseline (ratchet), pa se popravak ne može vratiti.
    -UpdateBaseline zapisuje trenutno stanje kao baseline (koristiti samo nakon pregleda).
    Rezultati ovise o verziji PSScriptAnalyzera (baseline je snimljen s 1.22.0); pri nadogradnji ga treba osvježiti.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Analyze.ps1
#>
[CmdletBinding()]
param(
    [string]$DistPath = '',
    [string]$DeepPath = '',
    [string]$Settings = '',
    [string]$BaselinePath = '',
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }   # $PSScriptRoot u zadanoj vrijednosti parametra nije pouzdan (Windows PowerShell 5.1)

if ([string]::IsNullOrEmpty($DistPath))     { $DistPath = Join-Path $root '..\dist\Auxilium-Dijagnostika-Ljuska.ps1' }
if ([string]::IsNullOrEmpty($DeepPath))     { $DeepPath = Join-Path $root '..\src\deep\DeepScan.ps1' }
if ([string]::IsNullOrEmpty($Settings))     { $Settings = Join-Path $root '..\PSScriptAnalyzerSettings.psd1' }
if ([string]::IsNullOrEmpty($BaselinePath)) { $BaselinePath = Join-Path $root 'pssa-baseline.json' }

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    throw 'Modul PSScriptAnalyzer nije instaliran (samo razvojno računalo): Install-Module PSScriptAnalyzer -Scope CurrentUser'
}
Import-Module PSScriptAnalyzer
$version = (Get-Module PSScriptAnalyzer).Version.ToString()

function Get-EnclosingFunction {
    param($Ast, [int]$Line)
    $best = $null
    $found = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($f in $found) {
        if ($f.Extent.StartLineNumber -le $Line -and $f.Extent.EndLineNumber -ge $Line) {
            if ($null -eq $best -or ($f.Extent.EndLineNumber - $f.Extent.StartLineNumber) -lt ($best.Extent.EndLineNumber - $best.Extent.StartLineNumber)) { $best = $f }
        }
    }
    if ($null -eq $best) { return '<skripta>' }
    return $best.Name
}

$counts = @{}
$targets = @(@{ Label = 'Ljuska'; Path = $DistPath }, @{ Label = 'DeepScan'; Path = $DeepPath })
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t.Path)) { throw ('Nema datoteke za analizu: {0} (prvo pokrenite build.ps1).' -f $t.Path) }
    $path = (Resolve-Path -LiteralPath $t.Path).Path
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $records = @(Invoke-ScriptAnalyzer -Path $path -Settings $Settings)
    foreach ($r in $records) {
        $fn = Get-EnclosingFunction $ast $r.Line
        $key = '{0} | {1} | {2} | {3}' -f $t.Label, $r.RuleName, $fn, $r.Message
        if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
    }
    Write-Host ('{0}: {1} nalaza' -f $t.Label, $records.Count)
}

function ConvertTo-BaselineJson {
    param([hashtable]$Map)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Map.Keys) { $keys.Add($k) }
    $keys.Sort([System.StringComparer]::Ordinal)
    $items = foreach ($k in $keys) { [ordered]@{ key = $k; count = $Map[$k] } }
    $doc = [ordered]@{ analyzerVersion = $version; findings = @($items) }
    return (($doc | ConvertTo-Json -Depth 4) -replace "`r?`n", "`r`n") + "`r`n"
}

if ($UpdateBaseline) {
    [System.IO.File]::WriteAllText($BaselinePath, (ConvertTo-BaselineJson $counts), (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ('Baseline zapisan: {0} ključeva, {1} nalaza.' -f $counts.Count, (($counts.Values | Measure-Object -Sum).Sum))
    exit 0
}

if (-not (Test-Path -LiteralPath $BaselinePath)) { throw ('Nema baselinea: {0} (pokrenite uz -UpdateBaseline).' -f $BaselinePath) }
$baseline = @{}
$doc = [System.IO.File]::ReadAllText($BaselinePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
foreach ($item in @($doc.findings)) { $baseline[[string]$item.key] = [int]$item.count }
if ([string]$doc.analyzerVersion -ne $version) { Write-Warning ('Baseline je snimljen s PSScriptAnalyzer {0}, a koristi se {1}: razlike mogu biti posljedica verzije.' -f $doc.analyzerVersion, $version) }

$new = New-Object System.Collections.Generic.List[string]
$fixed = 0
foreach ($k in $counts.Keys) {
    $had = 0
    if ($baseline.ContainsKey($k)) { $had = $baseline[$k] }
    if ($counts[$k] -gt $had) { $new.Add(('{0}x (baseline {1}): {2}' -f ($counts[$k]), $had, $k)) }
}
foreach ($k in $baseline.Keys) {
    $now = 0
    if ($counts.ContainsKey($k)) { $now = $counts[$k] }
    if ($now -lt $baseline[$k]) { $fixed += ($baseline[$k] - $now) }
}
if ($fixed -gt 0) { Write-Host ('Popravljeno u odnosu na baseline: {0} nalaza. Pokrenite uz -UpdateBaseline da se baseline spusti.' -f $fixed) -ForegroundColor Yellow }
if ($new.Count -gt 0) {
    $new.Sort([System.StringComparer]::Ordinal)
    foreach ($line in $new) { Write-Host ('  NOVO: ' + $line) -ForegroundColor Red }
    Write-Host ('NEUSPJEH: novih nalaza (ključeva): {0}.' -f $new.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'PSScriptAnalyzer: nema novih nalaza.' -ForegroundColor Green
exit 0
