#region HELPERS
function New-Color {
    param([int]$R, [int]$G, [int]$B)
    return [System.Drawing.Color]::FromArgb($R, $G, $B)
}

function Test-FontInstalled {
    param([string]$Name)
    try {
        $installed = New-Object System.Drawing.Text.InstalledFontCollection
        foreach ($family in $installed.Families) {
            if ($family.Name -eq $Name) { return $true }
        }
    } catch { <# namjerno: probiranje fonta: nedostupan font znači da nije instaliran #> }
    return $false
}

# Font iz sistemske obitelji (naziv) ili privatne obitelji (FontFamily iz mape Fonts). Privatna obitelj možda nema traženi stil: tada se bira prvi dostupni.
function New-UiFont {
    param($Family, [double]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    if ($Family -is [System.Drawing.FontFamily]) {
        $use = $null
        foreach ($candidate in @($Style, [System.Drawing.FontStyle]::Regular, [System.Drawing.FontStyle]::Bold, [System.Drawing.FontStyle]::Italic)) {
            if ($Family.IsStyleAvailable($candidate)) { $use = $candidate; break }
        }
        if ($null -ne $use) { return [System.Drawing.Font]::new($Family, [single]$Size, $use, [System.Drawing.GraphicsUnit]::Point) }
        return [System.Drawing.Font]::new('Segoe UI', [single]$Size, $Style)
    }
    return [System.Drawing.Font]::new([string]$Family, [single]$Size, $Style)
}

# Opcionalno: Orbitron*.ttf (naslovi) i Sora*.ttf (tekst) iz mape "Fonts" uz skriptu, bez instalacije u Windows (radi i s USB stika).
# Privatni fontovi se mogu crtati samo GDI+-om (DrawString), pa ih koriste samo ručno crtani elementi (zaglavlje, kartice, gumbi, natpisi);
# RichTextBox i padajući popis ostaju na Segoe UI / Consolas. Bez mape ili uz bilo koju grešku koriste se Bahnschrift / Segoe UI.
function Import-BrandFonts {
    $result = @{ Head = $null; Body = $null }
    try {
        $root = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Directory]::GetCurrentDirectory() }
        $dir = [System.IO.Path]::Combine($root, 'Fonts')
        if (-not [System.IO.Directory]::Exists($dir)) { return $result }
        $collection = New-Object System.Drawing.Text.PrivateFontCollection
        $loaded = 0
        $owner  = @{}
        foreach ($prefix in @('Orbitron', 'Sora')) {
            foreach ($file in @([System.IO.Directory]::GetFiles($dir, ($prefix + '*.ttf')))) {
                try {
                    $collection.AddFontFile($file)
                    $loaded++
                    # Obitelj pripada prefiksu datoteke koja ju je prva unijela (bira se po imenu datoteke, ne po unutarnjem nazivu obitelji).
                    foreach ($known in $collection.Families) {
                        if (-not $owner.ContainsKey($known.Name)) { $owner[$known.Name] = $prefix }
                    }
                } catch { Write-AppLog 'Debug' 'Font: AddFontFile' $_ }
            }
        }
        if ($loaded -eq 0) { $collection.Dispose(); return $result }
        $script:FontCollection = $collection
        foreach ($family in $collection.Families) {
            if ($null -eq $result.Head -and $owner[$family.Name] -eq 'Orbitron') { $result.Head = $family }
            if ($null -eq $result.Body -and $owner[$family.Name] -eq 'Sora')     { $result.Body = $family }
        }
    } catch { Write-AppLog 'Debug' 'Font: AddFontFile' $_ }
    return $result
}

# Oslobađa fontove i njihovu kolekciju (poziva se pri izlasku i na početku Initialize-Resources).
function Remove-AppFonts {
    foreach ($font in @($script:Fonts.Values)) {
        try { $font.Dispose() } catch { Write-Verbose ('Font: ' + $_.Exception.Message) }
    }
    $script:Fonts = @{}
    try {
        if ($script:FontCollection) { $script:FontCollection.Dispose(); $script:FontCollection = $null }
    } catch { Write-Verbose ('FontCollection: ' + $_.Exception.Message) }
}

