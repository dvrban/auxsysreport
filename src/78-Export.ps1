#region EXPORT
# Izvoz za web aplikaciju "IT Inventar" (schema auxilium-inventar/1): JSON uz PDF ili samo JSON (gumb "Izvezi JSON").
# Podaci se NE uzimaju iz prikazanih stavki nego zasebnim upitima (Get-InventoryData u zasebnom runspaceu, kao i prikupljanje statusa).
# Izvoz nikad ne smije srušiti ni poništiti PDF. Napomena za uređivanje: u ovom bloku nemojte tipkati \uXXXX nizove (alati za uređivanje
# ih pretvaraju u prave znakove); kodovi znakova grade se s [char]0x....

# =====================================================================================
#  Inventory-Block.ps1 - Auxilium inventar: skupljanje podataka o uređaju za JSON izvoz
#
#  Sadrži TOČNO dvije funkcije najviše razine (nema koda koji se izvršava pri učitavanju):
#    New-InventoryResult : čista funkcija, složi kanonsku [ordered] strukturu (schema/collectedAt/
#                          toolVersion/company/device/loggedOnUser). Ne baca iznimke.
#    Get-InventoryData   : kolektor, samo čitanje (CIM/registar). Svako polje u svom try/catch,
#                          upisuje se u -DeviceSink čim je poznato, vraća točno jedan objekt.
#  Obje su samostalne (sve pomoćne funkcije su ugniježđene) pa se mogu ubaciti u zaseban runspace
#  po imenu (SessionStateFunctionEntry), isto kao Get-SystemInfoItemsAsync. Windows PowerShell 5.1.
#
#  Odluke koje nisu očite iz specifikacije:
#   - Mreža/disk: izravno CIM klase (root/StandardCimv2, root/Microsoft/Windows/Storage) na kojima
#     su izgrađeni Get-NetIPConfiguration i Get-PhysicalDisk. Isti podaci, ali 10-60 ms umjesto
#     1,6 s / 0,7 s, uz -OperationTimeoutSec. Rezerva: Win32_NetworkAdapterConfiguration odnosno Win32_DiskDrive.
#   - storageCapacity: Size/1e9 se zaokruži na najbliži standardni marketinški korak ako je unutar 2 %
#     od njega (120,128,240,250,256,480,500,512,960,1000,1024,2000,2048,4000 GB), inače na cijeli GB.
#     Ispod 1000 GB: "<n> GB"; od 1000 GB: "<n> TB" s jednom decimalom ("1 TB", "1.2 TB", "2 TB"), uvijek s točkom.
#   - storageType "hybrid" se nikad ne emitira (SSHD se ne može pouzdano prepoznati).
#   - Ako dva CIM upita istekla, ostali CIM upiti se preskaču (WMI je mrtav), a polja se pune iz registra.
#   - RAM bez podataka o DIMM-ovima (Win32_PhysicalMemory prazan ili ne radi): najprije kernel32!GetPhysicallyInstalledSystemMemory
#     (stvarno ugrađeni RAM, isto što prikazuje Windows; P/Invoke u memoriji, bez Add-Type), tek zatim
#     Win32_ComputerSystem.TotalPhysicalMemory (točan na VM-ovima; na fizičkom računalu manji za hardverski rezerviranu memoriju).
#   - Office (Click-to-Run): od ProductReleaseIds bira se prvi ID koji je poznati paket (O365*, ProPlus/Standard/... , EEA "NoTeams"
#     inačice); tek ako nijedan nije paket, prvi preostali sirovi ID. Visio/Project/Access/jezični paketi i jednoaplikacijski
#     OneNote/Skype/Teams/SharePointDesigner ID-evi se preskaču.
#   - installedApps izuzima samo: SystemComponent=1, stavke bez imena ili s ParentKeyName te nazive '^(Update for|Security Update|Hotfix)'
#     i KB\d{6,}. (Windows Driver Package stavke ostaju u popisu, vidljive su u "Programs and Features".)
#   - Mreža: ako glavni put (MSFT_Net*) odabere adapter, ali nema MAC ili IP, nedostajuća vrijednost se nadopunjuje iz
#     Win32_NetworkAdapterConfiguration za isti InterfaceIndex. Adapter se bira prema najnižoj metrici zadanog puta (bez
#     razlike fizički/virtualni, prema specifikaciji).
# =====================================================================================

