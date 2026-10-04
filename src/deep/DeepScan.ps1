$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$wuItems = New-Object System.Collections.Generic.List[object]
$evItems = New-Object System.Collections.Generic.List[object]
$swItems = New-Object System.Collections.Generic.List[object]
$secItems = New-Object System.Collections.Generic.List[object]
$global:target = $evItems
$stdout = [Console]::OpenStandardOutput()
$utf8   = New-Object System.Text.UTF8Encoding($false)

function Add-Item {
    param([string]$Kind, [string]$Label = '', [string]$Value = '', [string]$Status = 'Normal')
    $global:target.Add([pscustomobject]@{ Kind = $Kind; Label = $Label; Value = $Value; Status = $Status })
}
function Get-Clean {
    param([string]$Text, [int]$Max = 150)
    $t = ($Text -replace '[\x00-\x1F]+', ' ' -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 1) + '...' }
    return $t
}
function Get-HrPlural {
    param([int]$n, [string]$one, [string]$few, [string]$many)
    $a = $n % 10
    $b = $n % 100
    if     ($a -eq 1 -and $b -ne 11)                               { return $one }
    elseif ($a -ge 2 -and $a -le 4 -and ($b -lt 12 -or $b -gt 14)) { return $few }
    else                                                           { return $many }
}
# Svaki redak izlaza je KUMULATIVNI popis stavki (jedan JSON po retku): ako roditelj prekine proces zbog isteka vremena,
# zadnji potpuno ispisani redak (npr. dnevnici događaja) i dalje se koristi.
function Send-Items {
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($i in $secItems) { $all.Add($i) }
    if (-not $grpDone.sec) {
        if ($secItems.Count -eq 0) { $all.Add([pscustomobject]@{ Kind = 'Section'; Label = ''; Value = 'SIGURNOST'; Status = 'Normal' }) }
        $all.Add([pscustomobject]@{ Kind = 'Text'; Label = ''; Value = 'Sigurnosna provjera nije dovršena u zadanom roku; prikazani podaci su djelomični ili nedostaju.'; Status = 'Warn' })
    }
    foreach ($i in $swItems) { $all.Add($i) }
    if (-not $grpDone.sw) {
        if ($swItems.Count -eq 0) { $all.Add([pscustomobject]@{ Kind = 'Section'; Label = ''; Value = 'SOFTVER I LICENCE'; Status = 'Normal' }) }
        $all.Add([pscustomobject]@{ Kind = 'Text'; Label = ''; Value = 'Prikupljanje softvera nije dovršeno u zadanom roku; prikazani podaci su djelomični ili nedostaju.'; Status = 'Warn' })
    }
    foreach ($i in $wuItems) { $all.Add($i) }
    if (-not $grpDone.wu) {
        if ($wuItems.Count -eq 0) { $all.Add([pscustomobject]@{ Kind = 'Section'; Label = ''; Value = 'WINDOWS UPDATE'; Status = 'Normal' }) }
        $all.Add([pscustomobject]@{ Kind = 'Text'; Label = ''; Value = 'Pretraga Windows Updatea nije dovršena u zadanom roku; prikazani podaci su djelomični ili nedostaju.'; Status = 'Warn' })
    }
    foreach ($i in $evItems) { $all.Add($i) }
    if ($all.Count -eq 0) { return }
    $json  = $all.ToArray() | ConvertTo-Json -Compress -Depth 4
    $bytes = $utf8.GetBytes($json + "`n")
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Add-Version {
    param([string]$Text, [string]$Version, [string]$Sep = '  ')
    if ([string]::IsNullOrWhiteSpace($Version)) { return $Text }
    $v = $Version.Trim()
    if ($Text -match ('(?<![0-9A-Za-z.])' + [regex]::Escape($v) + '(?![0-9A-Za-z]|\.[0-9])')) { return $Text }
    return ($Text + $Sep + $v)
}
$grpDone = @{ sec = $false; sw = $false; wu = $false }

function Get-IndicatorEvents {
    param([hashtable]$Filter)
    try { return ,@(Get-WinEvent -FilterHashtable $Filter -MaxEvents 2000 -ErrorAction SilentlyContinue) } catch { return ,@() }
}
function Format-Count {
    param([int]$n)
    if ($n -ge 2000) { return '2000+' }
    return [string]$n
}
$since    = (Get-Date).AddDays(-7)
$sinceUtc = $since.ToUniversalTime()

# ---------------- Dnevnici događaja (7 dana) ----------------
$global:target = $evItems
Add-Item 'Section' '' 'DNEVNICI DOGAĐAJA (ZADNJIH 7 DANA)'
try {
    foreach ($log in @('System', 'Application')) {
        $crit = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1; StartTime = $since } -MaxEvents 1000 -ErrorAction SilentlyContinue)
        $errs = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 2; StartTime = $since } -MaxEvents 3000 -ErrorAction SilentlyContinue)
        $total  = $crit.Count + $errs.Count
        $status = 'Good'
        if ($crit.Count -gt 0) { $status = 'Bad' } elseif ($errs.Count -gt 0) { $status = 'Warn' }
        $critText = [string]$crit.Count
        if ($crit.Count -ge 1000) { $critText = '1000+' }
        $errText = [string]$errs.Count
        if ($errs.Count -ge 3000) { $errText = '3000+' }
        Add-Item 'KV' $log ('kritičnih: {0}, grešaka: {1}' -f $critText, $errText) $status

        if ($total -gt 0) {
            $groups = (@($crit) + @($errs)) | Group-Object -Property { '{0}|{1}' -f $_.ProviderName, $_.Id } | Sort-Object Count -Descending | Select-Object -First 6
            foreach ($g in $groups) {
                $first = $g.Group[0]
                $msg = ''
                try { $msg = [string]$first.Message } catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
                if ([string]::IsNullOrWhiteSpace($msg)) { $msg = '(bez opisa)' }
                $line = '{0} (ID {1}): {2}' -f $first.ProviderName, $first.Id, (Get-Clean $msg 120)
                $st = 'Warn'
                if ($first.Level -eq 1) { $st = 'Bad' }
                Add-Item 'KV' ('{0}x' -f $g.Count) $line $st
            }
        }
    }

    # Ključni pokazatelji: svaki ima VLASTITI upit (ne ovise o ograničenom popisu iznad), a pogreška jednog ne ruši ostale.
    $key = Get-IndicatorEvents @{ LogName = 'System'; Id = 41, 6008, 1001; StartTime = $since }
    $unexpected = @($key | Where-Object { $_.Id -eq 41 }).Count
    if ($unexpected -eq 0) { $unexpected = @($key | Where-Object { $_.Id -eq 6008 }).Count }
    $bsod = @($key | Where-Object { $_.Id -eq 1001 -and $_.ProviderName -like '*SystemErrorReporting*' }).Count
    $diskProv = 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'stornvme', 'storahci', 'storport', 'Microsoft-Windows-StorPort', 'volmgr', 'volsnap', 'partmgr'
    $diskErr = (Get-IndicatorEvents @{ LogName = 'System'; ProviderName = $diskProv; Level = 1, 2; StartTime = $since }).Count
    $whea    = (Get-IndicatorEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 1, 2; StartTime = $since }).Count
    $crashEvents = Get-IndicatorEvents @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since }
    $crashApps = @{}
    foreach ($ev in $crashEvents) {
        $m = ''
        try { $m = [string]$ev.Message } catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
        if     ($m -match '(?i)\A\s*[^:\r\n]+:\s*([^,\r\n]+?\.(?:exe|dll))\s*,') { $name = $Matches[1] }
        elseif ($m -match '(?i)([A-Za-z0-9_\-\.]+\.exe)')                          { $name = $Matches[1] }
        else                                                                        { $name = '?' }
        if ($crashApps.ContainsKey($name)) { $crashApps[$name]++ } else { $crashApps[$name] = 1 }
    }

    $s = 'Good'; if ($unexpected -gt 0) { $s = 'Bad' }
    Add-Item 'KV' 'Nepl. gašenja' ('{0}' -f $unexpected) $s
    $s = 'Good'; if ($bsod -gt 0) { $s = 'Bad' }
    Add-Item 'KV' 'BSOD' ('{0}' -f $bsod) $s
    $s = 'Good'; if ($diskErr -gt 0) { $s = 'Bad' }
    Add-Item 'KV' 'Greške diska' (Format-Count $diskErr) $s
    $s = 'Good'; if ($whea -gt 0) { $s = 'Bad' }
    Add-Item 'KV' 'WHEA (hardv.)' (Format-Count $whea) $s
    $s = 'Good'; if ($crashEvents.Count -gt 0) { $s = 'Warn' }
    $crashText = Format-Count $crashEvents.Count
    if ($crashApps.Count -gt 0) {
        $top = $crashApps.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object { '{0} ({1})' -f $_.Key, $_.Value }
        $crashText = '{0}: {1}' -f (Format-Count $crashEvents.Count), ($top -join ', ')
    }
    Add-Item 'KV' 'Rušenja app' $crashText $s
} catch {
    Add-Item 'Text' '' ('Dnevnici događaja nisu dostupni: ' + (Get-Clean $_.Exception.Message 120)) 'Warn'
}
Send-Items