function Initialize-Resources {
    Remove-AppFonts   # ponovni poziv (npr. testni harness) ne smije iscuriti fontove iz prethodnog poziva
    # Paleta prati stil Auxilium web aplikacije (Nalozi / IT Inventar): tamne plošne površine, obrub od 1 px, jantarni i tirkizni naglasci.
    $script:Colors = @{
        # površine
        Form       = New-Color 9 12 20       # stranica i polja za unos
        Data       = New-Color 9 12 20
        TermBack   = New-Color 9 12 20
        Header     = New-Color 17 24 38      # traka zaglavlja
        Card       = New-Color 22 31 48      # kartice i sekundarne površine
        Button     = New-Color 22 31 48
        ButtonDown = New-Color 17 24 38
        Track      = New-Color 22 31 48
        Line       = New-Color 42 53 80      # svaki obrub od 1 px
        # tekst
        Text       = New-Color 232 236 245
        White      = New-Color 232 236 245
        Muted      = New-Color 139 147 169
        Silver     = New-Color 139 147 169
        Muted2     = New-Color 93 100 120    # nagovještaji, onemogućen tekst
        # naglasci
        Yellow     = New-Color 255 201 74    # jantarna: primarna radnja, aktivno, naglasci
        ButtonHot  = New-Color 201 154 58    # jantarna (hover primarnog gumba)
        OnAmber    = New-Color 19 19 19      # tamni tekst na jantarnoj
        Cyan       = New-Color 95 216 201    # fokus, poveznice, informacije
        Red        = New-Color 255 75 75
        LogoRed    = New-Color 230 57 70     # samo X u logotipu
        Progress   = New-Color 111 224 138
        # terminal
        TermText   = New-Color 232 236 245
        TermHeader = New-Color 95 216 201
        TermOk     = New-Color 111 224 138
        TermWarn   = New-Color 255 201 74
        TermError  = New-Color 255 75 75
        # status
        Good       = New-Color 111 224 138
        Warn       = New-Color 255 201 74
        Bad        = New-Color 255 75 75
    }

    $bold = [System.Drawing.FontStyle]::Bold
    $brand = Import-BrandFonts
    $headFamily = $brand.Head
    $headStyle  = $bold
    if ($null -eq $headFamily) {
        if (Test-FontInstalled 'Bahnschrift') {
            $headFamily = 'Bahnschrift'
        } else {
            $headFamily = 'Segoe UI Semibold'
            $headStyle  = [System.Drawing.FontStyle]::Regular
        }
    }
    $bodyFamily = $brand.Body
    if ($null -eq $bodyFamily) { $bodyFamily = 'Segoe UI' }

    $script:Fonts = @{
        Ui        = New-UiFont 'Segoe UI' 9
        UiBold    = New-UiFont 'Segoe UI' 9 $bold
        Combo     = New-UiFont 'Segoe UI' 10
        Button    = New-UiFont $bodyFamily 9
        Card      = New-UiFont $headFamily 8.5 $headStyle
        Strip     = New-UiFont $headFamily 8 $headStyle
        StripBtn  = New-UiFont $bodyFamily 9
        Hint      = New-UiFont $bodyFamily 8.5
        Mono      = New-UiFont 'Consolas' 9.5
        MonoBold  = New-UiFont 'Consolas' 9.5 $bold
        Term      = New-UiFont 'Consolas' 10
        LogoBold  = New-UiFont $headFamily 22 $headStyle
        LogoLight = New-UiFont $bodyFamily 10
        HeadSub   = New-UiFont $bodyFamily 10
        HeadSmall = New-UiFont $bodyFamily 8.5
        HealthNum = New-UiFont $headFamily 21 $headStyle
    }
}

function Remove-AppResources {
    # Redoslijed: prvo zaustaviti rad i osloboditi formu (kontrole drže reference na fontove), tek onda fontove i njihovu kolekciju.
    try { if ($script:UI.ProgressResetTimer) { $script:UI.ProgressResetTimer.Stop(); $script:UI.ProgressResetTimer.Dispose() } } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> }
    try { Stop-DeepScan } catch { <# namjerno: izlaz iz alata: greška pri zaustavljanju skeniranja nije bitna #> }
    try { if ($script:UI.DeepTimer) { $script:UI.DeepTimer.Stop(); $script:UI.DeepTimer.Dispose() } } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> }
    try { if ($script:UI.LiveTimer) { $script:UI.LiveTimer.Stop(); $script:UI.LiveTimer.Dispose() } } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> }
    try { if ($script:UI.ProgressTimer) { $script:UI.ProgressTimer.Stop(); $script:UI.ProgressTimer.Dispose() } } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> }
    try { if ($script:UI.Form) { $script:UI.Form.Dispose() } } catch { <# namjerno: oslobađanje resursa: greška pri zatvaranju nije bitna #> }
    Remove-AppFonts
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-Duration {
    param([TimeSpan]$Span)
    return ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
}

# Povremeno ispumpa Windows poruke kako sučelje ne bi "zamrznulo" tijekom dugih operacija.
function Update-Ui {
    if ($script:PumpWatch.ElapsedMilliseconds -ge 30) {
        [System.Windows.Forms.Application]::DoEvents()
        $script:PumpWatch.Restart()
    }
}

function Test-StopRequested {
    return ($script:CancelRequested -or $script:Closing)
}

function Wait-TaskUi {
    param($Task, [int]$TimeoutMs = 15000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Task.IsCompleted) {
        if ((Test-StopRequested) -or $watch.ElapsedMilliseconds -gt $TimeoutMs) { return $false }
        Update-Ui
        Start-Sleep -Milliseconds 15
    }
    return $true
}

function Resolve-SystemTool {
    param([Parameter(Mandatory)][string]$Name)
    $dir = Join-Path $env:SystemRoot 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $sysnative = Join-Path $env:SystemRoot 'Sysnative'
        if (Test-Path -LiteralPath $sysnative) { $dir = $sysnative }
    }
    return (Join-Path $dir $Name)
}
# Otisak ove skripte: prvih 8 heksadecimalnih znakova SHA-256 njezine datoteke (prazan niz ako se ne može izračunati, npr. nema datoteke).
function Get-ToolFingerprint {
    param([string]$Path = $PSCommandPath)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))).Replace('-', '')).Substring(0, 8)
    } catch {
        Write-Verbose ('Otisak alata: ' + $_.Exception.Message)
        return ''
    } finally { $sha.Dispose() }
}

