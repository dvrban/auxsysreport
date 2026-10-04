#Requires -Version 5.1
<#
.SYNOPSIS
    T0.2 - sastavlja src\ u jednu datoteku dist\Auxilium-Dijagnostika-Ljuska.ps1 (UTF-8 s BOM-om, CRLF) i piše dist\MANIFEST.txt.

.DESCRIPTION
    Pravila sastavljanja su u src\README.md. Bez parametara rezultat je bajt-identičan izdanju v4 (isti SHA-256).
    Build pada (iznimka, povratni kod 1) ako: oznaka ugrađenog dijela nije u izvoru točno jednom, neka datoteka nema BOM ili ima prekid retka
    koji nije CRLF, sastavljena datoteka ili dijete-skripta ne parsira se bez grešaka, ili BuildNumber nije moguće zamijeniti.
    Git hash (ako postoji git) ispisuje se i zapisuje u MANIFEST.txt kao komentar; u izvornik se ne umeće (to je zadatak T1.12).

.PARAMETER BuildNumber
    Ako je zadan (> 0), zamjenjuje broj u retku $script:BuildNumber. Zadano 0 = zadržava vrijednost iz src\.

.PARAMETER OutputDir
    Izlazna mapa (zadano dist\ uz ovu skriptu).

.PARAMETER SkipAnalyze
    Preskače PSScriptAnalyzer (tests\Invoke-Analyze.ps1). Zadano se pokreće ako je modul instaliran; novi nalazi (preko baselinea) ruše build.

.PARAMETER SkipClosureCheck
    Preskače tests\Test-Closure.ps1 (AST provjera popisa funkcija ubačenih u runspaceove; zadano se pokreće i ruši build).

.PARAMETER SkipTests
    Preskače Pester testove (tests\Invoke-Tests.ps1; pokreću se ako je instaliran Pester 5, inače upozorenje).

.PARAMETER RequireAnalyzer
    Ako PSScriptAnalyzer nije instaliran, build pada umjesto da upozori i preskoči analizu.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -BuildNumber 5
#>
[CmdletBinding()]
param(
    [int]$BuildNumber = 0,
    [string]$OutputDir = '',
    [switch]$SkipAnalyze,
    [switch]$SkipClosureCheck,
    [switch]$SkipTests,
    [switch]$RequireAnalyzer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }   # $PSScriptRoot u zadanoj vrijednosti parametra nije pouzdan (Windows PowerShell 5.1)

$utf8    = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$srcRoot = Join-Path $root 'src'
if ([string]::IsNullOrEmpty($OutputDir)) { $OutputDir = Join-Path $root 'dist' }
$outName = 'Auxilium-Dijagnostika-Ljuska.ps1'

function Read-SourceFile {
    param([Parameter(Mandatory)][string]$Path)
    $raw = [System.IO.File]::ReadAllBytes($Path)
    $name = [System.IO.Path]::GetFileName($Path)
    if ($raw.Length -lt 3 -or $raw[0] -ne 0xEF -or $raw[1] -ne 0xBB -or $raw[2] -ne 0xBF) { throw ('{0}: nema UTF-8 BOM na početku.' -f $name) }
    for ($i = 3; $i -lt $raw.Length; $i++) {
        $isLoneLf = ($raw[$i] -eq 10 -and $raw[$i - 1] -ne 13)
        $isLoneCr = ($raw[$i] -eq 13 -and ($i + 1 -ge $raw.Length -or $raw[$i + 1] -ne 10))
        if ($isLoneLf -or $isLoneCr) { throw ('{0}: prekid retka koji nije CRLF (pomak {1}).' -f $name, $i) }
    }
    return $utf8.GetString($raw, 3, $raw.Length - 3)
}

function Test-Parses {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$What)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ('{0} se ne parsira: {1}' -f $What, @($errors)[0].Message) }
}

# --- 1. Dijelovi: src\*.ps1 (bez podmapa), ordinalni redoslijed, spajaju se bez razdjelnika
$partFiles = @([System.IO.Directory]::GetFiles($srcRoot, '*.ps1', [System.IO.SearchOption]::TopDirectoryOnly))
if ($partFiles.Count -eq 0) { throw 'U mapi src\ nema dijelova (*.ps1).' }
[Array]::Sort($partFiles, [System.StringComparer]::Ordinal)
$builder = New-Object System.Text.StringBuilder
foreach ($partFile in $partFiles) { [void]$builder.Append((Read-SourceFile $partFile)) }
$text = $builder.ToString()

# --- 2. Ugrađeni dijelovi: doslovna zamjena (ne -replace: $_ i $' u DeepScan.ps1 bi pokvarili tekst)
$embeds = @(
    @{ Marker = '#<<NATIVE_CS>>#'; File = 'native\Native.cs' },
    @{ Marker = '#<<DEEP_SCAN>>#'; File = 'deep\DeepScan.ps1' }
)
$deepText = $null
foreach ($embed in $embeds) {
    $needle = $embed.Marker + "`r`n"
    $count = ([regex]::Matches($text, [regex]::Escape($needle))).Count
    if ($count -ne 1) { throw ('Oznaka {0} mora biti u dijelovima točno jednom, a nađena je {1} puta.' -f $embed.Marker, $count) }
    $body = Read-SourceFile (Join-Path $srcRoot $embed.File)
    if ($body -match "(?m)^'@") { throw ('{0} sadrži redak koji počinje s ''@ i prekinuo bi here-string.' -f $embed.File) }
    if ($embed.Marker -eq '#<<DEEP_SCAN>>#') { $deepText = $body }
    $text = $text.Replace($needle, $body)
}

