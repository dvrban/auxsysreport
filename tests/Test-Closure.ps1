#Requires -Version 5.1
<#
.SYNOPSIS
    T0.4 - AST provjera ručnih popisa funkcija koje se ubacuju u pozadinske runspaceove.

.DESCRIPTION
    Runspace ne vidi funkcije roditeljske skripte: svaki poziv Invoke-BackgroundRunspace ubacuje funkcije po imenu iz popisa -Functions.
    Nova pomoćna funkcija koju neka ubačena funkcija pozove, a nije na popisu, puca tek u runspaceu ("nije prepoznat kao naziv cmdleta"),
    zakopana iza praznog catch. Ova provjera iz AST-a sastavljene skripte izračuna potpuno zatvaranje ovisnosti od korijenske funkcije i:
      * pada ako zatvaranje sadrži funkciju koje nema na ručnom popisu (nedostaje u runspaceu),
      * pada ako neka funkcija iz zatvaranja koristi $script: ili $global: (u runspaceu te varijable ne postoje),
      * ispisuje napomenu (ne pada) za funkcije na popisu koje korijen ne poziva.
    Povratni kod 0 = prolazi, 1 = ne prolazi. Pokreće ga build.ps1 (osim uz -SkipClosureCheck).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Closure.ps1 -Path .\dist\Auxilium-Dijagnostika-Ljuska.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }   # $PSScriptRoot u zadanoj vrijednosti parametra nije pouzdan (Windows PowerShell 5.1)

# Mjesta ubacivanja se otkrivaju iz AST-a: svaki poziv Invoke-BackgroundRunspace (-Functions @('a','b'), -Command 'x') u funkciji koja ga zove.

if ([string]::IsNullOrEmpty($Path)) { $Path = Join-Path $root '..\dist\Auxilium-Dijagnostika-Ljuska.ps1' }
if (-not (Test-Path -LiteralPath $Path)) { throw ('Nema datoteke: {0} (prvo pokrenite build.ps1).' -f $Path) }
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $Path).Path, [ref]$tokens, [ref]$errors)
if (@($errors).Count -gt 0) { throw ('Datoteka se ne parsira: {0}' -f @($errors)[0].Message) }

$defined = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { $defined[$f.Name] = $f }

$failures = New-Object System.Collections.Generic.List[string]

function Get-Closure {
    param([string]$Root)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $todo = New-Object 'System.Collections.Generic.Stack[string]'
    $todo.Push($Root)
    while ($todo.Count -gt 0) {
        $name = $todo.Pop()
        if (-not $seen.Add($name)) { continue }
        $fn = $defined[$name]
        $cmds = $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $cmds) {
            $callee = $c.GetCommandName()
            if ($callee -and $defined.ContainsKey($callee)) { $todo.Push($callee) }
        }
    }
    return ,$seen   # zarez: inače PowerShell raspakira HashSet (jedan element postaje string bez svojstva Count)
}

$sites = New-Object System.Collections.Generic.List[object]
foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-BackgroundRunspace' }, $true)) {
    $hostFn = $call.Parent
    while ($null -ne $hostFn -and $hostFn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $hostFn = $hostFn.Parent }
    if ($null -eq $hostFn -or $hostFn.Name -eq 'Invoke-BackgroundRunspace') { continue }   # sama definicija nije mjesto poziva
    $els = @($call.CommandElements)
    $rootName = $null
    $funcNames = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $els.Count - 1; $i++) {
        if ($els[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        $pname = $els[$i].ParameterName
        if ($pname -eq 'Command' -and $els[$i + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $rootName = $els[$i + 1].Value }
        if ($pname -eq 'Functions') {
            foreach ($s in $els[$i + 1].FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) { $funcNames.Add($s.Value) }
        }
    }
    $sites.Add(@{ Host = $hostFn.Name; Root = $rootName; Listed = $funcNames.ToArray() })
}
if ($sites.Count -eq 0) { Write-Host 'NEUSPJEH: nijedan poziv Invoke-BackgroundRunspace nije pronađen.' -ForegroundColor Red; exit 1 }

foreach ($site in $sites) {
    Write-Host ('{0} -> {1}' -f $site.Host, $site.Root)
    if ([string]::IsNullOrEmpty($site.Root)) { $failures.Add(('{0}: -Command nije konstanta' -f $site.Host)); Write-Host '  NEUSPJEH: -Command mora biti konstantan niz' -ForegroundColor Red; continue }
    if (-not $defined.ContainsKey($site.Root)) { $failures.Add(('korijen {0} ne postoji' -f $site.Root)); Write-Host '  NEUSPJEH: nema korijena' -ForegroundColor Red; continue }
    $listed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $site.Listed) { [void]$listed.Add($n) }
    foreach ($n in $listed) { if (-not $defined.ContainsKey($n)) { $failures.Add(('{0}: -Functions navodi nepostojeću funkciju {1}' -f $site.Host, $n)); Write-Host ('  NEUSPJEH: nepostojeća funkcija na popisu: {0}' -f $n) -ForegroundColor Red } }
    if ($listed.Count -eq 0) { $failures.Add(('{0}: popis -Functions nije pronađen' -f $site.Host)); Write-Host '  NEUSPJEH: popis -Functions nije pronađen' -ForegroundColor Red; continue }

    $closure = Get-Closure $site.Root
    $missing = @($closure | Where-Object { -not $listed.Contains($_) })
    $extra   = @($listed | Where-Object { -not $closure.Contains($_) })
    if ($missing.Count -gt 0) {
        $failures.Add(('{0}: u runspaceu nedostaju: {1}' -f $site.Host, ($missing -join ', ')))
        Write-Host ('  NEUSPJEH: u runspaceu nedostaju funkcije: {0}' -f ($missing -join ', ')) -ForegroundColor Red
    }
    if ($extra.Count -gt 0) { Write-Host ('  napomena: na popisu, a korijen ih ne poziva: {0}' -f ($extra -join ', ')) -ForegroundColor Yellow }

    foreach ($name in $closure) {
        $vars = $defined[$name].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and ($n.VariablePath.IsScript -or $n.VariablePath.IsGlobal) }, $true)
        if (@($vars).Count -gt 0) {
            $first = @($vars)[0]
            $failures.Add(('{0}: koristi {1} (redak {2}), a u runspaceu te varijable ne postoje' -f $name, $first.Extent.Text, $first.Extent.StartLineNumber))
            Write-Host ('  NEUSPJEH: {0} koristi {1} (redak {2}); u runspaceu ta varijabla ne postoji' -f $name, $first.Extent.Text, $first.Extent.StartLineNumber) -ForegroundColor Red
        }
    }
    if ($missing.Count -eq 0) { Write-Host ('  OK: zatvaranje {0} funkcija: {1}' -f $closure.Count, ((@($closure) | Sort-Object) -join ', ')) -ForegroundColor Green }
}

if ($failures.Count -gt 0) {
    Write-Host ('NEUSPJEH: broj grešaka: {0}.' -f $failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'Zatvaranje ovisnosti ubačenih funkcija: u redu.' -ForegroundColor Green
exit 0
