#region TASKS - MREZA
function Get-ActiveIPv4Report {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        $type = [string]$nic.NetworkInterfaceType
        if ($type -eq 'Loopback' -or $type -eq 'Tunnel') { continue }

        $props = $nic.GetIPProperties()
        $gateways = @($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.Address.ToString() })
        $dns      = @($props.DnsAddresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() })

        foreach ($ua in $props.UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $ip = $ua.Address.ToString()
            $rows.Add([pscustomobject]@{
                Name    = $nic.Name
                Ip      = $ip
                Prefix  = $ua.PrefixLength
                Gateway = ($gateways -join ', ')
                Dns     = ($dns -join ', ')
                Apipa   = $ip.StartsWith('169.254.')
            })
        }
    }
    return $rows
}

function ConvertTo-HrPingStatus {
    param($Status)
    $map = @{
        'TimedOut'                       = 'isteklo vrijeme čekanja'
        'DestinationNetworkUnreachable'  = 'odredišna mreža nije dostupna'
        'DestinationHostUnreachable'     = 'odredišno računalo nije dostupno'
        'DestinationUnreachable'         = 'odredište nije dostupno'
        'DestinationProtocolUnreachable' = 'protokol na odredištu nije dostupan'
        'DestinationPortUnreachable'     = 'port na odredištu nije dostupan'
        'DestinationProhibited'          = 'promet prema odredištu je zabranjen'
        'TtlExpired'                     = 'TTL je istekao'
        'TtlReassemblyTimeExceeded'      = 'isteklo vrijeme ponovnog sastavljanja paketa'
        'TimeExceeded'                   = 'prekoračeno vrijeme'
        'PacketTooBig'                   = 'paket je prevelik'
        'BadRoute'                       = 'neispravna ruta'
        'NoResources'                    = 'nema dovoljno resursa'
        'HardwareError'                  = 'hardverska greška'
        'Unknown'                        = 'nepoznat status'
    }
    $text = [string]$Status
    if ($map.ContainsKey($text)) { return $map[$text] }
    return ('nema odgovora ({0})' -f $text)
}

function New-PingOutcome {
    param([string]$Target)
    return [pscustomobject]@{ Target = $Target; Resolved = $false; Sent = 0; Received = 0; SendError = '' }
}

function Test-PingTarget {
    param([Parameter(Mandatory)][string]$Target, [int]$Count = 4, [int]$TimeoutMs = 2000)

    $outcome = New-PingOutcome $Target
    Write-Terminal ('Ping prema {0}...' -f $Target) 'Info'

    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($Target, [ref]$address)) {
        try {
            $dnsTask = [System.Net.Dns]::GetHostAddressesAsync($Target)
        } catch {
            Write-Terminal ('  DNS razrješavanje za {0} nije uspjelo: {1}' -f $Target, $_.Exception.GetBaseException().Message) 'Error'
            return $outcome
        }
        if (-not (Wait-TaskUi -Task $dnsTask -TimeoutMs 10000)) {
            if (-not (Test-StopRequested)) { Write-Terminal ('  DNS razrješavanje za {0} je isteklo.' -f $Target) 'Error' }
            return $outcome
        }
        if ($dnsTask.IsFaulted) {
            Write-Terminal ('  DNS razrješavanje za {0} nije uspjelo: {1}' -f $Target, $dnsTask.Exception.GetBaseException().Message) 'Error'
            return $outcome
        }
        $addresses = @($dnsTask.Result)
        $address = $addresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
        if ($null -eq $address -and $addresses.Count -gt 0) { $address = $addresses[0] }
        if ($null -eq $address) {
            Write-Terminal ('  DNS nije vratio nijednu adresu za {0}.' -f $Target) 'Error'
            return $outcome
        }
        Write-Terminal ('  {0} razriješen u {1}' -f $Target, $address.ToString()) 'Normal'
    }
    $outcome.Resolved = $true

    $times  = New-Object System.Collections.Generic.List[long]
    $pinger = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($i = 1; $i -le $Count; $i++) {
            if (Test-StopRequested) { break }
            $outcome.Sent++
            $pingTask = $null
            try {
                $pingTask = $pinger.SendPingAsync($address, $TimeoutMs)
            } catch {
                # Bez rute (kabel izvađen, samo 169.254.x.x adresa, nema pristupnika...) slanje baca iznimku odmah.
                $outcome.SendError = $_.Exception.GetBaseException().Message
                Write-Terminal ('  Slanje nije moguće (nema rute do {0}?): {1}' -f $address, $outcome.SendError) 'Error'
                break
            }
            if (-not (Wait-TaskUi -Task $pingTask -TimeoutMs ($TimeoutMs + 3000))) {
                if (Test-StopRequested) { $outcome.Sent-- }
                break
            }
            if ($pingTask.IsFaulted) {
                Write-Terminal ('  Odgovor {0}/{1}: greška - {2}' -f $i, $Count, $pingTask.Exception.GetBaseException().Message) 'Warn'
            } else {
                $reply = $pingTask.Result
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $outcome.Received++
                    $times.Add($reply.RoundtripTime)
                    $rtt = '{0} ms' -f $reply.RoundtripTime
                    if ($reply.RoundtripTime -lt 1) { $rtt = '<1 ms' }
                    $ttl = ''
                    if ($null -ne $reply.Options) { $ttl = ' TTL={0}' -f $reply.Options.Ttl }
                    Write-Terminal ('  Odgovor od {0}: vrijeme={1}{2}' -f $reply.Address, $rtt, $ttl) 'Ok'
                } else {
                    Write-Terminal ('  Odgovor {0}/{1}: {2}' -f $i, $Count, (ConvertTo-HrPingStatus $reply.Status)) 'Warn'
                }
            }
            if ($i -lt $Count) {
                $pause = [System.Diagnostics.Stopwatch]::StartNew()
                while ($pause.ElapsedMilliseconds -lt 300 -and -not (Test-StopRequested)) { Update-Ui; Start-Sleep -Milliseconds 20 }
            }
        }
    } finally {
        $pinger.Dispose()
    }

    if ($outcome.Sent -gt 0 -and -not $outcome.SendError) {
        $lost = $outcome.Sent - $outcome.Received
        $summary = '  Poslano: {0}, primljeno: {1}, izgubljeno: {2}' -f $outcome.Sent, $outcome.Received, $lost
        if ($times.Count -gt 0) {
            $stats = $times | Measure-Object -Minimum -Maximum -Average
            $summary += ' | min/prosj./maks: {0}/{1:N0}/{2} ms' -f $stats.Minimum, $stats.Average, $stats.Maximum
        }
        $summaryLevel = 'Error'
        if ($outcome.Received -eq $outcome.Sent) { $summaryLevel = 'Ok' } elseif ($outcome.Received -gt 0) { $summaryLevel = 'Warn' }
        Write-Terminal $summary $summaryLevel
    }
    return $outcome
}

