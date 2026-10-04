#region LIVE PROCESS
function ConvertFrom-ConsoleBytes {
    param([byte[]]$Bytes)
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($Bytes)
    } catch { }
    try {
        $oem = [System.Text.Encoding]::GetEncoding([int][Auxilium.NativeMethods]::GetOEMCP())
        return $oem.GetString($Bytes)
    } catch {
        return [System.Text.Encoding]::Default.GetString($Bytes)
    }
}

function New-OutputReader {
    param([System.IO.Stream]$Stream)
    $reader = @{
        Stream  = $Stream
        Buffer  = New-Object 'byte[]' 8192
        Task    = $null
        Pending = New-Object 'System.Collections.Generic.List[byte]'
        Mode    = $null
        Text    = ''
        Done    = $false
    }
    $reader.Task = $Stream.ReadAsync($reader.Buffer, 0, $reader.Buffer.Length)
    return $reader
}

function Write-ProcessLine {
    param([string]$Line)

    $text = ($Line -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '').TrimEnd()
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $script:LastProcessOutput.Add($text)

    # Retci koji sadrže samo postotak napretka (SFC, DISM...) pokreću traku napretka i ispisuju se rijetko.
    if ($text -match '^\D*(\d{1,3})(?:[.,]\d+)?\s*%\D*$') {
        $pct = [Math]::Min(100, [int]$Matches[1])
        Set-ProgressMode 'Value' $pct
        $bucket = [int][Math]::Floor($pct / 10)
        if ($bucket -eq $script:LastPctBucket) { return }
        $script:LastPctBucket = $bucket
    }
    [void]$script:LineBatch.Add('  ' + $text)
}

# Ispisuje nakupljene retke jednim pozivom (ScrollToCaret po retku bi jako usporio velik izlaz).
function Send-ProcessBatch {
    if ($script:LineBatch.Count -gt 0) {
        $block = $script:LineBatch -join "`r`n"
        $script:LineBatch.Clear()
        Write-Terminal $block 'Normal'
    }
}

function Write-ProcessText {
    param($Reader, [switch]$Flush)

    $idx = [Math]::Max($Reader.Text.LastIndexOf("`n"), $Reader.Text.LastIndexOf("`r"))
    $complete = ''
    if ($Flush) {
        $complete = $Reader.Text
        $Reader.Text = ''
    } elseif ($idx -ge 0) {
        $complete = $Reader.Text.Substring(0, $idx + 1)
        $Reader.Text = $Reader.Text.Substring($idx + 1)
    }
    if ($complete.Length -gt 0) {
        foreach ($line in ($complete -split '[\r\n]+')) { Write-ProcessLine $line }
        Send-ProcessBatch
    }
}

# Prepoznaje kodiranje izlaza: UTF-16LE (SFC) ima BOM ili NUL bajtove, a 8-bitni tekst konzole nikad ne sadrži NUL.
function Set-OutputReaderMode {
    param($Reader)
    $pending = $Reader.Pending
    if ($pending.Count -ge 2 -and [int]$pending[0] -eq 255 -and [int]$pending[1] -eq 254) {
        $pending.RemoveRange(0, 2)
        $Reader.Mode = 'Utf16'
        return
    }
    $Reader.Mode = 'Byte'
    foreach ($value in $pending) {
        if ($value -eq 0) { $Reader.Mode = 'Utf16'; break }
    }
}

# Dekodira izlaz procesa: SFC piše UTF-16LE, ostali alati UTF-8 ili OEM kodnu stranicu.
function Receive-OutputChunk {
    param($Reader, [int]$Count)

    $chunk = New-Object 'byte[]' $Count
    [System.Array]::Copy($Reader.Buffer, 0, $chunk, 0, $Count)
    $Reader.Pending.AddRange($chunk)

    if ($null -eq $Reader.Mode -and $Reader.Pending.Count -ge 4) { Set-OutputReaderMode $Reader }
    if ($null -eq $Reader.Mode) { return }

    if ($Reader.Mode -eq 'Utf16') {
        $even = $Reader.Pending.Count - ($Reader.Pending.Count % 2)
        if ($even -gt 0) {
            $bytes = $Reader.Pending.GetRange(0, $even).ToArray()
            $Reader.Pending.RemoveRange(0, $even)
            $Reader.Text += [System.Text.Encoding]::Unicode.GetString($bytes)
        }
    } else {
        $last = -1
        for ($i = $Reader.Pending.Count - 1; $i -ge 0; $i--) {
            $value = [int]$Reader.Pending[$i]
            if ($value -eq 10 -or $value -eq 13) { $last = $i; break }
        }
        if ($last -ge 0) {
            $bytes = $Reader.Pending.GetRange(0, $last + 1).ToArray()
            $Reader.Pending.RemoveRange(0, $last + 1)
            $Reader.Text += (ConvertFrom-ConsoleBytes $bytes)
        }
    }
    Write-ProcessText $Reader
}