# --- 3. BuildNumber (samo na traženje)
if ($BuildNumber -gt 0) {
    $matches = [regex]::Matches($text, '(?m)^\$script:BuildNumber\s*=\s*\d+')
    if ($matches.Count -ne 1) { throw ('Redak $script:BuildNumber mora postojati točno jednom, a nađen je {0} puta.' -f $matches.Count) }
    $m = $matches[0]
    $text = $text.Substring(0, $m.Index) + '$script:BuildNumber = ' + $BuildNumber + $text.Substring($m.Index + $m.Length)
}

# --- 4. Provjere rezultata
Test-Parses $text 'Sastavljena datoteka'
Test-Parses $deepText 'src\deep\DeepScan.ps1'

# --- 5. Zapis: UTF-8 s BOM-om, CRLF
if (-not (Test-Path -LiteralPath $OutputDir)) { [void](New-Item -ItemType Directory -Path $OutputDir -Force) }
$outPath = Join-Path $OutputDir $outName
$stream = New-Object System.IO.MemoryStream
try {
    $preamble = $utf8Bom.GetPreamble()
    $stream.Write($preamble, 0, $preamble.Length)
    $bodyBytes = $utf8.GetBytes($text)
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $bytes = $stream.ToArray()
} finally { $stream.Dispose() }
[System.IO.File]::WriteAllBytes($outPath, $bytes)

$sha = [System.Security.Cryptography.SHA256]::Create()
try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }

$commit = ''
try {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git) {
        $out = & git -C $root rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { $commit = ([string]@($out)[0]).Trim() }
    }
} catch { $commit = '' }   # namjerno: git nije obavezan za build

$manifest = New-Object System.Text.StringBuilder
[void]$manifest.Append(('{0}  {1}' -f $hash, $outName) + "`r`n")
# Pokretač (.cmd) uz skriptu: bajt-kopija iz src\launcher\ (ne ulazi u sastavljanje, nego se samo kopira)
$launcherName = 'Pokreni-Auxilium-Ljuska.cmd'
$launcherBytes = [System.IO.File]::ReadAllBytes((Join-Path $srcRoot ('launcher\' + $launcherName)))
[System.IO.File]::WriteAllBytes((Join-Path $OutputDir $launcherName), $launcherBytes)
$sha2 = [System.Security.Cryptography.SHA256]::Create()
try { $launcherHash = [BitConverter]::ToString($sha2.ComputeHash($launcherBytes)).Replace('-', '') } finally { $sha2.Dispose() }
[void]$manifest.Append(('{0}  {1}' -f $launcherHash, $launcherName) + "`r`n")
if ($commit) { [void]$manifest.Append(('# git {0}' -f $commit) + "`r`n") }

[System.IO.File]::WriteAllText((Join-Path $OutputDir 'MANIFEST.txt'), $manifest.ToString(), (New-Object System.Text.ASCIIEncoding))

Write-Host ('Sastavljeno: {0}' -f $outPath)
Write-Host ('Dijelova: {0}, bajtova: {1}, SHA-256: {2}{3}' -f $partFiles.Count, $bytes.Length, $hash, $(if ($commit) { ', git ' + $commit } else { '' }))

# --- 6. Zatvaranje ovisnosti ubačenih funkcija (T0.4): nedostajuća funkcija ruši build, ne runtime
if (-not $SkipClosureCheck) {
    $closureHost = (Get-Process -Id $PID).Path
    & $closureHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Test-Closure.ps1') -Path $outPath
    if ($LASTEXITCODE -ne 0) { throw 'Zatvaranje ovisnosti ubačenih funkcija nije u redu (vidi iznad).' }
}

# --- 7. Pester (T0.5)
if (-not $SkipTests) {
    $pesterOk = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 } | Select-Object -First 1
    if ($pesterOk) {
        $testHost = (Get-Process -Id $PID).Path
        & $testHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Invoke-Tests.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Pester testovi ne prolaze (vidi iznad).' }
    } else {
        Write-Warning 'Pester 5 nije instaliran: testovi su preskočeni (Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser).'
    }
}

# --- 8. PSScriptAnalyzer (T0.3): novi nalazi u odnosu na baseline ruše build
if (-not $SkipAnalyze) {
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        $analyzeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'tests\Invoke-Analyze.ps1'), '-DistPath', $outPath)
        $hostExe = (Get-Process -Id $PID).Path
        & $hostExe @analyzeArgs
        if ($LASTEXITCODE -ne 0) { throw 'PSScriptAnalyzer: novi nalazi u odnosu na baseline (vidi iznad).' }
    } elseif ($RequireAnalyzer) {
        throw 'PSScriptAnalyzer nije instaliran, a zadan je -RequireAnalyzer.'
    } else {
        Write-Warning 'PSScriptAnalyzer nije instaliran: analiza je preskočena (Install-Module PSScriptAnalyzer -Scope CurrentUser).'
    }
}
