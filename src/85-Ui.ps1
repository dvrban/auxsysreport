#region UI
function Invoke-HeaderPaint {
    param($Sender, $E)
    $sf = $null
    $sfRight = $null
    $pen = $null
    try {
        $g = $E.Graphics
        $c = $script:Colors
        $f = $script:Fonts
        # Sve se crta GDI+-om (DrawString): jedino on podržava privatne fontove (Orbitron / Sora) i razmak među slovima.
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $sf = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
        $sf.FormatFlags = $sf.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap
        $sfRight = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
        $sfRight.FormatFlags = $sfRight.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap
        $sfRight.Alignment = [System.Drawing.StringAlignment]::Far
        $dpi = $g.DpiY

        $draw = {
            param([string]$Text, $Font, $Color, [double]$X, [double]$Y)
            $brush = New-Object System.Drawing.SolidBrush ($Color)
            try { $g.DrawString($Text, $Font, $brush, [single]$X, [single]$Y, $sf) } finally { $brush.Dispose() }
        }
        $ascent = {
            param($Font)
            $family = $Font.FontFamily
            return ([double]$family.GetCellAscent($Font.Style) / [double]$family.GetEmHeight($Font.Style) * $Font.SizeInPoints * $dpi / 72.0)
        }

        # Logotip: "AU" + crveni "X" + "ILIUM" + jantarna "." naslovnim fontom, zatim "INFORMATIKA" fontom teksta (prigušeno, široki razmak među slovima).
        $big = $f.LogoBold
        $small = $f.LogoLight
        $bigAscent = & $ascent $big
        # Centriranje po visini velikih slova (a ne po okviru retka): Bahnschrift ima velika slova više u retku, pa bi logotip inače bio previsoko.
        $capPx = 0.72 * $big.SizeInPoints * $dpi / 72.0
        $y = [Math]::Round((($Sender.Height - 1) - $capPx) / 2.0 - ($bigAscent - $capPx))
        $x = 18.0
        $parts = @(
            @{ T = 'AU';    C = $c.Text    },
            @{ T = 'X';     C = $c.LogoRed },
            @{ T = 'ILIUM'; C = $c.Text    },
            @{ T = '.';     C = $c.Yellow  }
        )
        foreach ($part in $parts) {
            & $draw $part.T $big $part.C $x $y
            $x += $g.MeasureString($part.T, $big, 2000, $sf).Width
        }
        $x += 12.0
        $ySmall = $y + $bigAscent - (& $ascent $small)
        foreach ($ch in 'INFORMATIKA'.ToCharArray()) {
            $s = [string]$ch
            & $draw $s $small $c.Muted $x $ySmall
            $x += $g.MeasureString($s, $small, 2000, $sf).Width + 3.0
        }

        $brush = New-Object System.Drawing.SolidBrush ($c.Muted)
        try {
            $rect1 = New-Object System.Drawing.RectangleF(($Sender.Width - 420), 20, 402, 22)
            $g.DrawString('Dijagnostika i održavanje sustava', $f.HeadSub, $brush, $rect1, $sfRight)
            $adminText = 'standardni korisnik'
            if ($script:IsAdmin) { $adminText = 'administrator' }
            $rect2 = New-Object System.Drawing.RectangleF(($Sender.Width - 420), 44, 402, 18)
            $g.DrawString(('v{0}  |  {1}  |  {2}' -f $script:AppVersion, $env:COMPUTERNAME, $adminText), $f.HeadSmall, $brush, $rect2, $sfRight)
        } finally {
            $brush.Dispose()
        }

        # Donji obrub trake zaglavlja (1 px).
        $pen = New-Object System.Drawing.Pen ($c.Line)
        $g.DrawLine($pen, 0, ($Sender.Height - 1), $Sender.Width, ($Sender.Height - 1))
    } catch { Write-AppLog 'Debug' 'Invoke-HeaderPaint' $_ } finally {
        if ($null -ne $sf) { $sf.Dispose() }
        if ($null -ne $sfRight) { $sfRight.Dispose() }
        if ($null -ne $pen) { $pen.Dispose() }
    }
}