# ---------------- Sigurnost: antivirus, vatrozid, šifriranje diska, SMBv1, RDP ----------------
$global:target = $secItems
Add-Item 'Section' '' 'SIGURNOST'
$thirdPartyAv = $false
$avOn = $false
$enabledProducts = @()
try {
    $avs = $null
    try { $avs = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -OperationTimeoutSec 20 -ErrorAction Stop) } catch { $avs = $null }
    if ($null -ne $avs -and $avs.Count -gt 0) {
        # productState: bit 0x1000 = zaštita uključena, bit 0x10 = definicije zastarjele.
        $enabledProducts = @($avs | Where-Object { ([int]$_.productState -band 0x1000) -ne 0 })
        $avOn = ($enabledProducts.Count -gt 0)
        foreach ($p in $avs) {
            $on = (([int]$p.productState -band 0x1000) -ne 0)
            $avName = Get-Clean ([string]$p.displayName) 60
            if ($on) {
                Add-Item 'KV' 'Antivirus' ($avName + ' - uključen') 'Good'
                if ($avName -notmatch 'Defender') { $thirdPartyAv = $true }
            } elseif ($avOn) {
                Add-Item 'KV' 'Antivirus' ($avName + ' - isključen (aktivan je drugi antivirus)') 'Muted'
            } else {
                Add-Item 'KV' 'Antivirus' ($avName + ' - ISKLJUČEN') 'Bad'
            }
        }
        foreach ($p in $enabledProducts) {
            $avName = Get-Clean ([string]$p.displayName) 60
            $age = $null
            if ($avName -match 'Defender') {
                try { $age = [int](Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureAge } catch { $age = $null }
            }
            if ($null -ne $age) {
                $ds = 'Good'; if ($age -gt 7) { $ds = 'Bad' } elseif ($age -gt 3) { $ds = 'Warn' }
                Add-Item 'KV' 'Definicije' ('{0}: {1} (staro {2} d)' -f $avName, $(if ($ds -eq 'Good') { 'ažurne' } else { 'zastarjele' }), $age) $ds
            } elseif (([int]$p.productState -band 0x10) -ne 0) {
                Add-Item 'KV' 'Definicije' ($avName + ': zastarjele') 'Warn'
            } else {
                Add-Item 'KV' 'Definicije' ($avName + ': ažurne') 'Good'
            }
        }
    } else {
        # Poslužitelji nemaju Security Center: izravno se pita Microsoft Defender.
        $mp = $null
        try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { $mp = $null }
        if ($null -ne $mp -and $mp.AntivirusEnabled) {
            $avOn = $true
            Add-Item 'KV' 'Antivirus' 'Microsoft Defender - uključen' 'Good'
            $age = [int]$mp.AntivirusSignatureAge
            $ds = 'Good'; if ($age -gt 7) { $ds = 'Bad' } elseif ($age -gt 3) { $ds = 'Warn' }
            Add-Item 'KV' 'Definicije' ('Microsoft Defender: {0} (staro {1} d)' -f $(if ($ds -eq 'Good') { 'ažurne' } else { 'zastarjele' }), $age) $ds
        } else {
            Add-Item 'KV' 'Antivirus' 'nije pronađen nijedan uključen antivirus' 'Bad'
        }
    }
} catch {
    Add-Item 'KV' 'Antivirus' ('provjera nije uspjela: ' + (Get-Clean $_.Exception.Message 100)) 'Muted'
}
try {
    $fw = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    $nameHr = @{ Domain = 'domena'; Private = 'privatna'; Public = 'javna' }
    $off = @($fw | Where-Object { [string]$_.Enabled -ne 'True' } | ForEach-Object { if ($nameHr.ContainsKey([string]$_.Name)) { $nameHr[[string]$_.Name] } else { [string]$_.Name } })
    if ($off.Count -eq 0) {
        Add-Item 'KV' 'Vatrozid' 'Windows vatrozid je uključen (domena, privatna, javna)' 'Good'
    } elseif ($thirdPartyAv) {
        Add-Item 'KV' 'Vatrozid' ('Windows vatrozid isključen za: {0} - provjerite vatrozid antivirusa' -f ($off -join ', ')) 'Warn'
    } else {
        $fs = 'Warn'; if ($off.Count -ge 3) { $fs = 'Bad' }
        Add-Item 'KV' 'Vatrozid' ('Windows vatrozid je ISKLJUČEN za: {0}' -f ($off -join ', ')) $fs
    }
} catch {
    Add-Item 'KV' 'Vatrozid' 'provjera nije dostupna' 'Muted'
}
$isLaptop = $false
try {
    $chassis = @((Get-CimInstance -ClassName Win32_SystemEnclosure -OperationTimeoutSec 20 -ErrorAction Stop).ChassisTypes)
    $isLaptop = (@($chassis | Where-Object { @(8, 9, 10, 11, 14, 30, 31, 32) -contains [int]$_ }).Count -gt 0)
} catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
try {
    $sysDrive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($sysDrive)) { $sysDrive = 'C:' }
    $vol = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $sysDrive) -OperationTimeoutSec 20 -ErrorAction Stop
    if ($null -eq $vol) { throw 'nema podataka' }
    $prot = [int](Invoke-CimMethod -InputObject $vol -MethodName GetProtectionStatus -ErrorAction Stop).ProtectionStatus
    if ($prot -eq 1) {
        Add-Item 'KV' 'Šifriranje diska' ('BitLocker je uključen na ' + $sysDrive) 'Good'
    } elseif ($isLaptop) {
        Add-Item 'KV' 'Šifriranje diska' ('Disk ' + $sysDrive + ' nije šifriran (BitLocker isključen) - rizik pri gubitku ili krađi laptopa') 'Warn'
    } else {
        Add-Item 'KV' 'Šifriranje diska' ('Disk ' + $sysDrive + ' nije šifriran (BitLocker isključen)') 'Normal'
    }
} catch {
    Add-Item 'KV' 'Šifriranje diska' 'provjera nije dostupna (izdanje Windowsa bez BitLockera ili nedovoljna prava)' 'Muted'
}
try {
    $smb1 = [bool](Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
    if ($smb1) { Add-Item 'KV' 'SMBv1' 'uključen (zastario i nesiguran protokol)' 'Bad' } else { Add-Item 'KV' 'SMBv1' 'isključen' 'Good' }
} catch {
    Add-Item 'KV' 'SMBv1' 'provjera nije dostupna' 'Muted'
}
try {
    $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction Stop
    if ([int]$ts.fDenyTSConnections -ne 0) {
        Add-Item 'KV' 'RDP' 'isključen' 'Good'
    } else {
        $nla = 0
        try { $nla = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction Stop).UserAuthentication } catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
        if ($nla -eq 1) { Add-Item 'KV' 'RDP' 'uključen (uz NLA: prijava se traži prije veze)' 'Warn' } else { Add-Item 'KV' 'RDP' 'uključen BEZ NLA zaštite' 'Bad' }
    }
} catch {
    Add-Item 'KV' 'RDP' 'provjera nije dostupna' 'Muted'
}
$grpDone.sec = $true
Send-Items

