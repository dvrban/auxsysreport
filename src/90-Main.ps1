#region MAIN
try {
    Initialize-Resources
    New-MainForm
    [void]$script:UI.Form.ShowDialog()
} catch {
    try {
        [void][System.Windows.Forms.MessageBox]::Show(
            ('Došlo je do fatalne greške:' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message),
            'Auxilium Informatika',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch { }
} finally {
    Remove-AppResources
    # Zapeti WMI upit u napuštenom runspaceu (foreground nit) inače bi držao skriveni powershell.exe živim: tada se proces završava silom.
    if ($script:AbandonedRunspace) { [System.Environment]::Exit(0) }
}
#endregion MAIN
