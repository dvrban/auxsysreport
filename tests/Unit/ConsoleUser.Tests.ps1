BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Get-ConsoleUser', 'Write-AppLog', 'Format-AppLogLine')))
    Initialize-NativeStub
    $script:AppRoot = ''
    function Get-CimInstance {
        [CmdletBinding()] param($ClassName, $OperationTimeoutSec)   # -ErrorAction dolazi iz [CmdletBinding()]
        $script:cimCalls++
        [pscustomobject]@{ UserName = 'CIM\rezerva' }
    }
}

Describe 'T1.9 Get-ConsoleUser koristi WTS, a CIM samo kao rezervu' {
    BeforeEach { $script:ConsoleUser = $null; $script:cimCalls = 0 }

    It 'WTS vrati korisnika: CIM se ne zove' {
        [Auxilium.NativeMethods]::Next = 'DOM\marko'
        Get-ConsoleUser | Should -Be 'DOM\marko'
        $script:cimCalls | Should -Be 0
    }
    It 'nitko nije prijavljen (prazan niz): ostaje prazan, CIM se ne zove' {
        [Auxilium.NativeMethods]::Next = ''
        Get-ConsoleUser | Should -Be ''
        $script:cimCalls | Should -Be 0
    }
    It 'WTS nije uspio ($null): koristi se CIM rezerva' {
        [Auxilium.NativeMethods]::Next = [NullString]::Value   # $null bi PowerShell pretvorio u prazan niz
        Get-ConsoleUser | Should -Be 'CIM\rezerva'
        $script:cimCalls | Should -Be 1
    }
    It 'rezultat se sprema: drugi poziv ne zove ni WTS ni CIM' {
        [Auxilium.NativeMethods]::Next = [NullString]::Value   # $null bi PowerShell pretvorio u prazan niz
        [void](Get-ConsoleUser)
        [void](Get-ConsoleUser)
        $script:cimCalls | Should -Be 1
    }
}
