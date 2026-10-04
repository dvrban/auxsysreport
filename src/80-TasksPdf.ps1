#region TASKS - PDF
function New-ReportModel {
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add((New-InfoItem 'Section' '' '1. Podaci o izvještaju'))
    $items.Add((New-InfoItem 'KV' 'Izdavatelj' 'Auxilium Informatika - IT podrška'))
    $items.Add((New-InfoItem 'KV' 'Datum i vrijeme' ((Get-Date).ToString('dd.MM.yyyy. HH:mm:ss'))))
    if (-not [string]::IsNullOrWhiteSpace($script:ReportCompany)) {
        $items.Add((New-InfoItem 'KV' 'Tvrtka / klijent' $script:ReportCompany))
    }
    $items.Add((New-InfoItem 'KV' 'Računalo' $env:COMPUTERNAME))
    $runAs   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $console = Get-ConsoleUser
    if ([string]::IsNullOrWhiteSpace($console)) {
        $items.Add((New-InfoItem 'KV' 'Korisnik' $runAs))
    } else {
        $items.Add((New-InfoItem 'KV' 'Korisnik' $console))
        if ($console -ne $runAs) { $items.Add((New-InfoItem 'KV' 'Alat pokrenut kao' $runAs)) }
    }
    $items.Add((New-InfoItem 'KV' 'Verzija alata' $script:AppVersion))
    # Mjesto za odjeljak Health Score: popunjava se nakon prikupljanja podataka (niže).
    $healthAt = $items.Count
    $items.Add((New-InfoItem 'Spacer'))

    $items.Add((New-InfoItem 'Section' '' '2. Informacije o sustavu'))
    if (@($script:SysInfo).Count -eq 0) {
        # Status još nije učitan (prekid / istek vremena): ponovno prikupljanje u pozadini, uz mogućnost prekida.
        $fresh = Get-SystemInfoItemsAsync -TimeoutSeconds 20
        if ($null -ne $fresh) {
            $script:SysInfo = @($fresh)
            if ($null -ne $script:UI.Status) { Show-SystemInfo @(Get-CombinedInfoItems) }
        } elseif (Test-StopRequested) {
            return $null
        }
    }
    # Neinstalirana ažuriranja i dnevnici (7 dana): ako se još prikupljaju, čeka se (uz mogućnost prekida); ako nisu pokrenuta, pokreću se.
    if (@($script:SysInfo).Count -gt 0) {
        if ($script:Deep.State -eq 'Idle' -or $script:Deep.State -eq 'Cancelled') { Start-DeepScan }
        if ($script:Deep.State -eq 'Running') {
            Write-Terminal '  Čekam ažuriranja na čekanju i dnevnike događaja (pozadinsko prikupljanje)...' 'Info'
            [void](Wait-DeepScan -TimeoutSeconds 120)
            if (Test-StopRequested) { return $null }
        }
    }
    if (@($script:SysInfo).Count -eq 0) {
        $items.Add((New-InfoItem 'Text' '' 'Podaci o sustavu nisu bili dostupni (WMI/CIM nije odgovorio).' 'Warn'))
    }
    $inOsSection = $false
    foreach ($info in @(Get-CombinedInfoItems)) {
        if ($info.Kind -eq 'Section') {
            $inOsSection = ($info.Value -eq 'OPERACIJSKI SUSTAV')
            $items.Add((New-InfoItem 'SubSection' '' $info.Value))
        } elseif ($info.Kind -eq 'KV' -and $inOsSection -and @('Računalo', 'Korisnik', 'Alat pokrenut kao') -contains $info.Label) {
            # Ti podaci već stoje u odjeljku 1 (s prijavljenim korisnikom): ne ponavljaju se, da izvještaj ne navodi dva različita korisnika.
            continue
        } else {
            $items.Add((New-InfoItem $info.Kind $info.Label $info.Value $info.Status $info.Percent))
        }
    }
    # Health Score na vrh izvještaja (u odjeljak 1), iz istih stavki kao i odjeljak 2.
    $healthItems = @()
    try {
        $healthResult = Get-HealthResult @(Get-CombinedInfoItems)
        if ($null -ne $healthResult) {
            $healthItems = @(Get-HealthReportItems $healthResult)
        } else {
            $healthItems = @((New-InfoItem 'SubSection' '' 'HEALTH/SECURITY SCORE'), (New-InfoItem 'Text' '' 'Ocjena nije izračunana: nema dovoljno podataka o sustavu.' 'Warn'))
        }
    } catch {
        # Greška pri računanju ocjene ne smije tiho nestati: vidljiva je u izvještaju i u terminalu.
        $healthItems = @((New-InfoItem 'SubSection' '' 'HEALTH/SECURITY SCORE'), (New-InfoItem 'Text' '' ('Ocjena nije izračunana: ' + $_.Exception.Message) 'Warn'))
        Write-Terminal ('Health/Security Score nije izračunan: {0}' -f $_.Exception.Message) 'Warn'
    }
    if ($healthItems.Count -gt 0) { $items.InsertRange($healthAt, [object[]]$healthItems) }
    $items.Add((New-InfoItem 'Spacer'))

    $items.Add((New-InfoItem 'Section' '' '3. Dnevnik izvršenih zadataka (terminal)'))
    $lines = @()
    if ($null -ne $script:UI.Terminal) { $lines = @($script:UI.Terminal.Lines) }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
        if ($lines.Count -eq 1) { $lines = @() } else { $lines = $lines[0..($lines.Count - 2)] }
    }
    if ($lines.Count -eq 0) {
        $items.Add((New-InfoItem 'Text' '' 'Nema zabilježenih zadataka u terminalu.'))
    } else {
        foreach ($line in $lines) { $items.Add((New-InfoItem 'Log' '' ([string]$line))) }
    }
    return $items
}

