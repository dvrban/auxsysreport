BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'Get-DpiScaleFromDpi', 'Add-RichText', 'Update-HealthTile', 'Get-HealthResult', 'New-InfoItem')))
    function New-FakeRtb {
        $r = [pscustomobject]@{ TextLength = 0; SelectionStart = 0; SelectionLength = 0; SelectionColor = $null; SelectionFont = $null; SelectionIndent = 0; SelectionHangingIndent = 0; SelectionTabs = $null; Appended = '' }
        $r | Add-Member ScriptMethod AppendText { param($t) $this.Appended += $t }
        return $r
    }
    function New-FakeTile { $t = [pscustomobject]@{ Height = 96; IsDisposed = $false; Invalidated = 0 }; $t | Add-Member ScriptMethod Invalidate { $this.Invalidated++ }; return $t }
    function Sec { param([string]$n) New-InfoItem 'Section' '' $n }
    function Row { param([string]$l, [string]$v, [string]$s) New-InfoItem 'KV' $l $v $s }
}

Describe 'DPI (T3.4)' {
    Context 'Get-DpiScaleFromDpi' {
        It 'preslikava DPI u faktor skaliranja' {
            Get-DpiScaleFromDpi 96  | Should -Be 1.0
            Get-DpiScaleFromDpi 120 | Should -Be 1.25
            Get-DpiScaleFromDpi 144 | Should -Be 1.5
            Get-DpiScaleFromDpi 168 | Should -Be 1.75
            Get-DpiScaleFromDpi 192 | Should -Be 2.0
        }
        It 'ispod 96 DPI (ili 0) vraća 1.0, nikad manje' {
            Get-DpiScaleFromDpi 72 | Should -Be 1.0
            Get-DpiScaleFromDpi 0  | Should -Be 1.0
        }
    }

    Context 'Add-RichText: uvlake i tabulatori su u pikselima uređaja' {
        BeforeEach { $script:Fonts = @{ Mono = 'm'; MonoBold = 'b' } }
        It 'pri 100 % su vrijednosti nepromijenjene' {
            $script:DpiScale = 1.0
            $r = New-FakeRtb
            Add-RichText $r 'x' 'c' -Indent 6 -Hanging 106 -Tabs @(112)
            $r.SelectionIndent | Should -Be 6
            $r.SelectionHangingIndent | Should -Be 106
            @($r.SelectionTabs) | Should -Be @(112)
        }
        It 'pri 150 % se množe faktorom i zaokružuju' {
            $script:DpiScale = 1.5
            $r = New-FakeRtb
            Add-RichText $r 'x' 'c' -Indent 6 -Hanging 106 -Tabs @(112)
            $r.SelectionIndent | Should -Be 9
            $r.SelectionHangingIndent | Should -Be 159
            @($r.SelectionTabs) | Should -Be @(168)
        }
        It 'bez tabulatora ih ne dira' {
            $script:DpiScale = 2.0
            $r = New-FakeRtb
            Add-RichText $r 'x' 'c' -Indent 6
            $r.SelectionTabs | Should -BeNullOrEmpty
            $r.SelectionIndent | Should -Be 12
        }
    }

    Context 'Update-HealthTile: visina kartice je u pikselima uređaja' {
        BeforeEach {
            $script:Deep = @{ State = 'Done' }
            $script:tile = New-FakeTile
            $script:UI = @{ HealthTile = $script:tile }
            $script:items = @((Sec 'SIGURNOST'), (Row 'Antivirus' 'Defender' 'Good'))
        }
        It 'bez podataka: 96 jedinica puta faktor' {
            $script:DpiScale = 2.0
            Update-HealthTile @()
            $script:tile.Height | Should -Be 192
        }
        It 's ocjenom pri 100 %: 98 + 14*7 + 8 + 15*1 + 8 = 227' {
            $script:DpiScale = 1.0
            Update-HealthTile $script:items
            $script:tile.Height | Should -Be 227
        }
        It 's ocjenom pri 200 %: dvostruko' {
            $script:DpiScale = 2.0
            Update-HealthTile $script:items
            $script:tile.Height | Should -Be 454
        }
    }

    Context 'ožičenje (statička provjera izvora)' {
        BeforeAll {
            $script:ui = [System.IO.File]::ReadAllText((Join-Path $script:AuxSrcRoot '85-Ui.ps1'))
            $script:main = [System.IO.File]::ReadAllText((Join-Path $script:AuxSrcRoot '90-Main.ps1'))
        }
        It 'forma koristi AutoScaleMode Dpi uz 96 DPI' {
            $script:ui | Should -Match 'AutoScaleDimensions = New-Object System\.Drawing\.SizeF\(96, 96\)'
            $script:ui | Should -Match 'AutoScaleMode\s+= \[System\.Windows\.Forms\.AutoScaleMode\]::Dpi'
        }
        It 'obrazac se gradi između SuspendLayout i ResumeLayout/PerformLayout (inače AutoScaleMode skalira prazan obrazac i kontrole ostaju neskalirane)' {
            foreach ($pair in @(@('New-MainForm', '$form'), @('Show-LogSelectionDialog', '$form'))) {
                $fn = Get-AuxFunctionText $pair[0]
                $suspend = $fn.IndexOf('$form.SuspendLayout()')
                $mode = $fn.IndexOf('$form.AutoScaleMode')
                $lastAdd = $fn.LastIndexOf('$form.Controls.Add(')
                if ($pair[0] -eq 'Show-LogSelectionDialog') { $lastAdd = $fn.IndexOf('$form.Controls.Add($ctl)') }
                $resume = $fn.IndexOf('$form.ResumeLayout($false)')
                $perform = $fn.IndexOf('$form.PerformLayout()')
                $suspend | Should -BeGreaterThan -1 -Because $pair[0]
                $suspend | Should -BeLessThan $mode -Because $pair[0]
                $lastAdd | Should -BeGreaterThan $mode -Because $pair[0]
                $resume | Should -BeGreaterThan $lastAdd -Because $pair[0]
                $perform | Should -BeGreaterThan $resume -Because $pair[0]
            }
        }
        It 'nijedan dio ne čita ContainerControl.AutoScaleFactor (protected: u strogom načinu baca iznimku i prekida Shown)' {
            foreach ($file in [System.IO.Directory]::GetFiles($script:AuxSrcRoot, '*.ps1')) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
                $hits = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Member.Extent.Text -eq 'AutoScaleFactor' }, $true))
                $hits.Count | Should -Be 0 -Because $file
            }
        }
        It 'zapis skaliranja u Shown rukovatelju ne smije prekinuti pokretanje: unutar je try' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:AuxSrcRoot '85-Ui.ps1'), [ref]$null, [ref]$null)
            $log = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.Extent.Text -like "*Write-AppLog 'Info' ('Zaslon:*" }, $true))
            $log.Count | Should -Be 1
            $p = $log[0].Parent
            $inTry = $false
            while ($null -ne $p) { if ($p -is [System.Management.Automation.Language.TryStatementAst]) { $inTry = $true; break }; $p = $p.Parent }
            $inTry | Should -BeTrue
        }
        It 'početna veličina prozora dijeli radnu površinu s faktorom (prozor se ne smije skalirati preko ekrana)' {
            $script:ui | Should -Match 'Floor\(\$workArea\.Width / \$dpiScale\)'
            $script:ui | Should -Match 'Floor\(\$workArea\.Height / \$dpiScale\)'
        }
        It 'Enable-DpiAwareness se zove prije Initialize-Resources (prije prvog prozora)' {
            $script:main.IndexOf('Enable-DpiAwareness') | Should -BeGreaterThan -1
            $script:main.IndexOf('Enable-DpiAwareness') | Should -BeLessThan $script:main.IndexOf('Initialize-Resources')
        }
        It 'marquee traka pomiče s faktorom skaliranja' {
            $script:ui | Should -Match 'Left \+= \[int\]\[Math\]::Round\(14 \* \[double\]\$script:DpiScale\)'
        }
        It 'NativeMethods ima EnableDpiAwareness (SetProcessDPIAware)' {
            $cs = [System.IO.File]::ReadAllText((Join-Path $script:AuxSrcRoot 'native\Native.cs'))
            $cs | Should -Match 'public static bool EnableDpiAwareness\(\)'
            $cs | Should -Match 'SetProcessDPIAware'
        }
    }
}