function New-AppIcon {
    try {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear($script:Colors.Header)
        $fontA = [System.Drawing.Font]::new('Segoe UI', 14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $sfmt = New-Object System.Drawing.StringFormat
        $sfmt.Alignment = [System.Drawing.StringAlignment]::Center
        $sfmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $white = New-Object System.Drawing.SolidBrush ($script:Colors.White)
        $red = New-Object System.Drawing.SolidBrush ($script:Colors.LogoRed)
        $g.DrawString('A', $fontA, $white, (New-Object System.Drawing.RectangleF(0, 1, 20, 30)), $sfmt)
        $g.DrawString('X', $fontA, $red, (New-Object System.Drawing.RectangleF(13, 1, 19, 30)), $sfmt)
        $white.Dispose(); $red.Dispose(); $fontA.Dispose(); $sfmt.Dispose(); $g.Dispose()
        $handle = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($handle).Clone()
        [Auxilium.NativeMethods]::TryDestroyIcon($handle)
        $bmp.Dispose()
        return $icon
    } catch {
        return $null
    }
}

# Boje gumba dolaze iz zajedničke palete; natpis se crta velikim slovima (Text ostaje izvorni). Kind: 0 običan, 1 primarni, 2 opasnost / prekid.
function Set-SkinButtonColors {
    param($Button, [int]$Kind = 0)
    $c = $script:Colors
    $Button.Kind           = $Kind
    $Button.ColorBack      = $c.Button
    $Button.ColorPressed   = $c.ButtonDown
    $Button.ColorLine      = $c.Line
    $Button.ColorText      = $c.Text
    $Button.ColorAccent    = $c.Yellow
    $Button.ColorAccentDim = $c.ButtonHot
    $Button.ColorOnAccent  = $c.OnAmber
    $Button.ColorDanger    = $c.Red
    $Button.ColorPage      = $c.Form
    $Button.ColorDisabled  = $c.Muted2
    $Button.ColorFocus     = $c.Cyan
}

function ConvertTo-SkinKind {
    param([string]$Kind)
    if ($Kind -eq 'Primary') { return 1 }
    if ($Kind -eq 'Danger')  { return 2 }
    return 0
}

function New-FlatButton {
    param([string]$Text, [ValidateSet('Normal', 'Primary', 'Danger')][string]$Kind = 'Normal')
    $btn = New-Object Auxilium.SkinButton
    $btn.Text         = $Text
    $btn.UseMnemonic  = $false
    $btn.Dock         = 'Fill'
    $btn.Font         = $script:Fonts.Button
    $btn.Cursor       = [System.Windows.Forms.Cursors]::Hand
    $btn.Margin       = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
    Set-SkinButtonColors $btn (ConvertTo-SkinKind $Kind)
    return $btn
}

function New-StripButton {
    param([string]$Text, [int]$Width, [ValidateSet('Normal', 'Primary', 'Danger')][string]$Kind = 'Normal')
    $btn = New-Object Auxilium.SkinButton
    $btn.Text        = $Text
    $btn.UseMnemonic = $false
    $btn.Dock        = 'Right'
    $btn.Width       = $Width
    $btn.Font        = $script:Fonts.StripBtn
    $btn.Cursor      = [System.Windows.Forms.Cursors]::Hand
    $btn.Margin      = New-Object System.Windows.Forms.Padding(0)
    Set-SkinButtonColors $btn (ConvertTo-SkinKind $Kind)
    return $btn
}

function New-CardGroup {
    param([string]$Title, [int]$Rows)
    $c = $script:Colors
    $group = New-Object Auxilium.CardBox
    $group.Text        = $Title
    $group.Dock        = 'Fill'
    $group.Font        = $script:Fonts.Card
    $group.ForeColor   = $c.Yellow
    $group.BackColor   = $c.Card
    $group.BorderColor = $c.Line
    $group.Padding     = New-Object System.Windows.Forms.Padding(8, 6, 8, 8)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock        = 'Fill'
    $layout.BackColor   = $c.Card
    $layout.ColumnCount = 1
    $layout.RowCount    = $Rows
    [void]$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    for ($i = 0; $i -lt $Rows; $i++) {
        [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, (100 / $Rows)))
    }
    $group.Controls.Add($layout)
    return @{ Group = $group; Layout = $layout }
}

