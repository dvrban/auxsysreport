# Regresijski testovi za popravke iz Faze 1: statičke provjere izvora (AST/tekst), jer se UI i WMI ne mogu pokrenuti bez Windowsa.
# -Skip se računa u fazi otkrivanja: pomoćne funkcije moraju biti učitane na vrhu datoteke
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    function Get-AuxAst {
        param([string]$FunctionName)
        $files = [System.IO.Directory]::GetFiles($script:AuxSrcRoot, '*.ps1', [System.IO.SearchOption]::TopDirectoryOnly)
        foreach ($file in $files) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            $f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName }, $false)
            if (@($f).Count -gt 0) { return @($f)[0] }
        }
        throw ('Funkcija {0} nije pronađena.' -f $FunctionName)
    }
    $script:allSrcText = ([System.IO.Directory]::GetFiles($script:AuxSrcRoot, '*.ps1', [System.IO.SearchOption]::AllDirectories) | ForEach-Object { [System.IO.File]::ReadAllText($_) }) -join "`n"
}

Describe 'T1.1 LiveRows se resetira uz svako brisanje panela statusa' {
    It 'iza svakog $rtb.Clear() u Update-SystemStatus slijedi $script:LiveRows = @{}' {
        $text = (Get-AuxAst 'Update-SystemStatus').Extent.Text
        $clears = [regex]::Matches($text, '\$rtb\.Clear\(\)').Count
        $resets = [regex]::Matches($text, '\$rtb\.Clear\(\)\s*\r?\n\s*\$script:LiveRows\s*=\s*@\{\}').Count
        $clears | Should -BeGreaterThan 0
        $resets | Should -Be $clears
    }
}

Describe 'T1.2 redoslijed oslobađanja resursa' {
    It 'Form.Dispose dolazi prije oslobađanja fontova i FontCollection' {
        $text = (Get-AuxAst 'Remove-AppResources').Extent.Text
        $form = $text.IndexOf('$script:UI.Form.Dispose()')
        $font = $text.IndexOf('Remove-AppFonts')
        $form | Should -BeGreaterThan -1
        $form | Should -BeLessThan $font
        $fonts = (Get-AuxAst 'Remove-AppFonts').Extent.Text
        $fonts.IndexOf('$font.Dispose()') | Should -BeLessThan $fonts.IndexOf('$script:FontCollection.Dispose()')
    }
    It 'Initialize-Resources na početku oslobađa fontove iz prethodnog poziva' {
        $text = (Get-AuxAst 'Initialize-Resources').Extent.Text
        $text.IndexOf('Remove-AppFonts') | Should -BeLessThan $text.IndexOf('$script:Colors = @{')
    }
}

Describe 'T1.3 sink između UI niti i runspacea je thread-safe' {
    It 'Get-SystemInfoItemsAsync koristi BlockingCollection, ne List' {
        $text = (Get-AuxAst 'Get-SystemInfoItemsAsync').Extent.Text
        $text | Should -Match "New-Object 'System.Collections.Concurrent.BlockingCollection\[object\]'"
        $text | Should -Not -Match 'New-Object System\.Collections\.Generic\.List\[object\]'
    }
    It 'BlockingCollection podržava Add, Count i ToArray (sučelje koje Get-SystemInfoItems i pozivatelj koriste)' {
        $sink = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
        $sink.Add('a'); $sink.Add('b')
        $sink.Count | Should -Be 2
        @($sink.ToArray()) -join ',' | Should -Be 'a,b'
    }
    It 'ToArray tijekom istodobnog pisanja iz druge niti ne baca iznimku (50 ponavljanja)' {
        for ($i = 0; $i -lt 50; $i++) {
            $sink = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
            # pisanje iz pravog runspacea (kao u aplikaciji); PowerShell delegat na tuđoj niti ne bi imao runspace
            $ps = [powershell]::Create()
            try {
                [void]$ps.AddScript({ param($s) for ($k = 0; $k -lt 2000; $k++) { $s.Add($k) } }).AddArgument($sink)
                $async = $ps.BeginInvoke()
                { $null = $sink.ToArray() } | Should -Not -Throw
                [void]$ps.EndInvoke($async)
            } finally { $ps.Dispose() }
        }
    }
}

