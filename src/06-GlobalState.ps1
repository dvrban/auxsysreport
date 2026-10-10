#region GLOBAL STATE
$script:AppName    = 'Auxilium Informatika'
$script:AppTitle   = 'Auxilium Informatika - Dijagnostika i čišćenje sustava'
# Verzije: interni broj izdanja (v1, v2, v3 ...) prikazuje se kao broj/100 s dvije decimale: v1 = 0.01, v2 = 0.02, ... v10 = 0.10, v99 = 0.99, v100 = 1.0.
# Pri svakom novom izdanju povećava se samo $script:BuildNumber.
$script:BuildNumber = 4
if ($script:BuildNumber % 100 -eq 0) { $script:AppVersion = '{0}.0' -f [int]($script:BuildNumber / 100) } else { $script:AppVersion = '{0}.{1}' -f [int][Math]::Floor($script:BuildNumber / 100), ([int]($script:BuildNumber % 100)).ToString('00') }

# Registar kontrola: svi ključevi se unaprijed postavljaju ($null) jer u strogom načinu (Set-StrictMode 2) čitanje nepostojećeg ključa baca iznimku,
# a funkcije ih čitaju i prije nego što je forma izgrađena (npr. Write-Terminal, Update-ClientBar).
$script:UI                = @{
    ActionButtons = @(); ClientControls = @(); ClientUpdating = $false
    BtnCancel = $null; ComboFrame = $null; ComboOff = $null; CompanyBox = $null; DeepTimer = $null; Form = $null; HealthTile = $null
    LiveTimer = $null; PathLabel = $null; WatchTimer = $null; ProgressFill = $null; ProgressResetTimer = $null; ProgressTimer = $null; ProgressTrack = $null
    Status = $null; Terminal = $null; LeftPane = $null
}
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
$script:LogPath           = ''      # dnevnik na stiku (Write-AppLog); LogFailed = zapis nije moguć, više se ne pokušava
$script:LogFailed         = $false
$script:DpiScale         = 1.0     # faktor skaliranja zaslona (1.0 = 100 %); postavlja Enable-DpiAwareness. Raspored se piše u 96-DPI jedinicama.
$script:CurrentTask       = ''      # naziv zadatka koji je u tijeku (Start-GuiTask): dijagnostika watchdoga
$script:UiWatch           = New-Object System.Diagnostics.Stopwatch   # watchdog sučelja (Update-UiWatchdog)
$script:UiWatchEntries    = 0
$script:LogLastSignature   = ''      # zadnji zapis bez vremena (spajanje ponavljanja u dnevniku)
$script:LogRepeats        = 0
$script:ToolHash          = ''      # prvih 8 znakova SHA-256 ove skripte (Get-ToolFingerprint): dokaz koje je izdanje napravilo izvještaj
$script:SettingsPath      = ''
$script:SettingsWarned    = $false
$script:SettingsLoadError = ''
$script:Settings          = [pscustomobject]@{ Company = ''; Companies = @(); ReportsRoot = '' }
$script:ConsoleUser       = $null
$script:ReportCompany     = $null
$script:FocusCompanyBox   = $false
$script:AbandonedRunspace  = $false
$script:Deep             = @{ State = 'Idle'; Process = $null; Readers = @(); Items = @(); Error = ''; Watch = $null; TimeoutSec = 120; TempFile = $null; RunDir = $null }
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
$script:LogDlg            = $null   # stanje dijaloga za odabir dnevnika (samo dok je otvoren)
# Strogi način (T1.6): alat radi pod Set-StrictMode -Version 2 (nepostavljene varijable, nepostojeća svojstva i sl. bacaju iznimku koju radnja ispiše u
# terminal i dnevnik). Prošao je ispitivanje na Windowsu (ocjena, PDF, JSON, mreža, čišćenje, izvoz dnevnika). Ako zapne na terenu, isključuje se praznom
# datotekom Auxilium-StrictMode.off uz skriptu. Set-StrictMode mora biti u opsegu skripte (ne u funkciji).
$script:StrictMode = $false
try {
    $strictOff = (-not [string]::IsNullOrEmpty($PSScriptRoot)) -and [System.IO.File]::Exists([System.IO.Path]::Combine($PSScriptRoot, 'Auxilium-StrictMode.off'))
    if (-not $strictOff) {
        Set-StrictMode -Version 2
        $script:StrictMode = $true
    }
} catch { $script:StrictMode = $false }
#endregion GLOBAL STATE