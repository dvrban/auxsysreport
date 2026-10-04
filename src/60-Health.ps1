#region HEALTH
# Health Score (0-100): ocjena stanja računala iz stavki koje alat već prikuplja (statusi Good/Warn/Bad i brojači) uz popis razloga.
# Težine: Sigurnost 30, Diskovi 20, Stabilnost 15, Ažuriranja 15, Resursi 10, Licence 5, Pošta 5. Svako područje ima gornju granicu odbitka.
# Područje bez podataka (npr. pozadinsko prikupljanje nije dovršeno) ne ulazi u zbroj, a ocjena se označava kao djelomična.
function Get-HealthResult {
    param($Items)

    $sections = @{}
    $order = New-Object System.Collections.Generic.List[string]
    $current = $null
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        if ($it.Kind -eq 'Section') {
            $current = [string]$it.Value
            if (-not $sections.ContainsKey($current)) {
                $sections[$current] = New-Object System.Collections.Generic.List[object]
                $order.Add($current)
            }
        } elseif ($null -ne $current) {
            $sections[$current].Add($it)
        }
    }

    function Get-Sec {
        param([string]$Prefix)
        foreach ($n in $order) {
            if ($n.StartsWith($Prefix)) { return ,@($sections[$n].ToArray()) }
        }
        return $null
    }
    function Get-Rows {
        param($Sec, [string]$Label)
        if ($null -eq $Sec) { return @() }
        return @($Sec | Where-Object { $_.Kind -eq 'KV' -and ([string]$_.Label).Trim() -eq $Label })
    }
    function Get-Worst {
        param($Rows)
        $worst = 'Good'
        foreach ($r in @($Rows)) {
            if ($r.Status -eq 'Bad') { return 'Bad' }
            if ($r.Status -eq 'Warn') { $worst = 'Warn' }
        }
        return $worst
    }
    function Test-HasRows {
        param($Sec)
        return (($null -ne $Sec) -and (@($Sec | Where-Object { $_.Kind -eq 'KV' }).Count -gt 0))
    }
    function New-Cat {
        param([string]$Name, [int]$Max, [bool]$Avail)
        return [pscustomobject]@{ Name = $Name; Max = $Max; Avail = $Avail; Lost = 0; Items = (New-Object System.Collections.Generic.List[object]) }
    }
    function Lose {
        param($Cat, [int]$Points, [string]$Text)
        if ($Cat.Avail -and $Points -gt 0) {
            $Cat.Lost += $Points
            $Cat.Items.Add([pscustomobject]@{ Points = $Points; Text = $Text; Category = $Cat.Name })
        }
    }

    $cats = New-Object System.Collections.Generic.List[object]
    $sec  = Get-Sec 'SIGURNOST'
    $soft = Get-Sec 'SOFTVER I LICENCE'
    $dl   = Get-Sec 'DISKOVI'
    $dh   = Get-Sec 'ZDRAVLJE DISKOVA'
    $ev   = Get-Sec 'DNEVNICI'
    $wu   = Get-Sec 'WINDOWS UPDATE'
    $hw   = Get-Sec 'PROCESSOR'
    $os   = Get-Sec 'OPERACIJSKI'

    # --- Sigurnost (30) ---
    $cat = New-Cat 'Sigurnost' 30 (Test-HasRows $sec)
    if ($cat.Avail) {
        if ((Get-Worst (Get-Rows $sec 'Antivirus')) -eq 'Bad') { Lose $cat 10 'Antivirus nije pronađen ili je isključen' }
        $w = Get-Worst (Get-Rows $sec 'Definicije')
        if ($w -eq 'Bad') { Lose $cat 4 'Definicije antivirusa su zastarjele (više od 7 dana)' } elseif ($w -eq 'Warn') { Lose $cat 2 'Definicije antivirusa nisu najnovije' }
        $w = Get-Worst (Get-Rows $sec 'Vatrozid')
        if ($w -eq 'Bad') { Lose $cat 6 'Windows vatrozid je isključen' } elseif ($w -eq 'Warn') { Lose $cat 3 'Windows vatrozid je djelomično isključen (provjerite vatrozid antivirusa)' }
        if ((Get-Worst (Get-Rows $sec 'Šifriranje diska')) -ne 'Good') { Lose $cat 4 'Disk nije šifriran (BitLocker) na prijenosnom računalu' }
        # SMBv1 i RDP zajedno najviše 3 boda.
        $pairLeft = 3
        if ((Get-Worst (Get-Rows $sec 'SMBv1')) -eq 'Bad') { Lose $cat 2 'SMBv1 je uključen (zastario protokol)'; $pairLeft -= 2 }
        $w = Get-Worst (Get-Rows $sec 'RDP')
        if ($w -eq 'Bad') { Lose $cat ([Math]::Min(3, $pairLeft)) 'RDP je uključen bez NLA zaštite' } elseif ($w -eq 'Warn') { Lose $cat ([Math]::Min(1, $pairLeft)) 'RDP (udaljeni pristup) je uključen' }
        $w = Get-Worst (Get-Rows $soft 'Windows')
        if ($w -eq 'Bad') { Lose $cat 3 'Windows nije aktiviran' } elseif ($w -eq 'Warn') { Lose $cat 2 'Windows je u odgodi aktivacije' }
    }
    $cats.Add($cat)

    # --- Diskovi (20) ---
    $cat = New-Cat 'Diskovi' 20 ((Test-HasRows $dl) -or (Test-HasRows $dh))
    if ($cat.Avail) {
        $diskName = ''
        foreach ($r in @($dh)) {
            if ($r.Kind -ne 'KV') { continue }
            $lab = ([string]$r.Label).Trim()
            if ($lab -like 'Disk *') { $diskName = [string]$r.Value; if ($diskName.Length -gt 40) { $diskName = $diskName.Substring(0, 40) }; continue }
            if ($lab -eq 'Zdravlje') {
                if ($r.Status -eq 'Bad') { Lose $cat 20 ('Zdravlje fizičkog diska je loše: ' + $diskName) } elseif ($r.Status -eq 'Warn') { Lose $cat 10 ('Zdravlje fizičkog diska je upozorenje: ' + $diskName) }
            } elseif ($lab -eq 'Istrošenost') {
                if ($r.Status -eq 'Bad') { Lose $cat 6 ('SSD je istrošen 90 % ili više: ' + $diskName) } elseif ($r.Status -eq 'Warn') { Lose $cat 3 ('SSD je istrošen 70 % ili više: ' + $diskName) }
            } elseif ($lab -eq 'Temperatura') {
                if ($r.Status -eq 'Bad') { Lose $cat 3 ('Disk je pretopao (70 °C ili više): ' + $diskName) } elseif ($r.Status -eq 'Warn') { Lose $cat 1 ('Disk je topao (55 °C ili više): ' + $diskName) }
            }
        }
        $sysDrive = [string]$env:SystemDrive
        foreach ($r in @($dl)) {
            if ($r.Kind -ne 'KV' -or ($r.Status -ne 'Bad' -and $r.Status -ne 'Warn')) { continue }
            $isSys = ((-not [string]::IsNullOrEmpty($sysDrive)) -and ([string]$r.Label).StartsWith($sysDrive, [System.StringComparison]::OrdinalIgnoreCase))
            $lab = ([string]$r.Label).Trim()
            if ($r.Status -eq 'Bad') {
                if ($isSys) { Lose $cat 8 ('Sistemski disk ' + $lab + ' ima manje od 10 % slobodnog prostora') } else { Lose $cat 3 ('Disk ' + $lab + ' ima manje od 10 % slobodnog prostora') }
            } else {
                if ($isSys) { Lose $cat 4 ('Sistemski disk ' + $lab + ' ima manje od 20 % slobodnog prostora') } else { Lose $cat 1 ('Disk ' + $lab + ' ima manje od 20 % slobodnog prostora') }
            }
        }
    }
    $cats.Add($cat)

    # --- Stabilnost (15): dnevnici događaja zadnjih 7 dana ---
    $cat = New-Cat 'Stabilnost' 15 (@(Get-Rows $ev 'BSOD').Count -gt 0)
    if ($cat.Avail) {
        if ((Get-Worst (Get-Rows $ev 'BSOD')) -eq 'Bad') { Lose $cat 6 'Plavi ekran (BSOD) u zadnjih 7 dana' }
        foreach ($r in @(Get-Rows $ev 'Nepl. gašenja')) {
            $n = 0; [void][int]::TryParse(([string]$r.Value).Trim(), [ref]$n)
            if ($n -ge 3) { Lose $cat 4 ('Neočekivana gašenja računala: ' + $n) } elseif ($n -gt 0) { Lose $cat 2 ('Neočekivana gašenja računala: ' + $n) }
        }
        if ((Get-Worst (Get-Rows $ev 'Greške diska')) -eq 'Bad') { Lose $cat 4 'Greške diska u dnevniku sustava' }
        if ((Get-Worst (Get-Rows $ev 'WHEA (hardv.)')) -eq 'Bad') { Lose $cat 4 'Hardverske greške (WHEA) u dnevniku sustava' }
        foreach ($r in @(Get-Rows $ev 'Rušenja app')) {
            if ($r.Status -eq 'Good') { continue }
            $n = 0; if (([string]$r.Value) -match '^\s*(\d+)') { $n = [int]$Matches[1] }
            if ($n -ge 10) { Lose $cat 4 ('Česta rušenja aplikacija: ' + $n) } else { Lose $cat 2 ('Rušenja aplikacija: ' + $n) }
        }
        $critical = $false; $errorsTotal = 0
        foreach ($logName in @('System', 'Application')) {
            foreach ($r in @(Get-Rows $ev $logName)) {
                if ($r.Status -eq 'Bad') { $critical = $true }
                if (([string]$r.Value) -match 'grešaka:\s*(\d+)') { $errorsTotal += [int]$Matches[1] }
            }
        }
        if ($critical) { Lose $cat 3 'Kritične greške u dnevnicima (System / Application)' }
        if ($errorsTotal -ge 50) { Lose $cat 2 ('Puno grešaka u dnevnicima: ' + $errorsTotal) }
    }
    $cats.Add($cat)

    # --- Ažuriranja (15) ---
    $pending = @(Get-Rows $wu 'Na čekanju')
    $cat = New-Cat 'Ažuriranja' 15 ($pending.Count -gt 0)
    if ($cat.Avail) {
        $n = 0; if (([string]$pending[0].Value) -match '^\s*(\d+)') { $n = [int]$Matches[1] }
        if ($n -ge 10) { Lose $cat 12 ('Neinstaliranih ažuriranja: ' + $n) } elseif ($n -ge 5) { Lose $cat 8 ('Neinstaliranih ažuriranja: ' + $n) } elseif ($n -ge 1) { Lose $cat 4 ('Neinstaliranih ažuriranja: ' + $n) }
        if (@(Get-Rows $wu 'Restart').Count -gt 0) { Lose $cat 2 'Potreban je restart zbog ažuriranja' }
        foreach ($r in @(Get-Rows $wu 'Zadnjih 7 d')) {
            if (([string]$r.Value) -match '(\d+)\s+neuspjel') {
                $f = [int]$Matches[1]
                if ($f -ge 3) { Lose $cat 3 ('Neuspjeli pokušaji ažuriranja u 7 dana: ' + $f) } elseif ($f -ge 1) { Lose $cat 1 ('Neuspjeli pokušaji ažuriranja u 7 dana: ' + $f) }
            }
        }
    }
    $cats.Add($cat)

    # --- Resursi (10) ---
    $ram = @(Get-Rows $hw 'RAM slobodno')
    $up  = @(Get-Rows $os 'Radi već')
    $cat = New-Cat 'Resursi' 10 (($ram.Count -gt 0) -or ($up.Count -gt 0))
    if ($cat.Avail) {
        $w = Get-Worst $ram
        if ($w -eq 'Bad') { Lose $cat 5 'Slobodno je manje od 10 % RAM-a' } elseif ($w -eq 'Warn') { Lose $cat 2 'Slobodno je manje od 20 % RAM-a' }
        if ($up.Count -gt 0 -and ([string]$up[0].Value) -match '^\s*(\d+)\s*d') {
            $days = [int]$Matches[1]
            if ($days -ge 60) { Lose $cat 5 ('Računalo nije restartirano ' + $days + ' dana') } elseif ($days -ge 30) { Lose $cat 3 ('Računalo nije restartirano ' + $days + ' dana') }
        }
    }
    $cats.Add($cat)

    # --- Licence (5) ---
    $cat = New-Cat 'Licence' 5 (Test-HasRows $soft)
    if ($cat.Avail) {
        $w = Get-Worst (Get-Rows $soft 'Office licenca')
        if ($w -eq 'Bad') { Lose $cat 5 'Office licenca nije ispravna' } elseif ($w -eq 'Warn') { Lose $cat 3 'Office licenca traži provjeru (odgoda)' }
        if ((Get-Worst (Get-Rows $soft 'Office update')) -eq 'Warn') { Lose $cat 2 'Automatska ažuriranja Officea su isključena' }
    }
    $cats.Add($cat)

    # --- Pošta (5): velike Outlook datoteke ---
    $cat = New-Cat 'Pošta' 5 (Test-HasRows $soft)
    if ($cat.Avail) {
        $mail = @($soft | Where-Object { $_.Kind -eq 'KV' -and ([string]$_.Value) -match '\.(ost|pst|nst) \(promijenjeno' })
        $w = Get-Worst $mail
        if ($w -eq 'Bad') { Lose $cat 5 'Outlook datoteka od 45 GB ili više' } elseif ($w -eq 'Warn') { Lose $cat 2 'Outlook datoteka od 20 GB ili više' }
    }
    $cats.Add($cat)

    $availMax = 0; $lostTotal = 0; $partial = $false
    foreach ($c in $cats) {
        if ($c.Avail) { $availMax += $c.Max; $lostTotal += [Math]::Min($c.Max, $c.Lost) } else { $partial = $true }
    }
    if ($availMax -le 0) { return $null }
    $score = [int][Math]::Round(100.0 * ($availMax - $lostTotal) / $availMax)
    $label = 'LOŠE'
    if ($score -ge 90) { $label = 'ODLIČNO' } elseif ($score -ge 75) { $label = 'DOBRO' } elseif ($score -ge 50) { $label = 'UPOZORENJE' }
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cats) { foreach ($d in $c.Items) { $all.Add($d) } }
    $sorted = @($all | Sort-Object -Property @{ Expression = 'Points'; Descending = $true })
    return [pscustomobject]@{ Score = $score; Label = $label; Partial = $partial; Deductions = $sorted; Categories = @($cats.ToArray()) }
}

