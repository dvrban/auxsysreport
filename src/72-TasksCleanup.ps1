#region TASKS - CISCENJE
function ConvertTo-ExtendedPath {
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return ('\\?\UNC\' + $Path.Substring(2)) }
    return ('\\?\' + $Path)
}

function Remove-DirectoryTree {
    param([System.IO.DirectoryInfo]$Directory, $Result)

    try { $entries = $Directory.GetFileSystemInfos() } catch { $Result.Skipped++; return }

    foreach ($entry in $entries) {
        if (Test-StopRequested) { return }
        try {
            $isDir  = (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            $isLink = (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

            if ($isDir -and -not $isLink) {
                $skippedBefore = $Result.Skipped
                Remove-DirectoryTree -Directory $entry -Result $Result
                $keepKey = $entry.FullName
                if ($keepKey.StartsWith('\\?\')) { $keepKey = $keepKey.Substring(4) }
                if ($script:KeepDirs -and $script:KeepDirs.ContainsKey($keepKey.TrimEnd('\').ToLowerInvariant())) { continue }
                try {
                    if (($entry.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { $entry.Attributes = [System.IO.FileAttributes]::Directory }
                    $entry.Delete()
                    $Result.Folders++
                } catch {
                    # Mapa se nije mogla obrisati: broji se samo ako unutra nije već preskočena neka stavka.
                    if ($Result.Skipped -eq $skippedBefore) { $Result.Skipped++ }
                }
            } elseif ($isDir) {
                # Junction / simbolička veza: briše se samo veza, nikad sadržaj cilja.
                $entry.Delete()
                $Result.Folders++
            } else {
                $length = 0
                try { $length = $entry.Length } catch { <# namjerno: veličina datoteke nedostupna: računa se kao 0 #> }
                if ($entry.IsReadOnly) { $entry.IsReadOnly = $false }
                $entry.Delete()
                $Result.Files++
                $Result.Bytes += $length
            }
        } catch {
            $Result.Skipped++
        }
        Update-Ui
    }
}

function Remove-FolderContent {
    param([AllowNull()][AllowEmptyString()][string]$Path)

    $result = [pscustomobject]@{ Path = $Path; Files = 0; Folders = 0; Bytes = [long]0; Skipped = 0; Refused = $false; Reason = '' }
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $result.Refused = $true; $result.Reason = 'putanja nije zadana'; return $result
        }
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $result.Path = $full
        $leaf = [System.IO.Path]::GetFileName($full)
        $root = [System.IO.Path]::GetPathRoot($full)

        if ([string]::IsNullOrWhiteSpace($leaf) -or ($full + '\') -eq $root) {
            $result.Refused = $true; $result.Reason = 'korijen diska nije dopušten'; return $result
        }
        if ($leaf -notin @('Temp', 'Tmp', 'Download')) {
            $result.Refused = $true; $result.Reason = 'neočekivana lokacija (dopušteno: Temp, Tmp, Download)'; return $result
        }
        if (-not [System.IO.Directory]::Exists($full)) {
            $result.Refused = $true; $result.Reason = 'mapa ne postoji'; return $result
        }
        # Prošireni put (\\?\) omogućuje brisanje stavki dužih od MAX_PATH i imena koja završavaju točkom ili razmakom.
        $dir = New-Object System.IO.DirectoryInfo((ConvertTo-ExtendedPath $full))
        if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $result.Refused = $true; $result.Reason = 'mapa je simbolička veza / junction'; return $result
        }

        Remove-DirectoryTree -Directory $dir -Result $result
    } catch {
        $result.Refused = $true
        $result.Reason  = $_.Exception.Message
    }
    return $result
}

function Write-CleanupResult {
    param($Result, [string]$Label)
    if ($Result.Refused) {
        Write-Terminal ('  {0}: preskočeno - {1}' -f $Label, $Result.Reason) 'Warn'
        return
    }
    $level = 'Ok'
    if ($Result.Skipped -gt 0) { $level = 'Info' }
    Write-Terminal ('  {0}: obrisano {1} datoteka, {2} mapa, oslobođeno {3}; nije obrisano (u upotrebi/zaštićeno): {4}' -f `
        $Label, $Result.Files, $Result.Folders, (Format-Bytes ([double]$Result.Bytes)), $Result.Skipped) $level
}

function Get-TempFolderTargets {
    $targets    = New-Object System.Collections.Generic.List[string]
    $seen       = @{}
    $candidates = @($env:TEMP, [System.IO.Path]::GetTempPath(), (Join-Path $env:LOCALAPPDATA 'Temp'), (Join-Path $env:SystemRoot 'Temp'))
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try { $normalized = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\') } catch { continue }
        $key = $normalized.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $targets.Add($normalized) }
    }

    # Cilj koji leži unutar drugog cilja (npr. Temp\2 pod RDP-om) preskače se: roditelj ga ionako prazni.
    $final = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $targets) {
        $leaf  = [System.IO.Path]::GetFileName($candidate)
        $under = $false
        if (@('Temp', 'Tmp', 'Download') -notcontains $leaf) {
            foreach ($other in $targets) {
                if ($other -ne $candidate -and $candidate.StartsWith($other + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $under = $true; break }
            }
        }
        if (-not $under) { $final.Add($candidate) }
    }
    return $final
}

# Korak 1: korisnički i sistemski TEMP. Vraća broj obrisanih bajtova.
function Clear-TempFolders {
    $freed = [double]0

    # Aktivni TEMP/TMP ove sesije se prazni, ali se sama mapa ne briše (npr. Temp\2 pod RDP-om).
    $script:KeepDirs = @{}
    foreach ($active in @($env:TEMP, $env:TMP, [System.IO.Path]::GetTempPath())) {
        if ([string]::IsNullOrWhiteSpace($active)) { continue }
        try { $script:KeepDirs[[System.IO.Path]::GetFullPath($active).TrimEnd('\').ToLowerInvariant()] = $true } catch { <# namjerno: neispravna putanja se ne dodaje među zaštićene mape #> }
    }
    try {
        foreach ($target in @(Get-TempFolderTargets)) {
            if (Test-StopRequested) { break }
            if (-not (Test-Path -LiteralPath $target)) { continue }
            $res = Remove-FolderContent -Path $target
            Write-CleanupResult $res $target
            $freed += [double]$res.Bytes
        }
    } finally {
        $script:KeepDirs = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP) -and -not (Test-Path -LiteralPath $env:TEMP)) {
        try { [void](New-Item -ItemType Directory -Path $env:TEMP -Force) } catch { Write-AppLog 'Debug' 'Clear-TempFolders: ponovno stvaranje TEMP-a' $_ }
    }
    return $freed
}

# Čeka stanje servisa uz pumpanje sučelja (ograničeno vrijeme, može se prekinuti).
function Wait-ServiceUi {
    param($Service, [string]$Target, [int]$Seconds = 30, [bool]$HonorCancel = $true)
    $until = (Get-Date).AddSeconds($Seconds)
    do {
        $Service.Refresh()
        if (([string]$Service.Status) -eq $Target) { return $true }
        Update-Ui
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $until -and -not ($HonorCancel -and (Test-StopRequested)))
    $Service.Refresh()
    return (([string]$Service.Status) -eq $Target)
}

# Korak 2: zaustavi wuauserv, očisti SoftwareDistribution\Download, ponovno pokreni wuauserv. Vraća broj obrisanih bajtova.
function Clear-UpdateCache {
    $freed       = [double]0
    $serviceName = 'wuauserv'
    $service     = $null
    try {
        $service = Get-Service -Name $serviceName -ErrorAction Stop
    } catch {
        Write-Terminal ('  Servis {0} nije pronađen: {1}' -f $serviceName, $_.Exception.Message) 'Warn'
        return $freed
    }

    $stopped = $false
    try {
        try {
            $service.Refresh()
            if (@('Stopped', 'StopPending') -notcontains ([string]$service.Status)) {
                Write-Terminal '  Zaustavljam servis Windows Update (wuauserv)...' 'Info'
                Stop-Service -Name $serviceName -Force -NoWait -ErrorAction Stop
            }
            $stopped = Wait-ServiceUi -Service $service -Target 'Stopped' -Seconds 30 -HonorCancel $true
        } catch {
            Write-Terminal ('  Servis se nije mogao zaustaviti: {0}' -f $_.Exception.Message) 'Warn'
        }

        if ($stopped) {
            Write-Terminal '  Servis je zaustavljen.' 'Ok'
            $download = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
            if (Test-Path -LiteralPath $download) {
                $res = Remove-FolderContent -Path $download
                Write-CleanupResult $res $download
                $freed += [double]$res.Bytes
            } else {
                Write-Terminal '  Mapa SoftwareDistribution\Download ne postoji.' 'Info'
            }
        } else {
            Write-Terminal '  Predmemorija nije očišćena jer se servis nije zaustavio.' 'Warn'
        }
    } finally {
        # Servis se uvijek vraća u rad, čak i ako je došlo do greške ili prekida.
        try {
            $svc = Get-Service -Name $serviceName -ErrorAction Stop
            $startType = ''
            try { $startType = [string]$svc.StartType } catch { <# namjerno: tip pokretanja servisa nije dostupan #> }
            if ($startType -eq 'Disabled') {
                Write-Terminal '  Servis wuauserv je onemogućen (Disabled) - ostaje zaustavljen.' 'Warn'
            } else {
                if (([string]$svc.Status) -eq 'StopPending') {
                    Write-Terminal '  Čekam da se servis wuauserv zaustavi radi ponovnog pokretanja (prekid se primjenjuje nakon toga)...' 'Info'
                    [void](Wait-ServiceUi -Service $svc -Target 'Stopped' -Seconds 30 -HonorCancel $false)
                }
                $svc.Refresh()
                $state = [string]$svc.Status
                if ($state -eq 'StopPending') {
                    Write-Terminal '  Servis wuauserv se i dalje zaustavlja; ponovno pokretanje je preskočeno. Pokrenite ga ručno ako zatreba.' 'Warn'
                } else {
                    if ($state -eq 'Stopped') {
                        try {
                            $svc.Start()
                        } catch {
                            # Servis je mogao biti pokrenut izvana (npr. greška 1056); bitno je stvarno stanje, ne oblik iznimke.
                            $svc.Refresh()
                            if (@('Running', 'StartPending') -notcontains ([string]$svc.Status)) { throw }
                        }
                    }
                    if (Wait-ServiceUi -Service $svc -Target 'Running' -Seconds 30 -HonorCancel $false) {
                        Write-Terminal '  Servis Windows Update (wuauserv) je ponovno pokrenut.' 'Ok'
                    } else {
                        Write-Terminal '  Servis wuauserv nije prešao u stanje Running u roku od 30 s.' 'Warn'
                    }
                }
            }
        } catch {
            Write-Terminal ('  Servis wuauserv nije bilo moguće ponovno pokrenuti: {0}' -f $_.Exception.Message) 'Error'
        }
    }
    return $freed
}

# Korak 3: prazni koš za smeće (Shell API, bez dijaloga; pražnjenje ide na zasebnoj STA niti da sučelje ostane živo).
function Clear-RecycleBinContent {
    try {
        $binSize  = [long]0
        $binItems = [long]0
        $hr = [Auxilium.NativeMethods]::QueryRecycleBin([ref]$binSize, [ref]$binItems)
        if ($hr -eq 0 -and $binItems -eq 0) {
            Write-Terminal '  Koš za smeće je već prazan.' 'Info'
            return
        }
        if ($hr -eq 0) {
            Write-Terminal ('  Stavki u košu: {0}, ukupna veličina: {1}' -f $binItems, (Format-Bytes ([double]$binSize))) 'Info'
        }
        $task = [Auxilium.NativeMethods]::EmptyRecycleBinAsync()
        while (-not $task.IsCompleted -and -not $script:Closing) {
            Update-Ui
            Start-Sleep -Milliseconds 50
        }
        if (-not $task.IsCompleted) { return }
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
        $hr = [int]$task.Result
        if ($hr -eq 0) {
            Write-Terminal '  Koš za smeće je ispražnjen.' 'Ok'
        } else {
            Write-Terminal ('  Pražnjenje koša nije uspjelo (HRESULT 0x{0:X8}).' -f $hr) 'Warn'
        }
    } catch {
        Write-Terminal ('  Koš za smeće: {0}' -f $_.Exception.Message) 'Warn'
    }
}

function Invoke-CleanupTask {
    $systemDrive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($systemDrive)) { $systemDrive = 'C:' }
    $driveInfo  = New-Object System.IO.DriveInfo(($systemDrive + '\'))
    $freeBefore = [double]$driveInfo.AvailableFreeSpace
    $totalFreed = [double]0
    $touched    = $false
    $rescan     = $false

    try {
        Write-Terminal '1/4  Brisanje privremenih datoteka (korisnički i sistemski TEMP)...' 'Info'
        $touched = $true
        $totalFreed += [double](Clear-TempFolders)
        if (Test-StopRequested) { return }

        # Korak 2 zaustavlja wuauserv, a pozadinsko skeniranje u isto vrijeme traži ažuriranja preko Windows Update API-ja: sačekati ga (najviše 30 s).
        if ($script:Deep.State -eq 'Running') {
            Write-Terminal '  Čekam završetak pozadinskog skeniranja prije zaustavljanja Windows Update servisa...' 'Info'
            [void](Wait-DeepScan 30)
            if (Test-StopRequested) { return }
        }
        # Skeniranje koje nije završilo uspješno (greška, istek bez podataka) ponavlja se nakon čišćenja da odjeljak Ažuriranja ne ostane prazan.
        $rescan = ($script:Deep.State -ne 'Done')
        Write-Terminal '2/4  Windows Update predmemorija (wuauserv + SoftwareDistribution\Download)...' 'Info'
        $totalFreed += [double](Clear-UpdateCache)
        if (Test-StopRequested) { return }

        Write-Terminal '3/4  Pražnjenje koša za smeće...' 'Info'
        Clear-RecycleBinContent

        Write-Terminal '4/4  Sažetak...' 'Info'
        $freeAfter = [double]$driveInfo.AvailableFreeSpace
        Write-Terminal ('  Obrisano datoteka ukupno: {0}' -f (Format-Bytes $totalFreed)) 'Ok'
        Write-Terminal ('  Slobodno na {0} prije: {1}, poslije: {2}' -f $systemDrive, (Format-Bytes $freeBefore), (Format-Bytes $freeAfter)) 'Ok'
    } finally {
        # Status se osvježava i nakon prekida/greške jer su datoteke možda već obrisane.
        if ($touched -and -not $script:Closing) {
            try { Update-SystemStatus -IgnoreCancel -SkipDeep:(-not $rescan) } catch { Write-Terminal ('Osvježavanje statusa nije uspjelo: {0}' -f $_.Exception.Message) 'Warn' }
        }
    }
}
#endregion TASKS - CISCENJE

