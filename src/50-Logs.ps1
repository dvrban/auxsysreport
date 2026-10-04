#region LOGS
# Izvoz svih Windows dnevnika događaja u TXT (uz izvještaj), pa brisanje svakog dnevnika TEK NAKON što je njegov izvoz uspješno zapisan i provjeren.
# $script:LogClearSelection: $null = svi dnevnici koji imaju zapise. Izbornik za odabir dnevnika dodaje se kasnije: dovoljno je postaviti popis
# naziva dnevnika (npr. @('System', 'Application')), a ostatak zadatka (izvoz, provjera, brisanje, popis) se ne mijenja.
# Popis svih Windows dnevnika događaja (Get-WinEvent -ListLog * traje 0,6-0,7 s, a na sporom disku i duže). Izvodi se u pozadinskom runspaceu (T2.3), pa ne smije
# koristiti $script: ni kontrole; vraća samo osnovne podatke (naziv, broj zapisa, veličina).
function Get-LogChannelInfo {
    foreach ($log in @(Get-WinEvent -ListLog * -ErrorAction SilentlyContinue)) {
        [pscustomobject]@{ LogName = [string]$log.LogName; RecordCount = $log.RecordCount; FileSize = $log.FileSize }
    }
}

# Plan izvoza: dnevnici koji imaju zapise. Popis se prikuplja u pozadini uz pumpanje sučelja; prekid daje prazan plan (pozivatelj provjerava Test-StopRequested),
# a istek vremena je greška (ne smije izgledati kao "nema dnevnika").
function Get-LogChannelPlan {
    param($Selection = $null, [int]$TimeoutSeconds = 60)
    $run = Invoke-BackgroundRunspace -Functions @('Get-LogChannelInfo') -Command 'Get-LogChannelInfo' -TimeoutSeconds $TimeoutSeconds
    if ($run.State -eq 'Cancelled') { return @() }
    if ($run.State -eq 'TimedOut') { throw ('Popis dnevnika događaja nije dobiven u {0} s (Windows Event Log ne odgovara).' -f $TimeoutSeconds) }
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($log in (@($run.Output) | Where-Object { $null -ne $_ } | Sort-Object -Property LogName)) {
        $records = 0
        if ($null -ne $log.RecordCount) { $records = [int64]$log.RecordCount }
        if ($records -le 0) { continue }
        $name = [string]$log.LogName
        $selected = $true
        if ($null -ne $Selection) { $selected = (@($Selection) -contains $name) }
        $plan.Add([pscustomobject]@{
            Name = $name; Records = $records; SizeBytes = [int64]$log.FileSize; Selected = $selected
            FileName = ''; Exported = $false; Events = 0; Bytes = 0; Cleared = $false; Note = ''
        })
    }
    return $plan.ToArray()
}

