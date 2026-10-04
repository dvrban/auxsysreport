# -Skip se računa u fazi otkrivanja: pomoćne funkcije moraju biti učitane na vrhu datoteke
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Test-FileHasBytes', 'Remove-StaleRunFolders', 'New-PrivateRunFolder', 'Write-AppLog', 'Format-AppLogLine')))
    $script:AppRoot = ''
    $script:LogFailed = $false
    $script:LogPath = ''
}

Describe 'T1.8 privremena skripta skeniranja' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('aux-run-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:root)
    }
    AfterEach { Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'Test-FileHasBytes: ista datoteka prolazi, izmijenjena ne' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('Write-Output 1')
        $f = Join-Path $script:root 'scan.ps1'
        [System.IO.File]::WriteAllBytes($f, $bytes)
        Test-FileHasBytes $f $bytes | Should -BeTrue
        [System.IO.File]::WriteAllBytes($f, [System.Text.Encoding]::UTF8.GetBytes('Write-Output 2'))
        Test-FileHasBytes $f $bytes | Should -BeFalse
    }
    It 'Remove-StaleRunFolders briše samo stare run-* mape' {
        $old = Join-Path $script:root 'run-old'; $new = Join-Path $script:root 'run-new'; $other = Join-Path $script:root 'ostalo'
        foreach ($d in $old, $new, $other) { [void][System.IO.Directory]::CreateDirectory($d) }
        Set-Content -LiteralPath (Join-Path $old 'scan.ps1') -Value 'x'
        [System.IO.Directory]::SetLastWriteTimeUtc($old, [datetime]::UtcNow.AddDays(-3))
        [System.IO.Directory]::SetLastWriteTimeUtc($other, [datetime]::UtcNow.AddDays(-3))
        Remove-StaleRunFolders $script:root 1
        (Test-Path $old) | Should -BeFalse
        (Test-Path $new) | Should -BeTrue
        (Test-Path $other) | Should -BeTrue
    }
    It 'Remove-StaleRunFolders ne baca ako mape nema' {
        { Remove-StaleRunFolders (Join-Path $script:root 'nema') 1 } | Should -Not -Throw
    }
    It 'Start-DeepScan više ne koristi GetTempPath, nego privatnu mapu s provjerom bajtova' {
        $text = Get-AuxFunctionText 'Start-DeepScan'
        $text | Should -Not -Match 'GetTempPath'
        $text | Should -Match 'New-PrivateRunFolder'
        $text.IndexOf('Test-FileHasBytes') | Should -BeGreaterThan $text.IndexOf('WriteAllBytes')
        $text.IndexOf('Test-FileHasBytes') | Should -BeLessThan $text.IndexOf('$proc.Start()')
    }
    It 'New-PrivateRunFolder daje ACL samo za Administrators i SYSTEM (bez nasljeđivanja)' -Skip:(-not (Test-IsWindowsPlatform)) {
        $env:ProgramData | Should -Not -BeNullOrEmpty
        $dir = New-PrivateRunFolder
        try {
            $acl = (New-Object System.IO.DirectoryInfo($dir)).GetAccessControl()
            $acl.AreAccessRulesProtected | Should -BeTrue
            $sids = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
            ($sids -join ',') | Should -Be 'S-1-5-18,S-1-5-32-544'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