function New-PdfBrush {
    param([int]$R, [int]$G, [int]$B)
    return (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($R, $G, $B)))
}

function Initialize-PdfState {
    param([System.Drawing.Printing.PrintDocument]$Doc, $Model)

    $bold = [System.Drawing.FontStyle]::Bold
    $p = @{ Error = $null; PageNo = 0 }
    # Ocjena za zaglavlje prve stranice (ista vrijednost kao red "Ocjena" u odjeljku Health/Security Score).
    $p.ScoreText   = ''
    $p.ScoreStatus = 'Normal'
    foreach ($modelItem in @($Model)) {
        if ($modelItem.Kind -eq 'KV' -and $modelItem.Label -eq 'Ocjena') {
            $p.ScoreText   = ([string]$modelItem.Value) -replace '\s*\(djelomično:.*\)\s*$', ' (djelomično)'
            $p.ScoreStatus = [string]$modelItem.Status
            break
        }
    }
    # Naslovni font logotipa kao u aplikaciji: Bahnschrift ako je instaliran, inače Segoe UI.
    $logoFamily = 'Segoe UI'
    try {
        foreach ($family in (New-Object System.Drawing.Text.InstalledFontCollection).Families) {
            if ($family.Name -eq 'Bahnschrift') { $logoFamily = 'Bahnschrift'; break }
        }
    } catch { }
    $p.Fonts = @{
        Body      = [System.Drawing.Font]::new('Segoe UI', 9)
        BodyBold  = [System.Drawing.Font]::new('Segoe UI', 9, $bold)
        Section   = [System.Drawing.Font]::new('Segoe UI', 12.5, $bold)
        Sub       = [System.Drawing.Font]::new('Segoe UI', 9.5, $bold)
        Mono      = [System.Drawing.Font]::new('Consolas', 7.5)
        Small     = [System.Drawing.Font]::new('Segoe UI', 8)
        LogoBold  = [System.Drawing.Font]::new($logoFamily, 22, $bold)
        LogoSub   = [System.Drawing.Font]::new('Segoe UI', 9.5)
        LogoLight = [System.Drawing.Font]::new('Segoe UI Light', 22)
        Title     = [System.Drawing.Font]::new('Segoe UI Semibold', 13)
    }
    $p.Brushes = @{
        Text    = New-PdfBrush 30 30 34
        Muted   = New-PdfBrush 105 105 115
        White   = New-PdfBrush 255 255 255
        Silver  = New-PdfBrush 192 192 200
        Red     = New-PdfBrush 220 30 60
        Yellow  = New-PdfBrush 255 204 0
        Band    = New-PdfBrush 20 20 24
        Log     = New-PdfBrush 244 244 246
        BarBack = New-PdfBrush 226 226 230
        Good    = New-PdfBrush 0 130 60
        Warn    = New-PdfBrush 190 120 0
        Bad     = New-PdfBrush 200 30 40
        HdrGood = New-PdfBrush 111 224 138
        HdrWarn = New-PdfBrush 255 201 74
        HdrBad  = New-PdfBrush 255 75 75
    }
    $p.Pens = @{
        Line = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(205, 205, 212)), 0.8
        Red  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(220, 30, 60)), 2.5
    }
    $p.Sf = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
    $p.SfRight = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
    $p.SfRight.Alignment = [System.Drawing.StringAlignment]::Far

    # Mjerenje u 1/100 inča (isto kao PrintPage Graphics): bitmap od 100 DPI s jedinicom Pixel.
    $p.Bmp = New-Object System.Drawing.Bitmap 8, 8
    $p.Bmp.SetResolution(100, 100)
    $p.Gm = [System.Drawing.Graphics]::FromImage($p.Bmp)
    $p.Gm.PageUnit = [System.Drawing.GraphicsUnit]::Pixel

    $paper = $Doc.DefaultPageSettings.PaperSize
    $p.PageW    = [double]$paper.Width
    $p.PageH    = [double]$paper.Height
    $p.ML       = 60.0
    $p.ContentW = $p.PageW - 120.0
    $p.LabelW   = 130.0
    $p.BandH    = 100.0
    $p.FirstTop = 125.0
    $p.ContTop  = 80.0
    $p.Bottom   = $p.PageH - 80.0

    $gm = $p.Gm; $f = $p.Fonts; $sf = $p.Sf
    $valueW = $p.ContentW - $p.LabelW
    $charW  = $gm.MeasureString(('M' * 200), $f.Mono, 100000, $sf).Width / 200.0
    $maxChars = [Math]::Max(20, [int][Math]::Floor($p.ContentW / $charW))
    $bodyH = $f.Body.GetHeight($gm)

    # Razvoj stavki (prelamanje redaka dnevnika) i izračun visina.
    $expanded = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Model) {
        if ($it.Kind -eq 'Log') {
            $text = (($it.Value -replace "`t", '    ') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
            if ($text.Length -eq 0) {
                $expanded.Add((New-InfoItem 'Log' '' ''))
            } else {
                # Prelamanje po riječima (monospace font); nastavci redaka uvučeni su za 4 znaka.
                $remaining = $text
                $firstLine = $true
                while ($remaining.Length -gt 0) {
                    $limit = $maxChars
                    if (-not $firstLine) { $limit = $maxChars - 4 }
                    if ($remaining.Length -le $limit) {
                        $chunk = $remaining
                        $remaining = ''
                    } else {
                        $cut = $remaining.LastIndexOf(' ', $limit - 1, $limit)
                        if ($cut -lt [int]($limit * 0.5)) { $cut = $limit }
                        $chunk = $remaining.Substring(0, $cut).TrimEnd()
                        $remaining = $remaining.Substring($cut).TrimStart()
                    }
                    if (-not $firstLine) { $chunk = '    ' + $chunk }
                    $expanded.Add((New-InfoItem 'Log' '' $chunk))
                    $firstLine = $false
                }
            }
        } else {
            $expanded.Add($it)
        }
    }

    $p.H = @{
        Section = $f.Section.GetHeight($gm) + 10.0
        Sub     = $f.Sub.GetHeight($gm) + 6.0
        Log     = $f.Mono.GetHeight($gm)
    }
    foreach ($it in $expanded) {
        if     ($it.Kind -eq 'Section')    { $it.Height = $p.H.Section }
        elseif ($it.Kind -eq 'SubSection') { $it.Height = $p.H.Sub }
        elseif ($it.Kind -eq 'KV') {
            $measured = $gm.MeasureString($it.Value, $f.Body, [int]$valueW, $sf).Height
            $it.Height = [Math]::Max($bodyH, $measured) + 3.0
        }
        elseif ($it.Kind -eq 'Bar')    { $it.Height = 12.0 }
        elseif ($it.Kind -eq 'Text')   { $it.Height = [Math]::Max($bodyH, $gm.MeasureString($it.Value, $f.Body, [int]$p.ContentW, $sf).Height) + 3.0 }
        elseif ($it.Kind -eq 'Spacer') { $it.Height = 8.0 }
        else                           { $it.Height = $p.H.Log }
    }

    # Straničenje.
    $pages = New-Object System.Collections.Generic.List[object]
    $cur   = New-Object System.Collections.Generic.List[object]
    $y     = $p.FirstTop
    for ($i = 0; $i -lt $expanded.Count; $i++) {
        $it   = $expanded[$i]
        $need = $it.Height
        if (($it.Kind -eq 'Section' -or $it.Kind -eq 'SubSection') -and ($i + 1) -lt $expanded.Count) { $need += $expanded[$i + 1].Height + 4.0 }
        if (($y + $need) -gt $p.Bottom -and $cur.Count -gt 0) {
            $pages.Add($cur)
            $cur = New-Object System.Collections.Generic.List[object]
            $y   = $p.ContTop
        }
        if ($cur.Count -eq 0 -and $it.Kind -eq 'Spacer') { continue }
        $it.Y = $y
        $cur.Add($it)
        $y += $it.Height
    }
    if ($cur.Count -gt 0 -or $pages.Count -eq 0) { $pages.Add($cur) }
    $p.Pages = $pages
    return $p
}