# Redovi za izvještaj (PDF): ocjena, traka i razlozi odbitka.
function Get-HealthReportItems {
    param($Health)
    $items = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Health) { return $items.ToArray() }
    $st = 'Warn'
    if ($Health.Score -ge 90) { $st = 'Good' } elseif ($Health.Score -lt 50) { $st = 'Bad' }
    $text = '{0} / 100 - {1}' -f $Health.Score, $Health.Label
    if ($Health.Partial) { $text += ' (djelomično: neka područja nisu provjerena)' }
    $items.Add((New-InfoItem 'SubSection' '' 'HEALTH/SECURITY SCORE'))
    $items.Add((New-InfoItem 'KV' 'Ocjena' $text $st))
    $items.Add((New-InfoItem 'Bar' '' ('{0} / 100' -f $Health.Score) $st ([double]$Health.Score)))
    foreach ($cat in @($Health.Categories)) {
        if (-not $cat.Avail) {
            $items.Add((New-InfoItem 'KV' $cat.Name 'nije provjereno' 'Muted'))
            continue
        }
        $earned = $cat.Max - [Math]::Min($cat.Max, $cat.Lost)
        $cs = 'Good'
        if ($cat.Lost -gt 0) { if ($cat.Lost -gt 0.4 * $cat.Max) { $cs = 'Bad' } else { $cs = 'Warn' } }
        $items.Add((New-InfoItem 'KV' $cat.Name ('{0} / {1}' -f $earned, $cat.Max) $cs))
    }
    $shown = 0
    foreach ($d in @($Health.Deductions)) {
        if ($shown -ge 8) { break }
        $ds = 'Normal'
        if ($d.Points -ge 8) { $ds = 'Bad' } elseif ($d.Points -ge 3) { $ds = 'Warn' }
        $items.Add((New-InfoItem 'KV' ('-' + $d.Points) ('{0}: {1}' -f $d.Category, $d.Text) $ds))
        $shown++
    }
    if (@($Health.Deductions).Count -eq 0) { $items.Add((New-InfoItem 'Text' '' 'Nema odbitaka: sve provjerene stavke su u redu.' 'Good')) }
    return $items.ToArray()
}

