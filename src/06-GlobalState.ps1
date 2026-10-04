#region GLOBAL STATE
$script:AppName    = 'Auxilium Informatika'
$script:AppTitle   = 'Auxilium Informatika - Dijagnostika i čišćenje sustava'
# Verzije: interni broj izdanja (v1, v2, v3 ...) prikazuje se kao broj/100 s dvije decimale: v1 = 0.01, v2 = 0.02, ... v10 = 0.10, v99 = 0.99, v100 = 1.0.
# Pri svakom novom izdanju povećava se samo $script:BuildNumber.
$script:BuildNumber = 4
if ($script:BuildNumber % 100 -eq 0) { $script:AppVersion = '{0}.0' -f [int]($script:BuildNumber / 100) } else { $script:AppVersion = '{0}.{1}' -f [int][Math]::Floor($script:BuildNumber / 100), ([int]($script:BuildNumber % 100)).ToString('00') }

$script:UI                = @{}
$script:Colors            = @{}
$script:Fonts             = @{}
$script:Busy              = $false
$script:CancelRequested   = $false
$script:Closing           = $false
$script:CurrentProcess    = $null
$script:SysInfo           = @()
$script:ProgressMode      = 'Idle'
$script:LastPctBucket     = -1
$script:LastProcessOutput = New-Object System.Collections.Generic.List[string]
$script:LineBatch         = New-Object System.Collections.Generic.List[string]
$script:KeepDirs          = $null
$script:AppRoot           = ''
$script:SettingsPath      = ''
$script:SettingsWarned    = $false
$script:SettingsLoadError = ''
$script:Settings          = [pscustomobject]@{ Company = ''; Companies = @(); ReportsRoot = '' }
$script:ConsoleUser       = $null
$script:ReportCompany     = $null
$script:FocusCompanyBox   = $false
$script:AbandonedRunspace  = $false
$script:Deep             = @{ State = 'Idle'; Process = $null; Readers = @(); Items = @(); Error = ''; Watch = $null; TimeoutSec = 120; TempFile = $null }
$script:PdfCancelled      = $false
$script:PumpWatch         = [System.Diagnostics.Stopwatch]::StartNew()
$script:Pdf               = $null
$script:FontCollection    = $null
$script:TaskHadError      = $false
$script:TaskNoResult      = $false
$script:Health            = $null
$script:HealthState       = 'Loading'
$script:LiveRows          = @{}
$script:CpuPrev           = $null
$script:LogClearSelection = $null
#endregion GLOBAL STATE

