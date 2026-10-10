#region WATCHDOG
# T3.7: tajmer od 100 ms na UI niti mjeri razmak između dvaju otkucaja. Dok se poruke pumpaju (Update-Ui / ShowDialog), razmak je ~100 ms; dulji razmak znači da je
# UI nit bila zauzeta i da sučelje nije reagiralo. Takvi razmaci se bilježe u dnevnik (uz naziv zadatka koji je tada radio), najviše MaxEntries po pokretanju.
# Razmak veći od 2 minute ignorira se (stanje mirovanja računala), a prvi otkucaj nakon pokretanja mjeri se od pokretanja tajmera.
function Update-UiWatchdog {
    param([int]$ThresholdMs = 400, [int]$MaxEntries = 50, [int]$IgnoreAboveMs = 120000)
    $elapsed = [int64]$script:UiWatch.ElapsedMilliseconds
    if ($elapsed -ge $ThresholdMs -and $elapsed -le $IgnoreAboveMs -and $script:UiWatchEntries -lt $MaxEntries) {
        $script:UiWatchEntries++
        $context = 'nema zadatka u tijeku'
        if ($script:CurrentTask) { $context = 'zadatak: ' + $script:CurrentTask }
        Write-AppLog 'Info' ('Sučelje nije reagiralo {0} ms ({1})' -f $elapsed, $context)
    }
    # Štoperica se ponovno pokreće TEK NAKON zapisa: spor zapis na stick (pa i antivirus) ne smije se ubrojiti u sljedeći razmak i tako pokrenuti lanac zapisa.
    $script:UiWatch.Restart()
}
#endregion WATCHDOG