# Kartica "Health Score" na vrhu statusa sustava (ocjena, oznaka i tri najveća razloga odbitka).
function New-HealthTile {
    $c = $script:Colors
    $tile = New-Object Auxilium.BufferedPanel
    $tile.Dock      = 'Top'
    $tile.Height    = 96
    $tile.BackColor = $c.Header
    $tile.Add_Paint({ param($sender, $e) Invoke-HealthPaint $sender $e })
    $script:UI.HealthTile = $tile
    return $tile
}

function Invoke-HealthPaint {
    param($Sender, $E)
    $sf = $null
    $sfRight = $null
    try {
        $g = $E.Graphics
        $c = $script:Colors
        $f = $script:Fonts
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $w = $Sender.Width
        $h = $Sender.Height
        $lineColor = $c.Button
        if ($c.ContainsKey('Line')) { $lineColor = $c.Line }
        $pen = New-Object System.Drawing.Pen ($lineColor)
        try { $g.DrawRectangle($pen, 0, 0, ($w - 1), ($h - 1)) } finally { $pen.Dispose() }

        $health = $script:Health
        $ready = ($script:HealthState -eq 'Ready' -and $null -ne $health)
        $scoreText = [string][char]0x2013
        $labelText = 'NEMA PODATAKA'
        $numColor = $c.Muted
        if ($script:HealthState -eq 'Computing') {
            $scoreText = [string][char]0x2026
            $labelText = 'PROVJERA U TIJEKU'
        } elseif ($ready) {
            $scoreText = '{0} / 100' -f $health.Score
            $labelText = $health.Label
            if ($health.Partial) { $labelText += ' (djelomično)' }
            if ($health.Score -ge 90) { $numColor = $c.Good } elseif ($health.Score -ge 50) { $numColor = $c.Yellow } else { $numColor = $c.Bad }
        }

        $sf = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
        $sf.FormatFlags = $sf.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap
        $sf.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $sfRight = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
        $sfRight.FormatFlags = $sfRight.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap
        $sfRight.Alignment = [System.Drawing.StringAlignment]::Far
        $drawAt = {
            param([string]$Text, $Font, $Color, [double]$X, [double]$Y, [double]$Width, $Format)
            $brush = New-Object System.Drawing.SolidBrush ($Color)
            try { $g.DrawString($Text, $Font, $brush, (New-Object System.Drawing.RectangleF([single]$X, [single]$Y, [single][Math]::Max(10, $Width), [single]($Font.Height + 2))), $Format) } finally { $brush.Dispose() }
        }
        $fillRect = {
            param($Color, [double]$X, [double]$Y, [double]$Width, [double]$Height)
            $brush = New-Object System.Drawing.SolidBrush ($Color)
            try { $g.FillRectangle($brush, [single]$X, [single]$Y, [single]$Width, [single]$Height) } finally { $brush.Dispose() }
        }
        $inner = [double]($w - 28)
        & $drawAt 'Health/Security Score' $f.Ui $c.Text 14 8 $inner $sf
        & $drawAt $scoreText $f.HealthNum $numColor 14 24 $inner $sf

        # Bar ocjene: 20 segmenata (svaki 5 bodova), boja po razini.
        $segments = 20
        $gap = 2.0
        $segW = ($inner - $gap * ($segments - 1)) / $segments
        $lit = 0
        if ($ready) { $lit = [int][Math]::Round($health.Score / 100.0 * $segments) }
        for ($i = 0; $i -lt $segments; $i++) {
            $segColor = $lineColor
            if ($i -lt $lit) { $segColor = $numColor }
            & $fillRect $segColor (14 + $i * ($segW + $gap)) 62 $segW 8
        }
        & $drawAt $labelText $f.UiBold $c.Text 14 76 $inner $sf

        if ($ready) {
            # Mini-barovi po područjima (zadržano bodova / najviše bodova).
            $y = 98.0
            $nameW = 84.0
            $valW = 46.0
            $barX = 14.0 + $nameW + 4.0
            $barW = [Math]::Max(20.0, $inner - $nameW - $valW - 8.0)
            foreach ($cat in @($health.Categories)) {
                & $drawAt ([string]$cat.Name) $f.Hint $c.Muted 14 $y $nameW $sf
                & $fillRect $lineColor $barX ($y + 5) $barW 6
                if ($cat.Avail) {
                    $earned = $cat.Max - [Math]::Min($cat.Max, $cat.Lost)
                    $catColor = $c.Good
                    if ($cat.Lost -gt 0) { if ($cat.Lost -gt 0.4 * $cat.Max) { $catColor = $c.Bad } else { $catColor = $c.Yellow } }
                    if ($earned -gt 0) { & $fillRect $catColor $barX ($y + 5) ($barW * $earned / $cat.Max) 6 }
                    & $drawAt ('{0} / {1}' -f $earned, $cat.Max) $f.Hint $c.Muted ($barX + $barW + 4) $y $valW $sfRight
                } else {
                    & $drawAt ([string][char]0x2013) $f.Hint $c.Muted ($barX + $barW + 4) $y $valW $sfRight
                }
                $y += 14.0
            }
            # Tri najveća razloga odbitka.
            $y += 6.0
            $shown = 0
            foreach ($d in @($health.Deductions)) {
                if ($shown -ge 3) { break }
                & $drawAt ('-{0}  {1}' -f $d.Points, $d.Text) $f.Hint $c.Muted 14 $y $inner $sf
                $y += 15.0
                $shown++
            }
            if (@($health.Deductions).Count -eq 0) { & $drawAt 'Nema odbitaka: sve je u redu.' $f.Hint $c.Muted 14 $y $inner $sf }
        }
    } catch {
    } finally {
        if ($null -ne $sf) { $sf.Dispose() }
        if ($null -ne $sfRight) { $sfRight.Dispose() }
    }
}

# Poziva se nakon svakog iscrtavanja statusa: ocjena se računa iz istih stavki koje se prikazuju.
function Update-HealthTile {
    param($Items)
    $tile = $script:UI.HealthTile
    if ($null -eq $tile -or $tile.IsDisposed) { return }
    $script:Health = $null
    if (@($Items).Count -eq 0) {
        $script:HealthState = 'Loading'
    } elseif ($script:Deep.State -eq 'Running') {
        $script:HealthState = 'Computing'
    } else {
        try { $script:Health = Get-HealthResult $Items } catch { $script:Health = $null }
        $script:HealthState = 'Ready'
    }
    $height = 96
    if ($script:HealthState -eq 'Ready' -and $null -ne $script:Health) {
        $lines = [Math]::Max(1, [Math]::Min(3, @($script:Health.Deductions).Count))
        $height = 98 + 14 * @($script:Health.Categories).Count + 8 + 15 * $lines + 8
    }
    if ($tile.Height -ne $height) { $tile.Height = $height }
    $tile.Invalidate()
}
#endregion HEALTH

