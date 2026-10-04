#region SYSTEM INFO
function New-InfoItem {
    param(
        [string]$Kind,
        [string]$Label = '',
        [string]$Value = '',
        [string]$Status = 'Normal',
        [double]$Percent = -1
    )
    return [pscustomobject]@{
        Kind    = $Kind
        Label   = $Label
        Value   = $Value
        Status  = $Status
        Percent = $Percent
        Height  = 0.0
        Y       = 0.0
    }
}

function Get-HealthLevel {
    param([string]$Health)
    if ($Health -eq 'Healthy') { return 'Good' }
    if ($Health -eq 'Unhealthy' -or $Health -eq 'Failed') { return 'Bad' }
    return 'Warn'
}

# Storage API vraća engleske nazive stanja; prevode se samo pri prikazu (boja se i dalje određuje iz izvorne vrijednosti).
function ConvertTo-HrHealth {
    param($Value, [switch]$Operational)
    if ($Operational) {
        $map = @{
            'OK' = 'U redu'; 'Degraded' = 'Smanjena izvedba'; 'Predictive Failure' = 'Predviđen kvar'; 'Lost Communication' = 'Izgubljena veza'
            'In Service' = 'U servisu'; 'Stressed' = 'Preopterećen'; 'No Contact' = 'Nema kontakta'
            'Other' = 'Ostalo'; 'Unknown' = 'Nepoznato'; 'Error' = 'Greška'; 'Non-Recoverable Error' = 'Nepopravljiva greška'
            'Starting' = 'Pokreće se'; 'Stopping' = 'Zaustavlja se'; 'Stopped' = 'Zaustavljeno'; 'Aborted' = 'Prekinuto'; 'Dormant' = 'Mirovanje'
            'Supporting Entity in Error' = 'Greška pomoćnog entiteta'; 'Completed' = 'Završeno'; 'Power Mode' = 'Način napajanja'; 'Relocating' = 'Premještanje'
            'Failed Media' = 'Kvar medija'; 'Split' = 'Podijeljeno'; 'Stale Metadata' = 'Zastarjeli metapodaci'; 'IO Error' = 'I/O greška'
            'Unrecognized Metadata' = 'Neprepoznati metapodaci'; 'Removing From Pool' = 'Uklanjanje iz skupa'; 'In Maintenance Mode' = 'Način održavanja'
            'Updating Firmware' = 'Ažuriranje firmwarea'; 'Device Hardware Error' = 'Greška hardvera uređaja'; 'Not Usable' = 'Neupotrebljivo'
            'Transient Error' = 'Privremena greška'; 'Starting Maintenance Mode' = 'Pokretanje načina održavanja'; 'Stopping Maintenance Mode' = 'Zaustavljanje načina održavanja'
            'Threshold Exceeded' = 'Prekoračen prag'; 'Abnormal Latency' = 'Povećana latencija'
        }
    } else {
        $map = @{ 'Healthy' = 'Ispravno'; 'Warning' = 'Upozorenje'; 'Unhealthy' = 'Neispravno'; 'Failed' = 'Kvar'; 'Unknown' = 'Nepoznato' }
    }
    $parts = foreach ($entry in @($Value)) {
        $text = [string]$entry
        if ($map.ContainsKey($text)) { $map[$text] } else { $text }
    }
    return (@($parts) -join ', ')
}