# ---------------- Softver: Office, mail, licence, instalirani programi ----------------
$global:target = $swItems
Add-Item 'Section' '' 'SOFTVER I LICENCE'
$userRoot = 'HKCU:'
$sidText = ''
try {
    if ($env:AUX_CONSOLE_USER) {
        $sidText = (New-Object System.Security.Principal.NTAccount($env:AUX_CONSOLE_USER)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        if (Test-Path ('Registry::HKEY_USERS\' + $sidText)) { $userRoot = 'Registry::HKEY_USERS\' + $sidText } else { $sidText = '' }
    }
} catch { $sidText = '' }
$profilePath = $env:USERPROFILE
if ($sidText) {
    try { $pp = (Get-ItemProperty ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $sidText)).ProfileImagePath; if ($pp) { $profilePath = $pp } } catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
}
$progs = @{}
$hiddenCount = 0
try {
    $uninstallPaths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', ($userRoot + '\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'))
    foreach ($up in $uninstallPaths) {
        foreach ($e in @(Get-ItemProperty -Path $up -ErrorAction SilentlyContinue)) {
            $n = [string]$e.DisplayName
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if ($e.SystemComponent -eq 1 -or $e.ParentKeyName -or $n -match '^(Update for|Security Update|Hotfix)|\bKB\d{6,}|Redistributable|^Windows Driver Package') { $hiddenCount++; continue }
            $progs[($n.ToLower() + '|' + [string]$e.DisplayVersion)] = [pscustomobject]@{ Name = $n.Trim(); Version = ([string]$e.DisplayVersion).Trim() }
        }
    }
} catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }

$lsMap = @{ 0 = 'nelicencirano'; 1 = 'licencirano'; 2 = 'početna odgoda'; 3 = 'odgoda'; 4 = 'odgoda (nelegalna kopija)'; 5 = 'traži se aktivacija'; 6 = 'produljena odgoda' }
try {
    foreach ($l in @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -OperationTimeoutSec 30 -ErrorAction Stop)) {
        $ls = [int]$l.LicenseStatus
        $st = 'Bad'
        if ($ls -eq 1) { $st = 'Good' } elseif ($ls -ge 2) { $st = 'Warn' }
        Add-Item 'KV' 'Windows' ('{0} - {1} (ključ ...{2})' -f (Get-Clean ([string]$l.Name) 50), $lsMap[$ls], $l.PartialProductKey) $st
    }
} catch { Add-Item 'Text' '' 'Upit licence Windowsa nije uspio ili je istekao.' 'Muted' }