function Invoke-NetworkTask {
    Write-Terminal 'Aktivne lokalne IPv4 adrese:' 'Info'
    try {
        $rows = @(Get-ActiveIPv4Report)
        if ($rows.Count -eq 0) {
            Write-Terminal '  Nema aktivnih IPv4 adresa. Provjerite kabel / Wi-Fi vezu.' 'Error'
        }
        foreach ($row in $rows) {
            Write-Terminal ('  {0}: {1}/{2}' -f $row.Name, $row.Ip, $row.Prefix) 'Normal'
            if ($row.Apipa) { Write-Terminal '    Upozorenje: link-local (APIPA) adresa 169.254.x.x - sučelje nije dobilo adresu od DHCP-a (normalno za virtualne adaptere).' 'Warn' }
            if ($row.Gateway) { Write-Terminal ('    Pristupnik: {0}' -f $row.Gateway) 'Normal' }
            if ($row.Dns)     { Write-Terminal ('    DNS: {0}' -f $row.Dns) 'Normal' }
        }
    } catch {
        Write-Terminal ('  Popis mrežnih sučelja nije dostupan: {0}' -f $_.Exception.Message) 'Warn'
    }

    $ipResult = $null
    try { $ipResult = Test-PingTarget -Target '8.8.8.8' } catch { Write-Terminal ('  Ping prema 8.8.8.8 nije uspio: {0}' -f $_.Exception.Message) 'Error' }
    if (Test-StopRequested) { return }
    if ($null -eq $ipResult) { $ipResult = New-PingOutcome '8.8.8.8' }

    $dnsResult = $null
    try { $dnsResult = Test-PingTarget -Target 'google.com' } catch { Write-Terminal ('  Ping prema google.com nije uspio: {0}' -f $_.Exception.Message) 'Error' }
    if (Test-StopRequested) { return }
    if ($null -eq $dnsResult) { $dnsResult = New-PingOutcome 'google.com' }

    $ipOk    = ($ipResult.Received -gt 0)
    $dnsOk   = ($dnsResult.Received -gt 0)
    $sent    = $ipResult.Sent + $dnsResult.Sent
    $rcv     = $ipResult.Received + $dnsResult.Received
    $lossPct = 0
    if ($sent -gt 0) { $lossPct = [int](100 * ($sent - $rcv) / $sent) }

    $anySendErr  = ($ipResult.SendError -or $dnsResult.SendError)
    $bothSendErr = ($ipResult.SendError -and $dnsResult.SendError)
    if ($bothSendErr -or ($anySendErr -and $rcv -eq 0)) {
        Write-Terminal 'Zaključak: nema mrežne rute - provjerite kabel / Wi-Fi / DHCP / zadani pristupnik.' 'Error'
    } elseif ($anySendErr) {
        $failedTarget = '8.8.8.8'
        if ($dnsResult.SendError) { $failedTarget = 'google.com' }
        Write-Terminal ('Zaključak: slanje prema {0} nije bilo moguće (nema rute ili je veza prekinuta tijekom testa), a drugi cilj odgovara - ponovite test.' -f $failedTarget) 'Warn'
    } elseif ($ipOk -and $dnsOk) {
        if ($lossPct -ge 25) {
            Write-Terminal ('Zaključak: veza radi, ali uz gubitak paketa (oko {0} %).' -f $lossPct) 'Warn'
        } else {
            Write-Terminal 'Zaključak: Internet veza i DNS rade ispravno.' 'Ok'
        }
    } elseif ($ipOk) {
        if (-not $dnsResult.Resolved) {
            Write-Terminal 'Zaključak: 8.8.8.8 odgovara, a google.com se ne razrješava - vjerojatno problem s DNS-om.' 'Warn'
        } else {
            Write-Terminal 'Zaključak: DNS razrješava google.com, ali on ne odgovara na ICMP.' 'Warn'
        }
    } elseif ($dnsOk) {
        Write-Terminal 'Zaključak: google.com odgovara, a 8.8.8.8 ne - ICMP prema 8.8.8.8 je vjerojatno blokiran.' 'Warn'
    } elseif ($dnsResult.Resolved) {
        Write-Terminal 'Zaključak: DNS radi, ali nema ICMP odgovora - ICMP je vjerojatno blokiran; to ne znači nužno da Internet ne radi.' 'Warn'
    } else {
        Write-Terminal 'Zaključak: nema odgovora ni od 8.8.8.8 ni od google.com - provjerite mrežnu vezu, pristupnik i vatrozid.' 'Error'
    }
}
#endregion TASKS - MREZA