function Get-PdfBrush {
    param([string]$Status)
    $b = $script:Pdf.Brushes
    if ($Status -eq 'Good') { return $b.Good }
    if ($Status -eq 'Warn') { return $b.Warn }
    if ($Status -eq 'Bad')  { return $b.Bad }
    return $b.Text
}

function Write-PdfPage {
    param($E)

    $p  = $script:Pdf
    $g  = $E.Graphics
    $f  = $p.Fonts
    $b  = $p.Brushes
    $sf = $p.Sf
    $x  = $p.ML
    $w  = $p.ContentW
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    $pageNo = $p.PageNo
    $total  = $p.Pages.Count
    $stamp  = (Get-Date).ToString('dd.MM.yyyy. HH:mm')

    # --- Zaglavlje ---
    if ($pageNo -eq 0) {
        $g.FillRectangle($b.Band, 0, 0, $p.PageW, $p.BandH)
        $g.FillRectangle($b.Red, 0, $p.BandH, $p.PageW, 3)
        # Logotip: "AU" + crveni "X" + "ILIUM" + žuta "." naslovnim fontom, zatim "INFORMATIKA" manjim fontom s razmakom među slovima (kao u aplikaciji).
        $parts = @(
            @{ T = 'AU';    B = $b.White  },
            @{ T = 'X';     B = $b.Red    },
            @{ T = 'ILIUM'; B = $b.White  },
            @{ T = '.';     B = $b.Yellow }
        )
        $px = $x
        $py = 26.0
        $big = $f.LogoBold
        foreach ($part in $parts) {
            $g.DrawString($part.T, $big, $part.B, $px, $py, $sf)
            $px += $g.MeasureString($part.T, $big, 10000, $sf).Width
        }
        $px += 8.0
        $small = $f.LogoSub
        $bigAscent   = $big.FontFamily.GetCellAscent($big.Style) / [double]$big.FontFamily.GetEmHeight($big.Style) * $big.Size * 100.0 / 72.0
        $smallAscent = $small.FontFamily.GetCellAscent($small.Style) / [double]$small.FontFamily.GetEmHeight($small.Style) * $small.Size * 100.0 / 72.0
        $subY = $py + $bigAscent - $smallAscent
        foreach ($letter in 'INFORMATIKA'.ToCharArray()) {
            $ls = [string]$letter
            $g.DrawString($ls, $small, $b.Silver, $px, $subY, $sf)
            $px += $g.MeasureString($ls, $small, 10000, $sf).Width + 2.2
        }
        $titleRect = New-Object System.Drawing.RectangleF(($x + 250), 28, ($w - 250), 24)
        $g.DrawString('Izvještaj o dijagnostici sustava', $f.Title, $b.White, $titleRect, $p.SfRight)
        $subRect = New-Object System.Drawing.RectangleF(($x + 250), 54, ($w - 250), 18)
        $subText = '{0}  |  {1}' -f $env:COMPUTERNAME, $stamp
        if (-not [string]::IsNullOrWhiteSpace($script:ReportCompany)) { $subText = '{0}  |  {1}' -f $script:ReportCompany, $subText }
        $g.DrawString($subText, $f.Small, $b.Silver, $subRect, $p.SfRight)
        # Health/Security Score odmah u zaglavlju prve stranice (boja po razini).
        if (-not [string]::IsNullOrEmpty($p.ScoreText)) {
            $scoreBrush = $b.HdrGood
            if ($p.ScoreStatus -eq 'Warn') { $scoreBrush = $b.HdrWarn } elseif ($p.ScoreStatus -eq 'Bad') { $scoreBrush = $b.HdrBad }
            $valueW = $g.MeasureString($p.ScoreText, $f.Section, 10000, $sf).Width
            $valueRect = New-Object System.Drawing.RectangleF(($x + 250), 74, ($w - 250), 22)
            $g.DrawString($p.ScoreText, $f.Section, $scoreBrush, $valueRect, $p.SfRight)
            $labelRect = New-Object System.Drawing.RectangleF(($x + 250), 79, ($w - 250 - $valueW - 10), 16)
            $g.DrawString('HEALTH/SECURITY SCORE', $f.Small, $b.Silver, $labelRect, $p.SfRight)
        }
    } else {
        $g.DrawString('Auxilium Informatika - Izvještaj o dijagnostici sustava', $f.Small, $b.Muted, $x, 42, $sf)
        $rightRect = New-Object System.Drawing.RectangleF($x, 42, $w, 16)
        $rightText = $env:COMPUTERNAME
        if (-not [string]::IsNullOrWhiteSpace($script:ReportCompany)) { $rightText = '{0}  |  {1}' -f $script:ReportCompany, $env:COMPUTERNAME }
        $g.DrawString($rightText, $f.Small, $b.Muted, $rightRect, $p.SfRight)
        $g.DrawLine($p.Pens.Line, $x, 60, ($x + $w), 60)
    }

    # --- Sadržaj ---
    foreach ($it in $p.Pages[$pageNo]) {
        $y = $it.Y
        if ($it.Kind -eq 'Section') {
            $g.DrawString($it.Value, $f.Section, $b.Text, $x, ($y + 6), $sf)
            $lineY = $y + $it.Height - 2
            $g.DrawLine($p.Pens.Line, $x, $lineY, ($x + $w), $lineY)
            $g.DrawLine($p.Pens.Red, $x, $lineY, ($x + 48), $lineY)
        } elseif ($it.Kind -eq 'SubSection') {
            $g.DrawString($it.Value, $f.Sub, $b.Muted, $x, ($y + 4), $sf)
        } elseif ($it.Kind -eq 'KV') {
            $labelIndent = 0.0
            if ($it.Label.StartsWith('  ')) { $labelIndent = 14.0 }
            $g.DrawString($it.Label.Trim(), $f.BodyBold, $b.Muted, ($x + $labelIndent), $y, $sf)
            $rect = New-Object System.Drawing.RectangleF(($x + $p.LabelW), $y, ($w - $p.LabelW), $it.Height)
            $g.DrawString($it.Value, $f.Body, (Get-PdfBrush $it.Status), $rect, $sf)
        } elseif ($it.Kind -eq 'Bar') {
            if (-not [string]::IsNullOrEmpty($it.Label)) { $g.DrawString($it.Label.Trim(), $f.Small, $b.Muted, $x, ($y - 1), $sf) }
            $barW = 220.0
            $bx = $x + $p.LabelW
            $g.FillRectangle($b.BarBack, $bx, ($y + 2), $barW, 6)
            $fillW = $barW * [Math]::Min(100.0, [Math]::Max(0.0, $it.Percent)) / 100.0
            if ($fillW -gt 0) { $g.FillRectangle((Get-PdfBrush $it.Status), $bx, ($y + 2), $fillW, 6) }
            $g.DrawString($it.Value, $f.Small, $b.Muted, ($bx + $barW + 8), ($y - 1), $sf)
        } elseif ($it.Kind -eq 'Text') {
            $rect = New-Object System.Drawing.RectangleF($x, $y, $w, $it.Height)
            $g.DrawString($it.Value, $f.Body, (Get-PdfBrush $it.Status), $rect, $sf)
        } elseif ($it.Kind -eq 'Log') {
            $g.FillRectangle($b.Log, ($x - 4), $y, ($w + 8), $it.Height)
            if ($it.Value.Length -gt 0) { $g.DrawString($it.Value, $f.Mono, $b.Text, $x, $y, $sf) }
        }
    }

    # --- Podnožje ---
    $footY = $p.PageH - 55
    $g.DrawLine($p.Pens.Line, $x, $footY, ($x + $w), $footY)
    $g.DrawString(('Auxilium Informatika  |  IT podrška  |  generirano {0}' -f $stamp), $f.Small, $b.Muted, $x, ($footY + 6), $sf)
    $pageRect = New-Object System.Drawing.RectangleF($x, ($footY + 6), $w, 16)
    $g.DrawString(('Stranica {0} / {1}' -f ($pageNo + 1), $total), $f.Small, $b.Muted, $pageRect, $p.SfRight)

    $p.PageNo = $pageNo + 1
    $E.HasMorePages = ($p.PageNo -lt $total)
}

