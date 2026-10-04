BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Get-HealthResult', 'New-InfoItem')))
    function New-Sec { param([string]$Name) New-InfoItem 'Section' '' $Name }
    function New-Row { param([string]$Label, [string]$Value, [string]$Status) New-InfoItem 'KV' $Label $Value $Status }
}

Describe 'Get-HealthResult' {
    It 'bez ijednog područja vraća $null (nema podataka)' {
        Get-HealthResult -Items @() | Should -BeNullOrEmpty
    }
    It 'samo ispravna sigurnost: 100, ODLIČNO, djelomično (ostala područja nisu provjerena)' {
        $items = @((New-Sec 'SIGURNOST'), (New-Row 'Antivirus' 'Defender' 'Good'), (New-Row 'Vatrozid' 'uključen' 'Good'))
        $h = Get-HealthResult -Items $items
        $h.Score | Should -Be 100
        $h.Label | Should -Be 'ODLIČNO'
        $h.Partial | Should -BeTrue
        @($h.Deductions).Count | Should -Be 0
    }
    It 'antivirus je prvi razlog odbitka (10 bodova)' {
        $items = @((New-Sec 'SIGURNOST'), (New-Row 'Antivirus' 'nije pronađen' 'Bad'))
        $h = Get-HealthResult -Items $items
        $h.Deductions[0].Points | Should -Be 10
        $h.Deductions[0].Text | Should -Match 'ntivirus'
        $h.Score | Should -Be 67   # (30 - 10) / 30
    }
    It 'zlatni skup A: sigurnost (antivirus + vatrozid) i 12 neinstaliranih ažuriranja daju 38 / LOŠE' {
        # Ručno izračunato iz pravila v0.04: Sigurnost 30 - (10 + 6) = 14; Ažuriranja 15 - 12 = 3; (14 + 3) / 45 = 37,8 -> 38
        $items = @(
            (New-Sec 'SIGURNOST'), (New-Row 'Antivirus' 'nije pronađen' 'Bad'), (New-Row 'Vatrozid' 'isključen' 'Bad'),
            (New-Sec 'WINDOWS UPDATE'), (New-Row 'Na čekanju' '12 ažuriranja' 'Warn')
        )
        $h = Get-HealthResult -Items $items
        $h.Score | Should -Be 38
        $h.Label | Should -Be 'LOŠE'
        $h.Partial | Should -BeTrue
        (@($h.Deductions) | ForEach-Object { $_.Points }) -join ',' | Should -Be '12,10,6'
    }
    It 'odbitak po području ne prelazi njegovu težinu' {
        $items = @(
            (New-Sec 'SIGURNOST'), (New-Row 'Antivirus' 'x' 'Bad'), (New-Row 'Definicije' 'x' 'Bad'), (New-Row 'Vatrozid' 'x' 'Bad'),
            (New-Row 'Šifriranje diska' 'x' 'Bad'), (New-Row 'SMBv1' 'x' 'Bad'), (New-Row 'RDP' 'x' 'Bad'), (New-Row 'Windows' 'x' 'Bad')
        )
        $h = Get-HealthResult -Items $items
        $h.Score | Should -BeGreaterOrEqual 0
        ($h.Categories | Where-Object Name -eq 'Sigurnost').Lost | Should -BeGreaterThan 0
    }
    It 'granice oznaka: 90 ODLIČNO, 75 DOBRO, 50 UPOZORENJE' {
        # jedno područje (Ažuriranja, težina 15): odbitak 4 -> 73 (UPOZORENJE), 12 -> 20 (LOŠE)
        $h = Get-HealthResult -Items @((New-Sec 'WINDOWS UPDATE'), (New-Row 'Na čekanju' '2 ažuriranja' 'Warn'))
        $h.Score | Should -Be 73
        $h.Label | Should -Be 'UPOZORENJE'
        $h = Get-HealthResult -Items @((New-Sec 'WINDOWS UPDATE'), (New-Row 'Na čekanju' '0 ažuriranja' 'Good'))
        $h.Label | Should -Be 'ODLIČNO'
    }
}