function New-InventoryResult {
    param(
        [object]$Company,
        [object]$ConsoleUser,
        [object]$ToolVersion,
        [object]$Device
    )

    try {
        # Jednoredni, trimani tekst: sve praznine i kontrolni znakovi postaju jedan razmak; prazno -> $null.
        # Nikad ne baca iznimku (vrijednost čiji ToString() pada daje $null samo za to polje). Usamljeni UTF-16 surogati
        # (oštećeni registarski nizovi) postaju razmak, da JSON ostane ispravan Unicode i za strogi UTF-8 koder.
        function ConvertTo-CleanText {
            param($Value)
            try {
                if ($null -eq $Value) { return $null }
                $hi = '[' + [char]0xD800 + '-' + [char]0xDBFF + ']'
                $lo = '[' + [char]0xDC00 + '-' + [char]0xDFFF + ']'
                $srx = $hi + '(?!' + $lo + ')|(?<!' + $hi + ')' + $lo
                $rx = '[\s\x00-\x1F\x7F-\x9F' + [char]0x200B + '-' + [char]0x200F + [char]0x2028 + [char]0x2029 + [char]0x202A + '-' + [char]0x202E + [char]0x2060 + [char]0xFEFF + ']+'   # razmaci, kontrolni i nevidljivi znakovi
                $s = [regex]::Replace([string]$Value, $srx, ' ')
                $s = [regex]::Replace($s, $rx, ' ').Trim()
                if ($s.Length -eq 0) { return $null }
                return $s
            } catch {
                return $null
            }
        }

        $deviceKeys = @('category', 'hostname', 'manufacturer', 'model', 'serialNumber', 'cpu', 'ram', 'ramType',
                        'storageType', 'storageCapacity', 'operatingSystem', 'officeVersion', 'antivirus',
                        'macAddress', 'ipAddress', 'warrantyUntil', 'installedApps')
        $ramTypes = @('ddr3', 'ddr4', 'ddr5', 'lpddr4', 'lpddr5', 'ostalo')   # dopuštene vrijednosti ramType (specifikacija)
        $isDict = $false
        try { $isDict = ($Device -is [System.Collections.IDictionary]) } catch { $isDict = $false }
        $dev = [ordered]@{}
        foreach ($key in $deviceKeys) {
            $raw = $null
            try {
                # Izravno indeksiranje (ne Contains): Dictionary[string,object] i ConcurrentDictionary ne izlažu Contains() PowerShellu.
                # Nedostajući ključ daje $null (Hashtable/OrderedDictionary) ili iznimku (generički rječnici), uhvaćenu ovdje.
                if ($isDict) { $raw = $Device[$key] }
            } catch { $raw = $null }

            if ($key -eq 'installedApps') {
                $apps = New-Object 'System.Collections.Generic.List[string]'
                try {
                    foreach ($a in @($raw)) {
                        $t = ConvertTo-CleanText $a
                        if ($null -ne $t) { $apps.Add($t) }
                        if ($apps.Count -ge 1500) { break }
                    }
                } catch { }
                $dev[$key] = $apps.ToArray()
            } elseif ($key -eq 'ramType') {
                # Samo vrijednosti iz popisa; sve ostalo (prazno, '0', '2', slobodan tekst) -> ključ se izostavlja.
                $t = ConvertTo-CleanText $raw
                if ($null -ne $t) {
                    $t = $t.ToLowerInvariant()
                    if ($ramTypes -contains $t) { $dev[$key] = $t }
                }
            } else {
                $dev[$key] = ConvertTo-CleanText $raw
            }
        }

        $loggedOn = ConvertTo-CleanText $ConsoleUser
        if ($null -eq $loggedOn) {
            $domain = ConvertTo-CleanText $env:USERDOMAIN
            $user = ConvertTo-CleanText $env:USERNAME
            if ($null -ne $user) {
                if ($null -ne $domain) { $loggedOn = $domain + '\' + $user } else { $loggedOn = $user }
            }
        }

        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)

        $result = [ordered]@{}
        $result['schema'] = 'auxilium-inventar/1'
        $result['collectedAt'] = $stamp
        $result['toolVersion'] = ConvertTo-CleanText $ToolVersion
        $result['company'] = ConvertTo-CleanText $Company
        $result['device'] = $dev
        $result['loggedOnUser'] = $loggedOn
        return $result
    } catch {
        # Posljednja linija obrane: minimalna, ali ispravna struktura.
        $stamp = $null
        try { $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
        $dev = [ordered]@{}
        foreach ($key in @('category', 'hostname', 'manufacturer', 'model', 'serialNumber', 'cpu', 'ram', 'storageType',
                           'storageCapacity', 'operatingSystem', 'officeVersion', 'antivirus', 'macAddress', 'ipAddress', 'warrantyUntil')) {
            $dev[$key] = $null
        }
        $dev['installedApps'] = @()
        $result = [ordered]@{}
        $result['schema'] = 'auxilium-inventar/1'
        $result['collectedAt'] = $stamp
        $result['toolVersion'] = $null
        $result['company'] = $null
        $result['device'] = $dev
        $result['loggedOnUser'] = $null
        return $result
    }
}

function Get-InventoryData {
    param(
        [object]$Company,
        [object]$ConsoleUser,
        [object]$ToolVersion,
        [object]$DeviceSink
    )

    # Ponašanje mora biti isto bez obzira na globalni $ErrorActionPreference domaćina: lokalno 'Stop'
    # (svaki neočekivani neprekinuti error postaje iznimka koju uhvati try/catch, ništa ne curi u izlaz).
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'
    $DebugPreference = 'SilentlyContinue'

    $dev = $null
    if ($DeviceSink -is [System.Collections.IDictionary]) { $dev = $DeviceSink } else { $dev = [hashtable]::Synchronized(@{}) }
    $cimState = @{ Timeouts = 0 }
    $hklm = $null
    $hku = $null
    $hkcu = $null
    $placeholderList = @(
        'To be filled by O.E.M.', 'To be filled by OEM', 'O.E.M.', 'OEM', 'System Product Name', 'System manufacturer',
        'System Version', 'System Serial Number', 'Chassis Serial Number', 'Default string', 'Default', 'Not Specified',
        'Not Available', 'Not Applicable', 'None', 'N/A', 'Invalid', 'Type1ProductConfigId', 'SerialNumberToDefault',
        '0123456789', '1234567890', '123456789', 'Unknown'
    )
    $uninstallSub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $uninstallSub32 = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    $uninstallUser = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
    $trademarkRx = '[' + [char]0xAE + [char]0x2122 + ']'   # znakovi (R) i (TM) u nazivu OS-a
    $catLaptop = 'Prijenosno ra' + [char]0x010D + 'unalo'   # "Prijenosno računalo" (znak je kodiran da prežive sve kodne stranice)
    $catDesktop = 'Desktop ra' + [char]0x010D + 'unalo'     # "Desktop računalo"

    # ------------------------------ pomoćne funkcije ------------------------------

    function Set-InvField {
        param([string]$Name, $Value)
        try { $dev[$Name] = $Value } catch { }
    }

    # Jednoredni, trimani tekst; -Placeholder briše tvorničke zamjenske vrijednosti (BIOS/DMI smeće).
    # Nikad ne baca iznimku; usamljeni UTF-16 surogati postaju razmak (isto kao u New-InventoryResult).
    function ConvertTo-CleanText {
        param($Value, [switch]$Placeholder)
        try {
            if ($null -eq $Value) { return $null }
            $hi = '[' + [char]0xD800 + '-' + [char]0xDBFF + ']'
            $lo = '[' + [char]0xDC00 + '-' + [char]0xDFFF + ']'
            $srx = $hi + '(?!' + $lo + ')|(?<!' + $hi + ')' + $lo
            $rx = '[\s\x00-\x1F\x7F-\x9F' + [char]0x200B + '-' + [char]0x200F + [char]0x2028 + [char]0x2029 + [char]0x202A + '-' + [char]0x202E + [char]0x2060 + [char]0xFEFF + ']+'   # razmaci, kontrolni i nevidljivi znakovi
            $s = [regex]::Replace([string]$Value, $srx, ' ')
            $s = [regex]::Replace($s, $rx, ' ').Trim()
            if ($s.Length -eq 0) { return $null }
            if ($Placeholder) {
                if ($placeholderList -contains $s) { return $null }
                if ($s -match '^(0+|f+|x+)$') { return $null }
            }
            return $s
        } catch {
            return $null
        }
    }

    # CIM upit s vremenskim ograničenjem; uvijek vraća polje (može biti prazno) ili baca iznimku.
    function Invoke-InvCim {
        param([string]$ClassName, [string]$Namespace, [string]$Filter, [string[]]$Property, [int]$TimeoutSec = 15)
        if ([int]$cimState.Timeouts -ge 2) { throw 'CIM preskočen: prethodni upiti su istekli.' }
        $p = @{ ClassName = $ClassName; OperationTimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
        if ($Namespace) { $p['Namespace'] = $Namespace }
        if ($Filter) { $p['Filter'] = $Filter }
        if ($Property) { $p['Property'] = $Property }   # samo potrebna svojstva (Win32_Processor.LoadPercentage inače košta ~1 s)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            return @(Get-CimInstance @p)
        } catch {
            if ($sw.Elapsed.TotalSeconds -ge ($TimeoutSec - 1)) { $cimState.Timeouts = [int]$cimState.Timeouts + 1 }
            throw
        }
    }

    # Vrijednost iz HKLM (64-bitni prikaz, neovisno o bitnosti procesa), očišćena.
    function Get-InvRegText {
        param([string]$SubKey, [string]$Name)
        if ($null -eq $hklm) { return $null }
        $k = $null
        try {
            $k = $hklm.OpenSubKey($SubKey)
            if ($null -eq $k) { return $null }
            return (ConvertTo-CleanText ($k.GetValue($Name)))
        } catch {
            return $null
        } finally {
            if ($null -ne $k) { $k.Close() }
        }
    }

    # Popis stavki iz jedne Uninstall grane: Name, Version, SystemComponent (bool), Parent (bool).
    function Get-InvUninstallEntries {
        param($Base, [string]$SubPath)
        $list = New-Object 'System.Collections.Generic.List[object]'
        if ($null -eq $Base) { return $list.ToArray() }
        $k = $null
        try {
            $k = $Base.OpenSubKey($SubPath)
            if ($null -ne $k) {
                foreach ($subName in $k.GetSubKeyNames()) {
                    $sk = $null
                    try {
                        $sk = $k.OpenSubKey($subName)
                        if ($null -ne $sk) {
                            $dn = $sk.GetValue('DisplayName')
                            if ($null -ne $dn) {
                                $parent = $sk.GetValue('ParentKeyName')
                                $list.Add([pscustomobject]@{
                                    Name            = [string]$dn
                                    Version         = [string]$sk.GetValue('DisplayVersion')
                                    SystemComponent = ([string]$sk.GetValue('SystemComponent') -eq '1')
                                    Parent          = (-not [string]::IsNullOrEmpty([string]$parent))
                                })
                            }
                        }
                    } catch { } finally {
                        if ($null -ne $sk) { $sk.Close() }
                    }
                }
            }
        } catch { } finally {
            if ($null -ne $k) { $k.Close() }
        }
        return $list.ToArray()
    }

    # Imena programa: bez SystemComponent/zakrpa, očišćena, bez duplikata (bez obzira na veličinu slova), sortirana, najviše 1500.
    function Get-InvAppNames {
        param($Entries)
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $names = New-Object 'System.Collections.Generic.List[string]'
        foreach ($e in @($Entries)) {
            if ($e.SystemComponent -or $e.Parent) { continue }
            $n = ConvertTo-CleanText $e.Name
            if ($null -eq $n) { continue }
            if ($n -match '^(Update for|Security Update|Hotfix)|\bKB\d{6,}') { continue }
            if ($seen.Add($n)) { $names.Add($n) }
        }
        $arr = $names.ToArray()
        [System.Array]::Sort($arr, [System.StringComparer]::OrdinalIgnoreCase)
        if ($arr.Length -gt 1500) {
            $cut = New-Object 'string[]' 1500
            [System.Array]::Copy($arr, $cut, 1500)
            $arr = $cut
        }
        return $arr
    }

    # AA:BB:CC:DD:EE:FF (velika slova); $null ako nije 12 heksadecimalnih znamenki ili je sve nule.
    function Format-InvMac {
        param($Raw)
        if ($null -eq $Raw) { return $null }
        $h = ([string]$Raw -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        if ($h.Length -ne 12) { return $null }
        if ($h -match '^0+$') { return $null }
        return [regex]::Replace($h, '(.{2})(?!$)', '$1:')
    }

    # Prvi IPv4 koji nije APIPA (169.254.x.x); ako postoji samo APIPA -> $null.
    function Select-InvIPv4 {
        param($Candidates)
        foreach ($c in @($Candidates)) {
            $s = [string]$c
            if ($s -match '^\d{1,3}(\.\d{1,3}){3}$' -and $s -notlike '169.254.*') { return $s }
        }
        return $null
    }

    # Kapacitet diska (bajtovi) -> "512 GB" / "1 TB" / "1.5 TB" (pravilo u zaglavlju datoteke).
    function Format-InvDiskCapacity {
        param([double]$Bytes)
        if ($Bytes -le 0) { return $null }
        $gb = $Bytes / 1e9
        $steps = @(120, 128, 240, 250, 256, 480, 500, 512, 960, 1000, 1024, 2000, 2048, 4000)
        $best = $null
        $bestDiff = [double]::MaxValue
        foreach ($s in $steps) {
            $d = [math]::Abs($gb - $s) / $s
            if ($d -le 0.02 -and $d -lt $bestDiff) { $best = $s; $bestDiff = $d }
        }
        if ($null -ne $best) { $g = [double]$best } else { $g = [math]::Round($gb, 0, [System.MidpointRounding]::AwayFromZero) }
        if ($g -ge 1000) {
            $tb = [math]::Round($g / 1000, 1, [System.MidpointRounding]::AwayFromZero)
            return ($tb.ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture) + ' TB')
        }
        return ($g.ToString('0', [System.Globalization.CultureInfo]::InvariantCulture) + ' GB')
    }

    # Disk sistemskog pogona: najprije MSFT_PhysicalDisk (isti izvor kao Get-PhysicalDisk), rezerva Win32_DiskDrive.
    function Get-InvSystemDisk {
        $sysLetter = $null
        try { $sd = [string]$env:SystemDrive; if ($sd.Length -ge 1) { $sysLetter = $sd.Substring(0, 1).ToUpperInvariant() } } catch { }
        if ($null -eq $sysLetter) {
            try { $sysLetter = ([System.Environment]::GetFolderPath('Windows')).Substring(0, 1).ToUpperInvariant() } catch { }
        }

        try {
            $ns = 'root/Microsoft/Windows/Storage'
            $pdisks = @(Invoke-InvCim 'MSFT_PhysicalDisk' $ns)
            if ($pdisks.Count -eq 0) { throw 'Nema fizičkih diskova.' }
            $target = $null
            try {
                $parts = @(Invoke-InvCim 'MSFT_Partition' $ns)
                $sysPart = $null
                foreach ($pt in $parts) {
                    if ($null -ne $sysLetter -and ([string]$pt.DriveLetter).ToUpperInvariant() -eq $sysLetter) { $sysPart = $pt; break }
                }
                if ($null -ne $sysPart -and $null -ne $sysPart.DiskNumber) {
                    $dn = ([int]$sysPart.DiskNumber).ToString()
                    $m = @($pdisks | Where-Object { [string]$_.DeviceId -eq $dn })
                    if ($m.Count -eq 1 -and [int]$m[0].BusType -ne 16) { $target = $m[0] }   # 16 = Storage Spaces (virtualni disk)
                }
            } catch { $target = $null }

            if ($null -eq $target) {
                # Rezerva: prvi unutarnji disk (ne USB/SD/MMC/virtualni/Storage Spaces), najmanji broj diska.
                $internal = @($pdisks | Where-Object { @(7, 12, 13, 15, 16) -notcontains [int]$_.BusType })
                $bestNum = [int]::MaxValue
                foreach ($d in $internal) {
                    $num = 0
                    if (-not [int]::TryParse([string]$d.DeviceId, [ref]$num)) { $num = [int]::MaxValue - 1 }
                    if ($num -lt $bestNum) { $bestNum = $num; $target = $d }
                }
            }
            if ($null -eq $target) { throw 'Nema odgovarajućeg diska.' }

            $bus = [int]$target.BusType
            $media = [int]$target.MediaType
            if ($bus -eq 17) { $type = 'm2_nvme' }
            elseif ($media -eq 4) { $type = 'ssd' }
            elseif ($media -eq 3) { $type = 'hdd' }
            else { $type = 'ostalo' }
            return [pscustomobject]@{ Type = $type; Capacity = (Format-InvDiskCapacity ([double]$target.Size)) }
        } catch { }

        # Rezerva bez Storage prostora imena: Win32_DiskDrive, tip samo po nazivu modela (NVMe / SSD), inače 'ostalo'.
        $drive = $null
        try {
            if ($null -ne $sysLetter) {
                $ld = @(Invoke-InvCim 'Win32_LogicalDisk' -Filter ("DeviceID='" + $sysLetter + ":'"))
                if ($ld.Count -gt 0) {
                    $part = @(Get-CimAssociatedInstance -InputObject $ld[0] -Association Win32_LogicalDiskToPartition -OperationTimeoutSec 15 -ErrorAction Stop)
                    if ($part.Count -gt 0) {
                        $dd = @(Get-CimAssociatedInstance -InputObject $part[0] -Association Win32_DiskDriveToDiskPartition -OperationTimeoutSec 15 -ErrorAction Stop)
                        if ($dd.Count -gt 0) { $drive = $dd[0] }
                    }
                }
            }
        } catch { $drive = $null }
        if ($null -eq $drive) {
            $all = @(Invoke-InvCim 'Win32_DiskDrive' | Where-Object { [string]$_.InterfaceType -ne 'USB' } | Sort-Object { [int]$_.Index })
            if ($all.Count -gt 0) { $drive = $all[0] }
        }
        if ($null -eq $drive) { return $null }
        $id = ([string]$drive.Model + ' ' + [string]$drive.PNPDeviceID)
        if ($id -match 'NVMe') { $type = 'm2_nvme' }
        elseif ($id -match '\bSSD\b|Solid.?State') { $type = 'ssd' }
        else { $type = 'ostalo' }
        return [pscustomobject]@{ Type = $type; Capacity = (Format-InvDiskCapacity ([double]$drive.Size)) }
    }

    # Rezerva: Win32_NetworkAdapterConfiguration. S $InterfaceIndex (adapter koji je odabrao glavni put) gleda se samo taj adapter;
    # bez njega adapter s IPv4 zadanim prolazom i najnižom metrikom. Vraća @{ Mac; Ip } (vrijednosti mogu biti $null) ili $null.
    # Baca iznimku ako CIM upit padne (pozivatelj je hvata).
    function Get-InvNetworkFallback {
        param($InterfaceIndex)
        if ($null -ne $InterfaceIndex) {
            $cfgs = @(Invoke-InvCim 'Win32_NetworkAdapterConfiguration' -Filter ('IPEnabled=TRUE AND InterfaceIndex=' + ([int]$InterfaceIndex).ToString()))
        } else {
            $cfgs = @(Invoke-InvCim 'Win32_NetworkAdapterConfiguration' -Filter 'IPEnabled=TRUE' | Where-Object {
                @(@($_.DefaultIPGateway) | Where-Object { [string]$_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and [string]$_ -ne '0.0.0.0' }).Count -gt 0
            })
        }
        if ($cfgs.Count -eq 0) { return $null }
        $pick = $null
        $pickMetric = [int64]::MaxValue
        foreach ($c in $cfgs) {
            $mt = [int64]::MaxValue - 1
            if ($null -ne $c.IPConnectionMetric) { $mt = [int64]$c.IPConnectionMetric }
            if ($mt -lt $pickMetric) { $pickMetric = $mt; $pick = $c }
        }
        if ($null -eq $pick) { $pick = $cfgs[0] }
        return [pscustomobject]@{ Mac = (Format-InvMac $pick.MACAddress); Ip = (Select-InvIPv4 @($pick.IPAddress)) }
    }

    # Adapter s IPv4 zadanim putem: najprije MSFT_Net* (isti izvor kao Get-NetIPConfiguration), rezerva Win32_NetworkAdapterConfiguration
    # (i za nadopunu samo jedne od dviju vrijednosti, ako je jedan od MSFT_Net* upita pao ili ne daje podatak).
    function Get-InvNetwork {
        $mac = $null
        $ip = $null
        $chosen = $null    # InterfaceIndex adaptera kojeg je odabrao glavni put
        try {
            $ns = 'root/StandardCimv2'
            $routes = @(Invoke-InvCim 'MSFT_NetRoute' $ns | Where-Object {
                $_.AddressFamily -eq 2 -and $_.DestinationPrefix -eq '0.0.0.0/0' -and
                -not [string]::IsNullOrEmpty([string]$_.NextHop) -and [string]$_.NextHop -ne '0.0.0.0' -and
                ($null -eq $_.Store -or [int]$_.Store -eq 1)    # 1 = ActiveStore
            })
            if ($routes.Count -gt 0) {
                $ipifs = @()
                try { $ipifs = @(Invoke-InvCim 'MSFT_NetIPInterface' $ns | Where-Object { $_.AddressFamily -eq 2 }) } catch { }
                $cands = New-Object 'System.Collections.Generic.List[object]'
                foreach ($r in $routes) {
                    $idx = [int]$r.InterfaceIndex
                    $metric = [int64]$r.RouteMetric
                    $up = $true
                    foreach ($i in $ipifs) {
                        if ([int]$i.InterfaceIndex -eq $idx) {
                            $metric += [int64]$i.InterfaceMetric
                            if ($null -ne $i.ConnectionState -and [int]$i.ConnectionState -ne 1) { $up = $false }
                            break
                        }
                    }
                    if ($up) { $cands.Add([pscustomobject]@{ Index = $idx; Metric = $metric }) }
                }
                if ($cands.Count -gt 0) {
                    $best = @($cands.ToArray() | Sort-Object -Property Metric, Index)[0]
                    $chosen = [int]$best.Index

                    $ip = $null
                    try {
                        $addrs = @(Invoke-InvCim 'MSFT_NetIPAddress' $ns | Where-Object { $_.AddressFamily -eq 2 -and [int]$_.InterfaceIndex -eq $best.Index })
                        $ordered = @($addrs | Where-Object { [int]$_.AddressState -eq 4 }) + @($addrs | Where-Object { [int]$_.AddressState -ne 4 })
                        $ip = Select-InvIPv4 @($ordered | ForEach-Object { $_.IPAddress })
                    } catch { $ip = $null }

                    $mac = $null
                    try {
                        $adapters = @(Invoke-InvCim 'MSFT_NetAdapter' $ns | Where-Object { [int]$_.InterfaceIndex -eq $best.Index })
                        if ($adapters.Count -gt 0) {
                            $a = $adapters[0]
                            $na = @($a.NetworkAddresses)   # prazan niz + Set-StrictMode: @()[0] baca iznimku, pa se indeksira tek uz provjeru
                            if ($na.Count -gt 0) { $mac = Format-InvMac $na[0] }
                            if ($null -eq $mac) { $mac = Format-InvMac $a.PermanentAddress }
                            if ($null -eq $mac) { $mac = Format-InvMac $a.LinkLayerAddress }
                        }
                    } catch { $mac = $null }
                }
            }
        } catch { }

        if ($null -ne $mac -and $null -ne $ip) { return [pscustomobject]@{ Mac = $mac; Ip = $ip } }

        # Nadopuna / rezerva: nedostajuće vrijednosti iz Win32_NetworkAdapterConfiguration (isti InterfaceIndex ako je poznat).
        try {
            $fb = Get-InvNetworkFallback $chosen
            if ($null -ne $fb) {
                if ($null -eq $mac) { $mac = $fb.Mac }
                if ($null -eq $ip) { $ip = $fb.Ip }
            }
        } catch { }

        # Odabrani adapter nije dao ništa: opća rezerva (adapter s IPv4 zadanim prolazom i najnižom metrikom).
        if ($null -eq $mac -and $null -eq $ip -and $null -ne $chosen) {
            try {
                $fb = Get-InvNetworkFallback $null
                if ($null -ne $fb) { $mac = $fb.Mac; $ip = $fb.Ip }
            } catch { }
        }

        if ($null -ne $mac -or $null -ne $ip) { return [pscustomobject]@{ Mac = $mac; Ip = $ip } }
        return $null
    }

    # Prijateljsko ime Office paketa iz ProductReleaseIds (Click-to-Run); $null ako nema paketa.
    # Prvi prolaz: prvi ID koji je poznati paket (neovisno o redoslijedu, jer ID-evi jednoaplikacijskih proizvoda mogu stajati ispred).
    # Drugi prolaz (samo ako nijedan nije poznati paket): prvi preostali ID, sirov. Visio/Project/Access/jezični paketi i
    # OneNote/Skype/Teams/SharePointDesigner ID-evi se preskaču u oba prolaza.
    # Samostalna (bez pomoćnih funkcija): EEA inačice bez Teamsa ("...EEANoTeams...", tržište EGP-a, pa i Hrvatska)
    # mapiraju se kao osnovni paket.
    function Get-InvOfficeSuiteName {
        param([string]$ReleaseIds)
        $skip = '^(Visio|Project|Access|LanguagePack|Language|ProofingTools|Proofing|Proof|OneNote|Skype|Lync|Teams|SharePointDesigner)'
        $ic = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'   # neovisno o kulturi (npr. tr-TR: I/i)
        # Poznati ID -> ime, inače $null.
        $resolve = {
            param([string]$Id)
            $norm = [regex]::Replace($Id, '(EEA)?NoTeams', '', $ic)
            if ($norm -ieq 'O365ProPlusRetail') { return 'Microsoft 365 Apps for enterprise' }
            if ($norm -match '^O365(Business|SmallBusPrem)Retail$') { return 'Microsoft 365 Apps for business' }
            if ($norm -ieq 'O365HomePremRetail') { return 'Microsoft 365 Family/Personal' }
            if ($norm -ieq 'O365EduCloudRetail') { return 'Microsoft 365 Apps for education' }
            $m = [regex]::Match($norm, '^(ProPlus|Standard|HomeBusiness|HomeStudent|Professional|Personal)(\d{4})?(Retail|Volume)$', $ic)
            if ($m.Success) {
                $year = $m.Groups[2].Value
                switch ($m.Groups[1].Value.ToLowerInvariant()) {
                    'proplus'      { $kind = 'Professional Plus' }
                    'standard'     { $kind = 'Standard' }
                    'homebusiness' { $kind = 'Home & Business' }
                    'homestudent'  { $kind = 'Home & Student' }
                    'professional' { $kind = 'Professional' }
                    default        { $kind = 'Personal' }
                }
                if ($year.Length -gt 0) { return ('Office ' + $year + ' ' + $kind) }
                return ('Office ' + $kind)
            }
            $m = [regex]::Match($norm, '^Home(\d{4})Retail$', $ic)
            if ($m.Success) { return ('Office ' + $m.Groups[1].Value + ' Home') }
            $m = [regex]::Match($norm, '^Mondo(\d{4})?(Retail|Volume)$', $ic)
            if ($m.Success) {
                if ($m.Groups[1].Value.Length -gt 0) { return ('Office ' + $m.Groups[1].Value + ' Mondo') }
                return 'Office Mondo'
            }
            return $null
        }
        $firstRaw = $null
        foreach ($raw in ([string]$ReleaseIds -split '[,;]')) {
            $id = $raw.Trim()
            if ($id.Length -eq 0) { continue }
            if ($id -match $skip) { continue }
            $name = & $resolve $id
            if ($null -ne $name) { return $name }
            if ($null -eq $firstRaw) { $firstRaw = $id }
        }
        return $firstRaw   # nepoznat ID: sirovi ID (ili $null kad nema nijednog)
    }

    # MSI Office: prvi paket po imenu ("Microsoft Office ..."), bez jezičnih/pomoćnih komponenti i pojedinačnih aplikacija;
    # verzija (DisplayVersion) se dodaje u zagradi ako je naziv već ne sadrži.
    function Get-InvMsiOfficeName {
        param($Entries)
        $skip = 'Proof|Language|MUI|Shared|Components?|Add-in|Viewer|Compatibility|Interop|Connector|Primary|Click-to-Run|Update|Service Pack|Runtime|Web Components|Snapshot|Access|Visio|Project|InfoPath|SharePoint|Lync|Communicator|OneNote|Groove|Excel|Word|PowerPoint|Outlook|Publisher'
        $msi = New-Object 'System.Collections.Generic.List[object]'
        foreach ($e in @($Entries)) {
            if ($e.SystemComponent -or $e.Parent) { continue }
            $n = ConvertTo-CleanText $e.Name
            if ($null -eq $n) { continue }
            if ($n -match '^Microsoft Office' -and $n -notmatch $skip) { $msi.Add([pscustomobject]@{ Name = $n; Version = (ConvertTo-CleanText $e.Version) }) }
        }
        if ($msi.Count -eq 0) { return $null }
        $names = New-Object 'string[]' $msi.Count
        for ($i = 0; $i -lt $msi.Count; $i++) { $names[$i] = $msi[$i].Name }
        [System.Array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
        $first = $null
        foreach ($m in $msi) { if ([string]::Equals($m.Name, $names[0], [System.StringComparison]::OrdinalIgnoreCase)) { $first = $m; break } }
        $text = $first.Name
        if ($null -ne $first.Version -and $first.Name.IndexOf($first.Version, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $text = $text + ' (' + $first.Version + ')'
        }
        return $text
    }

    # Stvarno ugrađeni RAM u bajtovima (kernel32!GetPhysicallyInstalledSystemMemory, vrijednost iz SMBIOS-a koju Windows prikazuje
    # kao "Installed RAM"). Samo čitanje; P/Invoke se gradi u memoriji (Reflection.Emit), bez Add-Type/csc i bez privremenih datoteka.
    # Poziva se samo kad nema DIMM podataka. $null ako API nije dostupan (VM bez SMBIOS memorije, Constrained Language Mode...).
    function Get-InvInstalledRamBytes {
        try {
            $an = New-Object System.Reflection.AssemblyName ('AuxInvNative' + [guid]::NewGuid().ToString('N'))
            $asm = [System.AppDomain]::CurrentDomain.DefineDynamicAssembly($an, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
            $mod = $asm.DefineDynamicModule($an.Name)
            $tb = $mod.DefineType('NativeRam', [System.Reflection.TypeAttributes]'Public, Class')
            $mb = $tb.DefinePInvokeMethod('GetPhysicallyInstalledSystemMemory', 'kernel32.dll',
                [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
                [System.Reflection.CallingConventions]::Standard,
                [bool], [type[]]@([uint64].MakeByRefType()),
                [System.Runtime.InteropServices.CallingConvention]::Winapi,
                [System.Runtime.InteropServices.CharSet]::Auto)
            $mb.SetImplementationFlags($mb.GetMethodImplementationFlags() -bor [System.Reflection.MethodImplAttributes]::PreserveSig)
            $nt = $tb.CreateType()
            $callArgs = [object[]]@([uint64]0)
            $ok = $nt.GetMethod('GetPhysicallyInstalledSystemMemory').Invoke($null, $callArgs)
            if ($ok -eq $true -and [uint64]$callArgs[0] -gt 0) { return ([decimal][uint64]$callArgs[0] * 1024) }
        } catch { }
        return $null
    }

    # ------------------------------ prikupljanje ------------------------------

    try {
        try { $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64) } catch { $hklm = $null }

        # warrantyUntil se ne može prikupiti; hostname = $env:COMPUTERNAME
        Set-InvField 'warrantyUntil' $null
        $hostname = ConvertTo-CleanText $env:COMPUTERNAME
        if ($null -eq $hostname) { try { $hostname = ConvertTo-CleanText ([System.Environment]::MachineName) } catch { } }
        Set-InvField 'hostname' $hostname

        # --- Proizvođač i model (Win32_ComputerSystem; objekt služi i kao rezerva za RAM / kategoriju) ---
        $cs = $null
        try { $cs = @(Invoke-InvCim 'Win32_ComputerSystem' -Property @('Manufacturer', 'Model', 'TotalPhysicalMemory', 'PCSystemType'))[0] } catch { $cs = $null }
        $manufacturer = $null
        $model = $null
        try { if ($null -ne $cs) { $manufacturer = ConvertTo-CleanText $cs.Manufacturer -Placeholder } } catch { }
        try { if ($null -ne $cs) { $model = ConvertTo-CleanText $cs.Model -Placeholder } } catch { }
        Set-InvField 'manufacturer' $manufacturer
        Set-InvField 'model' $model

        # --- Serijski broj (samo Win32_BIOS) ---
        $serial = $null
        try { $serial = ConvertTo-CleanText (@(Invoke-InvCim 'Win32_BIOS' -Property @('SerialNumber'))[0]).SerialNumber -Placeholder } catch { $serial = $null }
        Set-InvField 'serialNumber' $serial

        # --- Operacijski sustav ---
        $os = $null
        try { $os = @(Invoke-InvCim 'Win32_OperatingSystem' -Property @('Caption', 'ProductType', 'BuildNumber'))[0] } catch { $os = $null }
        $osText = $null
        try {
            $caption = $null
            if ($null -ne $os) { $caption = ConvertTo-CleanText $os.Caption }
            if ($null -eq $caption) {
                $caption = Get-InvRegText 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'ProductName'
                $bn = 0
                if ($null -ne $caption -and $caption -match '^Windows 10' -and
                    [int]::TryParse([string](Get-InvRegText 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild'), [ref]$bn) -and $bn -ge 22000) {
                    $caption = $caption -replace '^Windows 10', 'Windows 11'   # registar za Windows 11 i dalje piše "Windows 10"
                }
            }
            if ($null -ne $caption) {
                $caption = (ConvertTo-CleanText ([regex]::Replace($caption, $trademarkRx, ''))) -replace '^Microsoft\s+', ''
                $dispVer = Get-InvRegText 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
                if ($null -eq $dispVer) { $dispVer = Get-InvRegText 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'ReleaseId' }
                $build = Get-InvRegText 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild'
                if ($null -eq $build) { $build = Get-InvRegText 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' }
                if ($null -eq $build -and $null -ne $os) { $build = ConvertTo-CleanText $os.BuildNumber }
                $osText = $caption
                if ($null -ne $dispVer) { $osText = $osText + ' ' + $dispVer }
                if ($null -ne $build) { $osText = $osText + ' (build ' + $build + ')' }
            }
        } catch { $osText = $null }
        Set-InvField 'operatingSystem' $osText

        # --- Kategorija: Server > kućište (laptop/desktop) > baterija ---
        $category = $null
        try {
            $isServer = $false
            $osKnown = $false
            if ($null -ne $os) {
                if ($null -ne $os.ProductType) { $osKnown = $true; if ([int]$os.ProductType -ne 1) { $isServer = $true } }
                if ([string]$os.Caption -match 'Server') { $osKnown = $true; $isServer = $true }
            }
            if (-not $osKnown) {
                $inst = Get-InvRegText 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'InstallationType'
                $pn = Get-InvRegText 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'ProductName'
                if (($null -ne $inst -and $inst -match 'Server') -or ($null -ne $pn -and $pn -match 'Server')) { $isServer = $true }
            }
            if ($isServer) {
                $category = 'Server'
            } else {
                $chassis = New-Object 'System.Collections.Generic.List[int]'
                try {
                    foreach ($enc in @(Invoke-InvCim 'Win32_SystemEnclosure' -Property @('ChassisTypes'))) {
                        foreach ($t in @($enc.ChassisTypes)) { if ($null -ne $t) { $chassis.Add([int]$t) } }
                    }
                } catch { }
                $laptopTypes = @(8, 9, 10, 11, 14, 30, 31, 32)
                $desktopTypes = @(3, 4, 5, 6, 7, 13, 15, 16, 23, 24, 34, 35, 36)
                $isLaptop = $false
                $isDesktop = $false
                foreach ($t in $chassis) {
                    if ($laptopTypes -contains $t) { $isLaptop = $true }
                    if ($desktopTypes -contains $t) { $isDesktop = $true }
                }
                if ($isLaptop) {
                    $category = $catLaptop
                } elseif ($isDesktop) {
                    $category = $catDesktop     # i kad postoji Win32_Battery (UPS na desktopu)
                } else {
                    # Kućište Other/Unknown/nepoznato: baterija => laptop, inače desktop.
                    $battery = $null
                    try { $battery = @(Invoke-InvCim 'Win32_Battery' -Property @('Name')).Count } catch { $battery = $null }
                    if ($null -ne $battery) {
                        if ($battery -gt 0) { $category = $catLaptop } else { $category = $catDesktop }
                    } elseif ($null -ne $cs -and $null -ne $cs.PCSystemType) {
                        if (@(2, 8) -contains [int]$cs.PCSystemType) { $category = $catLaptop }
                        elseif ([int]$cs.PCSystemType -gt 0) { $category = $catDesktop }
                    }
                }
            }
        } catch { $category = $null }
        Set-InvField 'category' $category

        # --- Procesor (prvi) ---
        $cpu = $null
        try { $cpu = ConvertTo-CleanText (@(Invoke-InvCim 'Win32_Processor' -Property @('Name'))[0]).Name } catch { $cpu = $null }
        if ($null -eq $cpu) {
            try {
                $ck = $hklm.OpenSubKey('HARDWARE\DESCRIPTION\System\CentralProcessor\0')
                if ($null -ne $ck) { try { $cpu = ConvertTo-CleanText $ck.GetValue('ProcessorNameString') } finally { $ck.Close() } }
            } catch { $cpu = $null }
        }
        Set-InvField 'cpu' $cpu

        # --- RAM i tip RAM-a ---
        $ram = $null
        $ramType = $null
        $dimms = @()
        try { $dimms = @(Invoke-InvCim 'Win32_PhysicalMemory' -Property @('Capacity', 'SMBIOSMemoryType')) } catch { $dimms = @() }
        try {
            $sum = [decimal]0
            foreach ($d in $dimms) {
                try { if ($null -ne $d.Capacity) { $sum += [decimal]$d.Capacity } } catch { }   # neispravan element ne ruši cijeli zbroj (isto uz Set-StrictMode)
            }
            if ($sum -le 0) {
                # Nema DIMM podataka: najprije stvarno ugrađeni RAM (API), zatim TotalPhysicalMemory (točan na VM-u, na fizičkom
                # računalu umanjen za hardverski rezerviranu memoriju, npr. 62 GB umjesto 64 GB).
                # API vrijednost se prihvaća samo ako je uvjerljiva: ugrađeno ne može biti manje od iskoristivog (TotalPhysicalMemory),
                # a ni preko dvostruko veće (VM sa SMBIOS-om koji ne odgovara stvarnoj memoriji); inače vrijedi TotalPhysicalMemory.
                $installed = Get-InvInstalledRamBytes
                $usable = $null
                try { if ($null -ne $cs -and $null -ne $cs.TotalPhysicalMemory) { $usable = [decimal]$cs.TotalPhysicalMemory } } catch { $usable = $null }
                if ($null -ne $installed -and $installed -gt 0 -and ($null -eq $usable -or $usable -le 0 -or ($installed -ge $usable * [decimal]0.99 -and $installed -le $usable * 2))) { $sum = [decimal]$installed }
                elseif ($null -ne $usable) { $sum = $usable }
            }
            if ($sum -gt 0) {
                $gbRam = [math]::Round($sum / [decimal]1GB, 0, [System.MidpointRounding]::AwayFromZero)
                if ($gbRam -lt 1) { $gbRam = 1 }
                $ram = ([int]$gbRam).ToString() + ' GB'
            }
        } catch { $ram = $null }
        Set-InvField 'ram' $ram
        try {
            $typeMap = @{ 24 = 'ddr3'; 26 = 'ddr4'; 34 = 'ddr5'; 30 = 'lpddr4'; 35 = 'lpddr5' }
            $order = New-Object 'System.Collections.Generic.List[string]'
            $counts = @{}
            foreach ($d in $dimms) {
                $t = 0
                try { if ($null -ne $d.SMBIOSMemoryType) { $t = [int]$d.SMBIOSMemoryType } } catch { $t = 0 }
                if ($t -eq 0 -or $t -eq 2) { continue }    # nema podatka / 0 / 2 (Unknown) -> izostavi
                if ($typeMap.ContainsKey($t)) { $label = [string]$typeMap[$t] } else { $label = 'ostalo' }
                if (-not $counts.ContainsKey($label)) { $counts[$label] = 0; $order.Add($label) }
                $counts[$label] = [int]$counts[$label] + 1
            }
            $bestCount = 0
            foreach ($label in $order) {
                if ([int]$counts[$label] -gt $bestCount) { $bestCount = [int]$counts[$label]; $ramType = $label }
            }
        } catch { $ramType = $null }
        Set-InvField 'ramType' $ramType     # $null => New-InventoryResult izostavlja ključ

        # --- Disk sistemskog pogona ---
        $stType = $null
        $stCap = $null
        try {
            $disk = Get-InvSystemDisk
            if ($null -ne $disk) { $stType = $disk.Type; $stCap = $disk.Capacity }
        } catch { $stType = $null; $stCap = $null }
        Set-InvField 'storageType' $stType
        Set-InvField 'storageCapacity' $stCap

        # --- Mreža (adapter sa zadanim putem) ---
        $mac = $null
        $ipAddr = $null
        try {
            $net = Get-InvNetwork
            if ($null -ne $net) { $mac = $net.Mac; $ipAddr = $net.Ip }
        } catch { $mac = $null; $ipAddr = $null }
        Set-InvField 'macAddress' $mac
        Set-InvField 'ipAddress' $ipAddr

        # --- Antivirus (root\SecurityCenter2; na serverima prostor imena ne postoji) ---
        $av = $null
        try {
            $avNames = New-Object 'System.Collections.Generic.List[string]'
            foreach ($p in @(Invoke-InvCim 'AntiVirusProduct' 'root/SecurityCenter2' -Property @('displayName'))) {
                $n = ConvertTo-CleanText $p.displayName
                if ($null -ne $n -and -not $avNames.Contains($n)) { $avNames.Add($n) }
            }
            foreach ($n in $avNames) {
                if ($n -notmatch 'Windows Defender|Microsoft Defender') { $av = $n; break }
            }
            if ($null -eq $av -and $avNames.Count -gt 0) { $av = $avNames[0] }
        } catch { $av = $null }
        Set-InvField 'antivirus' $av

        # --- Office i instalirani programi (Uninstall grane) ---
        $hklmEntries = New-Object 'System.Collections.Generic.List[object]'
        try {
            foreach ($e in @(Get-InvUninstallEntries $hklm $uninstallSub)) { $hklmEntries.Add($e) }
            foreach ($e in @(Get-InvUninstallEntries $hklm $uninstallSub32)) { $hklmEntries.Add($e) }
        } catch { }

        $office = $null
        try {
            $c2rVersion = $null
            $c2rIds = $null
            foreach ($path in @('SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration')) {
                $ids = Get-InvRegText $path 'ProductReleaseIds'
                if ($null -ne $ids) {
                    $c2rIds = $ids
                    $c2rVersion = Get-InvRegText $path 'VersionToReport'
                    if ($null -eq $c2rVersion) { $c2rVersion = Get-InvRegText $path 'ClientVersionToReport' }
                    break
                }
            }
            if ($null -ne $c2rIds) {
                $suite = Get-InvOfficeSuiteName $c2rIds
                if ($null -ne $suite) {
                    if ($null -ne $c2rVersion) { $office = $suite + ' (' + $c2rVersion + ')' } else { $office = $suite }
                }
            }
            if ($null -eq $office) { $office = Get-InvMsiOfficeName $hklmEntries.ToArray() }
        } catch { $office = $null }
        Set-InvField 'officeVersion' $office

        # installedApps: najprije samo HKLM (djelomični rezultat ako zapne razrješavanje korisnika), zatim dodaje korisnički hive.
        $apps = [string[]]@()
        try {
            $apps = [string[]]@(Get-InvAppNames $hklmEntries.ToArray())
            Set-InvField 'installedApps' $apps
        } catch { $apps = [string[]]@() }

        try {
            $userBase = $null
            $userPath = $null
            $consoleText = ConvertTo-CleanText $ConsoleUser
            if ($null -ne $consoleText) {
                try {
                    $sid = (New-Object System.Security.Principal.NTAccount($consoleText)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                    $hku = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Registry64)
                    $probe = $hku.OpenSubKey($sid)
                    if ($null -ne $probe) {
                        $probe.Close()
                        $userBase = $hku
                        $userPath = $sid + '\' + $uninstallUser
                    }
                } catch { $userBase = $null; $userPath = $null }
            }
            if ($null -eq $userBase) {
                $hkcu = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
                $userBase = $hkcu
                $userPath = $uninstallUser
            }
            $all = New-Object 'System.Collections.Generic.List[object]'
            foreach ($e in $hklmEntries) { $all.Add($e) }
            foreach ($e in @(Get-InvUninstallEntries $userBase $userPath)) { $all.Add($e) }
            $apps = [string[]]@(Get-InvAppNames $all.ToArray())
        } catch { }
        Set-InvField 'installedApps' $apps
    } catch {
        # nikad ne propuštamo iznimku; što je prikupljeno već je u $dev
    } finally {
        foreach ($rk in @($hklm, $hku, $hkcu)) { try { if ($null -ne $rk) { $rk.Close() } } catch { } }
    }

    try {
        return (New-InventoryResult -Company $Company -ConsoleUser $ConsoleUser -ToolVersion $ToolVersion -Device $dev)
    } catch {
        return $null
    }
}

# Prikuplja podatke u zasebnom runspaceu (isti obrazac kao Get-SystemInfoItemsAsync): sučelje se pumpa dok se čeka, a pri isteku vremena
# ili prekidu vraća se ono što je do tada upisano u DeviceSink. Vraća @{ Data; Partial } ili $null ako je korisnik prekinuo zadatak.
function Get-InventoryDataAsync {
    param([AllowNull()][AllowEmptyString()][string]$Company, [int]$TimeoutSeconds = 60)

    $rs        = $null
    $ps        = $null
    $abandoned = $false
    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($name in @('New-InventoryResult', 'Get-InventoryData')) {
            $body = (Get-Item -LiteralPath ('function:' + $name)).ScriptBlock.ToString()
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($name, $body)))
        }
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $sink = [hashtable]::Synchronized(@{})
        $consoleUser = [string](Get-ConsoleUser)
        [void]$ps.AddCommand('Get-InventoryData').AddParameter('Company', $Company).AddParameter('ConsoleUser', $consoleUser).AddParameter('ToolVersion', $script:AppVersion).AddParameter('DeviceSink', $sink)
        $async = $ps.BeginInvoke()

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $async.IsCompleted) {
            $stop = Test-StopRequested
            if ($stop -or $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                # Zapeti WMI/CIM upit drži runspace živim: napušta se (proces se na kraju završava silom, vidi MAIN).
                $abandoned = $true
                $script:AbandonedRunspace = $true
                try { [void]$ps.BeginStop($null, $null) } catch { }
                if ($stop) { return $null }
                $device = @{}
                foreach ($key in @($sink.Keys)) { $device[$key] = $sink[$key] }
                $partial = New-InventoryResult -Company $Company -ConsoleUser $consoleUser -ToolVersion $script:AppVersion -Device $device
                return [pscustomobject]@{ Data = $partial; Partial = $true }
            }
            Update-Ui
            Start-Sleep -Milliseconds 25
        }
        $output = @($ps.EndInvoke($async))
        foreach ($streamError in $ps.Streams.Error) { Write-AppLog 'Warn' 'Prikupljanje inventara (runspace)' $streamError }
        $data = $null
        foreach ($item in $output) {
            if ($item -is [System.Collections.IDictionary]) { $data = $item }
        }
        if ($null -eq $data) { throw 'Prikupljanje podataka nije vratilo rezultat.' }
        return [pscustomobject]@{ Data = $data; Partial = $false }
    } finally {
        if (-not $abandoned) {
            try { if ($null -ne $ps) { $ps.Dispose() } } catch { }
            try { if ($null -ne $rs) { $rs.Dispose() } } catch { }
        }
    }
}

function ConvertTo-InventoryJson {
    param($Data)
    # -InputObject (ne cijev): u Windows PowerShellu 5.1 cijev bi raspakirala polja i jednoelementno polje postalo bi običan niz znakova.
    return (ConvertTo-Json -InputObject $Data -Depth 6)
}

# Prikuplja podatke i zapisuje JSON (UTF-8 bez BOM-a) u zadanu putanju; kratka privremena datoteka pa preimenovanje, kao i kod PDF-a.
# Vraća FileInfo ili $null (prekid). Iznimke (nedostupan stick, preduga putanja) prosljeđuje pozivatelju.
function Export-InventoryJson {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][AllowEmptyString()][string]$Company)

    # Granica je 259 (a ne 258 kao kod PDF-a): .json je za jedan znak duži od .pdf, pa uz PDF od 258 znakova JSON mora stati.
    if ($Path.Length -gt 259) { throw ('Putanja JSON datoteke je preduga ({0} znakova, najviše 259): {1}. Skratite naziv tvrtke ili pokrenite alat s mjesta bliže korijenu pogona.' -f $Path.Length, $Path) }
    Write-Terminal '  Prikupljam podatke za IT Inventar (uređaj, sustav, Office, antivirus, mreža, programi)...' 'Info'
    $result = Get-InventoryDataAsync -Company $Company
    if ($null -eq $result) { return $null }
    if ($result.Partial) { Write-Terminal '  Prikupljanje je isteklo (WMI/CIM ne odgovara): u JSON su upisani samo podaci prikupljeni do tada.' 'Warn' }

    $json = ConvertTo-InventoryJson $result.Data
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
    $stage = [System.IO.Path]::Combine($directory, ('.aux-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 8)))
    try {
        [System.IO.File]::WriteAllText($stage, $json, (New-Object System.Text.UTF8Encoding($false)))
        # Antivirus / indeksiranje znaju nakratko zaključati tek zapisanu datoteku: kao i kod PDF-a, 5 pokušaja u razmaku od 200 ms.
        $moved = $false
        $lastError = $null
        for ($attempt = 0; $attempt -lt 5 -and -not $moved; $attempt++) {
            try {
                if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
                [System.IO.File]::Move($stage, $Path)
                $moved = $true
            } catch {
                $lastError = $_
                Update-Ui
                Start-Sleep -Milliseconds 200
            }
        }
        if (-not $moved) {
            throw ('JSON datoteku nije moguće zapisati (zaključana ili zaštićena od pisanja): {0}' -f $lastError.Exception.GetBaseException().Message)
        }
    } finally {
        Remove-FileQuiet -Path $stage
    }
    return (Get-Item -LiteralPath $Path)
}

# Gumb "Izvezi JSON": isti JSON kao uz PDF, ali bez generiranja PDF-a; sprema se u mapu tvrtke pod istim obrascem imena.
function Invoke-InventoryExportTask {
    if ($null -ne $script:UI.CompanyBox) { Set-ActiveCompany $script:UI.CompanyBox.Text }
    $company       = Get-ActiveCompany
    $folderCompany = $company
    if ([string]::IsNullOrWhiteSpace($company)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:UI.Form,
            ('Tvrtka / klijent nije postavljena (polje na vrhu prozora).' + [Environment]::NewLine + [Environment]::NewLine +
             'Želite li JSON spremiti u mapu "Nerazvrstano"?' + [Environment]::NewLine +
             '(Ne = povratak na unos tvrtke.)'),
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Terminal 'Izvoz JSON-a je otkazan: upišite tvrtku / klijenta u polje na vrhu.' 'Warn'
            $script:FocusCompanyBox = $true
            $script:TaskNoResult    = $true
            return
        }
        $folderCompany = 'Nerazvrstano'
        $company       = $null
    }

    $folder   = Get-CompanyFolder $folderCompany
    $fileName = [System.IO.Path]::ChangeExtension((Get-ReportFileName), 'json')
    $path     = [System.IO.Path]::Combine($folder, $fileName)
    $tooLong  = 'Putanja JSON datoteke je preduga ({0} znakova, najviše 259): {1}. Skratite naziv tvrtke ili pokrenite alat s mjesta bliže korijenu pogona.'
    if ($path.Length -gt 259) { throw ($tooLong -f $path.Length, $path) }
    $problem = Test-FolderWritable $folder
    if ($problem) {
        throw ('U mapu za izvještaje nije moguće pisati: {0} ({1}). Provjerite je li stick umetnut, nije li zaštićen od pisanja i postoji li pogon na kojem se nalazi mapa izvještaja.' -f $folder, $problem)
    }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $suffix   = 2
    while (Test-Path -LiteralPath $path) {
        $path = [System.IO.Path]::Combine($folder, ('{0}_{1}.json' -f $baseName, $suffix))
        $suffix++
    }
    if ($path.Length -gt 259) { throw ($tooLong -f $path.Length, $path) }

    Write-Terminal ('Izvozim JSON: {0}' -f $path) 'Info'
    $file = Export-InventoryJson -Path $path -Company $company
    if ($null -eq $file) {
        Write-Terminal 'Izvoz JSON-a je prekinut.' 'Warn'
        return
    }
    Write-Terminal ('JSON je spremljen ({0}): {1}' -f (Format-Bytes ([double]$file.Length)), $file.FullName) 'Ok'
}
#endregion EXPORT

