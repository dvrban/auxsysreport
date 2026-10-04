#Requires -Version 5.1
<#
.SYNOPSIS
    T0.5 - pokreće Pester 5 testove (tests\Unit).

.DESCRIPTION
    Testovi učitavaju samo tražene funkcije iz src\ (AST), pa ne trebaju build. Zahtijeva Pester 5.x (samo razvojno računalo):
    Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser. Windows PowerShell 5.1 ima ugrađen Pester 3: -MinimumVersion 5 je obavezan.
    Povratni kod 0 = svi testovi prolaze.
#>
[CmdletBinding()]
param([string]$Path = '')

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }   # $PSScriptRoot u zadanoj vrijednosti parametra nije pouzdan (Windows PowerShell 5.1)
if ([string]::IsNullOrEmpty($Path)) { $Path = Join-Path $root 'Unit' }
$module = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $module) { throw 'Pester 5 nije instaliran: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck' }
Import-Module $module.Path -Force

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
Write-Host ('Pester: {0} testova prolazi, {1} preskočeno.' -f $result.PassedCount, $result.SkippedCount) -ForegroundColor Green
exit 0
