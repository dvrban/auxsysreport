# Pomoćne funkcije za Pester testove (T0.5).
# Dijelovi u src\ ne mogu se dot-sourceati u cijelosti: 04-Elevation i 90-Main izvode radnje pri učitavanju (UAC, prozor).
# Zato se iz src\*.ps1 AST-om izdvoje samo tražene funkcije (tekst definicije), a test ih definira dot-sourceom:
#     . ([scriptblock]::Create((Get-AuxFunctionText 'Format-Bytes', 'ConvertTo-SafeName')))

$script:AuxSrcRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src'))

function Get-AuxFunctionText {
    param([Parameter(Mandatory)][string[]]$Name)
    $files = @([System.IO.Directory]::GetFiles($script:AuxSrcRoot, '*.ps1', [System.IO.SearchOption]::TopDirectoryOnly))
    [Array]::Sort($files, [System.StringComparer]::Ordinal)
    $found = @{}
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            if ($Name -contains $f.Name) { $found[$f.Name] = $f.Extent.Text }
        }
    }
    foreach ($n in $Name) { if (-not $found.ContainsKey($n)) { throw ('Funkcija {0} nije pronađena u src\.' -f $n) } }
    return (($Name | ForEach-Object { $found[$_] }) -join "`r`n`r`n")
}

function Test-IsWindowsPlatform {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}