function Complete-OutputReader {
    param($Reader)
    if ($Reader.Pending.Count -gt 0) {
        if ($null -eq $Reader.Mode) { Set-OutputReaderMode $Reader }
        $bytes = $Reader.Pending.ToArray()
        $Reader.Pending.Clear()
        if ($Reader.Mode -eq 'Utf16') {
            $even = $bytes.Length - ($bytes.Length % 2)
            if ($even -gt 0) { $Reader.Text += [System.Text.Encoding]::Unicode.GetString($bytes, 0, $even) }
        } else {
            $Reader.Text += (ConvertFrom-ConsoleBytes $bytes)
        }
    }
    Write-ProcessText $Reader -Flush
}

# Pokreće vanjski alat i uživo prosljeđuje izlaz u terminal, bez blokiranja sučelja.
function Invoke-LiveProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = ''
    )

    $script:LastPctBucket     = -1
    $script:LastProcessOutput = New-Object System.Collections.Generic.List[string]
    $script:LineBatch.Clear()

    if (-not (Test-Path -LiteralPath $FilePath)) { throw ('Alat nije pronađen: {0}' -f $FilePath) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.WorkingDirectory       = $env:SystemRoot

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $exitCode = -1
    $readers  = @()

    try {
        Write-Terminal ('> {0} {1}' -f [System.IO.Path]::GetFileName($FilePath), $Arguments) 'Info'
        [void]$proc.Start()
        $script:CurrentProcess = $proc
        $readers = @(
            (New-OutputReader $proc.StandardOutput.BaseStream),
            (New-OutputReader $proc.StandardError.BaseStream)
        )
        Set-ProgressMode 'Marquee'

        while ($true) {
            $active = $false
            $gotData = $false
            foreach ($reader in $readers) {
                if ($reader.Done) { continue }
                $active = $true
                if ($reader.Task.IsCompleted) {
                    $count = 0
                    if (-not $reader.Task.IsFaulted -and -not $reader.Task.IsCanceled) { $count = [int]$reader.Task.Result }
                    if ($count -gt 0) {
                        $gotData = $true
                        Receive-OutputChunk $reader $count
                        $reader.Task = $reader.Stream.ReadAsync($reader.Buffer, 0, $reader.Buffer.Length)
                    } else {
                        Complete-OutputReader $reader
                        $reader.Done = $true
                    }
                }
            }
            if (-not $active) { break }
            if (Test-StopRequested) {
                try { $proc.Kill() } catch { }
                Write-Terminal 'Proces je prekinut na zahtjev korisnika.' 'Warn'
                break
            }
            Update-Ui
            if (-not $gotData) { Start-Sleep -Milliseconds 20 }
        }

        while (-not $proc.WaitForExit(100)) {
            if (Test-StopRequested) {
                try { $proc.Kill() } catch { }
                # do 2 s čekanja na kraj procesa, ali uz pumpanje poruka (sučelje se ne smije zamrznuti)
                $killWait = [System.Diagnostics.Stopwatch]::StartNew()
                while (-not $proc.WaitForExit(100) -and $killWait.ElapsedMilliseconds -lt 2000) { Update-Ui }
                break
            }
            Update-Ui
        }
        if ($proc.HasExited) { $exitCode = $proc.ExitCode }
    } finally {
        $script:CurrentProcess = $null
        try { Send-ProcessBatch } catch { }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        try { $proc.Dispose() } catch { }
    }
    return $exitCode
}
#endregion LIVE PROCESS

