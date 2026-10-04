#region PORTABLE
# Portable način rada: sve što alat trajno zapisuje (postavke, izvještaji) ostaje uz skriptu, npr. na USB stiku.
# Struktura:  <stick>\Auxilium-Dijagnostika.ps1, <stick>\Auxilium-Postavke.json, <stick>\Izvjestaji\<Tvrtka>\<RACUNALO>_<korisnik>_<datum-vrijeme>.pdf
function Initialize-Portable {
    param([string]$Root = '')
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($Root)) { $Root = [System.IO.Directory]::GetCurrentDirectory() }
    }
    $trimmed = $Root.TrimEnd('\')
    # Korijen pogona ("E:\" -> "E:") bi se spajanjem putanja pretvorio u relativnu putanju "E:Izvjestaji": završni "\" se mora zadržati.
    if ($trimmed.Length -le 2 -and $trimmed.EndsWith(':')) { $trimmed += '\' }
    $script:AppRoot      = $trimmed
    $script:SettingsPath = [System.IO.Path]::Combine($script:AppRoot, 'Auxilium-Postavke.json')
    $script:SettingsWarned = $false
    Import-AppSettings
}

# Pretvara proizvoljan tekst (ime tvrtke, računala, korisnika) u siguran naziv mape/datoteke.
function ConvertTo-SafeName {
    param([AllowNull()][AllowEmptyString()][string]$Name, [string]$Fallback = 'nepoznato', [int]$MaxLength = 60)
    $text = [string]$Name
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $text = $text.Replace([string]$ch, '_') }
    $text = ($text -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength).TrimEnd('.', ' ') }
    if ([string]::IsNullOrWhiteSpace($text)) { $text = $Fallback }
    if ($text -match '^(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$') { $text = '_' + $text }
    return $text
}

function Import-AppSettings {
    $settings = [pscustomobject]@{ Company = ''; Companies = @(); ReportsRoot = '' }
    $script:SettingsLoadError = ''
    try {
        if (Test-Path -LiteralPath $script:SettingsPath) {
            $json = [System.IO.File]::ReadAllText($script:SettingsPath) | ConvertFrom-Json
            if ($null -ne $json.Tvrtka) { $settings.Company = [string]$json.Tvrtka }
            if ($null -ne $json.Tvrtke) {
                $settings.Companies = @(@($json.Tvrtke) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
            if ($null -ne $json.KorijenIzvjestaja) {
                $rootText = [string]$json.KorijenIzvjestaja
                if ($rootText.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) {
                    $script:SettingsLoadError = 'KorijenIzvjestaja sadrži nedopuštene znakove; koristi se zadana mapa.'
                } else {
                    $settings.ReportsRoot = $rootText
                }
            }
        }
    } catch {
        $script:SettingsLoadError = $_.Exception.Message
    }
    $script:Settings = $settings
}

function Save-AppSettings {
    try {
        $data = [ordered]@{
            Tvrtka            = [string]$script:Settings.Company
            Tvrtke            = @($script:Settings.Companies)
            KorijenIzvjestaja = [string]$script:Settings.ReportsRoot
        }
        $json = $data | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object System.Text.UTF8Encoding($true)))
    } catch {
        if (-not $script:SettingsWarned) {
            $script:SettingsWarned = $true
            Write-Terminal ('Postavke nije moguće spremiti (stick zaštićen od pisanja?): {0}' -f $_.Exception.Message) 'Warn'
        }
    }
}

