#region ELEVATION
$script:IsAdmin = Test-IsAdministrator
$script:IsSta   = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)

if (-not $script:IsAdmin -or -not $script:IsSta) {
    try {
        if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or -not (Test-Path -LiteralPath $PSCommandPath)) {
            throw 'Skripta mora biti pokrenuta iz spremljene .ps1 datoteke kako bi se mogla podići na administratorska prava.'
        }

        $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            $nativeHost = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
            if (Test-Path -LiteralPath $nativeHost) { $hostExe = $nativeHost }
        }

        # Povišeni proces ne vidi mapirane mrežne diskove (slova pogona): put se zamjenjuje UNC putanjom.
        $scriptPath = $PSCommandPath
        try {
            $driveRoot = [System.IO.Path]::GetPathRoot($scriptPath)
            if ($driveRoot -match '^[A-Za-z]:\\$') {
                $logical = Get-CimInstance -OperationTimeoutSec 10 -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $driveRoot.Substring(0, 2)) -ErrorAction Stop
                if ($logical.DriveType -eq 4 -and $logical.ProviderName) {
                    $scriptPath = $logical.ProviderName.TrimEnd('\') + '\' + $scriptPath.Substring($driveRoot.Length)
                }
            }
        } catch { }

        $relaunch = @{
            FilePath     = $hostExe
            ArgumentList = ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $scriptPath)
            ErrorAction  = 'Stop'
        }
        if (-not $script:IsAdmin) { $relaunch.Verb = 'RunAs' }
        Start-Process @relaunch | Out-Null
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            ('Aplikacija zahtijeva administratorska prava i nije mogla biti pokrenuta.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message),
            'Auxilium Informatika',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
    exit
}
#endregion ELEVATION

