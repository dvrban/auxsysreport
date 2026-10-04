BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Format-AppLogLine', 'Write-AppLog')))
    $script:LogPath = ''
    $script:LogFailed = $false
}

Describe 'Format-AppLogLine' {
    It 'oblikuje vrijeme, razinu i poruku' {
        $line = Format-AppLogLine 'Warn' 'poruka' -Now ([datetime]'2026-10-04 12:34:56.789')
        $line | Should -Be '12:34:56.789 [WARN ] poruka'
    }
    It 'obična iznimka (bez ScriptStackTrace) ne baca ni pod StrictMode 2' {
        Set-StrictMode -Version 2
        try {
            $ex = New-Object System.InvalidOperationException 'pokvareno'
            $line = Format-AppLogLine 'Error' 'x' $ex
            $line | Should -Match 'InvalidOperationException: pokvareno'
        } finally { Set-StrictMode -Off }
    }
    It 'ErrorRecord dodaje prvi redak stoga' {
        try { throw 'bum' } catch { $rec = $_ }
        $line = Format-AppLogLine 'Error' 'x' $rec
        $line | Should -Match 'RuntimeException: bum'
        $line | Should -Match ' @ '
    }
    It 'zamjenjuje putanju profila i profile drugih korisnika (bez osobnih podataka)' {
        $line = Format-AppLogLine 'Info' 'datoteka C:\Users\Ivo\Documents\x.txt i D:\Users\Ana\y' -UserProfile 'C:\Users\Ivo'
        $line | Should -Not -Match 'Ivo'
        $line | Should -Not -Match 'Ana'
        $line | Should -Match '%USERPROFILE%'
    }
    It 'jedan zapis je jedan redak (prekidi retka u poruci se skupljaju)' {
        (Format-AppLogLine 'Info' "a`r`nb`nc") | Should -Not -Match "[\r\n]"
    }
}

Describe 'Write-AppLog' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('aux-log-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:root)
        $script:AppRoot = $script:root; $script:LogPath = ''; $script:LogFailed = $false; $script:LogLastSignature = ''; $script:LogRepeats = 0
    }
    AfterEach { Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'stvara Dnevnik\\Auxilium_<datum>.log i dopisuje retke' {
        Write-AppLog 'Info' 'prvi'
        Write-AppLog 'Warn' 'drugi'
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'Dnevnik') -Filter 'Auxilium_*.log')
        $files.Count | Should -Be 1
        @(Get-Content -LiteralPath $files[0].FullName).Count | Should -Be 2
    }
    It 'zadržava najviše 10 datoteka (rotacija)' {
        $dir = Join-Path $script:root 'Dnevnik'
        [void][System.IO.Directory]::CreateDirectory($dir)
        1..14 | ForEach-Object { Set-Content -LiteralPath (Join-Path $dir ('Auxilium_2020{0:00}01.log' -f $_)) -Value 'x' }
        Write-AppLog 'Info' 'novi'
        @(Get-ChildItem -LiteralPath $dir -Filter 'Auxilium_*.log').Count | Should -Be 10
        (Test-Path (Join-Path $dir 'Auxilium_20200101.log')) | Should -BeFalse
    }
    It 'nezapisiv stick ne ruši alat i ne pokušava se ponovno' {
        $script:AppRoot = Join-Path $script:root 'datoteka.txt'
        Set-Content -LiteralPath $script:AppRoot -Value 'ovo je datoteka, ne mapa'
        { Write-AppLog 'Error' 'x' } | Should -Not -Throw
        $script:LogFailed | Should -BeTrue
    }
    It 'bez AppRoot ne radi ništa' {
        $script:AppRoot = ''
        { Write-AppLog 'Info' 'x' } | Should -Not -Throw
        $script:LogPath | Should -Be ''
    }
    It 'jednaki uzastopni zapisi se spajaju u "ponovljeno N puta"' {
        1..5 | ForEach-Object { Write-AppLog 'Warn' 'ista greška' }
        Write-AppLog 'Info' 'nešto drugo'
        $lines = @(Get-Content -LiteralPath (Get-ChildItem (Join-Path $script:root 'Dnevnik') -Filter 'Auxilium_*.log')[0].FullName)
        $lines.Count | Should -Be 3
        $lines[1] | Should -Match 'ponovljen još 4 puta'
        $lines[2] | Should -Match 'nešto drugo'
    }
    It 'različiti zapisi se ne spajaju' {
        Write-AppLog 'Warn' 'a'; Write-AppLog 'Warn' 'b'; Write-AppLog 'Warn' 'a'
        @(Get-Content -LiteralPath (Get-ChildItem (Join-Path $script:root 'Dnevnik') -Filter 'Auxilium_*.log')[0].FullName).Count | Should -Be 3
    }
}