# Jedan dnevnik -> TXT (UTF-8 s BOM-om). wevtutil se pokreće s /uni:true (UTF-16), jer bi inače hrvatski znakovi bili izgubljeni (OEM kodna stranica);
# izlaz se tokom pretvara u UTF-8. Broj događaja određuje se iz zadnjeg retka "Event[N]". Vraća @{ Ok; Events; Bytes; Error }.
function Export-EventLogChannel {
    param([Parameter(Mandatory)][string]$Channel, [Parameter(Mandatory)][string]$Path)
    $result = [pscustomobject]@{ Ok = $false; Events = 0; Bytes = 0; Error = '' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = Resolve-SystemTool 'wevtutil.exe'
    $psi.Arguments              = ('qe "{0}" /f:text /uni:true' -f $Channel)
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $proc   = $null
    $writer = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $stream  = $proc.StandardOutput.BaseStream
        $writer  = New-Object System.IO.StreamWriter($Path, $false, (New-Object System.Text.UTF8Encoding($true)))
        $decoder = [System.Text.Encoding]::Unicode.GetDecoder()
        $buffer  = New-Object 'byte[]' 65536
        $chars   = New-Object 'char[]' 65537
        $first   = $true
        $tail    = ''
        $maxIndex = -1
        while ($true) {
            $read = $stream.ReadAsync($buffer, 0, $buffer.Length)
            while (-not $read.IsCompleted) {
                if (Test-StopRequested) {
                    try { $proc.Kill() } catch { <# namjerno: proces je možda već završio #> }
                    $result.Error = 'prekinuto'
                    return $result
                }
                Update-Ui
                Start-Sleep -Milliseconds 10
            }
            $count = $read.Result
            if ($count -le 0) { break }
            $offset = 0
            if ($first) {
                $first = $false
                if ($count -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) { $offset = 2 }
            }
            $len = $decoder.GetChars($buffer, $offset, ($count - $offset), $chars, 0)
            if ($len -gt 0) {
                $writer.Write($chars, 0, $len)
                $text = $tail + [string]::new($chars, 0, $len)
                foreach ($m in [regex]::Matches($text, '(?m)^Event\[(\d+)\]')) {
                    $idx = [int]$m.Groups[1].Value
                    if ($idx -gt $maxIndex) { $maxIndex = $idx }
                }
                if ($text.Length -gt 24) { $tail = $text.Substring($text.Length - 24) } else { $tail = $text }
            }
        }
        $writer.Flush()
        $writer.Dispose()
        $writer = $null
        while (-not $proc.HasExited) { Update-Ui; Start-Sleep -Milliseconds 10 }
        $errText = ''
        try { $errText = ([string]$errTask.Result).Trim() } catch { <# namjerno: tekst pogreške procesa nije obavezan #> }
        $result.Events = $maxIndex + 1
        $result.Bytes  = ([System.IO.FileInfo]$Path).Length
        if ($proc.ExitCode -ne 0) {
            $result.Error = 'wevtutil: ' + $(if ($errText) { $errText } else { 'izlazni kod ' + $proc.ExitCode })
        } elseif ($result.Bytes -le 3) {
            $result.Error = 'izvezena datoteka je prazna'
        } else {
            $result.Ok = $true
        }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($null -ne $writer) { try { $writer.Dispose() } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> } }
        if ($null -ne $proc) { try { $proc.Dispose() } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> } }
    }
    return $result
}

# Briše jedan dnevnik (wevtutil cl). Odvojena funkcija da se u testovima može zamijeniti (testovi nikad ne brišu prave dnevnike).
function Clear-EventLogChannel {
    param([Parameter(Mandatory)][string]$Channel)
    $result = [pscustomobject]@{ Ok = $false; Error = '' }
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = Resolve-SystemTool 'wevtutil.exe'
        $psi.Arguments              = ('cl "{0}"' -f $Channel)
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            if ($watch.Elapsed.TotalSeconds -gt 90) { try { $proc.Kill() } catch { <# namjerno: proces je možda već završio #> }; $result.Error = 'isteklo vrijeme'; return $result }
            Update-Ui
            Start-Sleep -Milliseconds 10
        }
        $errText = ''
        try { $errText = ([string]$errTask.Result).Trim() } catch { <# namjerno: tekst pogreške procesa nije obavezan #> }
        if ($proc.ExitCode -eq 0) { $result.Ok = $true } else { $result.Error = $(if ($errText) { $errText } else { 'izlazni kod ' + $proc.ExitCode }) }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($null -ne $proc) { try { $proc.Dispose() } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> } }
    }
    return $result
}