# Korijenska mapa izvještaja: zadano <stick>\Izvjestaji; putanje unutar sticka spremaju se relativno (slovo pogona se može promijeniti).
function Get-ReportsRoot {
    $stored = [string]$script:Settings.ReportsRoot
    if ($stored.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) { $stored = '' }
    if ([string]::IsNullOrWhiteSpace($stored)) { return [System.IO.Path]::Combine($script:AppRoot, 'Izvjestaji') }
    if ($stored.StartsWith('.\')) { return [System.IO.Path]::Combine($script:AppRoot, $stored.Substring(2)) }
    # Putanja na istom pogonu kao alat sprema se bez slova pogona (\Klijenti\Izvjestaji): slovo pogona sticka se mijenja od računala do računala.
    $appDrive = [System.IO.Path]::GetPathRoot($script:AppRoot)
    if ($appDrive -match '^[A-Za-z]:\\$' -and $stored.StartsWith('\') -and -not $stored.StartsWith('\\')) {
        return [System.IO.Path]::Combine($appDrive, $stored.TrimStart('\'))
    }
    return $stored
}

function Set-ReportsRoot {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 2 -and $full.EndsWith(':')) { $full += '\' }
    $prefix = $script:AppRoot
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    $appDrive = [System.IO.Path]::GetPathRoot($script:AppRoot)
    if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $script:Settings.ReportsRoot = '.\' + $full.Substring($prefix.Length)
    } elseif ($full.TrimEnd('\') -ieq $script:AppRoot.TrimEnd('\')) {
        $script:Settings.ReportsRoot = '.\'
    } elseif ($appDrive -match '^[A-Za-z]:\\$' -and $full.StartsWith($appDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
        $script:Settings.ReportsRoot = '\' + $full.Substring($appDrive.Length)
    } else {
        $script:Settings.ReportsRoot = $full
    }
    Save-AppSettings
}

function Get-ActiveCompany {
    return ([string]$script:Settings.Company)
}

function Get-CompanyFolder {
    param([string]$Company)
    return [System.IO.Path]::Combine((Get-ReportsRoot), (ConvertTo-SafeName $Company 'Nerazvrstano'))
}

function Set-ActiveCompany {
    param([AllowNull()][AllowEmptyString()][string]$Name, [switch]$KeepOrder)
    $clean = ([string]$Name -replace '\s+', ' ').Trim()
    if ($clean.Length -gt 60) { $clean = $clean.Substring(0, 60).Trim() }
    $script:Settings.Company = $clean
    # -KeepOrder: odabir iz padajućeg popisa (strelice, kotačić) ne smije premještati stavke, inače bi se izmjenjivale prve dvije tvrtke.
    if ($clean.Length -gt 0 -and -not ($KeepOrder -and (@($script:Settings.Companies) -contains $clean))) {
        $list = New-Object System.Collections.Generic.List[string]
        $list.Add($clean)
        foreach ($known in @($script:Settings.Companies)) {
            if ($known -ne $clean -and $list.Count -lt 30) { $list.Add($known) }
        }
        $script:Settings.Companies = $list.ToArray()
    }
    Save-AppSettings
    Update-ClientBar
}

# Korisnik koji je prijavljen na računalu (konzolna sesija); alat može raditi i pod drugim administratorskim računom.
function Get-ConsoleUser {
    if ($null -eq $script:ConsoleUser) {
        $script:ConsoleUser = ''
        try {
            $script:ConsoleUser = [string](Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 3 -ErrorAction Stop).UserName
        } catch { }
    }
    return $script:ConsoleUser
}

# Ime korisnika za naziv datoteke: bez domene (npr. DOMENA\marko -> marko).
function Get-ReportUserName {
    $user = Get-ConsoleUser
    if ([string]::IsNullOrWhiteSpace($user)) { $user = [Environment]::UserName }
    return (([string]$user) -replace '^.*\\', '')
}

function Get-ReportFileName {
    # Nepromjenjiva kultura: Get-Date -Format koristi kalendar kulture (ar-SA, th-TH, fa-IR) pa bi godina u imenu datoteke bila nestandardna.
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    return ('{0}_{1}_{2}.pdf' -f (ConvertTo-SafeName $env:COMPUTERNAME 'racunalo'), (ConvertTo-SafeName (Get-ReportUserName) 'korisnik'), $stamp)
}

# Vraća '' ako se u mapu može pisati (mapa se po potrebi stvara), inače tekst greške (stick zaštićen, izvučen, pun...).
function Test-FolderWritable {
    param([string]$Path)
    try {
        if (-not [System.IO.Directory]::Exists($Path)) { [void][System.IO.Directory]::CreateDirectory($Path) }
        $probe = [System.IO.Path]::Combine($Path, ('.auxilium-test-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 8)))
        [System.IO.File]::WriteAllText($probe, 'test')
        [System.IO.File]::Delete($probe)
        return ''
    } catch {
        return $_.Exception.Message
    }
}

function Get-DriveKind {
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if ([string]::IsNullOrWhiteSpace($root) -or $root.StartsWith('\\')) { return 'mreža' }
        if (-not [System.IO.Directory]::Exists($root)) { return 'nedostupno' }
        $type = (New-Object System.IO.DriveInfo($root)).DriveType
        if ($type -eq [System.IO.DriveType]::Removable) { return 'USB' }
        if ($type -eq [System.IO.DriveType]::Network) { return 'mreža' }
        return 'disk'
    } catch {
        return ''
    }
}

# Sprema izvještaj za zadanu tvrtku: <korijen>\<Tvrtka>\<RACUNALO>_<korisnik>_<datum-vrijeme>.pdf. Vraća FileInfo ili $null (prekid).
function Save-ReportForCompany {
    param([Parameter(Mandatory)][string]$Company, [Parameter(Mandatory)][string]$PrinterName)

    $folder   = Get-CompanyFolder $Company
    $fileName = Get-ReportFileName
    $path     = [System.IO.Path]::Combine($folder, $fileName)

    # Windows (bez dugih putanja) ne podržava putanje od 260 i više znakova; provjera ide PRIJE pisanja da poruka bude jasna
    # (inače bi korisnik vidio "nije moguće pisati / stick zaštićen" ili "putanja nije pronađena").
    $tooLong = 'Putanja izvještaja je preduga ({0} znakova, najviše 258): {1}. Skratite naziv tvrtke ili pokrenite alat s mjesta bliže korijenu pogona.'
    if ($path.Length -gt 258) { throw ($tooLong -f $path.Length, $path) }

    $problem = Test-FolderWritable $folder
    if ($problem) {
        throw ('U mapu za izvještaje nije moguće pisati: {0} ({1}). Provjerite je li stick umetnut, nije li zaštićen od pisanja i postoji li pogon na kojem se nalazi mapa izvještaja.' -f $folder, $problem)
    }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $suffix   = 2
    # Uz PDF se piše i istoimeni .json: ime je slobodno samo ako ne postoji ni jedan ni drugi (inače bi JSON prepisao raniji izvoz).
    while ((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($path, '.json')))) {
        $path = [System.IO.Path]::Combine($folder, ('{0}_{1}.pdf' -f $baseName, $suffix))
        $suffix++
    }
    if ($path.Length -gt 258) { throw ($tooLong -f $path.Length, $path) }

    $script:ReportCompany = $Company
    try {
        Write-Terminal ('Generiram PDF izvještaj: {0}' -f $path) 'Info'
        return (Export-ReportToPdf -Path $path -PrinterName $PrinterName)
    } finally {
        $script:ReportCompany = $null
    }
}
#endregion PORTABLE

