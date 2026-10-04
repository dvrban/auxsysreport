#Requires -Version 5.1
<#
.SYNOPSIS
    T0.1 - provjera podjele izvora: src\ sastavljen natrag daje izdanje v0.04 bajt po bajt i definira istih 122 funkcije.

.DESCRIPTION
    Sastavlja src\ prema pravilima iz src\README.md i uspoređuje rezultat s izdanjem (-Baseline):
      1. SHA-256 sastavljene datoteke mora biti jednak SHA-256 izdanja (UTF-8 s BOM-om, CRLF),
      2. popis funkcija najviše razine (AST) iz sastavljene datoteke mora biti jednak popisu iz izdanja, istim redoslijedom,
      3. zbroj funkcija definiranih u dijelovima src\*.ps1 (svaki parsiran zasebno) mora dati isti popis,
      4. svaki dio, kao i deep\DeepScan.ps1, mora se parsirati bez sintaksnih grešaka,
      5. svaka datoteka u src\ mora počinjati UTF-8 BOM-om (i nigdje drugdje ga nemati) i imati samo CRLF krajeve redaka.
    Povratni kod 0 = sve prolazi, 1 = barem jedna provjera ne prolazi.

    Provjera vrijedi samo dok se src\ ne razlikuje od izdanja (do prve izmjene koda u sljedećem tiketu). Poslije nje je zamjenjuju
    build.ps1 (T0.2) i Pester testovi (T0.5).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SrcSplit.ps1
#>
[CmdletBinding()]
param(
    [string]$Baseline  = (Join-Path $PSScriptRoot '..\v4\Auxilium-Dijagnostika-Ljuska.ps1'),
    [string]$SourceDir = (Join-Path $PSScriptRoot '..\src')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$utf8    = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$failures = New-Object System.Collections.Generic.List[string]

function Read-Utf8 {
    param([Parameter(Mandatory)][string]$Path)
    # ReadAllText prepoznaje BOM i ne vraća ga u tekstu: svaki dio počinje BOM-om, a u sastavljenoj datoteci BOM je samo jedan (na početku).
    return [System.IO.File]::ReadAllText($Path, $utf8)
}

function Add-Failure {
    param([Parameter(Mandatory)][string]$Text)
    $failures.Add($Text)
    Write-Host ('  NEUSPJEH: ' + $Text) -ForegroundColor Red
}

function Write-Pass {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ('  OK: ' + $Text) -ForegroundColor Green
}

function Get-Sha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') } finally { $sha.Dispose() }
}

function ConvertTo-FileBytes {
    param([Parameter(Mandatory)][string]$Text)
    $stream = New-Object System.IO.MemoryStream
    try {
        $preamble = $utf8Bom.GetPreamble()
        $stream.Write($preamble, 0, $preamble.Length)
        $body = $utf8.GetBytes($Text)
        $stream.Write($body, 0, $body.Length)
        return $stream.ToArray()
    } finally { $stream.Dispose() }
}

