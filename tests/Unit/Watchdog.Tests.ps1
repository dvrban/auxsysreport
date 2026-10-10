BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Update-UiWatchdog')))
    # Slijedna zamjena za Stopwatch: Value je "proteklo vrijeme", a Restart() ga vraća na 0 kao prava štoperica
    function New-FakeWatch {
        $w = [pscustomobject]@{ Value = [int64]0; Restarts = 0 }
        $w | Add-Member ScriptProperty ElapsedMilliseconds { $this.Value }
        $w | Add-Member ScriptMethod Restart { $this.Value = 0; $this.Restarts++ }
        return $w
    }
    function Write-AppLog { param($Level, $Message, $Err) $script:logged += , ("$Level|$Message"); $script:UiWatch.Value += $script:logCostMs }
}

Describe 'Update-UiWatchdog (T3.7)' {
    BeforeEach { $script:logged = @(); $script:UiWatchEntries = 0; $script:CurrentTask = ''; $script:logCostMs = 0; $script:UiWatch = New-FakeWatch }

    It 'normalan razmak (~100 ms) se ne bilježi, a štoperica se ponovno pokreće' {
        $script:UiWatch.Value = 120
        Update-UiWatchdog
        $script:logged.Count | Should -Be 0
        $script:UiWatch.Restarts | Should -Be 1
        $script:UiWatch.Value | Should -Be 0
    }
    It 'razmak preko praga se bilježi s nazivom zadatka' {
        $script:UiWatch.Value = 650
        $script:CurrentTask = 'Osvježavanje statusa sustava'
        Update-UiWatchdog
        $script:logged.Count | Should -Be 1
        $script:logged[0] | Should -Be 'Info|Sučelje nije reagiralo 650 ms (zadatak: Osvježavanje statusa sustava)'
    }
    It 'bez zadatka u tijeku to piše u zapisu' {
        $script:UiWatch.Value = 500
        Update-UiWatchdog
        $script:logged[0] | Should -Match 'nema zadatka u tijeku'
    }
    It 'granica praga: 399 ms se ne bilježi, 400 ms se bilježi' {
        $script:UiWatch.Value = 399; Update-UiWatchdog
        $script:logged.Count | Should -Be 0
        $script:UiWatch.Value = 400; Update-UiWatchdog
        $script:logged.Count | Should -Be 1
    }
    It 'granica mirovanja: 120000 ms se bilježi, 120001 ms se ignorira, a 20000 ms (stvarno zamrzavanje) se bilježi' {
        $script:UiWatch.Value = 20000; Update-UiWatchdog
        $script:UiWatch.Value = 120000; Update-UiWatchdog
        $script:logged.Count | Should -Be 2
        $script:UiWatch.Value = 120001; Update-UiWatchdog
        $script:logged.Count | Should -Be 2
        $script:UiWatch.Restarts | Should -Be 3   # i ignorirani razmak ponovno pokreće štopericu
    }
    It 'bilježi najviše MaxEntries zapisa po pokretanju, a štoperica se i dalje pokreće' {
        1..60 | ForEach-Object { $script:UiWatch.Value = 1000; Update-UiWatchdog }
        $script:logged.Count | Should -Be 50
        $script:UiWatch.Restarts | Should -Be 60
    }
    It 'trajanje samog zapisa u dnevnik se ne ubraja u sljedeći razmak (spor stick ne pokreće lanac zapisa)' {
        $script:logCostMs = 900   # zapis traje 900 ms
        $script:UiWatch.Value = 500
        Update-UiWatchdog
        $script:UiWatch.Value | Should -Be 0   # Restart nakon zapisa
        Update-UiWatchdog                       # sljedeći otkucaj odmah iza: razmak je ~0, ne 900
        $script:logged.Count | Should -Be 1
    }
}
