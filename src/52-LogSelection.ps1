#region LOG SELECTION
# T3.6: odabir dnevnika događaja koji se izvoze u TXT i potom brišu (Invoke-EventLogClearTask). Čista logika je zasebno (Pester); dijalog je sloj iznad nje.
# Zadano su označeni svi dnevnici sa zapisima (kao dosad), odnosno oni iz prethodnog odabira u ovoj sesiji ($script:LogClearSelection; $null = svi).

# Nazivi dnevnika koji će biti označeni na početku.
function Get-DefaultLogSelection {
    param($Plan, $Previous = $null)
    $all = @($Plan | ForEach-Object { [string]$_.Name })
    if ($null -eq $Previous) { return $all }
    $kept = @($all | Where-Object { @($Previous) -contains $_ })
    if ($kept.Count -eq 0) { return $all }   # raniji odabir više ne vrijedi (dnevnici su nestali ili prazni): ne počinje se bez ičega
    return $kept
}

# Dio plana koji odgovara odabranim nazivima.
function Select-LogPlanByName {
    param($Plan, [string[]]$Names)
    return @($Plan | Where-Object { @($Names) -contains [string]$_.Name })
}

function Get-LogSelectionSummary {
    param($Plan, [string[]]$Names)
    $chosen = @(Select-LogPlanByName $Plan $Names)
    $records = [int64]0
    $bytes = [int64]0
    foreach ($p in $chosen) { $records += [int64]$p.Records; $bytes += [int64]$p.SizeBytes }
    return ('Odabrano: {0} od {1} dnevnika, {2} zapisa, {3}' -f $chosen.Count, @($Plan).Count, ('{0:N0}' -f $records), (Format-Bytes ([double]$bytes)))
}

# Nazivi koje označava gumb "Samo System i Application".
function Get-CoreLogNames {
    param($Plan)
    return @($Plan | ForEach-Object { [string]$_.Name } | Where-Object { @('System', 'Application') -contains $_ })
}

function Get-CheckedLogNames {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($item in $script:LogDlg.List.Items) { if ($item.Checked) { $names.Add([string]$item.Text) } }
    return $names.ToArray()
}

function Update-LogSelectionSummary {
    $names = @(Get-CheckedLogNames)
    $script:LogDlg.Summary.Text = Get-LogSelectionSummary $script:LogDlg.Plan $names
    $script:LogDlg.Ok.Enabled = ($names.Count -gt 0)
}

function Set-LogChecks {
    param([string[]]$Names)
    $list = $script:LogDlg.List
    $list.BeginUpdate()
    try { foreach ($item in $list.Items) { $item.Checked = (@($Names) -contains [string]$item.Text) } } finally { $list.EndUpdate() }
    Update-LogSelectionSummary
}

