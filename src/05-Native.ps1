#region NATIVE
if (-not ('Auxilium.NativeMethods' -as [type])) {
    # Prevođenje C# (csc.exe) u Windows PowerShellu 5.1 ne podnosi TEMP putanju sa znakovima izvan ANSI stranice sustava (npr. profil "Đuro"
    # na sustavu s kodnom stranicom 1252): tada se TEMP/TMP samo za ovaj proces privremeno usmjeravaju na ASCII mapu (vraćaju se nakon prevođenja).
    $nativeTemp = $env:TEMP
    $nativeTmp  = $env:TMP
    try {
        $ansi = [System.Text.Encoding]::Default
        $tempSafe = $true
        foreach ($tempPath in @([System.IO.Path]::GetTempPath(), $env:TEMP, $env:TMP)) {
            if (-not [string]::IsNullOrEmpty($tempPath) -and ($ansi.GetString($ansi.GetBytes($tempPath)) -cne $tempPath)) { $tempSafe = $false }
        }
        if (-not $tempSafe) {
            # Redoslijed je bitan: C:\Windows\Temp neprivilegirani korisnik može pisati, ali csc.exe tamo ne pronalazi izvornu datoteku.
            foreach ($candidate in @($env:PUBLIC, $env:ProgramData, (Join-Path $env:SystemRoot 'Temp'))) {
                try {
                    if ([string]::IsNullOrEmpty($candidate) -or -not [System.IO.Directory]::Exists($candidate)) { continue }
                    if ($ansi.GetString($ansi.GetBytes($candidate)) -cne $candidate) { continue }
                    $probe = [System.IO.Path]::Combine($candidate, ('.aux-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 8)))
                    [System.IO.File]::WriteAllText($probe, 'x')
                    [System.IO.File]::Delete($probe)
                    $env:TEMP = $candidate
                    $env:TMP  = $candidate
                    break
                } catch { }
            }
        }
    } catch { }
    try {
    Add-Type -ErrorAction Stop -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
#<<NATIVE_CS>>#
'@
    } catch {
        # Povišeni proces radi sakriven: bez ove poruke bi neuspjeh prevođenja (npr. antivirus blokira csc.exe) prošao nezamijećeno.
        try {
            [void][System.Windows.Forms.MessageBox]::Show(
                ('Došlo je do fatalne greške:' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message),
                'Auxilium Informatika',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
        } catch { }
        exit 1
    } finally {
        $env:TEMP = $nativeTemp
        $env:TMP  = $nativeTmp
    }
}
#endregion NATIVE

