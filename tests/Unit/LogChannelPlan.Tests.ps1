# T2.3: plan izvoza dnevnika gradi se iz popisa prikupljenog u pozadini (Get-WinEvent ne postoji na Linuxu pa se Invoke-BackgroundRunspace zamjenjuje).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Get-LogChannelPlan')))
    function Invoke-BackgroundRunspace { param($Functions, $Command, $Parameters, $TimeoutSeconds, $HonorCancel) return $script:fakeRun }
    function L { param($n, $r, $s) [pscustomobject]@{ LogName = $n; RecordCount = $r; FileSize = $s } }
}

Describe 'Get-LogChannelPlan' {
    It 'preskače dnevnike bez zapisa, sortira po nazivu i računa veličine' {
        $script:fakeRun = [pscustomobject]@{ State = 'Completed'; Output = @((L 'System' 10 1000), (L 'Application' 5 500), (L 'Empty' 0 0), (L 'NullCount' $null 0)) }
        $plan = @(Get-LogChannelPlan)
        $plan.Count | Should -Be 2
        $plan[0].Name | Should -Be 'Application'
        $plan[1].Records | Should -Be 10
        $plan[1].SizeBytes | Should -Be 1000
        $plan[0].Selected | Should -BeTrue
    }
    It 'odabir ($Selection) označava samo navedene dnevnike' {
        $script:fakeRun = [pscustomobject]@{ State = 'Completed'; Output = @((L 'System' 10 1000), (L 'Application' 5 500)) }
        $plan = @(Get-LogChannelPlan -Selection @('System'))
        ($plan | Where-Object Selected).Name | Should -Be 'System'
    }
    It 'prekid daje prazan plan' {
        $script:fakeRun = [pscustomobject]@{ State = 'Cancelled'; Output = @() }
        @(Get-LogChannelPlan).Count | Should -Be 0
    }
    It 'istek vremena je greška, a ne prazan popis' {
        $script:fakeRun = [pscustomobject]@{ State = 'TimedOut'; Output = @() }
        { Get-LogChannelPlan -TimeoutSeconds 5 } | Should -Throw '*nije dobiven u 5 s*'
    }
    It 'prazan izlaz pozadinskog popisa daje prazan plan' {
        $script:fakeRun = [pscustomobject]@{ State = 'Completed'; Output = @() }
        @(Get-LogChannelPlan).Count | Should -Be 0
    }
}
