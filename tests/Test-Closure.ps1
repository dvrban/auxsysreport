#Requires -Version 5.1
<#
.SYNOPSIS
    T0.4 - AST provjera ručnih popisa funkcija koje se ubacuju u pozadinske runspaceove.

.DESCRIPTION
    Runspace ne vidi funkcije roditeljske skripte: Get-SystemInfoItemsAsync i Get-InventoryDataAsync ih ubacuju po imenu iz ručnog popisa.
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
    [string]$Path = (Join-Path $PSScriptRoot '..\dist\Auxilium-Dijagnostika-Ljuska.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Mjesta ubacivanja: funkcija koja ima ručni popis i korijenska naredba koja se u runspaceu poziva (AddCommand).
$sites = @(
    @{ Host = 'Get-SystemInfoItemsAsync'; Root = 'Get-SystemInfoItems' },
    @{ Host = 'Get-InventoryDataAsync';   Root = 'Get-InventoryData' }
)

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
    return $seen
}

foreach ($site in $sites) {
    Write-Host ('{0} -> {1}' -f $site.Host, $site.Root)
    if (-not $defined.ContainsKey($site.Host)) { $failures.Add(('funkcija {0} ne postoji' -f $site.Host)); Write-Host '  NEUSPJEH: nema funkcije' -ForegroundColor Red; continue }
    if (-not $defined.ContainsKey($site.Root)) { $failures.Add(('korijen {0} ne postoji' -f $site.Root)); Write-Host '  NEUSPJEH: nema korijena' -ForegroundColor Red; continue }

    # ručni popis: sve konstantne riječi u polju (@(...)) unutar funkcije koje su imena definiranih funkcija
    $listed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $arrays = $defined[$site.Host].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true)
    foreach ($arr in $arrays) {
        foreach ($s in $arr.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
            if ($defined.ContainsKey($s.Value)) { [void]$listed.Add($s.Value) }
        }
    }
    if ($listed.Count -eq 0) { $failures.Add(('{0}: ručni popis nije pronađen' -f $site.Host)); Write-Host '  NEUSPJEH: ručni popis nije pronađen' -ForegroundColor Red; continue }

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