function Get-ParsedScript {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    return [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
}

function Get-TopLevelFunctionNames {
    param([Parameter(Mandatory)]$Parsed)
    $found = $Parsed.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    return ,@($found | ForEach-Object { $_.Name })   # zarez: prazan popis ostaje polje (inače bi ga PowerShell pretvorio u $null)
}

function Get-ListDifference {
    param([string[]]$Expected, [string[]]$Actual)
    $Expected = @($Expected)
    $Actual   = @($Actual)
    $limit = [Math]::Min($Expected.Count, $Actual.Count)
    for ($i = 0; $i -lt $limit; $i++) {
        if ($Expected[$i] -cne $Actual[$i]) { return ('prva razlika na mjestu {0}: "{1}" / "{2}"' -f ($i + 1), $Expected[$i], $Actual[$i]) }
    }
    return ('duljine {0} / {1}' -f $Expected.Count, $Actual.Count)
}

$srcRoot = (Resolve-Path -LiteralPath $SourceDir).Path
$baselinePath = (Resolve-Path -LiteralPath $Baseline).Path
Write-Host ('Izvor:   ' + $srcRoot)
Write-Host ('Izdanje: ' + $baselinePath)

# --- 1. Sastavljanje: dijelovi src\*.ps1 redom po nazivu (ordinalno), bez razdjelnika
$partFiles = @([System.IO.Directory]::GetFiles($srcRoot, '*.ps1', [System.IO.SearchOption]::TopDirectoryOnly))
[Array]::Sort($partFiles, [System.StringComparer]::Ordinal)
Write-Host ('Dijelova: {0}' -f $partFiles.Count)
if ($partFiles.Count -eq 0) { throw 'U mapi src\ nema dijelova (*.ps1).' }

$builder = New-Object System.Text.StringBuilder
foreach ($partFile in $partFiles) { [void]$builder.Append((Read-Utf8 $partFile)) }
$assembled = $builder.ToString()

# Oznaka (cijeli redak s CRLF) zamjenjuje se cijelim sadržajem datoteke: tijelo here-stringa.
$embeds = @(
    @{ Marker = '#<<NATIVE_CS>>#'; File = 'native\Native.cs' },
    @{ Marker = '#<<DEEP_SCAN>>#'; File = 'deep\DeepScan.ps1' }
)

# --- 0. Kodiranje svake datoteke u src\: UTF-8 BOM na početku (i nigdje drugdje) i samo CRLF.
# Sastavljanje (Read-Utf8) prihvaća i datoteku bez BOM-a, pa ovo ne bi uhvatila provjera SHA-256, a Windows PowerShell 5.1 bi
# pojedini dio (dot-source, Get-Content) pročitao kao ANSI i pokvario hrvatska slova.
Write-Host 'Kodiranje datoteka'
$encodingFiles = @($partFiles) + @((Join-Path $srcRoot $embeds[0].File), (Join-Path $srcRoot $embeds[1].File))
$encodingProblems = 0
foreach ($file in $encodingFiles) {
    $raw = [System.IO.File]::ReadAllBytes($file)
    $shortName = $file.Substring($srcRoot.Length).TrimStart('\', '/')
    if ($raw.Length -lt 3 -or $raw[0] -ne 0xEF -or $raw[1] -ne 0xBB -or $raw[2] -ne 0xBF) { Add-Failure ('{0}: nema UTF-8 BOM na početku' -f $shortName); $encodingProblems++; continue }
    $lone = 0
    $extraBom = 0
    for ($i = 3; $i -lt $raw.Length; $i++) {
        $b = $raw[$i]
        if ($b -eq 10 -and $raw[$i - 1] -ne 13) { $lone++ }
        elseif ($b -eq 13 -and ($i + 1 -ge $raw.Length -or $raw[$i + 1] -ne 10)) { $lone++ }
        elseif ($b -eq 0xEF -and $i + 2 -lt $raw.Length -and $raw[$i + 1] -eq 0xBB -and $raw[$i + 2] -eq 0xBF) { $extraBom++ }
    }
    if ($lone -gt 0) { Add-Failure ('{0}: {1} prekida retka koji nisu CRLF' -f $shortName, $lone); $encodingProblems++ }
    if ($extraBom -gt 0) { Add-Failure ('{0}: BOM se pojavljuje i usred datoteke ({1}x)' -f $shortName, $extraBom); $encodingProblems++ }
}
if ($encodingProblems -eq 0) { Write-Pass ('svih {0} datoteka: UTF-8 s BOM-om na početku, samo CRLF' -f $encodingFiles.Count) }
Write-Host 'Sastavljanje'
foreach ($embed in $embeds) {
    $needle = $embed.Marker + "`r`n"
    $occurrences = [regex]::Matches($assembled, [regex]::Escape($needle)).Count
    if ($occurrences -ne 1) { Add-Failure ('oznaka {0} mora biti u dijelovima točno jednom, a nađena je {1} puta' -f $embed.Marker, $occurrences); continue }
    $embedPath = Join-Path $srcRoot $embed.File
    $assembled = $assembled.Replace($needle, (Read-Utf8 $embedPath))
}

# --- 2. Bajt-identičnost s izdanjem
Write-Host 'Bajt-identičnost'
$assembledBytes = ConvertTo-FileBytes $assembled
$baselineBytes  = [System.IO.File]::ReadAllBytes($baselinePath)
$assembledHash  = Get-Sha256 $assembledBytes
$baselineHash   = Get-Sha256 $baselineBytes
if ($assembledHash -ceq $baselineHash) {
    Write-Pass ('SHA-256 sastavljene datoteke = izdanje ({0})' -f $baselineHash)
} else {
    $limit = [Math]::Min($assembledBytes.Length, $baselineBytes.Length)
    $at = 0
    $line = 1
    while ($at -lt $limit -and $assembledBytes[$at] -eq $baselineBytes[$at]) { if ($baselineBytes[$at] -eq 10) { $line++ }; $at++ }
    Add-Failure ('sastavljena datoteka se razlikuje od izdanja: prvi različit bajt na pomaku {0} (redak {1}); duljine {2} / {3}; SHA-256 {4} / {5}' -f $at, $line, $assembledBytes.Length, $baselineBytes.Length, $assembledHash, $baselineHash)
}

# --- 3. Funkcije najviše razine (AST)
Write-Host 'Funkcije najviše razine'
$baselineParsed  = Get-ParsedScript (Read-Utf8 $baselinePath)
$assembledParsed = Get-ParsedScript $assembled
$baselineNames   = Get-TopLevelFunctionNames $baselineParsed
$assembledNames  = Get-TopLevelFunctionNames $assembledParsed
if ($baselineParsed.Errors.Count -gt 0)  { Add-Failure ('izdanje se ne parsira bez grešaka (broj grešaka: {0}, prva: {1})' -f $baselineParsed.Errors.Count, $baselineParsed.Errors[0].Message) }
if ($assembledParsed.Errors.Count -gt 0) { Add-Failure ('sastavljena datoteka se ne parsira bez grešaka (broj grešaka: {0}, prva: {1})' -f $assembledParsed.Errors.Count, $assembledParsed.Errors[0].Message) }
if (($baselineNames -join "`n") -ceq ($assembledNames -join "`n")) {
    Write-Pass ('sastavljena datoteka definira istih {0} funkcija, istim redoslijedom' -f $baselineNames.Count)
} else {
    Add-Failure ('popis funkcija se razlikuje od izdanja: {0}' -f (Get-ListDifference $baselineNames $assembledNames))
}

# --- 4. Svaki dio zasebno: bez sintaksnih grešaka, a zbroj funkcija daje isti popis
Write-Host 'Dijelovi zasebno'
$partNames = New-Object System.Collections.Generic.List[string]
foreach ($partFile in ($partFiles + (Join-Path $srcRoot $embeds[1].File))) {
    $parsed = Get-ParsedScript (Read-Utf8 $partFile)
    $shortName = [System.IO.Path]::GetFileName($partFile)
    if ($parsed.Errors.Count -gt 0) { Add-Failure ('{0}: ne parsira se bez grešaka (broj grešaka: {1}, prva: {2})' -f $shortName, $parsed.Errors.Count, $parsed.Errors[0].Message); continue }
    if ($partFile -in $partFiles) { foreach ($name in (Get-TopLevelFunctionNames $parsed)) { $partNames.Add($name) } }
}
if (($baselineNames -join "`n") -ceq ($partNames -join "`n")) {
    Write-Pass ('dijelovi src\*.ps1 zajedno definiraju istih {0} funkcija, istim redoslijedom; svi se parsiraju bez grešaka' -f $partNames.Count)
} else {
    Add-Failure ('zbroj funkcija iz dijelova ne odgovara izdanju: {0}' -f (Get-ListDifference $baselineNames $partNames.ToArray()))
}

if ($failures.Count -gt 0) {
    Write-Host ('NEUSPJEH: broj provjera koje ne prolaze: {0}.' -f $failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'SVE PROVJERE PROLAZE.' -ForegroundColor Green
exit 0
