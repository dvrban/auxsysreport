#region TERMINAL / PROGRESS
function Write-Terminal {
    param(
        [AllowEmptyString()][string]$Text = '',
        [ValidateSet('Normal', 'Header', 'Info', 'Ok', 'Warn', 'Error')][string]$Level = 'Normal'
    )
    if ($Level -eq 'Warn' -or $Level -eq 'Error') { Write-AppLog $Level $Text }   # upozorenja i greške ostaju i nakon zatvaranja alata
    try {
        $rtb = $script:UI.Terminal
        if ($null -ne $rtb -and -not $rtb.IsDisposed) {
            $c = $script:Colors
            $color = $c.TermText
            if ($Level -eq 'Error') { $script:TaskHadError = $true }
            if     ($Level -eq 'Header') { $color = $c.TermHeader }
            elseif ($Level -eq 'Ok')     { $color = $c.TermOk }
            elseif ($Level -eq 'Warn')   { $color = $c.TermWarn }
            elseif ($Level -eq 'Error')  { $color = $c.TermError }

            $line = $Text
            if ($Level -ne 'Normal') { $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text }

            if ($rtb.TextLength -gt 1500000) {
                # Ograničenje veličine: RichTextBox je ReadOnly pa se zaštita privremeno skida; reže se na kraju retka.
                $rtb.ReadOnly = $false
                try {
                    $newline = $rtb.Text.IndexOf("`n", 400000)
                    $cut = 400000
                    if ($newline -ge 0) { $cut = $newline + 1 }
                    $rtb.Select(0, $cut)
                    $rtb.SelectedText = ''
                    $rtb.ClearUndo()
                } finally {
                    $rtb.ReadOnly = $true
                }
            }
            $rtb.SelectionStart  = $rtb.TextLength
            $rtb.SelectionLength = 0
            $rtb.SelectionColor  = $color
            $rtb.AppendText($line + "`r`n")
            $rtb.SelectionColor  = $c.TermText
            $rtb.SelectionStart  = $rtb.TextLength
            $rtb.ScrollToCaret()
        }
    } catch { Write-AppLog 'Debug' 'Write-Terminal: ispis u terminal' $_ }
    Update-Ui
}

function Write-Banner {
    param([string]$Title)
    Write-Terminal '' 'Normal'
    Write-Terminal ('=' * 66) 'Normal'
    Write-Terminal ('>>> ' + $Title) 'Header'
    Write-Terminal ('=' * 66) 'Normal'
}

function Set-ProgressMode {
    param(
        [ValidateSet('Idle', 'Marquee', 'Value', 'Done', 'Error')][string]$Mode,
        [int]$Percent = 0
    )
    $track = $script:UI.ProgressTrack
    $fill  = $script:UI.ProgressFill
    $timer = $script:UI.ProgressTimer
    if ($null -eq $track -or $null -eq $fill -or $null -eq $timer) { return }
    $c     = $script:Colors
    $reset = $script:UI.ProgressResetTimer
    if ($null -ne $reset) { $reset.Stop() }

    # Jantarna dok zadatak traje, zelena kad je gotov, crvena kod greške (Done / Error se nakratko zadržavaju, pa traka nestaje).
    $script:ProgressMode = $Mode
    if ($Mode -eq 'Idle') {
        $timer.Stop()
        $fill.Left  = 0
        $fill.Width = 0
    } elseif ($Mode -eq 'Marquee') {
        $fill.BackColor = $c.Yellow
        if (-not $timer.Enabled) {
            $fill.Width = [int]($track.Width * 0.2)
            $fill.Left  = 0
            $timer.Start()
        }
    } elseif ($Mode -eq 'Value') {
        $timer.Stop()
        $fill.BackColor = $c.Yellow
        $pct = [Math]::Min(100, [Math]::Max(0, $Percent))
        $fill.Left  = 0
        $fill.Width = [int]($track.Width * $pct / 100)
    } else {
        $timer.Stop()
        if ($Mode -eq 'Error') { $fill.BackColor = $c.Red } else { $fill.BackColor = $c.Progress }
        $fill.Left  = 0
        $fill.Width = $track.Width
        if ($null -ne $reset) { $reset.Start() }
    }
}

function Set-BusyState {
    param([bool]$Busy)
    $script:Busy = $Busy
    try {
        foreach ($button in $script:UI.ActionButtons) { $button.Enabled = (-not $Busy) }
        foreach ($control in $script:UI.ClientControls) { $control.Enabled = (-not $Busy) }
        $script:UI.BtnCancel.Enabled = $Busy
        $script:UI.Form.UseWaitCursor = $Busy
        $script:UI.BtnCancel.UseWaitCursor = $false
        if ($Busy) {
            Set-ProgressMode 'Marquee'
        } elseif ($script:CancelRequested -or $script:Closing -or $script:TaskNoResult) {
            Set-ProgressMode 'Idle'
        } elseif ($script:TaskHadError) {
            Set-ProgressMode 'Error'
        } else {
            Set-ProgressMode 'Done'
        }
        if (-not $Busy -and $script:FocusCompanyBox) {
            $script:FocusCompanyBox = $false
            try { [void]$script:UI.CompanyBox.Focus() } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> }
        }
    } catch { Write-AppLog 'Debug' 'Set-BusyState' $_ }
}

function Stop-CurrentProcess {
    $proc = $script:CurrentProcess
    if ($null -ne $proc) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { <# namjerno: proces je možda već završio #> }
    }
}

function Start-GuiTask {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Command,
        [string]$ConfirmMessage = ''
    )
    if ($script:Busy) { return }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $started   = $false
    try {
        if (-not [string]::IsNullOrEmpty($ConfirmMessage)) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $script:UI.Form, $ConfirmMessage, $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Terminal 'Radnja je otkazana od strane korisnika.' 'Warn'
                return
            }
        }

        $script:CancelRequested = $false
        $script:TaskHadError    = $false
        $script:TaskNoResult    = $false
        Set-BusyState $true
        $started = $true
        Write-Banner $Title
        & $Command
        if ($script:CancelRequested) { Write-Terminal 'Zadatak je prekinut.' 'Warn' }
    } catch {
        Write-AppLog 'Debug' ('Zadatak ''{0}'': {1}' -f $Title, ([string]$_.ScriptStackTrace -split "`r?`n")[0])
        Write-Terminal ('GREŠKA: {0}' -f $_.Exception.Message) 'Error'
    } finally {
        if ($started) {
            $stopwatch.Stop()
            Write-Terminal ('Gotovo. Trajanje: {0}' -f (Format-Duration $stopwatch.Elapsed)) 'Info'
            Set-BusyState $false
        }
    }
}
#endregion TERMINAL / PROGRESS