# Verzija za prikaz: "0.04" ili "0.04 (D8E2DDDC)" kad je otisak poznat.
function Get-ToolVersionText {
    if ($script:ToolHash) { return ('{0} ({1})' -f $script:AppVersion, $script:ToolHash) }
    return [string]$script:AppVersion
}

# --- Dnevnik na stiku (T1.5): <stick>\Dnevnik\Auxilium_<datum>.log, zadnjih 10 datoteka, bez osobnih podataka.
# Format-AppLogLine je čista funkcija (testira se Pesterom); Write-AppLog radi samo I/O.
# Pozivati se smije samo s UI niti: koristi $script: varijable pa ga funkcije ubačene u runspace ne smiju zvati (provjerava Test-Closure.ps1).
function Format-AppLogLine {
    param([string]$Level, [AllowEmptyString()][string]$Message, $Err = $null, [AllowNull()][string]$UserProfile = $null, [datetime]$Now = [datetime]::Now)
    $line = '{0} [{1,-5}] {2}' -f $Now.ToString('HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture), $Level.ToUpperInvariant(), $Message
    if ($null -ne $Err) {
        $ex = $Err
        $stack = ''
        if ($Err -is [System.Management.Automation.ErrorRecord]) {
            $ex = $Err.Exception
            $stack = [string]$Err.ScriptStackTrace
        }
        $line += ' | ' + $ex.GetType().Name + ': ' + $ex.Message
        if ($stack) { $line += ' @ ' + (($stack -split "`r?`n")[0]) }
    }
    if (-not [string]::IsNullOrEmpty($UserProfile)) { $line = $line.Replace($UserProfile, '%USERPROFILE%') }
    $line = [regex]::Replace($line, '(?i)[A-Za-z]:\\Users\\[^\\\s''"]+', '%USERPROFILE%')   # i profili drugih korisnika
    return ($line -replace '\s*\r?\n\s*', ' ')
}

function Write-AppLog {
    param([ValidateSet('Debug', 'Info', 'Warn', 'Error')][string]$Level, [AllowEmptyString()][string]$Message, $Err = $null)
    if ($script:LogFailed -or [string]::IsNullOrEmpty($script:AppRoot)) { return }
    try {
        if (-not $script:LogPath) {
            $dir = [System.IO.Path]::Combine($script:AppRoot, 'Dnevnik')
            if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
            $old = @([System.IO.Directory]::GetFiles($dir, 'Auxilium_*.log'))
            [Array]::Sort($old, [System.StringComparer]::Ordinal)
            for ($i = 0; $i -lt ($old.Count - 9); $i++) { try { [System.IO.File]::Delete($old[$i]) } catch { Write-Verbose ('Dnevnik: ' + $_.Exception.Message) } }
            $script:LogPath = [System.IO.Path]::Combine($dir, ('Auxilium_{0}.log' -f [datetime]::Now.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)))
        }
        $line = Format-AppLogLine $Level $Message $Err $env:USERPROFILE
        # Ista greška u tajmeru ili crtanju ponavlja se desetke puta u minuti: uzastopni jednaki zapisi (bez vremena) se spajaju u "ponovljeno N puta".
        $signature = $line.Substring([Math]::Min(13, $line.Length))
        if ($signature -ceq $script:LogLastSignature) { $script:LogRepeats++; return }
        $text = ''
        if ($script:LogRepeats -gt 0) { $text = ('{0} [{1,-5}] (prethodni zapis ponovljen još {2} puta)' -f [datetime]::Now.ToString('HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture), 'INFO', $script:LogRepeats) + [Environment]::NewLine }
        $script:LogRepeats = 0
        $script:LogLastSignature = $signature
        $text += $line + [Environment]::NewLine
        [System.IO.File]::AppendAllText($script:LogPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        $script:LogFailed = $true   # stick zaštićen ili izvučen: dnevnik ne smije srušiti alat ni usporavati svaki poziv
    }
}
#endregion HELPERS