function New-TextArea {
    param([string]$Title, [System.Drawing.Color]$BackColor, [System.Drawing.Font]$Font, [System.Drawing.Color]$ForeColor)
    $c = $script:Colors

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.ReadOnly      = $true
    $rtb.Dock          = 'Fill'
    $rtb.BorderStyle   = 'None'
    $rtb.DetectUrls    = $false
    $rtb.WordWrap      = $true
    $rtb.ScrollBars    = 'Vertical'
    $rtb.Font          = $Font
    $rtb.BackColor     = $BackColor
    $rtb.ForeColor     = $ForeColor
    $rtb.Cursor        = [System.Windows.Forms.Cursors]::Default
    $rtb.HideSelection = $false
    $rtb.TabStop       = $false

    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock      = 'Fill'
    $inner.BackColor = $BackColor
    $inner.Padding   = New-Object System.Windows.Forms.Padding(6, 8, 2, 6)
    $inner.Controls.Add($rtb)

    $strip = New-Object System.Windows.Forms.Panel
    $strip.Dock      = 'Top'
    $strip.Height    = 30
    $strip.BackColor = $c.Card
    $strip.Padding   = New-Object System.Windows.Forms.Padding(10, 3, 3, 3)

    # Natpis velikim slovima, prigušen; GDI+ iscrtavanje (UseCompatibleTextRendering) omogućuje i privatni naslovni font.
    $label = New-Object System.Windows.Forms.Label
    $label.Text        = $Title.ToUpperInvariant()
    $label.UseMnemonic = $false
    $label.UseCompatibleTextRendering = $true
    $label.Dock        = 'Fill'
    $label.TextAlign   = 'MiddleLeft'
    $label.Font        = $script:Fonts.Strip
    $label.ForeColor   = $c.Yellow
    $label.BackColor   = $c.Card
    $strip.Controls.Add($label)

    $rule = New-Object System.Windows.Forms.Panel
    $rule.Dock      = 'Top'
    $rule.Height    = 1
    $rule.BackColor = $c.Line

    $container = New-Object System.Windows.Forms.Panel
    $container.Dock      = 'Fill'
    $container.BackColor = $BackColor
    $container.Controls.Add($inner)
    $container.Controls.Add($rule)
    $container.Controls.Add($strip)

    # Okvir od 1 px oko cijelog polja (boja obruba iza ispune s razmakom od 1 px).
    $frame = New-Object System.Windows.Forms.Panel
    $frame.Dock      = 'Fill'
    $frame.BackColor = $c.Line
    $frame.Padding   = New-Object System.Windows.Forms.Padding(1)
    $frame.Controls.Add($container)

    return @{ Container = $frame; Rtb = $rtb; Strip = $strip }
}

# Osvježava traku "Tvrtka / klijent": popis nedavnih tvrtki i putanju na koju će se spremiti izvještaj.
function Update-ClientBar {
    $box   = $script:UI.CompanyBox
    $label = $script:UI.PathLabel
    if ($null -eq $box -or $null -eq $label) { return }
    if ($script:UI.ClientUpdating) { return }
    $script:UI.ClientUpdating = $true
    try {
        $company = Get-ActiveCompany
        # Popis se ponovno gradi samo ako se stvarno promijenio (Items.Clear() poništava odabir i kvari kretanje strelicama).
        $wanted = @($script:Settings.Companies | ForEach-Object { [string]$_ })
        $have   = @($box.Items | ForEach-Object { [string]$_ })
        if ($wanted.Count -ne $have.Count -or ($wanted -join [string][char]0) -cne ($have -join [string][char]0)) {
            $box.Items.Clear()
            foreach ($known in $wanted) { [void]$box.Items.Add($known) }
        }
        if ($box.Text -ne $company) { $box.Text = $company }
        # Dok je popis onemogućen (zadatak traje), vidljiva je oznaka ComboOff: i ona mora pratiti promjenu teksta.
        if ($null -ne $script:UI.ComboOff -and -not $box.Enabled) { $script:UI.ComboOff.Text = $box.Text }

        if ([string]::IsNullOrWhiteSpace($company)) {
            $label.Text = ('Izvještaji: upišite tvrtku / klijenta.  Korijen: {0}' -f (Get-ReportsRoot))
        } else {
            $folder = Get-CompanyFolder $company
            $kind   = Get-DriveKind $folder
            $tag    = ''
            if ($kind) { $tag = '[{0}] ' -f $kind }
            $label.Text = ('Izvještaji se spremaju u: {0}{1}' -f $tag, $folder)
        }
    } finally {
        $script:UI.ClientUpdating = $false
    }
}

