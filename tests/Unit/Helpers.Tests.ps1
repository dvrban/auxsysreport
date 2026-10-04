# -Skip se računa u fazi otkrivanja, prije BeforeAll: pomoćne funkcije moraju biti učitane na vrhu datoteke
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Format-Bytes', 'ConvertTo-SafeName', 'New-InfoItem', 'Get-HealthLevel')))
    # -f koristi trenutnu kulturu (hr-HR daje zarez): testovi se izvode s nepromjenjivom kulturom
    $script:savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
}
AfterAll {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:savedCulture
}

Describe 'Format-Bytes' {
    It 'bajtovi bez decimala' {
        Format-Bytes 0 | Should -Be '0 B'
        Format-Bytes 999 | Should -Be '999 B'
        Format-Bytes 1023 | Should -Be '1,023 B'   # N0 ima separator tisuća
    }
    It 'KB, MB, GB s jednom decimalom' {
        Format-Bytes 1536 | Should -Be '1.5 KB'
        Format-Bytes (1MB) | Should -Be '1.0 MB'
        Format-Bytes (2.5GB) | Should -Be '2.5 GB'
    }
    It 'TB s dvije decimale' {
        Format-Bytes (1TB) | Should -Be '1.00 TB'
    }
}

Describe 'ConvertTo-SafeName' {
    It 'zamjenjuje znakove nedopuštene u nazivu datoteke' {
        ConvertTo-SafeName 'Tvrtka/d.o.o.' | Should -Be 'Tvrtka_d.o.o'
    }
    It 'na Windowsu zamjenjuje i : * ? " < > |' -Skip:(-not (Test-IsWindowsPlatform)) {
        ConvertTo-SafeName 'a:b*c?d' | Should -Be 'a_b_c_d'
    }
    It 'prazan ili null naziv daje zamjenski' {
        ConvertTo-SafeName '' | Should -Be 'nepoznato'
        ConvertTo-SafeName $null -Fallback 'x' | Should -Be 'x'
    }
    It 'rezervirani nazivi Windowsa dobivaju prefiks' {
        ConvertTo-SafeName 'con' | Should -Be '_con'
        ConvertTo-SafeName 'LPT1' | Should -Be '_LPT1'
    }
    It 'skraćuje na MaxLength i skida završne točke i razmake' {
        (ConvertTo-SafeName ('a' * 100) -MaxLength 10).Length | Should -Be 10
        ConvertTo-SafeName 'abc. . ' | Should -Be 'abc'
    }
    It 'skuplja višestruke razmake' {
        ConvertTo-SafeName 'a   b' | Should -Be 'a b'
    }
}

Describe 'New-InfoItem i Get-HealthLevel' {
    It 'New-InfoItem ima zadane vrijednosti' {
        $i = New-InfoItem 'KV' 'L' 'V'
        $i.Status | Should -Be 'Normal'
        $i.Percent | Should -Be -1
    }
    It 'Get-HealthLevel preslikava stanja diska' {
        Get-HealthLevel 'Healthy' | Should -Be 'Good'
        Get-HealthLevel 'Unhealthy' | Should -Be 'Bad'
        Get-HealthLevel 'Failed' | Should -Be 'Bad'
        Get-HealthLevel 'Warning' | Should -Be 'Warn'
        Get-HealthLevel 'Unknown' | Should -Be 'Warn'
    }
}