function Remove-PdfState {
    $p = $script:Pdf
    $script:Pdf = $null
    if ($null -eq $p) { return }
    foreach ($group in @('Fonts', 'Brushes', 'Pens')) {
        if ($p.ContainsKey($group)) {
            foreach ($key in @($p[$group].Keys)) { try { $p[$group][$key].Dispose() } catch { } }
        }
    }
    foreach ($key in @('Sf', 'SfRight', 'Gm', 'Bmp')) {
        try { if ($p.ContainsKey($key) -and $null -ne $p[$key]) { $p[$key].Dispose() } } catch { }
    }
}

function Test-PdfFileComplete {
    param([string]$Path)
    try {
        # FileShare.Read: otvaranje uspijeva tek kad spooler zatvori datoteku (inače bi sljedeće kopiranje dobilo sharing violation),
        # a istodobni čitači (antivirus, indeksiranje) ne smetaju.
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            if ($stream.Length -lt 64) { return $false }
            $count = [int][Math]::Min(1024, $stream.Length)
            [void]$stream.Seek(-$count, [System.IO.SeekOrigin]::End)
            $buffer = New-Object 'byte[]' $count
            $read = $stream.Read($buffer, 0, $count)
            return ([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read) -match '%%EOF')
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $false
    }
}

function Remove-FileQuiet {
    param([string]$Path, [int]$Retries = 20)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return }
            [System.IO.File]::Delete($Path)
            return
        } catch {
            Update-Ui
            Start-Sleep -Milliseconds 100
        }
    }
}