function New-ClientBar {
    $c = $script:Colors
    $f = $script:Fonts

    $bar = New-Object System.Windows.Forms.TableLayoutPanel
    $bar.Dock        = 'Top'
    $bar.Height      = 46
    $bar.BackColor   = $c.Card
    $bar.Padding     = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
    $bar.ColumnCount = 5
    $bar.RowCount    = 1
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 132))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 300))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 112))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 132))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$bar.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $title = New-Object System.Windows.Forms.Label
    $title.Text        = 'TVRTKA / KLIJENT'
    $title.UseMnemonic = $false
    $title.Dock        = 'Fill'
    $title.TextAlign   = 'MiddleLeft'
    $title.UseCompatibleTextRendering = $true
    $title.Font        = $f.Strip
    $title.ForeColor   = $c.Yellow
    $title.BackColor   = $c.Card

    $combo = New-Object Auxilium.SkinCombo
    $combo.ColorButton    = $c.Card
    $combo.ColorLine      = $c.Line
    $combo.ColorArrow     = $c.Muted
    $combo.ColorArrowOpen = $c.Yellow
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $combo.FlatStyle     = [System.Windows.Forms.FlatStyle]::Flat
    $combo.Font          = $f.Combo
    $combo.BackColor     = $c.Data
    $combo.ForeColor     = $c.Text
    $combo.MaxLength     = 60
    $combo.Dock          = 'Fill'

    # Polje za unos: pozadina stranice i obrub od 1 px (boja obruba iza ispune); u fokusu obrub postaje tirkizan.
    $comboFrame = New-Object System.Windows.Forms.Panel
    $comboFrame.BackColor = $c.Line
    $comboFrame.Padding   = New-Object System.Windows.Forms.Padding(1)
    $comboFrame.Width     = 290
    $comboFrame.Height    = $combo.Height + 2
    $comboFrame.Anchor    = [System.Windows.Forms.AnchorStyles]::Left
    $comboFrame.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $comboFrame.Controls.Add($combo)
    $script:UI.ComboFrame = $comboFrame
    # Stvarna visina polja poznata je tek kad ComboBox dobije prozor (prije toga javlja 21 px, a ima 25 px): tada se okvir uskladi.
    $combo.Add_HandleCreated({ try { $script:UI.ComboFrame.Height = $script:UI.CompanyBox.Height + 2 } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> } })

    # Onemogućen standardni ComboBox crta se svijetlosivo (sistemske boje) i ruši tamnu temu: dok traje zadatak umjesto njega
    # stoji tamna oznaka s istim tekstom, a pravi popis je skriven (i opet vidljiv čim se omogući).
    $comboOff = New-Object System.Windows.Forms.Label
    $comboOff.UseMnemonic  = $false
    $comboOff.AutoEllipsis = $true
    $comboOff.Dock         = 'Fill'
    $comboOff.TextAlign    = 'MiddleLeft'
    $comboOff.Padding      = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
    $comboOff.Font         = $f.Combo
    $comboOff.BackColor    = $c.Data
    $comboOff.ForeColor    = $c.Muted2
    $comboOff.Visible      = $false
    $comboFrame.Controls.Add($comboOff)
    $script:UI.ComboOff = $comboOff
    $combo.Add_EnabledChanged({
        try {
            $box = $script:UI.CompanyBox
            $script:UI.ComboOff.Text    = $box.Text
            $script:UI.ComboOff.Visible = (-not $box.Enabled)
            $box.Visible                = $box.Enabled
        } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> }
    })

    $btnOpen = New-FlatButton 'Otvori mapu'
    $btnOpen.Font   = $f.StripBtn
    $btnOpen.Margin = New-Object System.Windows.Forms.Padding(0, 1, 8, 1)
    $btnRoot = New-FlatButton 'Postavi mapu...'
    $btnRoot.Font   = $f.StripBtn
    $btnRoot.Margin = New-Object System.Windows.Forms.Padding(0, 1, 10, 1)

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text         = ''
    $pathLabel.UseMnemonic  = $false
    $pathLabel.AutoEllipsis = $true
    $pathLabel.Dock         = 'Fill'
    $pathLabel.TextAlign    = 'MiddleLeft'
    $pathLabel.Font         = $f.Hint
    $pathLabel.ForeColor    = $c.Silver
    $pathLabel.BackColor    = $c.Card

    $bar.Add_Paint({
        param($sender, $e)
        try {
            $linePen = New-Object System.Drawing.Pen ($script:Colors.Line)
            try { $e.Graphics.DrawLine($linePen, 0, ($sender.Height - 1), $sender.Width, ($sender.Height - 1)) } finally { $linePen.Dispose() }
        } catch { Write-AppLog 'Debug' 'New-ClientBar: crtanje' $_ }
    })

    $bar.Controls.Add($title, 0, 0)
    $bar.Controls.Add($comboFrame, 1, 0)
    $bar.Controls.Add($btnOpen, 2, 0)
    $bar.Controls.Add($btnRoot, 3, 0)
    $bar.Controls.Add($pathLabel, 4, 0)

    $script:UI.CompanyBox     = $combo
    $script:UI.PathLabel      = $pathLabel
    $script:UI.ClientControls = @($combo, $btnOpen, $btnRoot)

    $combo.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $e.SuppressKeyPress = $true
            Set-ActiveCompany $script:UI.CompanyBox.Text
        }
    })
    $combo.Add_Leave({
        if (-not $script:Busy -and -not $script:Closing) { Set-ActiveCompany $script:UI.CompanyBox.Text }
    })
    $combo.Add_Enter({ try { $script:UI.ComboFrame.BackColor = $script:Colors.Cyan } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> } })
    $combo.Add_Leave({ try { $script:UI.ComboFrame.BackColor = $script:Colors.Line } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> } })
    $combo.Add_SelectionChangeCommitted({
        Set-ActiveCompany ([string]$script:UI.CompanyBox.SelectedItem) -KeepOrder
    })

    $btnOpen.Add_Click({
        try {
            Set-ActiveCompany $script:UI.CompanyBox.Text
            $company = Get-ActiveCompany
            $folder = Get-ReportsRoot
            if (-not [string]::IsNullOrWhiteSpace($company)) { $folder = Get-CompanyFolder $company }
            [void](Test-FolderWritable $folder)
            if (-not [System.IO.Directory]::Exists($folder)) { throw ('Mapa ne postoji i nije je moguće stvoriti: {0}' -f $folder) }
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
        } catch {
            Write-Terminal ('Mapu nije moguće otvoriti: {0}' -f $_.Exception.Message) 'Warn'
        }
    })

    $btnRoot.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $dialog.Description         = 'Odaberite korijensku mapu za izvještaje (npr. mapu na USB stiku). U njoj se za svaku tvrtku stvara zasebna mapa.'
            $dialog.ShowNewFolderButton = $true
            $current = Get-ReportsRoot
            if ([System.IO.Directory]::Exists($current)) { $dialog.SelectedPath = $current }
            if ($dialog.ShowDialog($script:UI.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
                Set-ReportsRoot $dialog.SelectedPath
                Update-ClientBar
                Write-Terminal ('Korijenska mapa izvještaja: {0}' -f (Get-ReportsRoot)) 'Info'
            }
        } catch {
            Write-Terminal ('Mapu nije moguće postaviti: {0}' -f $_.Exception.Message) 'Warn'
        } finally {
            $dialog.Dispose()
        }
    })

    return $bar
}

