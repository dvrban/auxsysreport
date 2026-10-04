BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Get-DeepTimingText', 'Get-DeepStderrHint', 'ConvertFrom-ConsoleBytes')))
    function B { param([string]$s) return ,[System.Text.Encoding]::UTF8.GetBytes($s) }
}

Describe 'Get-DeepTimingText (T2.7: mjerenje skupina dubokog skeniranja)' {
    It 'pretvara kumulativna vremena u trajanje po skupini i ukupno' {
        $t = Get-DeepTimingText (B "AUXTIMING dnevnici=3000;sigurnost=5500;softver=9800;update=14700`r`n")
        $t | Should -Be 'dnevnici 3.0 s, sigurnost 2.5 s, softver 4.3 s, update 4.9 s (ukupno 14.7 s)'
    }
    It 'nađe redak i među drugim stderr tekstom' {
        (Get-DeepTimingText (B "neka upozorenja`r`nAUXTIMING dnevnici=1000`r`n")) | Should -Be 'dnevnici 1.0 s (ukupno 1.0 s)'
    }
    It 'bez mjerenja ili s neispravnim zapisom vraća prazan niz' {
        Get-DeepTimingText (B '') | Should -Be ''
        Get-DeepTimingText (B 'samo tekst') | Should -Be ''
        Get-DeepTimingText (B "AUXTIMING bezvrijednosti;x=abc`r`n") | Should -Be ''
    }
    It 'Get-DeepStderrHint ne uključuje redak AUXTIMING u razlog neuspjeha' {
        $h = Get-DeepStderrHint (B "Greška X`r`nAUXTIMING dnevnici=1000`r`n")
        $h | Should -Not -Match 'AUXTIMING'
        $h | Should -Match 'Greška X'
    }
}