# Ispisuje izvještaj u privremenu PDF datoteku i tek nakon uspjeha je premješta na odabrano mjesto
# (neuspjeh ili prekid ne smiju uništiti postojeći izvještaj). Vraća FileInfo ili $null ako je prekinuto.
function Export-ReportToPdf {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PrinterName
    )

    $script:PdfCancelled = $false
    if (Test-StopRequested) { return $null }

    $model = New-ReportModel
    if ($null -eq $model) { return $null }
    $partial = Join-Path ([System.IO.Path]::GetTempPath()) ('Auxilium_{0}.pdf' -f [guid]::NewGuid().ToString('N'))
    $doc     = New-Object System.Drawing.Printing.PrintDocument
    try {
        $doc.PrinterSettings.PrinterName = $PrinterName
        if (-not $doc.PrinterSettings.IsValid) { throw ('Pisač "{0}" nije ispravno konfiguriran.' -f $PrinterName) }

        $directory = [System.IO.Path]::GetDirectoryName($Path)
        if (-not [string]::IsNullOrEmpty($directory) -and -not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }

        $doc.PrinterSettings.PrintToFile   = $true
        $doc.PrinterSettings.PrintFileName = $partial
        $doc.DocumentName                  = 'Auxilium Informatika - Izvještaj o dijagnostici sustava'
        $doc.PrintController               = New-Object System.Drawing.Printing.StandardPrintController

        foreach ($paper in $doc.PrinterSettings.PaperSizes) {
            if ($paper.Kind -eq [System.Drawing.Printing.PaperKind]::A4) { $doc.DefaultPageSettings.PaperSize = $paper; break }
        }
        $doc.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(0, 0, 0, 0)
        $doc.DefaultPageSettings.Landscape = $false

        $script:Pdf = Initialize-PdfState -Doc $doc -Model $model
        $pageCount  = $script:Pdf.Pages.Count
        $doc.add_PrintPage({
            param($sender, $e)
            try {
                # Sučelje se pumpa po stranici, a Prekini/zatvaranje prekidaju ispis.
                [System.Windows.Forms.Application]::DoEvents()
                if (Test-StopRequested) {
                    $script:PdfCancelled = $true
                    $e.Cancel = $true
                    $e.HasMorePages = $false
                    return
                }
                Write-PdfPage $e
            } catch {
                $script:Pdf.Error = $_.Exception.Message
                $e.HasMorePages = $false
            }
        })

        Write-Terminal ('  Stranica u izvještaju: {0}; ispis u datoteku...' -f $pageCount) 'Info'
        $doc.Print()
        if ($null -ne $script:Pdf -and $script:Pdf.Error) { throw ('Greška pri iscrtavanju izvještaja: ' + $script:Pdf.Error) }
        if ($script:PdfCancelled) { return $null }

        # Pisač "Microsoft Print to PDF" zapisuje datoteku asinkrono - čeka se da bude kompletna (prvo datoteka, tek onda prekid).
        $deadline = (Get-Date).AddSeconds([Math]::Max(40, 20 + $pageCount))
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            if ((Test-Path -LiteralPath $partial) -and (Test-PdfFileComplete $partial)) { $ready = $true; break }
            if (Test-StopRequested) { break }
            Update-Ui
            Start-Sleep -Milliseconds 150
        }
        if (-not $ready) {
            if (Test-StopRequested) { return $null }
            throw 'PDF datoteka nije stvorena u očekivanom roku. Provjerite pisač "Microsoft Print to PDF".'
        }

        # Kopiranje u odredišnu mapu (nova datoteka nasljeđuje ACL odredišta, radi i među volumenima), pa preimenovanje preko cilja.
        # Ako je cilj zaključan (npr. otvoren u pregledniku PDF-a), izvještaj se sprema pod zamjenskim imenom.
        # Kratko ime privremene datoteke (ne ovisi o imenu izvještaja) da putanja ne prijeđe MAX_PATH.
        $stageDir = [System.IO.Path]::GetDirectoryName($Path)
        if ([string]::IsNullOrEmpty($stageDir)) { $stageDir = (Get-Location).Path }
        $stage = [System.IO.Path]::Combine($stageDir, ('.aux-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 8)))
        $moved = $false
        $moveError = ''
        try {
            for ($i = 0; $i -lt 5 -and -not $moved; $i++) {
                try {
                    [System.IO.File]::Copy($partial, $stage, $true)
                    Move-Item -LiteralPath $stage -Destination $Path -Force -ErrorAction Stop
                    $moved = $true
                } catch {
                    $moveError = $_.Exception.Message
                    Update-Ui
                    Start-Sleep -Milliseconds 200
                }
            }
            if (-not $moved) {
                $altDir = [System.IO.Path]::GetDirectoryName($Path)
                if ([string]::IsNullOrEmpty($altDir)) { $altDir = (Get-Location).Path }
                $altBase = [System.IO.Path]::GetFileNameWithoutExtension($Path)
                $altExt  = [System.IO.Path]::GetExtension($Path)
                $alt = Join-Path $altDir ('{0}_{1}{2}' -f $altBase, (Get-Date -Format 'HHmmss'), $altExt)
                $n = 1
                while (Test-Path -LiteralPath $alt) {
                    $alt = Join-Path $altDir ('{0}_{1}_{2}{3}' -f $altBase, (Get-Date -Format 'HHmmss'), $n, $altExt)
                    $n++
                }
                try {
                    [System.IO.File]::Copy($partial, $alt, $false)
                } catch {
                    throw ('Odredišnu datoteku nije moguće prepisati (možda je otvorena u drugom programu), a ni zamjensko spremanje nije uspjelo: {0}' -f $_.Exception.Message)
                }
                Write-Terminal ('  Odredišnu datoteku nije bilo moguće zapisati (možda je otvorena u drugom programu); izvještaj je spremljen kao: {0}  [razlog: {1}]' -f $alt, $moveError) 'Warn'
                $Path = $alt
            }
        } finally {
            Remove-FileQuiet -Path $stage
        }
    } finally {
        Remove-PdfState
        $doc.Dispose()
        Remove-FileQuiet -Path $partial
    }
    return (Get-Item -LiteralPath $Path)
}

