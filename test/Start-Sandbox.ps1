#Requires -Version 5.1
<#
.SYNOPSIS
    T0.6 - pokreće sastavljeni alat (dist\) u Windows Sandboxu: čist Windows, pravi UAC, bez Officea, bez instalacije.

.DESCRIPTION
    Windows Sandbox mora biti uključen (Windows 10/11 Pro, Enterprise ili Education: Uključivanje ili isključivanje značajki sustava Windows).
    Skripta iz predloška test\Auxilium.wsb izrađuje test\Auxilium.generated.wsb s punom putanjom mape dist\ i otvara ga.
    Mapa dist\ je u Sandboxu zapisiva (C:\Auxilium: alat uz skriptu sprema postavke i izvještaje, a promjene ostaju na računalu domaćinu); mrežu i GPU isključuje. Prije toga pokrenite build.ps1.
    Kontrolna lista za ručni pregled: test\README.md.
#>
[CmdletBinding()]
param([string]$DistDir = '', [switch]$NoLaunch)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }   # $PSScriptRoot u zadanoj vrijednosti parametra nije pouzdan (Windows PowerShell 5.1)
if ([string]::IsNullOrEmpty($DistDir)) { $DistDir = Join-Path $root '..\dist' }
$dist = (Resolve-Path -LiteralPath $DistDir).Path
foreach ($need in 'Auxilium-Dijagnostika-Ljuska.ps1', 'Pokreni-Auxilium-Ljuska.cmd') {
    if (-not (Test-Path -LiteralPath (Join-Path $dist $need))) { throw ('U {0} nema {1}: prvo pokrenite build.ps1.' -f $dist, $need) }
}
$template = [System.IO.File]::ReadAllText((Join-Path $root 'Auxilium.wsb'))
$generated = $template.Replace('__DIST__', [System.Security.SecurityElement]::Escape($dist))
$out = Join-Path $root 'Auxilium.generated.wsb'
[System.IO.File]::WriteAllText($out, $generated, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('Zapisano: {0}' -f $out)
if (-not $NoLaunch) {
    if (-not (Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue)) { throw 'Windows Sandbox nije uključen na ovom računalu.' }
    Start-Process -FilePath $out
}
