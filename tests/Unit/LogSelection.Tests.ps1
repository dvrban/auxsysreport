BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Get-DefaultLogSelection', 'Select-LogPlanByName', 'Get-LogSelectionSummary', 'Get-CoreLogNames', 'Get-ChosenLogPlan', 'Get-LogClearQuestion', 'Get-LogDialogDeficit', 'Show-LogSelectionDialog', 'Format-Bytes')))
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

Describe 'Odabir dnevnika (T3.6): Get-ChosenLogPlan (što se izvozi i briše)' {
    BeforeEach { $script:LogClearSelection = $null }
    It 'vraća samo odabrane dnevnike i pamti odabir' {
        Mock Show-LogSelectionDialog { return , @('System', 'Setup') }
        $r = @(Get-ChosenLogPlan $script:plan)
        $r.Name | Should -Be @('System', 'Setup')
        $script:LogClearSelection | Should -Be @('System', 'Setup')
    }
    It 'odabir jednog dnevnika daje polje od jednog elementa' {
        Mock Show-LogSelectionDialog { return , @('Security') }
        $r = Get-ChosenLogPlan $script:plan
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'Security'
    }
    It 'razlika u veličini slova ne mijenja odabir; udvostručeni nazivi ne udvostručuju dnevnik' {
        Mock Show-LogSelectionDialog { return , @('system', 'SYSTEM') }
        $r = @(Get-ChosenLogPlan $script:plan)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'System'
    }
    It 'odustajanje daje $null i ne mijenja zapamćeni odabir' {
        $script:LogClearSelection = @('Application')
        Mock Show-LogSelectionDialog { return $null }
        Get-ChosenLogPlan $script:plan | Should -BeNullOrEmpty
        $script:LogClearSelection | Should -Be @('Application')
    }
    It 'odabir koji ne odgovara nijednom dnevniku tretira se kao odustajanje (nikad "svi")' {
        Mock Show-LogSelectionDialog { return , @('Nepostojeci') }
        Get-ChosenLogPlan $script:plan | Should -BeNullOrEmpty
    }
    It 'dijalogu se predlaže zapamćeni odabir, a bez njega svi dnevnici' {
        Mock Show-LogSelectionDialog { return $null }
        Get-ChosenLogPlan $script:plan | Out-Null
        Should -Invoke Show-LogSelectionDialog -Times 1 -ParameterFilter { @($Initial).Count -eq 4 }
        $script:LogClearSelection = @('Setup')
        Get-ChosenLogPlan $script:plan | Out-Null
        Should -Invoke Show-LogSelectionDialog -Times 1 -ParameterFilter { @($Initial).Count -eq 1 -and $Initial[0] -eq 'Setup' }
    }
}

Describe 'Odabir dnevnika (T3.6): Get-LogClearQuestion (završna potvrda opisuje ono što će se dogoditi)' {
    BeforeAll { $script:all = @($script:plan | ForEach-Object { $_.Name }) }
    It 'svi dnevnici: tekst kao dosad (sve, uključujući Security)' {
        $q = Get-LogClearQuestion -Plan $script:plan -AllNames $script:all -Dir 'C:\Izvoz' -TotalRecords 3510 -EstMinutes 1
        $q | Should -Match 'sve Windows dnevnike događaja koji imaju zapise \(4 dnevnika, ukupno 3510 zapisa\)'
        $q | Should -Match 'uključujući dnevnik Security'
        $q | Should -Not -Match 'SAMO odabrane'
    }
    It 'podskup bez Securityja: ne tvrdi "sve" ni brisanje Securityja, navodi nazive i da ostali ostaju netaknuti' {
        $sub = @(Select-LogPlanByName $script:plan @('System', 'Application'))
        $q = Get-LogClearQuestion -Plan $sub -AllNames $script:all -Dir 'C:\Izvoz' -TotalRecords 1500 -EstMinutes 1
        $q | Should -Match 'SAMO odabrane dnevnike događaja \(2 od 4, ukupno 1500 zapisa\): Application, System'
        $q | Should -Not -Match 'sve Windows dnevnike'
        $q | Should -Not -Match 'uključujući dnevnik Security'
        $q | Should -Match 'Security nije odabran'
    }
    It 'podskup sa Securityjem: Security se izričito navodi' {
        $sub = @(Select-LogPlanByName $script:plan @('Security'))
        $q = Get-LogClearQuestion -Plan $sub -AllNames $script:all -Dir 'C:\Izvoz' -TotalRecords 2000 -EstMinutes 1
        $q | Should -Match 'SAMO odabrane'
        $q | Should -Match 'uključujući dnevnik Security'
    }
    It 'više od 12 dnevnika: popis se skraćuje s "... i još N"' {
        $many = @(1..20 | ForEach-Object { P ('Log{0:D2}' -f $_) 1 1 })
        $names = @($many | ForEach-Object { $_.Name })
        $sub = @(Select-LogPlanByName $many ($names | Select-Object -First 15))
        $q = Get-LogClearQuestion -Plan $sub -AllNames $names -Dir 'C:\Izvoz' -TotalRecords 15 -EstMinutes 1
        $q | Should -Match '\.\.\. i još 3'
        $q | Should -Match 'Log12'
        $q | Should -Not -Match 'Log13'
    }
    It 'sadrži mapu, procjenu trajanja i upit s gumbom' {
        $q = Get-LogClearQuestion -Plan $script:plan -AllNames $script:all -Dir 'C:\Izvoz\dnevnici' -TotalRecords 1 -EstMinutes 7
        $q | Should -Match 'C:\\Izvoz\\dnevnici'
        $q | Should -Match 'oko 7 min'
        $q | Should -Match 'Želite li nastaviti\?'
    }
}

