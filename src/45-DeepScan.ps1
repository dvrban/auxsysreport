#region DEEP SCAN
# Neinstalirana ažuriranja (Windows Update API) i dnevnici događaja za zadnjih 7 dana prikupljaju se u ZASEBNOM PowerShell procesu:
# može se prekinuti (Kill), ima vremensko ograničenje i ne drži sučelje. Rezultat dolazi kao JSON preko standardnog izlaza;
# svaki redak je KUMULATIVNI popis stavki (dnevnici se ispisuju prvi, pa još jednom zajedno s ažuriranjima), pa se pri isteku
# vremena (npr. zapela pretraga Windows Updatea) i dalje koristi ono što je do tada stiglo.
function Get-DeepScanScript {
    $source = @'
#<<DEEP_SCAN>>#
'@
    # Skraćivanje (uvlake i prazni retci) da naredba ostane daleko ispod granice od 32 767 znakova.
    $lines = foreach ($line in ($source -split "`r?`n")) {
        $trimmed = $line.TrimStart()
        if ($trimmed.Length -gt 0) { $trimmed }
    }
    return ($lines -join "`n")
}

function New-RawReader {
    param([System.IO.Stream]$Stream)
    $reader = @{
        Stream = $Stream
        Buffer = New-Object 'byte[]' 8192
        Ms     = New-Object System.IO.MemoryStream
        Task   = $null
        Eof    = $false
    }
    $reader.Task = $Stream.ReadAsync($reader.Buffer, 0, $reader.Buffer.Length)
    return $reader
}

function Remove-DeepTempFile {
    $d = $script:Deep
    if ($d.TempFile) {
        try { [System.IO.File]::Delete([string]$d.TempFile) } catch { }
        $d.TempFile = $null
    }
}

function Stop-DeepScan {
    $d = $script:Deep
    if ($null -ne $d.Process) {
        try { if (-not $d.Process.HasExited) { $d.Process.Kill() } } catch { }
        try { $d.Process.Dispose() } catch { }
    }
    $d.Process = $null
    $d.Readers = @()
    Remove-DeepTempFile
    if ($d.State -eq 'Running') { $d.State = 'Cancelled' }
    if ($null -ne $script:UI.DeepTimer) { try { $script:UI.DeepTimer.Stop() } catch { } }
}

function Start-DeepScan {
    param([string]$ScriptText = '')

    Stop-DeepScan
    $d = $script:Deep
    $d.Items = @()
    $d.Error = ''
    try {
        if ([string]::IsNullOrEmpty($ScriptText)) { $ScriptText = Get-DeepScanScript }
        # Skripta je preduga za -EncodedCommand (granica 32 767 znakova): izvodi se iz privremene datoteke koja se briše nakon završetka.
        $psArgs = $null
        try {
            $tempScript = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('Auxilium_scan_{0}.ps1' -f [guid]::NewGuid().ToString('N')))
            [System.IO.File]::WriteAllText($tempScript, $ScriptText, (New-Object System.Text.UTF8Encoding($true)))
            $d.TempFile = $tempScript
            $psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $tempScript
        } catch {
            $writeError = $_.Exception.Message
            $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptText))
            if ($encoded.Length -gt 30000) { throw ('Privremena skripta nije mogla biti zapisana ({0}), a prevelika je za izravno izvođenje.' -f $writeError) }
            $psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = Resolve-SystemTool 'WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments              = $psArgs
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.WorkingDirectory       = $env:SystemRoot
        # Pozadinski proces čita podatke o Outlooku/programima iz registra PRIJAVLJENOG korisnika (ne administratora koji je pokrenuo alat).
        $consoleUser = [string](Get-ConsoleUser)
        if (-not [string]::IsNullOrWhiteSpace($consoleUser)) { $psi.EnvironmentVariables['AUX_CONSOLE_USER'] = $consoleUser }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $d.Process = $proc
        $d.Readers = @((New-RawReader $proc.StandardOutput.BaseStream), (New-RawReader $proc.StandardError.BaseStream))
        $d.Watch   = [System.Diagnostics.Stopwatch]::StartNew()
        $d.State   = 'Running'
        if ($null -ne $script:UI.DeepTimer) { $script:UI.DeepTimer.Start() }
    } catch {
        $d.State = 'Failed'
        $d.Error = $_.Exception.Message
    }
}