function Get-SystemInfoItems {
    # -Sink: popis koji pozivatelj može pročitati i ako prikupljanje istekne (djelomični rezultati); -ConsoleUser: prijavljeni korisnik (iz predmemorije roditelja).
    param([string]$ConsoleUser = '', $Sink = $null)
    $items = $Sink
    if ($null -eq $items) { $items = New-Object System.Collections.Generic.List[object] }
    $os    = $null

    # --- Operacijski sustav ---
    $items.Add((New-InfoItem 'Section' '' 'OPERACIJSKI SUSTAV'))
    try {
        $os = Get-CimInstance -OperationTimeoutSec 10 -ClassName Win32_OperatingSystem -ErrorAction Stop
        $items.Add((New-InfoItem 'KV' 'Naziv' ([string]$os.Caption).Trim()))

        $display = ''
        try {
            $display = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name DisplayVersion -ErrorAction Stop).DisplayVersion
        } catch { <# namjerno: ubačena funkcija (runspace): nema dnevnika; polje se izostavlja #> }
        $versionText = '{0} (build {1})' -f $os.Version, $os.BuildNumber
        if (-not [string]::IsNullOrWhiteSpace($display)) { $versionText = '{0} / {1}' -f $versionText, $display }
        $items.Add((New-InfoItem 'KV' 'Verzija' $versionText))
        $items.Add((New-InfoItem 'KV' 'Arhitektura' ([string]$os.OSArchitecture)))
        $items.Add((New-InfoItem 'KV' 'Računalo' $env:COMPUTERNAME))
        $runAs = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ([string]::IsNullOrWhiteSpace($ConsoleUser)) {
            $items.Add((New-InfoItem 'KV' 'Korisnik' $runAs))
        } else {
            $items.Add((New-InfoItem 'KV' 'Korisnik' $ConsoleUser))
            if ($ConsoleUser -ne $runAs) { $items.Add((New-InfoItem 'KV' 'Alat pokrenut kao' $runAs)) }
        }

        $uptime = (Get-Date) - $os.LastBootUpTime
        $items.Add((New-InfoItem 'KV' 'Radi već' ('{0} d {1} h {2} min' -f $uptime.Days, $uptime.Hours, $uptime.Minutes)))
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Podaci o OS-u nisu dostupni: ' + $_.Exception.Message) 'Warn'))
    }

    # --- Hardver ---
    $items.Add((New-InfoItem 'Section' '' 'PROCESSOR, MBO & RAM'))
    try {
        $cs = Get-CimInstance -OperationTimeoutSec 10 -ClassName Win32_ComputerSystem -ErrorAction Stop
        $model = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        $items.Add((New-InfoItem 'KV' 'Model' $model))
    } catch { <# namjerno: ubačena funkcija (runspace): nema dnevnika; polje se izostavlja #> }
    try {
        $board = Get-CimInstance -OperationTimeoutSec 10 -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        $boardText = ('{0} {1}' -f $board.Manufacturer, $board.Product).Trim()
        $items.Add((New-InfoItem 'KV' 'Matična ploča' $boardText))
    } catch {
        $items.Add((New-InfoItem 'KV' 'Matična ploča' 'nije dostupno' 'Warn'))
    }
    try {
        $cpus = @(Get-CimInstance -OperationTimeoutSec 10 -ClassName Win32_Processor -ErrorAction Stop)
        foreach ($cpu in $cpus) {
            $cpuName = ([string]$cpu.Name -replace '\s+', ' ').Trim()
            $items.Add((New-InfoItem 'KV' 'Procesor' $cpuName))
            $items.Add((New-InfoItem 'KV' 'Jezgre / niti' ('{0} / {1}' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)))
        }
    } catch {
        $items.Add((New-InfoItem 'KV' 'Procesor' 'nije dostupno' 'Warn'))
    }
    # Opterećenje procesora: prosjek kratkog mjerenja (400 ms); u prozoru se zatim osvježava uživo (Update-LiveMeters).
    try {
        $idle1 = [uint64]0; $total1 = [uint64]0; $idle2 = [uint64]0; $total2 = [uint64]0
        if ([Auxilium.NativeMethods]::GetCpuTimes([ref]$idle1, [ref]$total1)) {
            Start-Sleep -Milliseconds 400
            if ([Auxilium.NativeMethods]::GetCpuTimes([ref]$idle2, [ref]$total2) -and $total2 -gt $total1) {
                $cpuLoad = 100.0 * (1.0 - (([double]($idle2 - $idle1)) / [double]($total2 - $total1)))
                $cpuLoad = [Math]::Min(100.0, [Math]::Max(0.0, $cpuLoad))
                $cpuStatus = 'Good'
                if ($cpuLoad -ge 90) { $cpuStatus = 'Bad' } elseif ($cpuLoad -ge 70) { $cpuStatus = 'Warn' }
                $items.Add((New-InfoItem 'Bar' 'CPU' ('{0:N0} % opterećenje' -f $cpuLoad) $cpuStatus $cpuLoad))
            }
        }
    } catch { <# namjerno: ubačena funkcija (runspace): nema dnevnika; polje se izostavlja #> }
    if ($null -ne $os) {
        try {
            $totalBytes = [double]$os.TotalVisibleMemorySize * 1KB
            $freeBytes  = [double]$os.FreePhysicalMemory * 1KB
            $freePct    = 0
            if ($totalBytes -gt 0) { $freePct = $freeBytes / $totalBytes * 100 }
            $ramStatus = 'Good'
            if ($freePct -lt 10) { $ramStatus = 'Bad' } elseif ($freePct -lt 20) { $ramStatus = 'Warn' }
            $items.Add((New-InfoItem 'KV' 'RAM ukupno' (Format-Bytes $totalBytes)))
            $items.Add((New-InfoItem 'KV' 'RAM slobodno' ('{0} ({1:N0} %)' -f (Format-Bytes $freeBytes), $freePct) $ramStatus))
            $items.Add((New-InfoItem 'Bar' 'RAM' ('{0:N0} % zauzeto' -f (100 - $freePct)) $ramStatus (100 - $freePct)))
        } catch { <# namjerno: ubačena funkcija (runspace): nema dnevnika; polje se izostavlja #> }
    }

    # --- Grafička kartica (GPU) ---
    $items.Add((New-InfoItem 'Section' '' 'GRAFIČKA KARTICA (GPU)'))
    try {
        $gpus = @(Get-CimInstance -OperationTimeoutSec 10 -ClassName Win32_VideoController -ErrorAction Stop)
        if ($gpus.Count -eq 0) {
            $items.Add((New-InfoItem 'Text' '' 'Nije pronađena nijedna grafička kartica.' 'Warn'))
        }
        $gpuIndex = 0
        foreach ($gpu in $gpus) {
            $gpuIndex++
            $gpuName = ([string]$gpu.Name).Trim()
            $nameStatus = 'Normal'
            if ($gpuName -match 'Basic Display|Basic Render') { $nameStatus = 'Warn' }
            $items.Add((New-InfoItem 'KV' ('GPU ' + $gpuIndex) $gpuName $nameStatus))
            if ($nameStatus -eq 'Warn') {
                $items.Add((New-InfoItem 'KV' '  Napomena' 'instaliran je osnovni Windows driver - nedostaje driver proizvođača' 'Warn'))
            }

            $driverText = [string]$gpu.DriverVersion
            if ($null -ne $gpu.DriverDate) { $driverText = '{0} ({1})' -f $driverText, ([datetime]$gpu.DriverDate).ToString('dd.MM.yyyy.') }
            if (-not [string]::IsNullOrWhiteSpace($driverText)) { $items.Add((New-InfoItem 'KV' '  Driver' $driverText)) }

            # AdapterRAM je 32-bitni i za kartice s 4 GB ili više pokazuje krivu vrijednost: tada se čita QWORD iz registra.
            $vramBytes = 0.0
            if ($null -ne $gpu.AdapterRAM) { $vramBytes = [double]$gpu.AdapterRAM }
            if ($vramBytes -le 0 -or $vramBytes -ge 4290000000) {
                try {
                    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                    foreach ($sub in (Get-ChildItem -LiteralPath $classKey -ErrorAction SilentlyContinue)) {
                        if ($sub.PSChildName -notmatch '^\d{4}$') { continue }
                        $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
                        if ($null -ne $props -and $props.DriverDesc -eq $gpu.Name -and $null -ne $props.'HardwareInformation.qwMemorySize') {
                            $vramBytes = [double]$props.'HardwareInformation.qwMemorySize'
                            break
                        }
                    }
                } catch { <# namjerno: ubačena funkcija (runspace): nema dnevnika; polje se izostavlja #> }
            }
            if ($vramBytes -gt 0) { $items.Add((New-InfoItem 'KV' '  VRAM' (Format-Bytes $vramBytes))) }

            if ($null -ne $gpu.CurrentHorizontalResolution -and [int]$gpu.CurrentHorizontalResolution -gt 0) {
                $mode = '{0} x {1}' -f $gpu.CurrentHorizontalResolution, $gpu.CurrentVerticalResolution
                if ($null -ne $gpu.CurrentRefreshRate -and [int]$gpu.CurrentRefreshRate -gt 0) { $mode = '{0} @ {1} Hz' -f $mode, $gpu.CurrentRefreshRate }
                $items.Add((New-InfoItem 'KV' '  Zaslon' $mode))
            }
            $gpuState = [string]$gpu.Status
            if (-not [string]::IsNullOrWhiteSpace($gpuState) -and $gpuState -ne 'OK') {
                $items.Add((New-InfoItem 'KV' '  Stanje' $gpuState 'Bad'))
            }
        }
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Podaci o grafičkoj kartici nisu dostupni: ' + $_.Exception.Message) 'Warn'))
    }

    # --- Logički diskovi ---
    $items.Add((New-InfoItem 'Section' '' 'DISKOVI (LOGIČKI)'))
    try {
        $volumes = @(Get-CimInstance -OperationTimeoutSec 10 -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop)
        if ($volumes.Count -eq 0) {
            $items.Add((New-InfoItem 'Text' '' 'Nema lokalnih diskova.' 'Warn'))
        }
        foreach ($vol in $volumes) {
            $size  = [double]$vol.Size
            $label = [string]$vol.DeviceID
            if ($size -le 0) {
                $items.Add((New-InfoItem 'KV' $label 'kapacitet nije dostupan (zaključan BitLocker / disk nije spreman?)' 'Warn'))
                continue
            }
            if ($null -eq $vol.FreeSpace) {
                $items.Add((New-InfoItem 'KV' $label ('{0} ukupno, slobodan prostor nije dostupan' -f (Format-Bytes $size)) 'Warn'))
                continue
            }
            $free    = [double]$vol.FreeSpace
            $freePct = $free / $size * 100
            $usedPct = 100 - $freePct
            $status  = 'Good'
            if ($freePct -lt 10) { $status = 'Bad' } elseif ($freePct -lt 20) { $status = 'Warn' }
            $items.Add((New-InfoItem 'KV' $label ('{0} slobodno od {1}' -f (Format-Bytes $free), (Format-Bytes $size)) $status))
            $items.Add((New-InfoItem 'Bar' '' ('{0:N0} % zauzeto' -f $usedPct) $status $usedPct))
        }
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Podaci o diskovima nisu dostupni: ' + $_.Exception.Message) 'Warn'))
    }

    # --- Zdravlje fizičkih diskova (Storage API) ---
    $items.Add((New-InfoItem 'Section' '' 'ZDRAVLJE DISKOVA (NVMe / SSD)'))
    try {
        $physical = @(Get-PhysicalDisk -ErrorAction Stop | Sort-Object { [int]$_.DeviceId })
        if ($physical.Count -eq 0) {
            $items.Add((New-InfoItem 'Text' '' 'Storage API nije vratio nijedan fizički disk.' 'Warn'))
        }
        foreach ($pd in $physical) {
            $media = [string]$pd.MediaType
            if ($media -eq 'Unspecified') { $media = '' }
            $kind = ('{0} {1}' -f $pd.BusType, $media).Trim()
            $title = '{0} ({1}, {2})' -f ([string]$pd.FriendlyName).Trim(), $kind, (Format-Bytes ([double]$pd.Size))
            $items.Add((New-InfoItem 'KV' ('Disk ' + $pd.DeviceId) $title))

            $health = [string]$pd.HealthStatus
            $level  = Get-HealthLevel $health
            $opText = ConvertTo-HrHealth $pd.OperationalStatus -Operational
            $healthText = ConvertTo-HrHealth $health
            if (-not [string]::IsNullOrWhiteSpace($opText)) { $healthText = '{0} / {1}' -f $healthText, $opText }
            $items.Add((New-InfoItem 'KV' '  Zdravlje' $healthText $level))

            try {
                $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
                if ($null -ne $rel) {
                    if ($null -ne $rel.Temperature) {
                        $tempStatus = 'Good'
                        if ($rel.Temperature -ge 70) { $tempStatus = 'Bad' } elseif ($rel.Temperature -ge 55) { $tempStatus = 'Warn' }
                        $items.Add((New-InfoItem 'KV' '  Temperatura' ('{0} °C' -f $rel.Temperature) $tempStatus))
                    }
                    if ($null -ne $rel.Wear) {
                        $wearStatus = 'Good'
                        if ($rel.Wear -ge 90) { $wearStatus = 'Bad' } elseif ($rel.Wear -ge 70) { $wearStatus = 'Warn' }
                        $items.Add((New-InfoItem 'KV' '  Istrošenost' ('{0} %' -f $rel.Wear) $wearStatus))
                    }
                    if ($null -ne $rel.PowerOnHours) {
                        $items.Add((New-InfoItem 'KV' '  Sati rada' ('{0:N0} h' -f $rel.PowerOnHours)))
                    }
                }
            } catch { <# namjerno: ubačena funkcija (runspace): nema dnevnika; polje se izostavlja #> }
        }
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Get-PhysicalDisk nije dostupan: ' + $_.Exception.Message) 'Warn'))
    }

    # --- Printeri (zadnji odjeljak: upit prema Print Spooleru ne smije blokirati ostale podatke) ---
    $items.Add((New-InfoItem 'Section' '' 'PRINTERI'))
    try {
        $runAsUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if (-not [string]::IsNullOrWhiteSpace($ConsoleUser) -and $ConsoleUser -ne $runAsUser) {
            $items.Add((New-InfoItem 'Text' '' ('Printeri su očitani za račun {0}; osobni (mrežni) printeri i zadani printer korisnika {1} mogu nedostajati ili se razlikovati.' -f $runAsUser, $ConsoleUser) 'Warn'))
        }
        $printers = @(Get-CimInstance -OperationTimeoutSec 10 -ClassName Win32_Printer -ErrorAction Stop | Sort-Object -Property @{ Expression = { if ($_.Default) { 0 } else { 1 } } }, Name)
        if ($printers.Count -eq 0) {
            $items.Add((New-InfoItem 'Text' '' 'Nema instaliranih printera.'))
        }
        $printerStates = @{ 3 = 'spreman'; 4 = 'ispisuje'; 5 = 'zagrijava se'; 6 = 'ispis zaustavljen'; 7 = 'izvan mreže' }
        # DetectedErrorState: samo vrijednosti 3-8 su jednoznačne u obje Microsoftove tablice.
        $printerErrors = @{ 3 = 'malo papira'; 4 = 'nema papira'; 5 = 'malo tonera'; 6 = 'nema tonera'; 7 = 'otvorena vrata'; 8 = 'zaglavljen papir' }
        foreach ($printer in $printers) {
            $virtual = ([string]$printer.PortName -match '^(PORTPROMPT:|nul:|SHRFAX:|XPSPort:|FILE:|Microsoft\.Office)') -or ([string]$printer.Name -match '^((Microsoft Print to PDF|Microsoft XPS Document Writer|OneNote|Send To OneNote).*|Fax)$')
            $printerLabel = 'Printer'
            if ($printer.Default) { $printerLabel = 'Zadani' }
            $printerText = ([string]$printer.Name).Trim()
            if ($virtual) { $printerText += ' (virtualni)' }
            $items.Add((New-InfoItem 'KV' $printerLabel $printerText))
            if (-not $virtual) {
                if (-not [string]::IsNullOrWhiteSpace([string]$printer.DriverName)) { $items.Add((New-InfoItem 'KV' '  Driver' ([string]$printer.DriverName))) }
                if (-not [string]::IsNullOrWhiteSpace([string]$printer.PortName)) { $items.Add((New-InfoItem 'KV' '  Port' ([string]$printer.PortName))) }

                $pStatus = $null
                if ($null -ne $printer.PrinterStatus) { $pStatus = [int]$printer.PrinterStatus }
                $pError = 0
                if ($null -ne $printer.DetectedErrorState) { $pError = [int]$printer.DetectedErrorState }
                $pExtended = 0
                if ($null -ne $printer.ExtendedPrinterStatus) { $pExtended = [int]$printer.ExtendedPrinterStatus }

                $stateText  = 'spreman'
                $stateLevel = 'Good'
                if ($printer.WorkOffline -or $pStatus -eq 7 -or $pExtended -eq 7) {
                    $stateText = 'izvan mreže'; $stateLevel = 'Warn'
                } elseif ($printerErrors.ContainsKey($pError)) {
                    $stateText = $printerErrors[$pError]; $stateLevel = 'Warn'
                } elseif ($pError -gt 8) {
                    $stateText = ('greška pisača (kod {0})' -f $pError); $stateLevel = 'Warn'
                } elseif ($pExtended -eq 9) {
                    $stateText = 'greška pisača'; $stateLevel = 'Warn'
                } elseif ($pExtended -eq 8 -or $pStatus -eq 6) {
                    $stateText = 'pauziran / zaustavljen'; $stateLevel = 'Warn'
                } elseif ($null -eq $pStatus -or $pStatus -le 2) {
                    $stateText = 'status nepoznat'; $stateLevel = 'Normal'
                } elseif ($printerStates.ContainsKey($pStatus)) {
                    $stateText = $printerStates[$pStatus]
                    if ($pStatus -ge 6) { $stateLevel = 'Warn' }
                }
                $items.Add((New-InfoItem 'KV' '  Stanje' $stateText $stateLevel))
            }
        }
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Podaci o printerima nisu dostupni (servis Print Spooler?): ' + $_.Exception.Message) 'Warn'))
    }

    return $items
}

function Get-StatusColor {
    param([string]$Status)
    $c = $script:Colors
    if ($Status -eq 'Good') { return $c.Good }
    if ($Status -eq 'Warn') { return $c.Warn }
    if ($Status -eq 'Bad')  { return $c.Bad }
    if ($Status -eq 'Muted') { return $c.Muted }
    return $c.Text
}

function Add-RichText {
    param(
        $Rtb,
        [AllowEmptyString()][string]$Text,
        $Color,
        [bool]$Bold = $false,
        [int]$Indent = 0,
        [int]$Hanging = 0,
        [int[]]$Tabs = $null,
        [bool]$NewLine = $true
    )
    $Rtb.SelectionStart  = $Rtb.TextLength
    $Rtb.SelectionLength = 0
    $Rtb.SelectionColor  = $Color
    if ($Bold) { $Rtb.SelectionFont = $script:Fonts.MonoBold } else { $Rtb.SelectionFont = $script:Fonts.Mono }
    $Rtb.SelectionIndent        = $Indent
    $Rtb.SelectionHangingIndent = $Hanging
    if ($null -ne $Tabs) { $Rtb.SelectionTabs = $Tabs }
    if ($NewLine) { $Rtb.AppendText($Text + "`n") } else { $Rtb.AppendText($Text) }
}

function Show-SystemInfo {
    param($Items, [switch]$KeepScroll)
    $rtb = $script:UI.Status
    $c   = $script:Colors
    $firstLine = 0
    if ($KeepScroll) { try { $firstLine = [Auxilium.NativeMethods]::GetFirstVisibleLine($rtb.Handle) } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> } }
    # Panel se briše i gradi redak po redak (oko 150 ms): bez isključenog iscrtavanja cijela kolona vidljivo trepne.
    [Auxilium.NativeMethods]::SetRedraw($rtb.Handle, $false)
    try {
        $rtb.Clear()
        $script:LiveRows = @{}

        $first = $true
        foreach ($it in $Items) {
            if ($it.Kind -eq 'Section') {
                if (-not $first) { Add-RichText $rtb '' $c.Text }
                Add-RichText $rtb $it.Value.ToUpperInvariant() $c.Yellow -Bold $true -Indent 6
                Add-RichText $rtb (([string][char]0x2500) * 40) $c.Line -Indent 6
            } elseif ($it.Kind -eq 'KV') {
                if ([regex]::IsMatch([string]$it.Value, '^(?:\\\\)?[^\s\\\-]{27,}')) {
                    # Vrijednost koja počinje predugačkim nedjeljivim nizom (UNC naziv printera, URL porta) ne stane uz oznaku: RichEdit bi zalomio
                    # sam tabulator i oznaka bi ostala sama u retku. Takva vrijednost ide u novi redak ispod oznake.
                    Add-RichText $rtb $it.Label $c.Muted -Indent 6
                    Add-RichText $rtb $it.Value (Get-StatusColor $it.Status) -Indent 112
                } else {
                    Add-RichText $rtb ($it.Label + "`t") $c.Muted -Indent 6 -Hanging 106 -Tabs @(112) -NewLine $false
                    Add-RichText $rtb $it.Value (Get-StatusColor $it.Status) -Indent 6 -Hanging 106 -Tabs @(112)
                }
            } elseif ($it.Kind -eq 'Bar') {
                $filled = [int][Math]::Round([Math]::Min(100, [Math]::Max(0, $it.Percent)) / 100 * 16)
                $bar = (([string][char]0x2588) * $filled) + (([string][char]0x2591) * (16 - $filled))
                if ([string]::IsNullOrEmpty($it.Label)) {
                    Add-RichText $rtb ("`t" + $bar + ' ' + ('{0:N0} %' -f $it.Percent)) (Get-StatusColor $it.Status) -Indent 6 -Hanging 106 -Tabs @(112)
                } else {
                    # Bar s oznakom (CPU / RAM) osvježava se uživo (Update-LiveMeters): postotak je fiksne širine pa se položaji redaka ne pomiču.
                    Add-RichText $rtb ($it.Label + "`t") $c.Muted -Indent 6 -Hanging 106 -Tabs @(112) -NewLine $false
                    $liveStart = $rtb.TextLength
                    $liveText  = $bar + ' ' + ('{0,3:N0} %' -f $it.Percent)
                    Add-RichText $rtb $liveText (Get-StatusColor $it.Status) -Indent 6 -Hanging 106 -Tabs @(112)
                    $script:LiveRows[[string]$it.Label] = @{ Start = $liveStart; Length = $liveText.Length; Item = $it }
                }
            } else {
                Add-RichText $rtb $it.Value (Get-StatusColor $it.Status) -Indent 6
            }
            $first = $false
        }

        $rtb.SelectionStart  = 0
        $rtb.SelectionLength = 0
        $rtb.ScrollToCaret()
        if ($KeepScroll -and $firstLine -gt 0) { try { [Auxilium.NativeMethods]::ScrollToFirstVisibleLine($rtb.Handle, $firstLine) } catch { <# namjerno: kozmetika sučelja (tema, pomak, fokus): bez toga alat radi #> } }
    } finally {
        [Auxilium.NativeMethods]::SetRedraw($rtb.Handle, $true)
        $rtb.Invalidate()
    }
    # Health Score se računa iz istih stavki koje se prikazuju.
    try { Update-HealthTile $Items } catch { Write-AppLog 'Debug' 'Update-HealthTile' $_ }
}

# Prikupljanje podataka (CIM/Storage upiti) izvodi se u zasebnom runspaceu, a sučelje se pumpa dok se čeka.
# Vraća polje stavki, ili $null ako je prekinuto / isteklo vrijeme.
function Get-SystemInfoItemsAsync {
    param([bool]$HonorCancel = $true, [int]$TimeoutSeconds = 60)

    $names     = @('New-InfoItem', 'Get-HealthLevel', 'Format-Bytes', 'ConvertTo-HrHealth', 'Get-SystemInfoItems')
    $rs        = $null
    $ps        = $null
    $abandoned = $false
    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($name in $names) {
            $body = (Get-Item -LiteralPath ('function:' + $name)).ScriptBlock.ToString()
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($name, $body)))
        }
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        # Popis (List, ne ArrayList: njegov Add vraća indeks i zagadio bi izlaz) u koji funkcija odmah upisuje stavke: ako upit zapne,
        # sve što je do tada prikupljeno ostaje dostupno. Prijavljeni korisnik prosljeđuje se kao parametar (runspace nema vlastitu predmemoriju).
        # BlockingCollection: Add i ToArray su sigurni među nitima (obični List bi pri isteku vremena, dok runspace još piše, mogao baciti iznimku u ToArray).
        $sink = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
        [void]$ps.AddCommand('Get-SystemInfoItems').AddParameter('Sink', $sink).AddParameter('ConsoleUser', [string](Get-ConsoleUser))
        $async = $ps.BeginInvoke()

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $async.IsCompleted) {
            $stop = ($script:Closing -or ($HonorCancel -and $script:CancelRequested))
            if ($stop -or $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                $abandoned = $true
                $script:AbandonedRunspace = $true
                try { [void]$ps.BeginStop($null, $null) } catch { <# namjerno: zaustavljanje napuštenog runspacea: zapeti WMI poziv se ionako ne može prekinuti #> }
                if (-not $stop) {
                    Write-Terminal 'Prikupljanje podataka o sustavu je isteklo (WMI/CIM ne odgovara).' 'Warn'
                    $partial = @()
                    try { $partial = @($sink.ToArray()) } catch { Write-AppLog 'Debug' 'Get-SystemInfoItemsAsync: sink.ToArray()' $_ }
                    if ($partial.Count -gt 0) {
                        $partial += (New-InfoItem 'Text' '' 'Prikupljanje je isteklo: prikazani su samo podaci prikupljeni do tada (WMI/CIM ne odgovara).' 'Warn')
                        return ,$partial
                    }
                }
                return $null
            }
            Update-Ui
            Start-Sleep -Milliseconds 25
        }
        $output = $ps.EndInvoke($async)
        foreach ($streamError in $ps.Streams.Error) { Write-AppLog 'Warn' 'Prikupljanje podataka o sustavu (runspace)' $streamError }
        return ,@($output)
    } finally {
        if (-not $abandoned) {
            try { if ($null -ne $ps) { $ps.Dispose() } } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> }
            try { if ($null -ne $rs) { $rs.Dispose() } } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> }
        }
    }
}

function Update-SystemStatus {
    param([switch]$IgnoreCancel, [switch]$SkipDeep)

    $rtb = $script:UI.Status
    if ($null -ne $rtb) {
        $rtb.Clear()
        $script:LiveRows = @{}   # panel je prazan: stari pomaci u retku više ne vrijede (LiveTimer bi pisao na pogrešno mjesto)
        Add-RichText $rtb 'Učitavanje podataka o sustavu...' $script:Colors.Muted -Indent 6
    }
    Write-Terminal 'Prikupljanje informacija o sustavu...' 'Info'

    $items = $null
    try {
        $items = Get-SystemInfoItemsAsync -HonorCancel (-not $IgnoreCancel)
    } catch {
        Write-Terminal ('  Pozadinsko prikupljanje nije uspjelo ({0}); koristim izravan način.' -f $_.Exception.Message) 'Warn'
        $items = @(Get-SystemInfoItems -ConsoleUser ([string](Get-ConsoleUser)))
    }

    if ($null -eq $items) {
        # Prekinuto ili isteklo vrijeme: zadržava se prethodni prikaz.
        if ($null -ne $rtb) {
            if (@($script:SysInfo).Count -gt 0) {
                Show-SystemInfo @(Get-CombinedInfoItems)
            } else {
                $rtb.Clear()
                $script:LiveRows = @{}
                Add-RichText $rtb 'Podaci o sustavu nisu učitani. Pritisnite "Osvježi".' $script:Colors.Muted -Indent 6
            }
        }
        return
    }

    $script:SysInfo = @($items)
    # Ažuriranja na čekanju i dnevnici (7 dana) prikupljaju se u pozadini; sučelje ostaje slobodno.
    if (-not $SkipDeep) { Start-DeepScan }
    if ($null -ne $rtb) { Show-SystemInfo @(Get-CombinedInfoItems) }
    Write-Terminal 'Status sustava je osvježen.' 'Ok'
    if (-not $SkipDeep -and $script:Deep.State -eq 'Running') {
        Write-Terminal 'Softver (Office, mail), ažuriranja na čekanju i dnevnici događaja (7 dana) učitavaju se u pozadini...' 'Info'
    }
}
#endregion SYSTEM INFO

