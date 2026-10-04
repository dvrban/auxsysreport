#region TASKS - SISTEM
function Invoke-SfcDismTask {
    Write-Terminal 'Korak 1/2: DISM /Online /Cleanup-Image /CheckHealth' 'Info'
    $code = Invoke-LiveProcess -FilePath (Resolve-SystemTool 'dism.exe') -Arguments '/Online /Cleanup-Image /CheckHealth'
    if (Test-StopRequested) { return }
    $dismText = $script:LastProcessOutput -join ' '
    $repairable = $false
    if ($code -eq 0) {
        Write-Terminal 'DISM CheckHealth je završen (kod izlaza 0).' 'Ok'
        # "is repairable" (engleski) / "popravljiv" (hrvatski Windows); poruke "not repairable" / "cannot be repaired" ne smiju pokrenuti popravak.
        if (($dismText -match '(?i)repairable|popravljiv') -and ($dismText -notmatch '(?i)not repairable|cannot be repaired|nije popravljiv|ne može se popraviti')) { $repairable = $true }
    } else {
        Write-Terminal ('DISM je završio s kodom izlaza {0}.' -f $code) 'Warn'
    }

    if ($repairable) {
        # Dodatni korak: samo kad je spremište komponenti označeno kao oštećeno, ali popravljivo. SFC zamjenske datoteke uzima iz tog spremišta.
        Write-Terminal 'Spremište komponenti je oštećeno, ali popravljivo. Dodatni korak: DISM /Online /Cleanup-Image /RestoreHealth (traži internetsku vezu, može potrajati 10-30 minuta)' 'Warn'
        $code = Invoke-LiveProcess -FilePath (Resolve-SystemTool 'dism.exe') -Arguments '/Online /Cleanup-Image /RestoreHealth'
        if (Test-StopRequested) { return }
        if ($code -eq 0) {
            Write-Terminal 'DISM RestoreHealth je završen (kod izlaza 0): spremište komponenti je popravljeno.' 'Ok'
        } else {
            Write-Terminal ('DISM RestoreHealth je završio s kodom izlaza {0}. Provjerite internetsku vezu i Windows Update; SFC se ipak pokreće.' -f $code) 'Warn'
        }
    }

    Write-Terminal 'Korak 2/2: sfc /scannow (može potrajati nekoliko minuta)' 'Info'
    $code = Invoke-LiveProcess -FilePath (Resolve-SystemTool 'sfc.exe') -Arguments '/scannow'
    if (Test-StopRequested) { return }
    if ($code -eq 0) {
        Write-Terminal 'SFC provjera je završena (kod izlaza 0).' 'Ok'
    } else {
        Write-Terminal ('SFC je završio s kodom izlaza {0}. Pogledajte ispis iznad.' -f $code) 'Warn'
    }
}

function Invoke-ChkdskTask {
    $drive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'C:' }
    Write-Terminal ('Provjera diska {0} u načinu samo za čitanje (bez popravaka).' -f $drive) 'Info'
    $code = Invoke-LiveProcess -FilePath (Resolve-SystemTool 'chkdsk.exe') -Arguments $drive
    if (Test-StopRequested) { return }
    if ($code -eq 0) {
        Write-Terminal 'CHKDSK nije pronašao probleme (kod izlaza 0).' 'Ok'
    } else {
        # Kodovi vrijede za način samo za čitanje (bez /f): 1 se ne pojavljuje, 2 = čišćenje nije izvršeno, 3 = greške nisu ispravljene ili provjera nije dovršena.
        $message = 'CHKDSK je završio s kodom izlaza ' + $code + '.'
        if ($code -eq 2) {
            $message = 'CHKDSK: potrebno je čišćenje, ali nije izvršeno jer je način samo za čitanje (kod izlaza 2). Pregledajte ispis iznad.'
        } elseif ($code -eq 3) {
            $message = 'CHKDSK: pronađene su greške koje nisu ispravljene jer je način samo za čitanje, ILI provjera nije mogla biti dovršena (kod izlaza 3). Pregledajte ispis iznad; ako navodi probleme, zakažite chkdsk /f.'
        } elseif ($code -eq -1) {
            $message = 'CHKDSK se nije uredno završio (nema koda izlaza).'
        }
        Write-Terminal $message 'Warn'
    }
}
#endregion TASKS - SISTEM

