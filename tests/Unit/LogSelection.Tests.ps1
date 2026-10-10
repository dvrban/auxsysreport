BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Get-DefaultLogSelection', 'Select-LogPlanByName', 'Get-LogSelectionSummary', 'Get-CoreLogNames', 'Format-Bytes')))
    function P { param([string]$n, [int64]$r, [int64]$s) [pscustomobject]@{ Name = $n; Records = $r; SizeBytes = $s } }
    $script:plan = @((P 'System' 1000 1048576), (P 'Application' 500 524288), (P 'Security' 2000 2097152), (P 'Setup' 10 1024))
    $script:cultureBefore = [System.Threading.Thread]::CurrentThread.CurrentCulture
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
}
AfterAll { [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:cultureBefore }

Describe 'Odabir dnevnika (T3.6): čista logika' {
    Context 'Get-DefaultLogSelection' {
        It 'bez prethodnog odabira označava sve' {
            @(Get-DefaultLogSelection $script:plan $null).Count | Should -Be 4
        }
        It 'raniji odabir se zadržava (samo dnevnici koji još postoje)' {
            $d = @(Get-DefaultLogSelection $script:plan @('System', 'Nepostojeci'))
            $d | Should -Be @('System')
        }
        It 'raniji odabir koji više ne vrijedi daje sve (ne počinje se bez ičega)' {
            @(Get-DefaultLogSelection $script:plan @('Nepostojeci')).Count | Should -Be 4
        }
    }
    Context 'Select-LogPlanByName i Get-CoreLogNames' {
        It 'filtrira plan po nazivima' {
            @(Select-LogPlanByName $script:plan @('Security', 'Setup')).Name | Should -Be @('Security', 'Setup')
        }
        It 'prazan odabir daje prazan plan' {
            @(Select-LogPlanByName $script:plan @()).Count | Should -Be 0
        }
        It 'System i Application su "uobičajeni"' {
            Get-CoreLogNames $script:plan | Should -Be @('System', 'Application')
        }
    }
    Context 'Get-LogSelectionSummary' {
        It 'zbraja zapise i veličinu odabranih dnevnika' {
            Get-LogSelectionSummary $script:plan @('System', 'Application') | Should -Be 'Odabrano: 2 od 4 dnevnika, 1,500 zapisa, 1.5 MB'
        }
        It 'bez odabira: nule' {
            Get-LogSelectionSummary $script:plan @() | Should -Be 'Odabrano: 0 od 4 dnevnika, 0 zapisa, 0 B'
        }
    }
}

Describe 'Odabir dnevnika (T3.6): ožičenje' {
    BeforeAll {
        $script:task = Get-AuxFunctionText 'Invoke-EventLogClearTask'
        $script:dialog = Get-AuxFunctionText 'Show-LogSelectionDialog'
    }
    It 'dijalog dolazi nakon popisa, a prije provjere mape, prostora i završne potvrde' {
        $dlg = $script:task.IndexOf('Show-LogSelectionDialog')
        $dlg | Should -BeGreaterThan $script:task.IndexOf('Get-LogChannelPlan')
        $dlg | Should -BeLessThan $script:task.IndexOf('Get-CompanyFolder')
        $dlg | Should -BeLessThan $script:task.IndexOf('Želite li nastaviti?')
    }
    It 'završna potvrda s gumbom Ne kao zadanim ostaje' {
        $script:task | Should -Match 'MessageBoxDefaultButton\]::Button2'
    }
    It 'odustajanje iz dijaloga prekida radnju prije izvoza i brisanja' {
        $script:task | Should -Match '\$null -eq \$chosen[\s\S]*?return'
    }
    It 'dijalog ne guta iznimke oko ShowDialog (razorna radnja se ne smije nastaviti sa svim dnevnicima)' {
        $script:dialog | Should -Match 'try \{[\s\S]*ShowDialog[\s\S]*\} finally \{'
        $script:dialog | Should -Not -Match 'catch \{[^}]*return \$Initial'
    }
    It 'prazan odabir onemogućuje gumb za izvoz i brisanje' {
        (Get-AuxFunctionText 'Update-LogSelectionSummary') | Should -Match 'Ok\.Enabled = \(\$names\.Count -gt 0\)'
    }
}