Describe 'T1.7 CIM upiti uvijek imaju rok' {
    It 'svaki Get-CimInstance ima -OperationTimeoutSec, -CimSession ili je splat (@p s rokom)' {
        $bad = New-Object System.Collections.Generic.List[string]
        $files = [System.IO.Directory]::GetFiles($script:AuxSrcRoot, '*.ps1', [System.IO.SearchOption]::TopDirectoryOnly)
        foreach ($file in $files) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-CimInstance' }, $true)
            foreach ($c in $cmds) {
                $text = $c.Extent.Text
                if ($text -match '-OperationTimeoutSec|-CimSession' -or $text -match '@\w+') { continue }
                $bad.Add(('{0}:{1}' -f [System.IO.Path]::GetFileName($file), $c.Extent.StartLineNumber))
            }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'Invoke-InvCim (splat) uvijek postavlja OperationTimeoutSec' {
        $script:allSrcText | Should -Match 'function Invoke-InvCim[\s\S]*?OperationTimeoutSec = \$TimeoutSec'
    }
}

Describe 'T1.10 prekid zadatka ne blokira sučelje' {
    It 'nema WaitForExit(2000) bez pumpanja poruka' {
        $script:allSrcText | Should -Not -Match 'WaitForExit\(2000\)'
        (Get-AuxAst 'Invoke-LiveProcess').Extent.Text | Should -Match 'while \(-not \$proc\.WaitForExit\(100\) -and \$killWait\.ElapsedMilliseconds -lt 2000\) \{ Update-Ui \}'
    }
}

Describe 'T1.4 duboko čišćenje ne ruši pozadinsko skeniranje' {
    It 'Wait-DeepScan se zove prije koraka 2 (zaustavljanje wuauserv), a ponovno skeniranje ovisi o ishodu' {
        $text = (Get-AuxAst 'Invoke-CleanupTask').Extent.Text
        $wait = $text.IndexOf('Wait-DeepScan 30')
        $step2 = $text.IndexOf('2/4')
        $wait | Should -BeGreaterThan -1
        $wait | Should -BeLessThan $step2
        $text | Should -Match '\$rescan\s*=\s*\(\$script:Deep\.State -ne ''Done''\)'
        $text | Should -Match 'Update-SystemStatus -IgnoreCancel -SkipDeep:\(-not \$rescan\)'
    }
}

Describe 'T1.12 otisak alata' {
    BeforeAll { . ([scriptblock]::Create((Get-AuxFunctionText 'Get-ToolFingerprint', 'Get-ToolVersionText'))) }
    It 'Get-ToolFingerprint daje prvih 8 znakova SHA-256 datoteke' {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ('fp-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllBytes($f, [System.Text.Encoding]::UTF8.GetBytes('abc'))
        try { Get-ToolFingerprint $f | Should -Be 'BA7816BF' } finally { Remove-Item $f -Force }   # SHA-256("abc") = BA7816BF...
    }
    It 'bez datoteke vraća prazan niz' {
        Get-ToolFingerprint 'nema-datoteke.ps1' | Should -Be ''
        Get-ToolFingerprint '' | Should -Be ''
    }
    It 'Get-ToolVersionText: s otiskom i bez' {
        $script:AppVersion = '0.05'; $script:ToolHash = 'A1B2C3D4'
        Get-ToolVersionText | Should -Be '0.05 (A1B2C3D4)'
        $script:ToolHash = ''
        Get-ToolVersionText | Should -Be '0.05'
    }
    It 'PDF izvještaj i terminal koriste Get-ToolVersionText' {
        $script:allSrcText | Should -Match "'Verzija alata' \(Get-ToolVersionText\)"
    }
}

Describe 'Treptanje panela statusa: iscrtavanje se isključuje tijekom gradnje' {
    It 'Show-SystemInfo i Set-LiveRow uključuju iscrtavanje natrag u finally (inače bi panel ostao zamrznut)' {
        foreach ($name in 'Show-SystemInfo', 'Set-LiveRow') {
            $text = (Get-AuxAst $name).Extent.Text
            $off = $text.IndexOf('SetRedraw($rtb.Handle, $false)')
            $on  = $text.IndexOf('SetRedraw($rtb.Handle, $true)')
            $off | Should -BeGreaterThan -1
            $on | Should -BeGreaterThan $off
            $text.Substring($off, $on - $off) | Should -Match 'finally'
        }
    }
    It 'NativeMethods ima javnu SetRedraw (WM_SETREDRAW = 0x000B)' {
        $cs = [System.IO.File]::ReadAllText((Join-Path $script:AuxSrcRoot 'native\Native.cs'))
        $cs | Should -Match 'public static void SetRedraw\(IntPtr handle, bool enable\)'
        $cs | Should -Match '0x000B'
    }
}

Describe 'Set-LiveRow ne prepisuje redak kad se prikaz nije promijenio' {
    BeforeAll {
        . ([scriptblock]::Create((Get-AuxFunctionText 'Set-LiveRow', 'Get-StatusColor')))
        # lažna kontrola: broji koliko je puta redak prepisan
        $script:rewrites = 0
        $script:fakeRtb = [pscustomobject]@{ SelectionStart = 0; SelectionLength = 0; Handle = [IntPtr]::Zero; ClientSize = [pscustomobject]@{ Width = 300 }; SelectionColor = $null }
        $script:fakeRtb | Add-Member -MemberType ScriptMethod -Name Select -Value { param($a, $b) }
        $script:fakeRtb | Add-Member -MemberType ScriptMethod -Name Invalidate -Value { param($r) }
        $script:fakeRtb | Add-Member -MemberType ScriptMethod -Name GetPositionFromCharIndex -Value { param($i) [pscustomobject]@{ Y = 10 } }
        $script:fakeRtb | Add-Member -MemberType ScriptProperty -Name SelectedText -Value { '' } -SecondValue { param($v) $script:rewrites++ }
        Initialize-NativeStub
        function Get-StatusColor { param($s) return 0 }
    }
    BeforeEach {
        $script:rewrites = 0
        $script:UI = @{ Status = $script:fakeRtb }
        $bar = ([string][char]0x2588) * 0 + ([string][char]0x2591) * 16 + ' ' + ('{0,3:N0} %' -f 0)
        $item = [pscustomobject]@{ Percent = -1; Value = ''; Status = '' }
        $script:LiveRows = @{ CPU = @{ Start = 0; Length = $bar.Length; Item = $item } }
    }
    It 'ista vrijednost drugi put: bez ponovnog prepisivanja, ali stavka za PDF ostaje osvježena' {
        Set-LiveRow 'CPU' 0 'Good' '0 % opterećenje'
        Set-LiveRow 'CPU' 0 'Good' '0 % opterećenje (novo)'
        $script:rewrites | Should -Be 1
        $script:LiveRows['CPU'].Item.Value | Should -Be '0 % opterećenje (novo)'
    }
    It 'promjena postotka: ponovno prepisivanje' {
        Set-LiveRow 'CPU' 0 'Good' 'a'
        Set-LiveRow 'CPU' 50 'Good' 'b'
        $script:rewrites | Should -Be 2
    }
    It 'izvor: Set-LiveRow usporeduje potpis prije prepisivanja i ne zove Invalidate() na cijeloj kontroli u glavnom putu' {
        $text = (Get-AuxAst 'Set-LiveRow').Extent.Text
        $text | Should -Match 'Signature'
        $text.IndexOf('Signature -ceq') | Should -BeLessThan $text.IndexOf('SetRedraw($rtb.Handle, $false)')
        $text | Should -Match 'New-Object System\.Drawing\.Rectangle'
    }
}

Describe 'Trijaža praznih catch blokova (T1.5)' {
    It 'svaki prazan catch u src\ (uključujući deep\DeepScan.ps1) ima oznaku "namjerno:" s razlogom' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($file in [System.IO.Directory]::GetFiles($script:AuxSrcRoot, '*.ps1', [System.IO.SearchOption]::AllDirectories)) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            $empty = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] -and $n.Body.Statements.Count -eq 0 }, $true)
            foreach ($c in $empty) {
                if ($c.Extent.Text -notmatch 'namjerno:\s*\S') { $bad.Add(('{0}:{1}' -f [System.IO.Path]::GetFileName($file), $c.Extent.StartLineNumber)) }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'funkcije ubačene u runspace ne zovu Write-AppLog (koristi $script:)' {
        foreach ($name in 'Get-SystemInfoItems', 'Get-InventoryData', 'New-InventoryResult') {
            (Get-AuxAst $name).Extent.Text | Should -Not -Match 'Write-AppLog'
        }
    }
}