Describe 'Odabir dnevnika (T3.6): visina dijaloga na malim zaslonima' {
    It 'veliki zaslon: bez skraćivanja' {
        Get-LogDialogDeficit 1040 1.0 | Should -Be 0
        Get-LogDialogDeficit 1040 1.5 | Should -Be 0
    }
    It '1366x768 pri 125 %: stane bez skraćivanja; pri 150 % popis se skraćuje' {
        Get-LogDialogDeficit 728 1.25 | Should -Be 0
        Get-LogDialogDeficit 728 1.5 | Should -BeGreaterThan 0
    }
    It 'skraćivanje je ograničeno (popis ostaje ≥ 120) i nema dijeljenja nulom' {
        Get-LogDialogDeficit 300 1.5 | Should -Be 210
        Get-LogDialogDeficit 700 0 | Should -Be 0
    }
}

Describe 'Odabir dnevnika (T3.6): ožičenje' {
    BeforeAll {
        $script:task = Get-AuxFunctionText 'Invoke-EventLogClearTask'
        $script:dialog = Get-AuxFunctionText 'Show-LogSelectionDialog'
    }
    It 'odabir dolazi nakon popisa, a prije provjere mape, prostora i završne potvrde' {
        $dlg = $script:task.IndexOf('Get-ChosenLogPlan')
        $dlg | Should -BeGreaterThan $script:task.IndexOf('Get-LogChannelPlan')
        $dlg | Should -BeLessThan $script:task.IndexOf('Get-CompanyFolder')
        $dlg | Should -BeLessThan $script:task.IndexOf('Get-LogClearQuestion')
        $dlg | Should -BeLessThan $script:task.IndexOf('Export-EventLogChannel')
        $dlg | Should -BeLessThan $script:task.IndexOf('Clear-EventLogChannel')
    }
    It 'završni upit se gradi iz filtriranog plana, a ne iz teksta "sve dnevnike"' {
        $script:task | Should -Match 'Get-LogClearQuestion -Plan \$plan'
        $script:task | Should -Not -Match 'izvesti u TXT sve'
    }
    It 'završna potvrda s gumbom Ne kao zadanim ostaje' {
        $script:task | Should -Match 'MessageBoxDefaultButton\]::Button2'
    }
    It 'odustajanje iz dijaloga prekida radnju prije izvoza i brisanja' {
        $script:task | Should -Match 'if \(\$null -eq \$plan\) \{[^}]*\$script:TaskNoResult = \$true\s+return\s+\}'
    }
    It 'dijalog ne guta iznimke oko ShowDialog (razorna radnja se ne smije nastaviti sa svim dnevnicima)' {
        $script:dialog | Should -Match 'try \{[\s\S]*ShowDialog[\s\S]*\} finally \{'
        $script:dialog | Should -Not -Match 'catch \{[^}]*return \$Initial'
    }
    It 'skupno označavanje računa sažetak jednom (Busy), a ne po svakoj kvačici' {
        (Get-AuxFunctionText 'Set-LogChecks') | Should -Match 'LogDlg\.Busy = \$true[\s\S]*LogDlg\.Busy = \$false'
        $script:dialog | Should -Match 'Add_ItemChecked\(\{ if \(\$script:LogDlg\.Busy\) \{ return \}'
    }
    It 'prazan odabir onemogućuje gumb za izvoz i brisanje' {
        (Get-AuxFunctionText 'Update-LogSelectionSummary') | Should -Match 'Ok\.Enabled = \(\$names\.Count -gt 0\)'
    }
}