# Stavke prikupljene u pozadini + status (učitavanje / greška) za prikaz u panelu i PDF-u.
function Get-CombinedInfoItems {
    $combined = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($script:SysInfo)) { $combined.Add($item) }
    if ($combined.Count -eq 0) { return $combined }

    $d = $script:Deep
    $title = 'SOFTVER, UPDATE I DNEVNICI (7 DANA)'
    if ($d.State -eq 'Done') {
        foreach ($item in @($d.Items)) { $combined.Add($item) }
    } elseif ($d.State -eq 'Running') {
        $combined.Add((New-InfoItem 'Section' '' $title))
        $combined.Add((New-InfoItem 'Text' '' 'Učitavanje u pozadini (do dvije minute)...' 'Muted'))
    } elseif ($d.State -eq 'Failed' -or $d.State -eq 'Timeout' -or $d.State -eq 'Cancelled') {
        $combined.Add((New-InfoItem 'Section' '' $title))
        $reason = [string]$d.Error
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'prikupljanje je prekinuto' }
        $combined.Add((New-InfoItem 'Text' '' ('Nije dostupno: ' + $reason) 'Warn'))
    }
    return $combined
}

function Update-StatusPanel {
    $rtb = $script:UI.Status
    if ($null -eq $rtb -or $rtb.IsDisposed) { return }
    if (@($script:SysInfo).Count -eq 0) { return }
    Show-SystemInfo @(Get-CombinedInfoItems) -KeepScroll
}

# Čita sve što je pozadinski proces dosad ispisao.
function Read-DeepOutput {
    $d = $script:Deep
    foreach ($reader in @($d.Readers)) {
        while (-not $reader.Eof -and $null -ne $reader.Task -and $reader.Task.IsCompleted) {
            $count = 0
            if (-not $reader.Task.IsFaulted -and -not $reader.Task.IsCanceled) { $count = [int]$reader.Task.Result }
            if ($count -gt 0) {
                $reader.Ms.Write($reader.Buffer, 0, $count)
                $reader.Task = $reader.Stream.ReadAsync($reader.Buffer, 0, $reader.Buffer.Length)
            } else {
                $reader.Eof  = $true
                $reader.Task = $null
            }
        }
    }
}

# Izlaz pozadinskog procesa -> stavke. Vrijedi ZADNJI potpuni redak (kumulativni popis); nepoznate vrste stavki se odbacuju.
function ConvertFrom-DeepBytes {
    param([byte[]]$Bytes, [switch]$Killed)
    $text  = [System.Text.Encoding]::UTF8.GetString($Bytes)
    $lines = @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
    # Nakon nasilnog prekida zadnji redak može biti napola ispisan: odbacuje se ako nije završen novim retkom.
    if ($Killed -and -not $text.EndsWith("`n") -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    if ($lines.Count -eq 0) { throw 'nema potpunog retka s podacima' }
    # PowerShell 5.1 vraća JSON polje kao jedan objekt: ForEach-Object ga raspakira u pojedinačne stavke.
    $parsed = @($lines[$lines.Count - 1] | ConvertFrom-Json | ForEach-Object { $_ })
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $parsed) {
        $kind = [string]$entry.Kind
        if (@('Section', 'KV', 'Text') -notcontains $kind) { continue }
        $status = [string]$entry.Status
        if ([string]::IsNullOrWhiteSpace($status)) { $status = 'Normal' }
        $list.Add((New-InfoItem $kind ([string]$entry.Label) ([string]$entry.Value) $status))
    }
    if ($list.Count -eq 0) { throw 'prazan odgovor' }
    # Bez "," ispred: poziv se omata u @(...) pa bi povratno polje inače postalo polje unutar polja (ugniježđene stavke).
    return $list.ToArray()
}

# Razlog neuspjeha iz standardne pogreške pozadinskog procesa (blokiran skriptom, parse greška...). Putanje i korisničko ime se zamjenjuju
# oznakama jer poruka može završiti u izvještaju za klijenta.
function Get-DeepStderrHint {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    $text = ConvertFrom-ConsoleBytes $Bytes
    if ($text -match '^\s*#< CLIXML') { return '' }
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($ln in ($text -split "`r?`n")) {
        $s = $ln.Trim()
        if (-not $s) { continue }
        if ($s -match '^(At |\+ |Windows PowerShell|Copyright|Install the latest|Try the new)') { continue }
        $keep.Add($s)
    }
    $hint = (($keep.ToArray()) -join ' ')
    $hint = $hint.Replace([System.IO.Path]::GetTempPath(), '%TEMP%\')
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) { $hint = $hint.Replace($env:USERPROFILE, '%USERPROFILE%') }
    $hint = ($hint -replace '\s+', ' ').Trim()
    if ($hint.Length -gt 200) { $hint = $hint.Substring(0, 199) + '...' }
    if ($hint -match '(?i)malicious|virus|blocked|AppLocker|group policy') { $hint += ' (moguće blokirano sigurnosnim programom)' }
    return $hint
}

