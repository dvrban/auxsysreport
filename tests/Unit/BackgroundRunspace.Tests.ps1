# T2.1: Invoke-BackgroundRunspace s pravim runspaceom (radi i na Linuxu): rezultat, parametri, prekid i istek vremena.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Invoke-BackgroundRunspace', 'Test-StopRequested')))
    function Update-Ui { }
    function Write-AppLog { param($Level, $Message, $Err) $script:logged += , ("$Level|$Message") }
    # ubačene funkcije (ne smiju koristiti $script:)
    function Get-Twice { param([int]$N) return ($N * 2) }
    function Get-Doubled { param([int]$N, $Sink) $v = Get-Twice $N; if ($null -ne $Sink) { $Sink.Add($v) }; return $v }
    function Get-Slow { param($Sink, [int]$Seconds = 3) $Sink.Add('prvi'); Start-Sleep -Seconds $Seconds; return 'gotovo' }
    function Get-Failing { param($Sink) Write-Error 'neuspjelo'; return 'ok' }
}

Describe 'Invoke-BackgroundRunspace' {
    BeforeEach { $script:Closing = $false; $script:CancelRequested = $false; $script:AbandonedRunspace = $false; $script:logged = @() }

    It 'vraća izlaz naredbe i prosljeđuje parametre; ubačena funkcija zove drugu ubačenu' {
        $sink = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
        $r = Invoke-BackgroundRunspace -Functions @('Get-Doubled', 'Get-Twice') -Command 'Get-Doubled' -Parameters @{ N = 21; Sink = $sink }
        $r.State | Should -Be 'Completed'
        @($r.Output)[0] | Should -Be 42
        @($sink.ToArray())[0] | Should -Be 42
        $script:AbandonedRunspace | Should -BeFalse
    }
    It 'istek vremena: State TimedOut, runspace se napušta, a sink ima što je do tada prikupljeno' {
        $sink = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
        $r = Invoke-BackgroundRunspace -Functions @('Get-Slow') -Command 'Get-Slow' -Parameters @{ Sink = $sink; Seconds = 4 } -TimeoutSeconds 1
        $r.State | Should -Be 'TimedOut'
        $script:AbandonedRunspace | Should -BeTrue
        @($sink.ToArray()) | Should -Contain 'prvi'
    }
    It 'prekid korisnika: State Cancelled' {
        $script:CancelRequested = $true
        $sink = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
        $r = Invoke-BackgroundRunspace -Functions @('Get-Slow') -Command 'Get-Slow' -Parameters @{ Sink = $sink; Seconds = 4 } -TimeoutSeconds 30
        $r.State | Should -Be 'Cancelled'
        $script:AbandonedRunspace | Should -BeTrue
    }
    It 'HonorCancel = $false ignorira CancelRequested, ali ne i zatvaranje alata' {
        $script:CancelRequested = $true
        $r = Invoke-BackgroundRunspace -Functions @('Get-Doubled', 'Get-Twice') -Command 'Get-Doubled' -Parameters @{ N = 1; Sink = $null } -HonorCancel $false
        $r.State | Should -Be 'Completed'
        $script:CancelRequested = $false
        $script:Closing = $true
        $r2 = Invoke-BackgroundRunspace -Functions @('Get-Slow') -Command 'Get-Slow' -Parameters @{ Sink = (New-Object 'System.Collections.Concurrent.BlockingCollection[object]'); Seconds = 3 } -HonorCancel $false
        $r2.State | Should -Be 'Cancelled'
    }
    It 'greške iz runspacea (stream Error) ulaze u dnevnik kao Warn' {
        $sink = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
        $r = Invoke-BackgroundRunspace -Functions @('Get-Failing') -Command 'Get-Failing' -Parameters @{ Sink = $sink }
        $r.State | Should -Be 'Completed'
        ($script:logged -join ';') | Should -Match 'Warn\|Pozadinski runspace: Get-Failing'
    }
    It 'funkcija koja nije ubačena u runspace ne postoji: greška završava u dnevniku (prije T2.1 je bila nijema)' {
        $r = Invoke-BackgroundRunspace -Functions @('Get-Doubled') -Command 'Get-Doubled' -Parameters @{ N = 2; Sink = $null }
        # Get-Twice nije ubačena: poziv u runspaceu daje grešku u streamu (ne rušenje), a rezultat je prazan ($null)
        @($r.Output)[0] | Should -BeNullOrEmpty
        ($script:logged -join ';') | Should -Match 'Warn'
    }
}