function Invoke-PdfTask {
    $printerName = 'Microsoft Print to PDF'
    $installed   = @([System.Drawing.Printing.PrinterSettings]::InstalledPrinters)
    if ($installed -notcontains $printerName) {
        Write-Terminal ('Pisač "{0}" nije instaliran.' -f $printerName) 'Error'
        Write-Terminal '  Uključite ga u: Windows značajke (optionalfeatures) -> Microsoft Print to PDF.' 'Warn'
        Write-Terminal '  Gumb "Izvezi JSON" radi i bez tog pisača.' 'Info'
        return
    }

    # Izvještaj se sprema automatski u mapu tvrtke: <korijen>\<Tvrtka>\<RACUNALO>_<korisnik>_<datum-vrijeme>.pdf
    if ($null -ne $script:UI.CompanyBox) { Set-ActiveCompany $script:UI.CompanyBox.Text }
    $company = Get-ActiveCompany
    if ([string]::IsNullOrWhiteSpace($company)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:UI.Form,
            ('Tvrtka / klijent nije postavljena (polje na vrhu prozora).' + [Environment]::NewLine + [Environment]::NewLine +
             'Želite li izvještaj spremiti u mapu "Nerazvrstano"?' + [Environment]::NewLine +
             '(Ne = povratak na unos tvrtke.)'),
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Terminal 'Generiranje PDF-a je otkazano: upišite tvrtku / klijenta u polje na vrhu.' 'Warn'
            # Polje je trenutno onemogućeno (zadatak je u tijeku): fokus se vraća u Set-BusyState kad zadatak završi.
            $script:FocusCompanyBox = $true
            $script:TaskNoResult    = $true
            return
        }
        $company = 'Nerazvrstano'
    }

    $file = Save-ReportForCompany -Company $company -PrinterName $printerName
    if ($null -eq $file) { return }
    [System.Windows.Forms.Application]::DoEvents()
    if (Test-StopRequested) {
        Write-Terminal ('Prekid je zatražen, ali je PDF već spremljen: {0}' -f $file.FullName) 'Warn'
        return
    }
    Write-Terminal ('PDF izvještaj je spremljen ({0}): {1}' -f (Format-Bytes ([double]$file.Length)), $file.FullName) 'Ok'

    # JSON za IT Inventar uz PDF (isto ime, nastavak .json). Greška pri izvozu nikad ne poništava već spremljen PDF.
    $jsonFile = $null
    try {
        $jsonCompany = $null
        if (-not [string]::IsNullOrWhiteSpace((Get-ActiveCompany))) { $jsonCompany = $company }
        $jsonFile = Export-InventoryJson -Path ([System.IO.Path]::ChangeExtension($file.FullName, '.json')) -Company $jsonCompany
        if ($null -ne $jsonFile) {
            Write-Terminal ('JSON za IT Inventar je spremljen ({0}): {1}' -f (Format-Bytes ([double]$jsonFile.Length)), $jsonFile.FullName) 'Ok'
        } else {
            Write-Terminal 'Izvoz JSON-a je prekinut (PDF je spremljen).' 'Warn'
        }
    } catch {
        Write-Terminal ('JSON izvoz nije uspio (PDF je spremljen): {0}' -f $_.Exception.Message) 'Warn'
    }

    # Prekid (ili zatvaranje prozora) tijekom izvoza JSON-a: kao i prije izvoza, nakon prekida se ne prikazuje pitanje o otvaranju PDF-a.
    if (Test-StopRequested) {
        Write-Terminal ('Prekid je zatražen, ali je PDF već spremljen: {0}' -f $file.FullName) 'Warn'
        return
    }

    $openText = 'PDF izvještaj je spremljen:' + [Environment]::NewLine + $file.FullName
    if ($null -ne $jsonFile) { $openText += [Environment]::NewLine + 'JSON: ' + $jsonFile.FullName }
    $open = [System.Windows.Forms.MessageBox]::Show(
        $script:UI.Form,
        ($openText + [Environment]::NewLine + [Environment]::NewLine + 'Želite li ga otvoriti?'),
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($open -eq [System.Windows.Forms.DialogResult]::Yes) {
        try { Start-Process -FilePath $file.FullName } catch { Write-Terminal ('Datoteku nije moguće otvoriti: {0}' -f $_.Exception.Message) 'Warn' }
    }
}
#endregion TASKS - PDF