function Write-LogManifest {
    param([string]$Path, $Plan, [string]$Stage)
    $nl = [Environment]::NewLine
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('Auxilium Informatika - izvoz dnevnika događaja')
    [void]$sb.AppendLine(('Računalo : {0}' -f $env:COMPUTERNAME))
    [void]$sb.AppendLine(('Korisnik : {0}' -f (Get-ReportUserName)))
    [void]$sb.AppendLine(('Datum    : {0}' -f (Get-Date).ToString('dd.MM.yyyy. HH:mm:ss')))
    [void]$sb.AppendLine(('Verzija  : {0}' -f $script:AppVersion))
    [void]$sb.AppendLine(('Stanje   : {0}' -f $Stage))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Dnevnik | zapisa prije izvoza | izvezeno događaja | datoteka | veličina | brisanje')
    foreach ($e in @($Plan)) {
        if (-not $e.Selected) { continue }
        $cleared = 'nije obrisan'
        if ($e.Cleared) { $cleared = 'obrisan' }
        $size = ''
        if ($e.Exported) { $size = Format-Bytes ([double]$e.Bytes) }
        $note = ''
        if ($e.Note) { $note = '  [' + $e.Note + ']' }
        [void]$sb.AppendLine(('{0} | {1} | {2} | {3} | {4} | {5}{6}' -f $e.Name, $e.Records, $e.Events, $e.FileName, $size, $cleared, $note))
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

function Invoke-EventLogClearTask {
    if (-not $script:IsAdmin) {
        Write-Terminal 'Brisanje dnevnika događaja traži administratorska prava (alat nije pokrenut kao administrator).' 'Error'
        return
    }
    if ($null -ne $script:UI.CompanyBox) { Set-ActiveCompany $script:UI.CompanyBox.Text }
    $company       = Get-ActiveCompany
    $folderCompany = $company
    if ([string]::IsNullOrWhiteSpace($company)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:UI.Form,
            ('Tvrtka / klijent nije postavljena (polje na vrhu prozora).' + [Environment]::NewLine + [Environment]::NewLine +
             'Želite li dnevnike izvesti u mapu "Nerazvrstano"?' + [Environment]::NewLine +
             '(Ne = povratak na unos tvrtke.)'),
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Terminal 'Izvoz i brisanje dnevnika je otkazano: upišite tvrtku / klijenta u polje na vrhu.' 'Warn'
            $script:FocusCompanyBox = $true
            $script:TaskNoResult    = $true
            return
        }
        $folderCompany = 'Nerazvrstano'
    }

    Write-Terminal '  Popis dnevnika događaja koji imaju zapise...' 'Info'
    $plan = @(Get-LogChannelPlan -Selection $script:LogClearSelection | Where-Object { $_.Selected })
    if (Test-StopRequested) { return }
    if ($plan.Count -eq 0) {
        Write-Terminal 'Nema dnevnika događaja sa zapisima (ili nijedan nije odabran).' 'Warn'
        $script:TaskNoResult = $true
        return
    }
    $totalRecords = [int64](($plan | Measure-Object -Property Records -Sum).Sum)
    $totalBytes   = [int64](($plan | Measure-Object -Property SizeBytes -Sum).Sum)

    $folder   = Get-CompanyFolder $folderCompany
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension((Get-ReportFileName)) + '_dnevnici'
    $dir      = [System.IO.Path]::Combine($folder, $baseName)
    $suffix   = 2
    while (Test-Path -LiteralPath $dir) {
        $dir = [System.IO.Path]::Combine($folder, ('{0}_{1}' -f $baseName, $suffix))
        $suffix++
    }
    $room = 258 - ($dir.Length + 1) - 4
    if ($room -lt 20) {
        throw ('Putanja mape za dnevnike je preduga ({0} znakova): {1}. Skratite naziv tvrtke ili pokrenite alat s mjesta bliže korijenu pogona.' -f $dir.Length, $dir)
    }
    $problem = Test-FolderWritable $folder
    if ($problem) {
        throw ('U mapu za izvještaje nije moguće pisati: {0} ({1}). Provjerite je li stick umetnut, nije li zaštićen od pisanja i postoji li pogon na kojem se nalazi mapa izvještaja.' -f $folder, $problem)
    }
    # Slobodan prostor: TXT je otprilike veličine samih dnevnika; traži se 30 % rezerve i 64 MB.
    $need = [int64]($totalBytes * 1.3) + 64MB
    $free = $null
    try {
        $root = [System.IO.Path]::GetPathRoot($dir)
        if (-not [string]::IsNullOrEmpty($root) -and -not $root.StartsWith('\\')) { $free = (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace }
    } catch { Write-AppLog 'Debug' 'Provjera slobodnog prostora za izvoz dnevnika' $_ }
    if ($null -ne $free -and $free -lt $need) {
        throw ('Na odredišnom pogonu nema dovoljno slobodnog prostora za izvoz dnevnika: potrebno oko {0}, slobodno {1}. Dnevnici nisu dirani.' -f (Format-Bytes ([double]$need)), (Format-Bytes ([double]$free)))
    }

    $estMinutes = [Math]::Max(1, [int][Math]::Ceiling($totalRecords / 1500.0 / 60.0))
    $question = ('Alat će:' + [Environment]::NewLine +
        ('1) izvesti u TXT sve Windows dnevnike događaja koji imaju zapise ({0} dnevnika, ukupno {1} zapisa) u mapu:' -f $plan.Count, $totalRecords) + [Environment]::NewLine +
        $dir + [Environment]::NewLine + [Environment]::NewLine +
        '2) tek nakon uspješno zapisanog i provjerenog izvoza svakog dnevnika taj dnevnik OBRISATI.' + [Environment]::NewLine + [Environment]::NewLine +
        'Brisanje je NEPOVRATNO (uključujući dnevnik Security) i uklanja tragove o događajima u sustavu; ostaju samo TXT datoteke. ' +
        ('Izvoz traje oko {0} min.' -f $estMinutes) + [Environment]::NewLine + [Environment]::NewLine + 'Želite li nastaviti?')
    $answer = [System.Windows.Forms.MessageBox]::Show($script:UI.Form, $question, $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Terminal 'Izvoz i brisanje dnevnika je otkazano od strane korisnika (ništa nije izvezeno ni obrisano).' 'Warn'
        $script:TaskNoResult = $true
        return
    }

    [void][System.IO.Directory]::CreateDirectory($dir)
    Write-Terminal ('Izvoz u mapu: {0}' -f $dir) 'Info'

    # --- 1. Izvoz ---
    $used = @{}
    $index = 0
    foreach ($entry in $plan) {
        $index++
        if (Test-StopRequested) { break }
        $safe = ConvertTo-SafeName (($entry.Name -replace '[\\/]', '_')) 'dnevnik' ([Math]::Min(120, $room))
        $fileName = $safe + '.txt'
        $k = 2
        while ($used.ContainsKey($fileName.ToLowerInvariant())) { $fileName = ('{0}_{1}.txt' -f $safe, $k); $k++ }
        $used[$fileName.ToLowerInvariant()] = $true
        $entry.FileName = $fileName
        Set-ProgressMode 'Value' ([int](70.0 * ($index - 1) / $plan.Count))
        Write-Terminal ('[{0}/{1}] {2}: {3} zapisa...' -f $index, $plan.Count, $entry.Name, $entry.Records) 'Normal'
        $r = Export-EventLogChannel -Channel $entry.Name -Path ([System.IO.Path]::Combine($dir, $fileName))
        $entry.Events = $r.Events
        $entry.Bytes  = $r.Bytes
        if (Test-StopRequested) { break }
        if (-not $r.Ok) {
            $entry.Note = 'izvoz nije uspio: ' + $r.Error
            Write-Terminal ('  NIJE izvezeno: {0}' -f $r.Error) 'Warn'
            continue
        }
        # Provjera: broj izvezenih događaja mora odgovarati broju zapisa (dopušteno je više, jer dnevnik raste dok traje izvoz).
        if ($r.Events -lt ($entry.Records - 5) -and $r.Events -lt [Math]::Floor($entry.Records * 0.98)) {
            $entry.Note = ('provjera nije prošla: izvezeno {0} od {1} događaja' -f $r.Events, $entry.Records)
            Write-Terminal ('  Provjera nije prošla (izvezeno {0} od {1} događaja): dnevnik se NEĆE brisati.' -f $r.Events, $entry.Records) 'Warn'
            continue
        }
        $entry.Exported = $true
        Write-Terminal ('  izvezeno {0} događaja, {1}' -f $r.Events, (Format-Bytes ([double]$r.Bytes))) 'Ok'
    }
    $manifest = [System.IO.Path]::Combine($dir, '00-POPIS.txt')
    if (Test-StopRequested) {
        try { Write-LogManifest -Path $manifest -Plan $plan -Stage 'izvoz prekinut - nijedan dnevnik nije obrisan' } catch { Write-AppLog 'Debug' 'Zapis popisa (00-POPIS.txt) dnevnika' $_ }
        Write-Terminal 'Zadatak je prekinut tijekom izvoza: NIJEDAN dnevnik nije obrisan. Dosad izvezene datoteke ostaju u mapi.' 'Warn'
        return
    }
    $exported = @($plan | Where-Object { $_.Exported })
    $failed   = @($plan | Where-Object { -not $_.Exported })
    try { Write-LogManifest -Path $manifest -Plan $plan -Stage 'izvoz završen, brisanje u tijeku' } catch { Write-Terminal ('Popis (00-POPIS.txt) nije zapisan: {0}' -f $_.Exception.Message) 'Warn' }
    Write-Terminal ('Izvoz je završen: {0} od {1} dnevnika izvezeno{2}.' -f $exported.Count, $plan.Count, $(if ($failed.Count -gt 0) { ', ' + $failed.Count + ' nije' } else { '' })) 'Ok'
    if ($exported.Count -eq 0) {
        Write-Terminal 'Nijedan dnevnik nije uspješno izvezen: ništa se ne briše.' 'Error'
        return
    }

    # --- 2. Brisanje (samo dnevnika čiji je izvoz uspio; Security zadnji) ---
    $ordered = @($exported | Where-Object { $_.Name -ne 'Security' }) + @($exported | Where-Object { $_.Name -eq 'Security' })
    $done = 0
    $clearFailed = 0
    foreach ($entry in $ordered) {
        if (Test-StopRequested) { break }
        $done++
        Set-ProgressMode 'Value' ([int](70.0 + 30.0 * ($done - 1) / $ordered.Count))
        $r = Clear-EventLogChannel -Channel $entry.Name
        if ($r.Ok) {
            $entry.Cleared = $true
        } else {
            $clearFailed++
            $entry.Note = 'brisanje nije uspjelo: ' + $r.Error
            Write-Terminal ('  [{0}/{1}] {2}: brisanje NIJE uspjelo ({3})' -f $done, $ordered.Count, $entry.Name, $r.Error) 'Warn'
        }
    }
    $cleared = @($plan | Where-Object { $_.Cleared }).Count
    try { Write-LogManifest -Path $manifest -Plan $plan -Stage 'završeno' } catch { Write-AppLog 'Debug' 'Zapis popisa (00-POPIS.txt) dnevnika' $_ }
    Set-ProgressMode 'Value' 100
    if (Test-StopRequested) {
        Write-Terminal ('Brisanje je prekinuto: obrisano {0} od {1} izvezenih dnevnika.' -f $cleared, $exported.Count) 'Warn'
    } else {
        Write-Terminal ('Obrisano je {0} dnevnika događaja; TXT kopije su u mapi: {1}' -f $cleared, $dir) 'Ok'
    }
    if ($clearFailed -gt 0) { Write-Terminal ('{0} dnevnika nije bilo moguće obrisati (vidi gore i 00-POPIS.txt).' -f $clearFailed) 'Warn' }
    if ($failed.Count -gt 0) { Write-Terminal ('{0} dnevnika nije obrisano jer izvoz nije uspio ili provjera nije prošla.' -f $failed.Count) 'Warn' }
    Write-Terminal 'Napomena: ocjena stanja (Stabilnost) računa se iz dnevnika zadnjih 7 dana, pa je nakon brisanja povoljnija. Pritisnite "Osvježi" za novi izračun.' 'Info'
}
#endregion LOGS

