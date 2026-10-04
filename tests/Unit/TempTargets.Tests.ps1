# -Skip se računa u fazi otkrivanja, prije BeforeAll: pomoćne funkcije moraju biti učitane na vrhu datoteke
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Get-TempFolderTargets')))
}

# Putanje s obrnutom kosom crtom: smisleno samo na Windowsu (u Linuxu se test preskače).
Describe 'Get-TempFolderTargets' -Skip:(-not (Test-IsWindowsPlatform)) {
    BeforeEach {
        $script:saved = @{ TEMP = $env:TEMP; LOCALAPPDATA = $env:LOCALAPPDATA; SystemRoot = $env:SystemRoot }
    }
    AfterEach {
        $env:TEMP = $script:saved.TEMP; $env:LOCALAPPDATA = $script:saved.LOCALAPPDATA; $env:SystemRoot = $script:saved.SystemRoot
    }
    It 'uklanja duplikate neovisno o velikim slovima' {
        $env:TEMP = 'C:\Users\a\AppData\Local\Temp'
        $env:LOCALAPPDATA = 'c:\users\a\appdata\local'
        $env:SystemRoot = 'C:\Windows'
        $t = @(Get-TempFolderTargets)
        @($t | Where-Object { $_ -like '*Users*Temp' }).Count | Should -Be 1
        $t | Should -Contain 'C:\Windows\Temp'
    }
    It 'preskače mapu koja leži unutar drugog cilja (Temp\2 pod RDP-om)' {
        $env:TEMP = 'C:\Users\a\AppData\Local\Temp\2'
        $env:LOCALAPPDATA = 'C:\Users\a\AppData\Local'
        $env:SystemRoot = 'C:\Windows'
        $t = @(Get-TempFolderTargets)
        $t | Should -Not -Contain 'C:\Users\a\AppData\Local\Temp\2'
        $t | Should -Contain 'C:\Users\a\AppData\Local\Temp'
    }
}
