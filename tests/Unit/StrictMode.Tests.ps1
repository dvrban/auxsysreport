# Čiste funkcije pokrenute pod Set-StrictMode -Version 2 (kako radi alat uz Auxilium-StrictMode.on). Greške koje je strogi način otkrio na Windowsu
# (npr. @($null) -> $null.Status u Get-HealthResult) ovdje postaju regresijski testovi.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Get-HealthResult', 'Get-HealthReportItems', 'New-InfoItem', 'ConvertFrom-DeepBytes', 'Get-CombinedInfoItems', 'Get-ToolVersionText')))
    # New-ReportModel: WindowsIdentity ne postoji na Linuxu pa se u kopiji teksta zamjenjuje konstantom (ostalo je neizmijenjeno)
    $text = (Get-AuxFunctionText 'New-ReportModel').Replace('[System.Security.Principal.WindowsIdentity]::GetCurrent().Name', "'DOM\admin'")
    . ([scriptblock]::Create($text))
    function Sec { param([string]$n) New-InfoItem 'Section' '' $n }
    function Row { param([string]$l, [string]$v, [string]$s) New-InfoItem 'KV' $l $v $s }
    function Get-ConsoleUser { return 'DOM\marko' }
    function Write-Terminal { param($Text, $Level) }
    function Test-StopRequested { return $false }
    function Start-DeepScan { }
    function Wait-DeepScan { param($TimeoutSeconds) return $true }
    function Get-SystemInfoItemsAsync { param($TimeoutSeconds) return $null }
    $script:AppVersion = '0.04'; $script:ToolHash = 'ABCD1234'; $script:ReportCompany = 'Firma'
}

Describe 'Strogi način (Set-StrictMode -Version 2)' {
    BeforeEach { Set-StrictMode -Version 2 }
    AfterEach { Set-StrictMode -Off }

    Context 'Get-HealthResult' {
        It 'puni skup područja' {
            $items = @((Sec 'SIGURNOST'), (Row 'Antivirus' 'Defender' 'Good'), (Row 'Vatrozid' 'uključen' 'Good'), (Row 'Šifriranje diska' 'BitLocker' 'Good'),
                (Sec 'WINDOWS UPDATE'), (Row 'Na čekanju' '3 ažuriranja' 'Warn'), (Sec 'DISKOVI'), (Row 'C:' '100 GB' 'Good'),
                (Sec 'ZDRAVLJE DISKOVA'), (Row 'Disk 0' 'Samsung' 'Normal'), (Row 'Zdravlje' 'Healthy' 'Good'),
                (Sec 'DNEVNICI'), (Row 'BSOD' '0' 'Good'), (Row 'System' 'grešaka: 4' 'Warn'), (Sec 'PROCESSOR, MBO & RAM'), (Row 'RAM slobodno' '41 GB' 'Good'),
                (Sec 'OPERACIJSKI SUSTAV'), (Row 'Radi već' '0 d 5 h' 'Good'), (Sec 'SOFTVER I LICENCE'), (Row 'Windows' 'aktiviran' 'Good'))
            $h = Get-HealthResult $items
            $h.Score | Should -BeGreaterThan 0
            @(Get-HealthReportItems $h).Count | Should -BeGreaterThan 0
        }
        It 'samo jedno područje (ostala nemaju redaka: prazni popisi redaka ne smiju rušiti)' {
            $h = Get-HealthResult @((Sec 'SIGURNOST'), (Row 'Antivirus' 'Defender' 'Good'))
            $h.Score | Should -Be 100
        }
        It 'područje DISKOVI bez ZDRAVLJE DISKOVA i obrnuto' {
            { Get-HealthResult @((Sec 'DISKOVI'), (Row 'C:' '100 GB' 'Bad')) } | Should -Not -Throw
            { Get-HealthResult @((Sec 'ZDRAVLJE DISKOVA'), (Row 'Disk 0' 'S' 'Normal'), (Row 'Zdravlje' 'Failed' 'Bad')) } | Should -Not -Throw
        }
        It 'bez ijedne stavke vraća $null' {
            Get-HealthResult @() | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertFrom-DeepBytes' {
        It 'stavke dijete-skripte (Kind/Label/Value/Status)' {
            $json = '[{"Kind":"Section","Label":"","Value":"DNEVNICI","Status":"Normal"},{"Kind":"KV","Label":"BSOD","Value":"0","Status":"Good"}]' + "`n"
            @(ConvertFrom-DeepBytes ([System.Text.Encoding]::UTF8.GetBytes($json))).Count | Should -Be 2
        }
    }

    Context 'New-ReportModel' {
        BeforeEach {
            $script:SysInfo = @((Sec 'OPERACIJSKI SUSTAV'), (Row 'Naziv' 'Windows 11' 'Normal'), (Row 'Računalo' 'X' 'Normal'), (Row 'Radi već' '0 d 5 h' 'Good'),
                (Sec 'SIGURNOST'), (Row 'Antivirus' 'Defender' 'Good'), (New-InfoItem 'Bar' 'CPU' '3 %' 'Good' 3))
            $script:Deep = @{ State = 'Done'; Items = @((Sec 'WINDOWS UPDATE'), (Row 'Na čekanju' '0 ažuriranja' 'Good')); Error = '' }
            $script:UI = @{ Status = $null; Terminal = $null }
        }
        It 'gradi model izvještaja (sa završenim skeniranjem)' {
            $m = New-ReportModel
            @($m).Count | Should -BeGreaterThan 10
        }
        It 'gradi model i kad skeniranje nije uspjelo' {
            $script:Deep = @{ State = 'Failed'; Items = @(); Error = 'x' }
            { New-ReportModel } | Should -Not -Throw
        }
    }
}