function New-MainForm {
    $c = $script:Colors
    $f = $script:Fonts

    Initialize-Portable

    [System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
        param($sender, $e)
        try { Write-AppLog 'Debug' ('UI nit: ' + $e.Exception.GetType().FullName + ' @ ' + (([string]$e.Exception.StackTrace -split "`r?`n")[0])) } catch { $script:LogFailed = $true }
        try { Write-Terminal ('NEOČEKIVANA GREŠKA: {0}' -f $e.Exception.Message) 'Error' } catch { $script:LogFailed = $true }
    })

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $script:AppTitle
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox     = $false
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    # Zadana veličina je 1400x760 (1040 za zaglavlje, kartice i terminal + 360 za status sustava s lijeve strane); na zaslonima s manjom radnom površinom
    # (skaliranje 125-150 %) ograničava se na nju.
    $workArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Control]::MousePosition).WorkingArea
    $form.Size            = New-Object System.Drawing.Size([Math]::Min(1400, $workArea.Width), [Math]::Min(760, $workArea.Height))
    $form.BackColor       = $c.Form
    $form.ForeColor       = $c.Text
    $form.Font            = $f.Ui
    $icon = New-AppIcon
    if ($null -ne $icon) { $form.Icon = $icon }
    $script:UI.Form = $form

    # --- Zaglavlje s logotipom ---
    $header = New-Object Auxilium.BufferedPanel
    $header.Dock      = 'Top'
    $header.Height    = 76
    $header.BackColor = $c.Header
    $header.Add_Paint({ param($sender, $e) Invoke-HeaderPaint $sender $e })

    # --- Zelena traka napretka ---
    $track = New-Object System.Windows.Forms.Panel
    $track.Dock      = 'Top'
    $track.Height    = 6
    $track.BackColor = $c.Track
    $fill = New-Object System.Windows.Forms.Panel
    $fill.BackColor = $c.Progress
    $fill.Left      = 0
    $fill.Top       = 0
    $fill.Height    = 6
    $fill.Width     = 0
    $track.Controls.Add($fill)
    $script:UI.ProgressTrack = $track
    $script:UI.ProgressFill  = $fill

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 25
    $timer.Add_Tick({
        $bar = $script:UI.ProgressFill
        $area = $script:UI.ProgressTrack
        $bar.Left += 14
        if ($bar.Left -gt $area.Width) { $bar.Left = -$bar.Width }
    })
    $script:UI.ProgressTimer = $timer

    # Nakon završetka zadatka zelena (ili crvena) traka ostaje kratko vidljiva, a zatim nestaje.
    $resetTimer = New-Object System.Windows.Forms.Timer
    $resetTimer.Interval = 2500
    $resetTimer.Add_Tick({
        try {
            $script:UI.ProgressResetTimer.Stop()
            if (-not $script:Busy) { Set-ProgressMode 'Idle' }
        } catch { Write-AppLog 'Debug' 'Tajmer: ProgressResetTimer' $_ }
    })
    $script:UI.ProgressResetTimer = $resetTimer

    # Tajmer koji prati pozadinsko prikupljanje (ažuriranja na čekanju i dnevnici događaja).
    $deepTimer = New-Object System.Windows.Forms.Timer
    $deepTimer.Interval = 400
    $deepTimer.Add_Tick({ try { Update-DeepScan } catch { Write-AppLog 'Debug' 'Tajmer: Update-DeepScan' $_ } })
    $script:UI.DeepTimer = $deepTimer

    # Tajmer za uživo osvježavanje CPU i RAM barova u statusu sustava (svake 2 s).
    $liveTimer = New-Object System.Windows.Forms.Timer
    $liveTimer.Interval = 2000
    $liveTimer.Add_Tick({ try { Update-LiveMeters } catch { Write-AppLog 'Debug' 'Tajmer: Update-LiveMeters' $_ } })
    $script:UI.LiveTimer = $liveTimer
    $liveTimer.Start()

    # --- Tijelo ---
    $body = New-Object System.Windows.Forms.Panel
    $body.Dock      = 'Fill'
    $body.BackColor = $c.Form
    $body.Padding   = New-Object System.Windows.Forms.Padding(0)

    # Sadržaj desno od statusa (kartice i terminal), s razmakom od 12 px prema rubovima i prema statusu.
    $content = New-Object System.Windows.Forms.Panel
    $content.Dock      = 'Fill'
    $content.BackColor = $c.Form
    $content.Padding   = New-Object System.Windows.Forms.Padding(12)

    $main = New-Object System.Windows.Forms.TableLayoutPanel
    $main.Dock        = 'Fill'
    $main.BackColor   = $c.Form
    $main.ColumnCount = 1
    $main.RowCount    = 2
    [void]$main.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$main.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 190))
    [void]$main.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    # --- Kartice ---
    $cards = New-Object System.Windows.Forms.TableLayoutPanel
    $cards.Dock        = 'Fill'
    $cards.BackColor   = $c.Form
    $cards.ColumnCount = 3
    $cards.RowCount    = 1
    for ($i = 0; $i -lt 3; $i++) {
        [void]$cards.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 33.33))
    }
    [void]$cards.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $card1 = New-CardGroup '1. Sistem & Popravci' 3
    $btnSfc = New-FlatButton 'Pokreni SFC & DISM'
    $btnChk = New-FlatButton 'CHKDSK Provjera (R-O)'
    $card1.Layout.Controls.Add($btnSfc, 0, 0)
    $card1.Layout.Controls.Add($btnChk, 0, 1)

    $card2 = New-CardGroup '2. Čišćenje sustava' 3
    $btnClean = New-FlatButton 'Duboko Čišćenje (TEMP)'
    $btnLogs  = New-FlatButton 'Izvezi i obriši dnevnike'
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text        = 'Briše TEMP datoteke, Windows Update predmemoriju i koš. Dnevnike prvo izvozi u TXT uz izvještaj, pa tek onda briše. Traži potvrdu.'
    $hint.UseMnemonic = $false
    $hint.Dock        = 'Fill'
    $hint.TextAlign   = 'MiddleLeft'
    $hint.Font        = $f.Hint
    $hint.ForeColor   = $c.Muted
    $hint.BackColor   = $c.Card
    $hint.Padding     = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
    $card2.Layout.Controls.Add($btnClean, 0, 0)
    $card2.Layout.Controls.Add($btnLogs, 0, 1)
    $card2.Layout.Controls.Add($hint, 0, 2)

    $card3 = New-CardGroup '3. Mreža & Izvještaji' 3
    $btnNet  = New-FlatButton 'Test Mreže & Ping'
    $btnPdf  = New-FlatButton 'Generiraj PDF Izvještaj' -Kind Primary
    $btnJson = New-FlatButton 'Izvezi JSON'
    # Drugi redak kartice: primarna radnja (PDF) i uz nju uži gumb za izvoz samo JSON-a.
    $reportRow = New-Object System.Windows.Forms.TableLayoutPanel
    $reportRow.Dock        = 'Fill'
    $reportRow.BackColor   = $c.Card
    $reportRow.Margin      = New-Object System.Windows.Forms.Padding(0)
    $reportRow.Padding     = New-Object System.Windows.Forms.Padding(0)
    $reportRow.ColumnCount = 2
    $reportRow.RowCount    = 1
    [void]$reportRow.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$reportRow.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 88))
    [void]$reportRow.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    $btnPdf.Margin  = New-Object System.Windows.Forms.Padding(4, 4, 2, 4)
    $btnJson.Margin = New-Object System.Windows.Forms.Padding(2, 4, 4, 4)
    $reportRow.Controls.Add($btnPdf, 0, 0)
    $reportRow.Controls.Add($btnJson, 1, 0)
    $card3.Layout.Controls.Add($btnNet, 0, 0)
    $card3.Layout.Controls.Add($reportRow, 0, 1)

    $card1.Group.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $card2.Group.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $card3.Group.Margin = New-Object System.Windows.Forms.Padding(0)
    $cards.Controls.Add($card1.Group, 0, 0)
    $cards.Controls.Add($card2.Group, 1, 0)
    $cards.Controls.Add($card3.Group, 2, 0)

    # --- Status sustava (lijevo, cijela visina prozora) i terminal (desno, ispod kartica) ---
    $statusArea = New-TextArea 'STATUS SUSTAVA' $c.Data $f.Mono $c.Text
    $btnRefresh = New-StripButton 'Osvježi' 70
    $statusArea.Strip.Controls.Add($btnRefresh)
    # Kartica Health Score iznad popisa statusa (razmak od 8 px ispod nje).
    $healthSpacer = New-Object System.Windows.Forms.Panel
    $healthSpacer.Dock      = 'Top'
    $healthSpacer.Height    = 8
    $healthSpacer.BackColor = $c.Data
    $healthTile = New-HealthTile
    $statusArea.Rtb.Parent.Controls.Add($healthSpacer)
    $statusArea.Rtb.Parent.Controls.Add($healthTile)

    $termArea = New-TextArea 'TERMINAL' $c.TermBack $f.Term $c.TermText
    $btnCancel = New-StripButton 'Prekini' 70 -Kind Danger
    $btnClear  = New-StripButton 'Očisti' 70
    $btnCancel.Enabled = $false
    # Razmak od 4 px između Prekini i Očisti: Margin se kod Dock=Right ne primjenjuje pa se postavlja uskim panelom (redoslijed: Prekini, razmak, Očisti).
    $stripGap = New-Object System.Windows.Forms.Panel
    $stripGap.Dock      = 'Right'
    $stripGap.Width     = 4
    $stripGap.BackColor = $c.Card
    $termArea.Strip.Controls.Add($btnCancel)
    $termArea.Strip.Controls.Add($stripGap)
    $termArea.Strip.Controls.Add($btnClear)
    $termArea.Container.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)

    $main.Controls.Add($cards, 0, 0)
    $main.Controls.Add($termArea.Container, 0, 1)
    $content.Controls.Add($main)

    # Zaglavlje, traka napretka i traka tvrtke protežu se preko cijele širine prozora. Redoslijed: zadnje dodano s Dock=Top ide na sam vrh.
    $clientBar = New-ClientBar

    # Tijelo: status sustava lijevo (u ravnini s karticama, do dna prozora), kartice i terminal desno.
    # Dock=Left se postavlja prije Dock=Fill, pa se dodaje zadnji.
    $leftPane = New-Object System.Windows.Forms.Panel
    $leftPane.Dock      = 'Left'
    $leftPane.Width     = 360
    $leftPane.BackColor = $c.Form
    $leftPane.Padding   = New-Object System.Windows.Forms.Padding(12, 12, 0, 12)
    $statusArea.Container.Dock = 'Fill'
    $leftPane.Controls.Add($statusArea.Container)
    $body.Controls.Add($content)
    $body.Controls.Add($leftPane)

    $form.Controls.Add($body)
    $form.Controls.Add($clientBar)
    $form.Controls.Add($track)
    $form.Controls.Add($header)

    # Redoslijed tipkom Tab: najprije polje tvrtke, zatim kartice i terminal, status zadnji.
    $clientBar.TabIndex = 0
    $body.TabIndex      = 1
    $content.TabIndex   = 0
    $leftPane.TabIndex  = 1

    $script:UI.Status        = $statusArea.Rtb
    $script:UI.Terminal      = $termArea.Rtb
    $script:UI.BtnCancel     = $btnCancel
    $script:UI.ActionButtons = @($btnSfc, $btnChk, $btnClean, $btnLogs, $btnNet, $btnPdf, $btnJson, $btnRefresh)

    # --- Događaji ---
    $btnSfc.Add_Click({ Start-GuiTask -Title 'SFC & DISM - provjera i popravak sustavnih datoteka' -Command 'Invoke-SfcDismTask' })
    $btnChk.Add_Click({ Start-GuiTask -Title 'CHKDSK - provjera diska (samo čitanje)' -Command 'Invoke-ChkdskTask' })
    $btnClean.Add_Click({
        Start-GuiTask -Title 'Duboko čišćenje sustava' -Command 'Invoke-CleanupTask' -ConfirmMessage (
            'Duboko čišćenje će trajno obrisati:' + [Environment]::NewLine +
            ' - privremene datoteke (korisnički i sistemski TEMP)' + [Environment]::NewLine +
            ' - Windows Update predmemoriju (SoftwareDistribution\Download)' + [Environment]::NewLine +
            ' - sadržaj koša za smeće' + [Environment]::NewLine + [Environment]::NewLine +
            'Datoteke koje su otvorene u drugim programima obično se preskaču. Prije čišćenja zatvorite druge programe i instalacije.' + [Environment]::NewLine + [Environment]::NewLine +
            'Želite li nastaviti?')
    })
    $btnNet.Add_Click({ Start-GuiTask -Title 'Test mreže i ping' -Command 'Invoke-NetworkTask' })
    $btnPdf.Add_Click({ Start-GuiTask -Title 'Generiranje PDF izvještaja' -Command 'Invoke-PdfTask' })
    $btnLogs.Add_Click({ Start-GuiTask -Title 'Izvoz i brisanje dnevnika događaja' -Command 'Invoke-EventLogClearTask' })
    $btnJson.Add_Click({ Start-GuiTask -Title 'Izvoz JSON-a za IT Inventar' -Command 'Invoke-InventoryExportTask' })
    $btnRefresh.Add_Click({ Start-GuiTask -Title 'Osvježavanje statusa sustava' -Command 'Update-SystemStatus' })
    $btnClear.Add_Click({ try { $script:UI.Terminal.Clear() } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> } })
    $btnCancel.Add_Click({
        if ($script:Busy) {
            $script:CancelRequested = $true
            Write-Terminal 'Zatražen je prekid zadatka...' 'Warn'
            Stop-CurrentProcess
        }
    })

    $form.Add_FormClosing({
        param($sender, $e)
        if ($script:Busy) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $script:UI.Form, 'Zadatak je još u tijeku. Želite li ga prekinuti i zatvoriti aplikaciju?', $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
            $script:Closing = $true
            $script:CancelRequested = $true
            Stop-CurrentProcess
        }
    })

    $form.Add_Shown({
        try { [Auxilium.NativeMethods]::TryEnableDarkTitleBar($script:UI.Form.Handle) } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> }
        try { [Auxilium.NativeMethods]::TrySetDarkScrollbars($script:UI.Status.Handle) } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> }
        try { [Auxilium.NativeMethods]::TrySetDarkScrollbars($script:UI.Terminal.Handle) } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> }
        try { [Auxilium.NativeMethods]::TrySetTheme($script:UI.CompanyBox.Handle, 'DarkMode_CFD') } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> }
        $adminText = 'standardni korisnik (neke radnje neće raditi)'
        if ($script:IsAdmin) { $adminText = 'administrator' }
        $script:ToolHash = Get-ToolFingerprint
        Write-Terminal ('Auxilium Informatika - Dijagnostika i čišćenje sustava v{0}' -f (Get-ToolVersionText)) 'Header'
        Write-Terminal ('Računalo: {0} | Korisnik: {1} | Prava: {2}' -f $env:COMPUTERNAME, [Environment]::UserName, $adminText) 'Info'
        Write-AppLog 'Info' ('Pokrenuto: v{0}, prava: {1}' -f (Get-ToolVersionText), $adminText)
        try {
            # Ako je UAC podignut drugim računom, Temp i koš koji se čiste pripadaju tom računu, a ne prijavljenom korisniku.
            $consoleUser = Get-ConsoleUser
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            if (-not [string]::IsNullOrWhiteSpace($consoleUser) -and $consoleUser -ne $me) {
                Write-Terminal ('Upozorenje: alat radi kao {0}, a prijavljen je {1}. Čišćenje se odnosi na Temp i koš računa {0}, ne računa {1}.' -f $me, $consoleUser) 'Warn'
            }
        } catch { Write-AppLog 'Debug' 'Provjera prijavljenog korisnika' $_ }

        Write-Terminal ('Alat se pokreće iz: {0}  [{1}]' -f $script:AppRoot, (Get-DriveKind $script:AppRoot)) 'Info'
        if ($script:SettingsLoadError) { Write-Terminal ('Postavke nisu učitane (koriste se zadane): {0}' -f $script:SettingsLoadError) 'Warn' }
        try {
            Update-ClientBar
            $startCompany = Get-ActiveCompany
            if ([string]::IsNullOrWhiteSpace($startCompany)) {
                Write-Terminal 'Upišite tvrtku / klijenta u polje na vrhu: izvještaji se spremaju u njezinu mapu na stiku.' 'Warn'
            } else {
                Write-Terminal ('Aktivna tvrtka / klijent: {0}  ->  {1}' -f $startCompany, (Get-CompanyFolder $startCompany)) 'Info'
            }
        } catch {
            Write-Terminal ('Traka tvrtke nije inicijalizirana: {0}' -f $_.Exception.Message) 'Warn'
        }
        Write-Terminal 'Spremno. Odaberite radnju iz kartica iznad.' 'Normal'
        # Nakon početnog učitavanja fokus ide u polje tvrtke (Set-BusyState), a ne na posljednji gumb.
        $script:FocusCompanyBox = $true
        Start-GuiTask -Title 'Učitavanje podataka o sustavu' -Command 'Update-SystemStatus'
    })
}
#endregion UI