$appNames = [ordered]@{ Word = 'WINWORD.EXE'; Excel = 'EXCEL.EXE'; Outlook = 'OUTLOOK.EXE'; PowerPoint = 'POWERPNT.EXE'; OneNote = 'ONENOTE.EXE'; Access = 'MSACCESS.EXE'; Publisher = 'MSPUB.EXE'; Visio = 'VISIO.EXE'; Project = 'WINPROJ.EXE' }
$officeRoot = ''
$c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
if ($c2r -and $c2r.VersionToReport) {
    $rel = [string]$c2r.ProductReleaseIds
    $name = $rel
    if     ($rel -match 'O365ProPlusRetail')   { $name = 'Microsoft 365 Apps for enterprise' }
    elseif ($rel -match 'O365BusinessRetail')  { $name = 'Microsoft 365 Apps for business' }
    elseif ($rel -match 'O365HomePremRetail')  { $name = 'Microsoft 365 Family/Personal' }
    elseif ($rel -match 'ProPlus(\d{4})')      { $name = 'Office ' + $Matches[1] + ' Professional Plus' }
    elseif ($rel -match 'Standard(\d{4})')     { $name = 'Office ' + $Matches[1] + ' Standard' }
    elseif ($rel -match 'HomeBusiness(\d{4})') { $name = 'Office ' + $Matches[1] + ' Home & Business' }
    elseif ($rel -match 'HomeStudent(\d{4})')  { $name = 'Office ' + $Matches[1] + ' Home & Student' }
    Add-Item 'KV' 'Office' ('{0} [{1}]' -f $name, $rel)
    Add-Item 'KV' 'Office verzija' ('{0} ({1})' -f $c2r.VersionToReport, $c2r.Platform)
    $chMap = @{ '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'; '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'; '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'; '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'; 'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise Channel (Preview)'; '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta Channel' }
    $cdn = [string]$c2r.CDNBaseUrl
    if (-not $cdn) { $cdn = [string]$c2r.UpdateChannel }
    if ($cdn -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
        $g = $Matches[1].ToLower()
        $channel = $g
        if ($chMap.ContainsKey($g)) { $channel = $chMap[$g] }
        Add-Item 'KV' 'Office kanal' $channel
    }
    $upd = [string]$c2r.UpdatesEnabled
    if ($upd -eq 'False') { Add-Item 'KV' 'Office update' 'automatska ažuriranja su ISKLJUČENA' 'Warn' }
    elseif ($upd) { Add-Item 'KV' 'Office update' 'automatska ažuriranja uključena' 'Good' }
    if ($c2r.InstallationPath) { $officeRoot = (([string]$c2r.InstallationPath).TrimEnd('\')) + '\root\Office16' }
} else {
    foreach ($v in @('16.0', '15.0', '14.0', '12.0')) {
        foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Office\', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\')) {
            if ($officeRoot) { break }
            $ir = Get-ItemProperty ($hive + $v + '\Common\InstallRoot') -ErrorAction SilentlyContinue
            if ($ir -and $ir.Path) {
                $cand = ([string]$ir.Path).TrimEnd('\')
                foreach ($x in $appNames.Values) {
                    if (Test-Path -LiteralPath ($cand + '\' + $x)) { $officeRoot = $cand; break }
                }
            }
        }
        if ($officeRoot) { break }
    }
    $msi = @($progs.Values | Where-Object { $_.Name -match '^Microsoft Office' -and $_.Name -notmatch 'Click-to-Run|Proof|Language|MUI|Shared|Components|Add-in|Viewer|Compatibility|Interop|Connector|database engine|Web Components|Live|Communicator|Primary' } | Sort-Object Name | Select-Object -First 3)
    if ($officeRoot -or $msi.Count -gt 0) {
        foreach ($m in $msi) { Add-Item 'KV' 'Office' ((Add-Version (Get-Clean $m.Name 70) $m.Version ' ').Trim()) }
        if ($msi.Count -eq 0) { Add-Item 'KV' 'Office' 'instaliran (MSI), naziv paketa nije pronađen' }
    } else {
        Add-Item 'KV' 'Office' 'nije pronađen'
    }
}
if ($officeRoot) {
    $found = @()
    foreach ($k in $appNames.Keys) { if (Test-Path -LiteralPath ($officeRoot + '\' + $appNames[$k])) { $found += $k } }
    if ($found.Count -gt 0) { Add-Item 'KV' 'Office progr.' ($found -join ', ') }
}
Send-Items
$vnext = $false
try {
    $ln = Get-ItemProperty ($userRoot + '\Software\Microsoft\Office\16.0\Common\Licensing\LicensingNext') -ErrorAction SilentlyContinue
    if ($ln) {
        foreach ($lp in $ln.PSObject.Properties) {
            if ($lp.Name -match '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider|MigrationToV5Done|InstalledGraceKey)$') { continue }
            $iv = 0
            if ([int]::TryParse([string]$lp.Value, [ref]$iv) -and $iv -gt 0) { $vnext = $true }
        }
    }
} catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
$tokenFresh = $false
try {
    $tokDir = $profilePath + '\AppData\Local\Microsoft\Office\Licenses\5'
    if (Test-Path -LiteralPath $tokDir) {
        $tokenFresh = (@(Get-ChildItem -LiteralPath $tokDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-35) }).Count -gt 0)
    }
} catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
try {
    foreach ($l in @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" -OperationTimeoutSec 30 -ErrorAction Stop)) {
        $ls = [int]$l.LicenseStatus
        $st = 'Bad'
        if ($ls -eq 1) { $st = 'Good' } elseif ($ls -ge 2) { $st = 'Warn' }
        $licText = '{0} - {1} (ključ ...{2})' -f (Get-Clean ([string]$l.Name) 50), $lsMap[$ls], $l.PartialProductKey
        if ($ls -ne 1 -and ([string]$l.Name) -match 'O365|365|Subscription') {
            if ($vnext -and $tokenFresh -and ([string]$l.Name) -match '_Grace') {
                # Licenca po korisniku (vNext): strojni zapis "Grace" je samo zamjenski i nije mjerodavan.
                $st = 'Normal'
                $licText = 'pretplata Microsoft 365 (licenca po korisniku, korisnik je prijavljen); strojni zapis "Grace" je uobičajen i nije mjerodavan'
            } else {
                $licText += ' - za pretplatu Microsoft 365 provjerite prijavu u Office račun (Datoteka > Račun)'
            }
        }
        Add-Item 'KV' 'Office licenca' $licText $st
    }
} catch { Add-Item 'Text' '' 'Upit licence Officea nije uspio ili je istekao.' 'Muted' }
Send-Items

Add-Item 'Section' '' 'MAIL KLIJENTI'
$defMail = ''
try {
    $classRoot = 'HKCU:\Software\Classes'
    if ($sidText) { $classRoot = 'Registry::HKEY_USERS\' + $sidText + '_Classes' }
    $assoc = $userRoot + '\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\mailto'
    $mailto = [string](Get-ItemProperty ($assoc + '\UserChoiceLatest\ProgId') -ErrorAction SilentlyContinue).ProgId
    if (-not $mailto) { $mailto = [string](Get-ItemProperty ($assoc + '\UserChoice') -ErrorAction SilentlyContinue).ProgId }
    $mailName = ''
    if ($mailto -like 'AppX*') {
        $aumid = ''
        foreach ($cr in @($classRoot, 'HKLM:\SOFTWARE\Classes')) {
            $aumid = [string](Get-ItemProperty ($cr + '\' + $mailto + '\Application') -ErrorAction SilentlyContinue).AppUserModelID
            if ($aumid) { break }
        }
        if     ($aumid -match 'OutlookForWindows')         { $mailName = 'Novi Outlook' }
        elseif ($aumid -match 'windowscommunicationsapps') { $mailName = 'Windows Pošta' }
        elseif ($aumid)                                    { $mailName = 'Store aplikacija ' + ($aumid -replace '!.*$', '') }
    } elseif ($mailto -match '^Outlook\.URL\.mailto') {
        $mailName = 'klasični Outlook'
    } elseif ($mailto) {
        $mailName = [string](Get-ItemProperty ($classRoot + '\' + $mailto) -ErrorAction SilentlyContinue).'(default)'
        if (-not $mailName) { $mailName = [string](Get-ItemProperty ('HKLM:\SOFTWARE\Classes\' + $mailto) -ErrorAction SilentlyContinue).'(default)' }
        if (-not $mailName) { $mailName = $mailto }
    }
    $mapi = [string](Get-ItemProperty ($userRoot + '\Software\Clients\Mail') -ErrorAction SilentlyContinue).'(default)'
    if (-not $mapi) { $mapi = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Clients\Mail' -ErrorAction SilentlyContinue).'(default)' }
    if ($mailName) {
        $defMail = $mailName
        if ($mapi -and $mailName -ne 'klasični Outlook') { $defMail += ' (MAPI: ' + $mapi + ')' }
    } elseif ($mapi) {
        $defMail = $mapi + ' (MAPI zadani; mailto nije postavljen ili zapis nije valjan)'
    }
} catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
if ($defMail) { Add-Item 'KV' 'Zadani klijent' (Get-Clean $defMail 100) } else { Add-Item 'KV' 'Zadani klijent' 'nije postavljen' }
if ($officeRoot -and (Test-Path -LiteralPath ($officeRoot + '\OUTLOOK.EXE'))) {
    $ov = ''
    try { $ov = (Get-Item -LiteralPath ($officeRoot + '\OUTLOOK.EXE')).VersionInfo.FileVersion } catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
    Add-Item 'KV' 'Outlook' ('klasični, verzija {0}' -f $ov)
}
Send-Items
$apx = @()
$apxOk = $true
try { $apx = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.Name -in 'Microsoft.OutlookForWindows', 'microsoft.windowscommunicationsapps', 'MSTeams' }) } catch { $apxOk = $false }
if ($apxOk) {
    foreach ($spec in @(@('Microsoft.OutlookForWindows', 'Novi Outlook'), @('microsoft.windowscommunicationsapps', 'Win Mail/Cal.'), @('MSTeams', 'Teams (novi)'))) {
        $ap = @($apx | Where-Object { $_.Name -eq $spec[0] } | Sort-Object { try { [version][string]$_.Version } catch { [version]'0.0' } } -Descending | Select-Object -First 1)
        if ($ap.Count -gt 0) { Add-Item 'KV' $spec[1] ('verzija {0}' -f $ap[0].Version) }
        elseif ($spec[0] -eq 'MSTeams') { Add-Item 'KV' $spec[1] 'nije pronađen' }
    }
} else {
    Add-Item 'Text' '' 'Store aplikacije (novi Outlook, Teams) nisu provjerene: potrebna su administratorska prava.' 'Muted'
}
foreach ($m in @($progs.Values | Where-Object { $_.Name -match 'Thunderbird|eM Client|Mailbird|Postbox|The Bat|Mailspring|Claws Mail|Opera Mail|Spark|Evolution' } | Select-Object -First 4)) {
    Add-Item 'KV' 'Mail klijent' ((Add-Version (Get-Clean $m.Name 70) $m.Version ' ').Trim())
}
foreach ($v in @('16.0', '15.0', '14.0')) {
    $pr = @(Get-ChildItem ($userRoot + '\Software\Microsoft\Office\' + $v + '\Outlook\Profiles') -ErrorAction SilentlyContinue)
    if ($pr.Count -gt 0) {
        Add-Item 'KV' 'Mail profili' ('{0}: {1}' -f $pr.Count, ((@($pr | ForEach-Object { $_.PSChildName }) -join ', ')))
        break
    }
}
$dirList = New-Object System.Collections.Generic.List[string]
$dirList.Add($profilePath + '\AppData\Local\Microsoft\Outlook')
$dirList.Add($profilePath + '\Documents\Outlook Files')
try {
    $pers = [string](Get-ItemProperty ($userRoot + '\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders') -ErrorAction SilentlyContinue).Personal
    if (-not $pers) {
        $raw = [string](Get-Item -LiteralPath ($userRoot + '\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') -ErrorAction SilentlyContinue).GetValue('Personal', '', 'DoNotExpandEnvironmentNames')
        if ($raw) { $pers = $raw.Replace('%USERPROFILE%', $profilePath) }
        if ($pers -match '%') { $pers = '' }
    }
    if ($pers) {
        $pers = $pers.TrimEnd('\')
        $dirList.Add($pers + '\Outlook Files')
        $dirList.Add($pers)
    }
} catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
$mailFiles = @()
$seenDirs = @{}
foreach ($dir in $dirList) {
    $dk = $dir.ToLower()
    if ($seenDirs.ContainsKey($dk)) { continue }
    $seenDirs[$dk] = 1
    try {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $mailFiles += @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(ost|pst|nst)$' })
    } catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
}
if ($mailFiles.Count -gt 0) {
    Add-Item 'KV' 'Outlook datot.' ('{0} (OST/PST/NST)' -f $mailFiles.Count)
    foreach ($f in ($mailFiles | Sort-Object Length -Descending | Select-Object -First 8)) {
        $gb = $f.Length / 1GB
        if ($gb -ge 1) { $sizeText = '{0:N1} GB' -f $gb } else { $sizeText = '{0:N0} MB' -f ($f.Length / 1MB) }
        $st = 'Normal'
        if ($gb -ge 45) { $st = 'Bad' } elseif ($gb -ge 20) { $st = 'Warn' }
        Add-Item 'KV' $sizeText ('{0} (promijenjeno {1})' -f (Get-Clean $f.Name 70), $f.LastWriteTime.ToString('dd.MM.yyyy.')) $st
    }
    if ($mailFiles.Count -gt 8) {
        $restN = $mailFiles.Count - 8
        Add-Item 'Text' '' ('... i još {0} {1} (navedene su najveće)' -f $restN, (Get-HrPlural $restN 'datoteka' 'datoteke' 'datoteka')) 'Muted'
    }
}
Send-Items
$sorted = @($progs.Values | Sort-Object Name)
Add-Item 'Section' '' ('INSTALIRANI PROGRAMI ({0})' -f $sorted.Count)
foreach ($p in ($sorted | Select-Object -First 150)) {
    $line = Add-Version (Get-Clean $p.Name 80) $p.Version
    Add-Item 'Text' '' $line
}
if ($sorted.Count -gt 150) { Add-Item 'Text' '' ('... i još {0} programa' -f ($sorted.Count - 150)) }
Add-Item 'Text' '' 'Store/MSIX aplikacije (npr. novi Teams, WhatsApp) nisu uključene u ovaj popis programa.' 'Muted'
if ($hiddenCount -gt 0) { Add-Item 'Text' '' ('Izostavljeno {0} {1} (zakrpe, sistemske komponente, Visual C++ paketi, driver paketi).' -f $hiddenCount, (Get-HrPlural $hiddenCount 'stavka' 'stavke' 'stavki')) 'Muted' }
$grpDone.sw = $true
Send-Items

# ---------------- Windows Update (pretraga može biti spora ili zapeti) ----------------
$global:target = $wuItems
Add-Item 'Section' '' 'WINDOWS UPDATE'
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()

    try {
        $sysInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($sysInfo.RebootRequired) { Add-Item 'KV' 'Restart' 'potrebno ponovno pokretanje računala' 'Warn' }
    } catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }

    $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
    $count  = [int]$result.Updates.Count
    if ($count -eq 0) {
        Add-Item 'KV' 'Na čekanju' 'nema neinstaliranih ažuriranja' 'Good'
    } else {
        Add-Item 'KV' 'Na čekanju' ('{0} {1}' -f $count, (Get-HrPlural $count 'neinstalirano ažuriranje' 'neinstalirana ažuriranja' 'neinstaliranih ažuriranja')) 'Warn'
        $sevMap = @{ 'Critical' = 'kritično'; 'Important' = 'važno'; 'Moderate' = 'umjereno'; 'Low' = 'nisko' }
        $catMap = @{ 'Drivers' = 'driver'; 'Security Updates' = 'sigurnosno'; 'Critical Updates' = 'kritično'; 'Definition Updates' = 'definicije'; 'Feature Packs' = 'značajke'; 'Update Rollups' = 'zbirno'; 'Service Packs' = 'service pack'; 'Tools' = 'alat' }
        $shown = 0
        foreach ($u in $result.Updates) {
            if ($shown -ge 15) {
                $rest = $count - 15
                Add-Item 'Text' '' ('... i još {0} {1}' -f $rest, (Get-HrPlural $rest 'ažuriranje' 'ažuriranja' 'ažuriranja'))
                break
            }
            $kb = '-'
            if ($u.KBArticleIDs.Count -gt 0) { $kb = 'KB' + $u.KBArticleIDs.Item(0) }
            $text = Get-Clean ([string]$u.Title) 130
            $tags = New-Object System.Collections.Generic.List[string]
            $status = 'Normal'
            foreach ($cat in $u.Categories) {
                $catName = [string]$cat.Name
                if ($catMap.ContainsKey($catName) -and -not $tags.Contains($catMap[$catName])) { $tags.Add($catMap[$catName]) }
                if ($catName -eq 'Critical Updates' -or $catName -eq 'Security Updates') { $status = 'Bad' }
            }
            $sev = [string]$u.MsrcSeverity
            if ($sev) {
                $sevText = $sev
                if ($sevMap.ContainsKey($sev)) { $sevText = $sevMap[$sev] }
                $tags.Add($sevText)
                if ($sev -eq 'Critical' -or $sev -eq 'Important') { $status = 'Bad' }
            }
            if ($tags.Count -gt 0) { $text = '{0} [{1}]' -f $text, ($tags -join ', ') }
            Add-Item 'KV' $kb $text $status
            $shown++
        }
    }

    Send-Items
    try {
        $total = [int]$searcher.GetTotalHistoryCount()
        if ($total -gt 0) {
            $history = $searcher.QueryHistory(0, [Math]::Min($total, 200))
            $okCount = 0
            $failed  = New-Object System.Collections.Generic.List[object]
            foreach ($h in $history) {
                if ($h.Operation -ne 1) { continue }
                $when = [datetime]::SpecifyKind([datetime]$h.Date, [System.DateTimeKind]::Utc)
                if ($when -lt $sinceUtc) { continue }
                if ($h.ResultCode -eq 2) { $okCount++ }
                elseif ($h.ResultCode -ge 3) {
                    $uid = ''
                    try { $uid = [string]$h.UpdateIdentity.UpdateID } catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
                    $failed.Add([pscustomobject]@{ When = $when.ToLocalTime(); Title = [string]$h.Title; HResult = [int]$h.HResult; Id = $uid })
                }
            }
            # Isto ažuriranje koje se svaku noć ponovno pokušava instalirati prikazuje se jednom (s brojem pokušaja).
            $groups = @($failed | Group-Object -Property { '{0}|{1}|{2}' -f $_.Id, $_.Title, $_.HResult })
            $failStatus = 'Good'
            if ($failed.Count -gt 0) { $failStatus = 'Bad' }
            Add-Item 'KV' 'Zadnjih 7 d' ('{0} uspješno, {1} neuspjelih pokušaja ({2} različitih)' -f $okCount, $failed.Count, $groups.Count) $failStatus
            foreach ($g in ($groups | Select-Object -First 8)) {
                $f = $g.Group[0]
                $n = ''
                if ($g.Count -gt 1) { $n = ' (x{0})' -f $g.Count }
                Add-Item 'KV' $f.When.ToString('dd.MM. HH:mm') ('{0} (greška 0x{1:X8}){2}' -f (Get-Clean $f.Title 110), $f.HResult, $n) 'Bad'
            }
            if ($groups.Count -gt 8) { Add-Item 'Text' '' ('... i još {0} različitih neuspjelih ažuriranja' -f ($groups.Count - 8)) }
        } else {
            Add-Item 'KV' 'Zadnjih 7 d' 'nema zapisa o instalacijama' 'Normal'
        }
    } catch { <# namjerno: skripta skeniranja (zaseban proces, bez dnevnika): nedostupan podatak se preskače #> }
} catch {
    Add-Item 'Text' '' ('Windows Update nije dostupan: ' + (Get-Clean $_.Exception.Message 120)) 'Warn'
}
$grpDone.wu = $true
Send-Items