# Modalni dijalog s popisom dnevnika (kvačice). Vraća polje odabranih naziva ili $null ako je korisnik odustao. Iznimka se NE guta: radnja je razorna pa se pri
# kvaru dijaloga ne smije nastaviti sa "svim dnevnicima" (Start-GuiTask ispisuje grešku, a ništa nije izvezeno ni obrisano).
function Show-LogSelectionDialog {
    param($Plan, [string[]]$Initial)
    $c = $script:Colors
    $f = $script:Fonts
    $form = New-Object System.Windows.Forms.Form
    $script:LogDlg = @{ Form = $form; Plan = @($Plan); List = $null; Summary = $null; Ok = $null }
    try {
        $form.Text            = 'Odabir dnevnika događaja'
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox     = $false
        $form.MinimizeBox     = $false
        $form.ShowInTaskbar   = $false
        $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterParent
        $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)   # isto kao glavni prozor (T3.4)
        $form.AutoScaleMode       = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.ClientSize      = New-Object System.Drawing.Size(640, 530)
        $form.BackColor       = $c.Form
        $form.ForeColor       = $c.Text
        $form.Font            = $f.Ui
        $form.KeyPreview      = $true

        $info = New-Object System.Windows.Forms.Label
        $info.Location  = New-Object System.Drawing.Point(16, 12)
        $info.Size      = New-Object System.Drawing.Size(608, 48)
        $info.ForeColor = $c.Muted
        $info.Text      = 'Označeni dnevnici izvest će se u TXT, a zatim OBRISATI (nepovratno, Security zadnji). Neoznačeni ostaju netaknuti. Završna potvrda slijedi nakon odabira.'

        $list = New-Object System.Windows.Forms.ListView
        $list.Location      = New-Object System.Drawing.Point(16, 66)
        $list.Size          = New-Object System.Drawing.Size(608, 330)
        $list.View          = [System.Windows.Forms.View]::Details
        $list.CheckBoxes    = $true
        $list.FullRowSelect = $true
        $list.HideSelection = $false
        $list.BorderStyle   = [System.Windows.Forms.BorderStyle]::FixedSingle
        $list.BackColor     = $c.Data
        $list.ForeColor     = $c.Text
        [void]$list.Columns.Add('Dnevnik', 100)
        $colRecords = $list.Columns.Add('Zapisa', 60)
        $colRecords.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
        $colSize = $list.Columns.Add('Veličina', 60)
        $colSize.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
        foreach ($p in ($Plan | Sort-Object -Property Name)) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$p.Name)
            [void]$item.SubItems.Add(('{0:N0}' -f [int64]$p.Records))
            [void]$item.SubItems.Add((Format-Bytes ([double]$p.SizeBytes)))
            $item.Checked = (@($Initial) -contains [string]$p.Name)
            [void]$list.Items.Add($item)
        }

        $summary = New-Object System.Windows.Forms.Label
        $summary.Location  = New-Object System.Drawing.Point(16, 404)
        $summary.Size      = New-Object System.Drawing.Size(608, 22)
        $summary.ForeColor = $c.Yellow

        $btnAll  = New-FlatButton 'Odaberi sve'
        $btnNone = New-FlatButton 'Poništi sve'
        $btnCore = New-FlatButton 'Samo System i Application'
        $btnOk     = New-FlatButton 'Izvezi i obriši odabrano' 'Danger'
        $btnCancel = New-FlatButton 'Odustani'
        $place = { param($Button, [int]$X, [int]$Y, [int]$W, [int]$H) $Button.Dock = 'None'; $Button.Location = New-Object System.Drawing.Point($X, $Y); $Button.Size = New-Object System.Drawing.Size($W, $H) }
        & $place $btnAll  16 436 120 34
        & $place $btnNone 142 436 120 34
        & $place $btnCore 268 436 200 34
        & $place $btnOk     324 482 190 36
        & $place $btnCancel 524 482 100 36

        $script:LogDlg.List = $list
        $script:LogDlg.Summary = $summary
        $script:LogDlg.Ok = $btnOk

        $list.Add_ItemChecked({ try { Update-LogSelectionSummary } catch { Write-AppLog 'Debug' 'Dijalog dnevnika: sažetak' $_ } })
        $btnAll.Add_Click({ Set-LogChecks @($script:LogDlg.Plan | ForEach-Object { [string]$_.Name }) })
        $btnNone.Add_Click({ Set-LogChecks @() })
        $btnCore.Add_Click({ Set-LogChecks (Get-CoreLogNames $script:LogDlg.Plan) })
        $btnOk.Add_Click({ $script:LogDlg.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK })
        $btnCancel.Add_Click({ $script:LogDlg.Form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel })
        $form.Add_KeyDown({ if ($args[1].KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $script:LogDlg.Form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel } })
        $form.Add_Shown({
            # Širine stupaca iz stvarne širine popisa (u pikselima uređaja): ne ovisi o skaliranju zaslona.
            try {
                $l = $script:LogDlg.List
                $w = $l.ClientSize.Width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
                $l.Columns[0].Width = [int]($w * 0.58)
                $l.Columns[1].Width = [int]($w * 0.20)
                $l.Columns[2].Width = [int]($w * 0.22)
            } catch { Write-AppLog 'Debug' 'Dijalog dnevnika: širine stupaca' $_ }
            try { [Auxilium.NativeMethods]::TryEnableDarkTitleBar($script:LogDlg.Form.Handle) } catch { Write-AppLog 'Debug' 'Dijalog dnevnika: tamna naslovna traka' $_ }
        })

        foreach ($ctl in @($info, $list, $summary, $btnAll, $btnNone, $btnCore, $btnOk, $btnCancel)) { $form.Controls.Add($ctl) }
        Update-LogSelectionSummary

        $result = $form.ShowDialog($script:UI.Form)
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return ,@(Get-CheckedLogNames)
    } finally {
        $form.Dispose()
        $script:LogDlg = $null
    }
}
#endregion LOG SELECTION