function Complete-DeepScan {
    $d = $script:Deep
    $bytes = @()
    if (@($d.Readers).Count -gt 0) { $bytes = $d.Readers[0].Ms.ToArray() }
    $errBytes = @()
    if (@($d.Readers).Count -gt 1) { $errBytes = $d.Readers[1].Ms.ToArray() }
    $exitCode = -1
    try { $exitCode = $d.Process.ExitCode } catch { }
    try { $d.Process.Dispose() } catch { }
    $d.Process = $null
    $d.Readers = @()
    Remove-DeepTempFile

    # Bez JSON-a na izlazu (i s pogreškom pri izlasku): skript je blokiran ili se nije mogao pokrenuti, pa se razlog traži u stderr-u.
    $noJson = $true
    if ($bytes.Length -gt 0) {
        $firstChar = [char]$bytes[0]
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $firstChar = '[' }
        if ($firstChar -eq '[' -or $firstChar -eq '{') { $noJson = $false } elseif ($exitCode -eq 0) { $noJson = $false }
    }
    if ($bytes.Length -eq 0 -or ($noJson -and $exitCode -ne 0)) {
        $d.State = 'Failed'
        $d.Error = ('pozadinski proces nije vratio podatke ili je blokiran (kod izlaza {0})' -f $exitCode)
        $hint = ''
        try { $hint = Get-DeepStderrHint $errBytes } catch { $hint = '' }
        if ($hint) { $d.Error += ': ' + $hint }
    } else {
        try {
            $d.Items = @(ConvertFrom-DeepBytes $bytes)
            $d.State = 'Done'
        } catch {
            $d.State = 'Failed'
            $d.Error = ('neispravan odgovor pozadinskog procesa: {0}' -f $_.Exception.Message)
        }
    }
    if ($null -ne $script:UI.DeepTimer) { try { $script:UI.DeepTimer.Stop() } catch { } }

    $message = 'Softver (Office, mail), ažuriranja na čekanju i dnevnici događaja (7 dana) su učitani.'
    $level   = 'Ok'
    if ($d.State -ne 'Done') {
        $message = 'Softver, ažuriranja i dnevnici nisu učitani: ' + $d.Error
        $level = 'Warn'
    }
    Update-StatusPanel
    Write-Terminal $message $level
}

# Istek vremena: proces se prekida, ali ono što je već stiglo (npr. dnevnici događaja dok je pretraga Windows Updatea zapela) se zadržava.
function Stop-DeepScanTimeout {
    param([string]$Why)
    $d = $script:Deep
    $partial = @()
    try {
        Read-DeepOutput
        if (@($d.Readers).Count -gt 0) { $partial = $d.Readers[0].Ms.ToArray() }
    } catch { }
    Stop-DeepScan

    $got = @()
    if ($partial.Length -gt 0) { try { $got = @(ConvertFrom-DeepBytes $partial -Killed) } catch { $got = @() } }
    if ($got.Count -gt 0) {
        # Pozadinski skript sam označava nedovršene skupine (softver / Windows Update) napomenom "nije dovršeno u zadanom roku",
        # pa roditelj ne pogađa uzrok i ne umeće vlastite oznake.
        $d.Items = $got
        $d.State = 'Done'
        $d.Error = ''
        Update-StatusPanel
        Write-Terminal 'Prikupljanje je isteklo: dio podataka nedostaje (vidi napomene u panelu i izvještaju).' 'Warn'
    } else {
        $d.State = 'Timeout'
        $d.Error = $Why
        Update-StatusPanel
        Write-Terminal ('Ažuriranja i dnevnici nisu učitani: ' + $Why) 'Warn'
    }
}

# Poziva ga tajmer sučelja (ili Wait-DeepScan): čita izlaz pozadinskog procesa i prati istek vremena.
function Update-DeepScan {
    $d = $script:Deep
    if ($d.State -ne 'Running') {
        if ($null -ne $script:UI.DeepTimer) { try { $script:UI.DeepTimer.Stop() } catch { } }
        return
    }
    try {
        Read-DeepOutput
        $allEof = (@($d.Readers | Where-Object { -not $_.Eof }).Count -eq 0)
        if ($allEof -and $d.Process.WaitForExit(0)) {
            Complete-DeepScan
            return
        }
        if ($d.Watch.Elapsed.TotalSeconds -gt $d.TimeoutSec) {
            Stop-DeepScanTimeout -Why ('isteklo vrijeme ({0} s)' -f $d.TimeoutSec)
        }
    } catch {
        Write-AppLog 'Error' 'Duboko skeniranje (Update-DeepScan)' $_
        Stop-DeepScan
        $d.State = 'Failed'
        $d.Error = $_.Exception.Message
        Update-StatusPanel
    }
}

# Čeka završetak pozadinskog prikupljanja uz pumpanje sučelja; prekid zadatka ne ubija prikupljanje.
function Wait-DeepScan {
    param([int]$TimeoutSeconds = 120)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($script:Deep.State -eq 'Running') {
        if (Test-StopRequested) { return $false }
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            Stop-DeepScanTimeout -Why ('isteklo vrijeme ({0} s)' -f $TimeoutSeconds)
            return ($script:Deep.State -eq 'Done')
        }
        Update-DeepScan
        Update-Ui
        Start-Sleep -Milliseconds 100
    }
    return ($script:Deep.State -eq 'Done')
}
#endregion DEEP SCAN


