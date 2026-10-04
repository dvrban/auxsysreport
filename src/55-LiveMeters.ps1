#region LIVE METERS
# CPU i RAM barovi u statusu sustava osvježavaju se uživo (tajmer, svake 2 s): u retku se zamjenjuje samo tekst bara, uz očuvan položaj skrolanja i
# odabir. Opterećenje procesora računa se iz razlike dvaju očitanja GetSystemTimes (ne ovisi o jeziku Windowsa).
function Set-LiveRow {
    param([string]$Label, [double]$Percent, [string]$Status, [string]$Text)
    $row = $script:LiveRows[$Label]
    if ($null -eq $row) { return }
    $rtb = $script:UI.Status
    $pct = [Math]::Min(100.0, [Math]::Max(0.0, $Percent))
    $filled = [int][Math]::Round($pct / 100 * 16)
    $bar = (([string][char]0x2588) * $filled) + (([string][char]0x2591) * (16 - $filled)) + ' ' + ('{0,3:N0} %' -f $pct)
    if ($bar.Length -ne $row.Length) { return }
    # Prepisivanje retka uzrokuje treptanje panela: radi se samo kad se prikaz stvarno promijenio (postotak ili boja), a ne pri svakom otkucaju tajmera.
    $signature = $bar + '|' + $Status
    if ($row.Signature -ceq $signature) {
        $row.Item.Percent = $pct
        $row.Item.Value   = $Text
        $row.Item.Status  = $Status
        return
    }
    $row.Signature = $signature
    $selStart = $rtb.SelectionStart
    $selLen   = $rtb.SelectionLength
    $firstLine = 0
    try { $firstLine = [Auxilium.NativeMethods]::GetFirstVisibleLine($rtb.Handle) } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> }
    [Auxilium.NativeMethods]::SetRedraw($rtb.Handle, $false)
    try {
        $rtb.Select($row.Start, $row.Length)
        $rtb.SelectedText = $bar
        $rtb.Select($row.Start, $row.Length)
        $rtb.SelectionColor = (Get-StatusColor $Status)
        $rtb.Select($selStart, $selLen)
        try { [Auxilium.NativeMethods]::ScrollToFirstVisibleLine($rtb.Handle, $firstLine) } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> }
    } finally {
        [Auxilium.NativeMethods]::SetRedraw($rtb.Handle, $true)
    }
    # Ponovno se iscrtava samo pojas retka s barom, ne cijela kolona.
    try {
        $pt = $rtb.GetPositionFromCharIndex($row.Start)
        $rtb.Invalidate((New-Object System.Drawing.Rectangle(0, [Math]::Max(0, $pt.Y - 4), $rtb.ClientSize.Width, 32)))
    } catch { $rtb.Invalidate() }
    # Stavke u $script:SysInfo su iste kao prikazane: PDF izvještaj tako dobiva najnovije vrijednosti.
    $row.Item.Percent = $pct
    $row.Item.Value   = $Text
    $row.Item.Status  = $Status
}

function Update-LiveMeters {
    $rtb = $script:UI.Status
    if ($null -eq $rtb -or $rtb.IsDisposed -or -not $rtb.IsHandleCreated -or $script:Closing) { return }
    $cpuPct = $null
    try {
        $idle = [uint64]0
        $total = [uint64]0
        if ([Auxilium.NativeMethods]::GetCpuTimes([ref]$idle, [ref]$total)) {
            $prev = $script:CpuPrev
            if ($null -ne $prev -and $total -gt $prev.Total) {
                $cpuPct = 100.0 * (1.0 - (([double]($idle - $prev.Idle)) / [double]($total - $prev.Total)))
            }
            $script:CpuPrev = @{ Idle = $idle; Total = $total }
        }
    } catch { Write-AppLog 'Debug' 'Update-LiveMeters: CPU' $_ }
    if ($script:LiveRows.Count -eq 0) { return }
    if ($null -ne $cpuPct) {
        $st = 'Good'
        if ($cpuPct -ge 90) { $st = 'Bad' } elseif ($cpuPct -ge 70) { $st = 'Warn' }
        Set-LiveRow 'CPU' $cpuPct $st ('{0:N0} % opterećenje' -f $cpuPct)
    }
    $mem = -1
    try { $mem = [int][Auxilium.NativeMethods]::GetMemoryLoad() } catch { Write-AppLog 'Debug' 'Update-LiveMeters: RAM' $_ }
    if ($mem -ge 0) {
        $st = 'Good'
        if ($mem -ge 90) { $st = 'Bad' } elseif ($mem -ge 80) { $st = 'Warn' }
        Set-LiveRow 'RAM' $mem $st ('{0:N0} % zauzeto' -f $mem)
    }
}
#endregion LIVE METERS

