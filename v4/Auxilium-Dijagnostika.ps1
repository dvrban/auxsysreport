#Requires -Version 5.1
<#
.SYNOPSIS
    Auxilium Informatika - Dijagnostika i čišćenje sustava (WinForms GUI).

.DESCRIPTION
    Samostalna aplikacija za IT podršku tvrtke "Auxilium Informatika".
      * automatsko podizanje na administratorska prava (UAC)
      * status sustava (OS, hardver, GPU, printeri, diskovi, zdravlje NVMe/SSD preko Get-PhysicalDisk)
      * softver: Windows/Office licence i verzije, zadani mail klijent, Outlook profili i OST/PST datoteke, popis instaliranih programa
      * neinstalirana Windows ažuriranja i dnevnici događaja za zadnjih 7 dana (prikupljaju se u pozadini)
      * SFC & DISM, CHKDSK (samo čitanje), duboko čišćenje, test mreže
      * PDF izvještaj preko [System.Drawing.Printing] i pisača "Microsoft Print to PDF"

    PORTABLE (USB stick): alat radi s bilo kojeg slova pogona i ništa ne instalira na računalo.
      <stick>\Pokreni-Auxilium.cmd            pokretač (dvoklik)
      <stick>\Auxilium-Dijagnostika.ps1       ova skripta
      <stick>\Auxilium-Postavke.json          zadnja tvrtka, popis tvrtki, korijen izvještaja (nastaje sam)
      <stick>\Izvjestaji\<Tvrtka>\<RACUNALO>_<korisnik>_<datum-vrijeme>.pdf
    Tvrtka / klijent se bira u polju na vrhu prozora; PDF se sprema automatski u mapu te tvrtke.

    Datoteka je spremljena kao UTF-8 s BOM-om kako bi hrvatski dijakritici (Š, Ž, Č, Ć, Đ)
    bili ispravno prikazani u Windows PowerShell 5.1.

.NOTES
    Pokretanje: desni klik -> "Run with PowerShell" ili
    powershell.exe -ExecutionPolicy Bypass -File .\Auxilium-Dijagnostika.ps1
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

#region ENCODING
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch { }
#endregion ENCODING

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

function Test-IsAdministrator {
    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

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
                $logical = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $driveRoot.Substring(0, 2)) -ErrorAction Stop
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

#region NATIVE
if (-not ('Auxilium.NativeMethods' -as [type])) {
    try {
    Add-Type -ErrorAction Stop -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Auxilium
{
    // Panel bez treperenja (dvostruko međuspremanje) - koristi se za zaglavlje s logotipom.
    public class BufferedPanel : Panel
    {
        public BufferedPanel()
        {
            this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                          ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            this.UpdateStyles();
        }
    }

    // GroupBox s tamnim, tankim obrubom i naslovom u boji teksta (standardni GroupBox crta bijeli rub).
    public class CardBox : GroupBox
    {
        private Color borderColor = Color.FromArgb(78, 78, 90);

        public Color BorderColor
        {
            get { return borderColor; }
            set { borderColor = value; this.Invalidate(); }
        }

        public CardBox()
        {
            this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                          ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            this.UpdateStyles();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(this.BackColor);
            TextFormatFlags flags = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix |
                                    TextFormatFlags.SingleLine | TextFormatFlags.Left;
            Size ts = TextRenderer.MeasureText(g, this.Text, this.Font, new Size(int.MaxValue, int.MaxValue), flags);
            int top = ts.Height / 2;
            using (Pen pen = new Pen(borderColor))
            {
                g.DrawRectangle(pen, 0, top, this.Width - 1, this.Height - 1 - top);
            }
            if (this.Text.Length > 0)
            {
                using (SolidBrush brush = new SolidBrush(this.BackColor))
                {
                    g.FillRectangle(brush, 8, 0, ts.Width + 8, ts.Height);
                }
                TextRenderer.DrawText(g, this.Text, this.Font, new Point(12, 0), this.ForeColor, flags);
            }
        }
    }

    public static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SHQUERYRBINFO
        {
            public int cbSize;
            public long i64Size;
            public long i64NumItems;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHQueryRecycleBin(string pszRootPath, ref SHQUERYRBINFO pSHQueryRBInfo);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHEmptyRecycleBin(IntPtr hwnd, string pszRootPath, uint dwFlags);

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr handle);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        // Očuvanje položaja skrolanja RichTextBoxa pri ponovnom crtanju (EM_GETFIRSTVISIBLELINE / EM_LINESCROLL).
        public static int GetFirstVisibleLine(IntPtr handle)
        {
            try { return (int)SendMessage(handle, 0xCE, IntPtr.Zero, IntPtr.Zero); } catch { return 0; }
        }

        public static void ScrollToFirstVisibleLine(IntPtr handle, int line)
        {
            try
            {
                int current = (int)SendMessage(handle, 0xCE, IntPtr.Zero, IntPtr.Zero);
                SendMessage(handle, 0xB6, IntPtr.Zero, (IntPtr)(line - current));
            }
            catch { }
        }

        [DllImport("kernel32.dll")]
        public static extern uint GetOEMCP();

        // Tamna naslovna traka (Windows 10 2004+ / Windows 11); na starijim sustavima se tiho ignorira.
        public static void TryEnableDarkTitleBar(IntPtr handle)
        {
            try
            {
                int on = 1;
                if (DwmSetWindowAttribute(handle, 20, ref on, 4) != 0) { DwmSetWindowAttribute(handle, 19, ref on, 4); }
            }
            catch { }
        }

        public static int QueryRecycleBin(out long size, out long items)
        {
            SHQUERYRBINFO info = new SHQUERYRBINFO();
            info.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO));
            int hr = SHQueryRecycleBin(null, ref info);
            size = info.i64Size;
            items = info.i64NumItems;
            return hr;
        }

        // SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND.
        // Pražnjenje je sinkrono i može trajati; izvodi se na zasebnoj STA niti kako sučelje ne bi zamrznulo.
        public static System.Threading.Tasks.Task<int> EmptyRecycleBinAsync()
        {
            System.Threading.Tasks.TaskCompletionSource<int> tcs = new System.Threading.Tasks.TaskCompletionSource<int>();
            System.Threading.Thread worker = new System.Threading.Thread(delegate ()
            {
                try { tcs.SetResult(SHEmptyRecycleBin(IntPtr.Zero, null, 0x7)); }
                catch (Exception ex) { tcs.SetException(ex); }
            });
            worker.SetApartmentState(System.Threading.ApartmentState.STA);
            worker.IsBackground = true;
            worker.Start();
            return tcs.Task;
        }

        public static void TrySetDarkScrollbars(IntPtr handle)
        {
            try { SetWindowTheme(handle, "DarkMode_Explorer", null); } catch { }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME64 { public uint Low; public uint High; }

        [DllImport("kernel32.dll")]
        private static extern bool GetSystemTimes(out FILETIME64 idle, out FILETIME64 kernel, out FILETIME64 user);

        // Vrijeme procesora (mirovanje i ukupno, jedinice od 100 ns): opterećenje = 1 - razlika(mirovanje) / razlika(ukupno) između dva očitanja.
        // Ne ovisi o jeziku Windowsa (za razliku od brojača performansi s lokaliziranim nazivima).
        public static bool GetCpuTimes(out ulong idle, out ulong total)
        {
            idle = 0; total = 0;
            try
            {
                FILETIME64 i, k, u;
                if (!GetSystemTimes(out i, out k, out u)) { return false; }
                idle = ((ulong)i.High << 32) | i.Low;
                total = (((ulong)k.High << 32) | k.Low) + (((ulong)u.High << 32) | u.Low);
                return true;
            }
            catch { return false; }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private class MEMORYSTATUSEX
        {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);

        // Postotak zauzete fizičke memorije; -1 ako očitanje nije uspjelo.
        public static int GetMemoryLoad()
        {
            try
            {
                MEMORYSTATUSEX s = new MEMORYSTATUSEX();
                if (GlobalMemoryStatusEx(s)) { return (int)s.dwMemoryLoad; }
            }
            catch { }
            return -1;
        }

        public static void TryDestroyIcon(IntPtr handle)
        {
            try { DestroyIcon(handle); } catch { }
        }
    }
}
'@
    } catch {
        # Povišeni proces radi sakriven: bez ove poruke bi neuspjeh prevođenja (npr. antivirus blokira csc.exe) prošao nezamijećeno.
        try {
            [void][System.Windows.Forms.MessageBox]::Show(
                ('Došlo je do fatalne greške:' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message),
                'Auxilium Informatika',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
        } catch { }
        exit 1
    }
}
#endregion NATIVE

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
$script:Health            = $null
$script:HealthState       = 'Loading'
$script:LiveRows          = @{}
$script:CpuPrev           = $null
$script:LogClearSelection = $null
#endregion GLOBAL STATE

#region HELPERS
function New-Color {
    param([int]$R, [int]$G, [int]$B)
    return [System.Drawing.Color]::FromArgb($R, $G, $B)
}

function Initialize-Resources {
    $script:Colors = @{
        Header     = New-Color 17 17 21
        Form       = New-Color 34 34 39
        Card       = New-Color 44 44 51
        Data       = New-Color 30 30 34
        Text       = New-Color 232 232 238
        Muted      = New-Color 150 150 162
        Silver     = New-Color 192 192 200
        White      = [System.Drawing.Color]::White
        Red        = New-Color 230 30 60
        Yellow     = New-Color 255 204 0
        Button     = New-Color 62 62 72
        ButtonHot  = New-Color 84 90 118
        ButtonDown = New-Color 30 30 36
        Progress   = New-Color 0 200 83
        Track      = New-Color 38 38 44
        TermBack   = [System.Drawing.Color]::Black
        TermGreen  = New-Color 0 230 70
        TermHeader = New-Color 190 255 190
        TermOk     = New-Color 90 255 140
        TermWarn   = New-Color 255 204 0
        TermError  = New-Color 255 90 90
        Good       = New-Color 90 220 130
        Warn       = New-Color 255 193 7
        Bad        = New-Color 255 100 100
    }

    $bold = [System.Drawing.FontStyle]::Bold
    $script:Fonts = @{
        Ui        = [System.Drawing.Font]::new('Segoe UI', 9)
        UiBold    = [System.Drawing.Font]::new('Segoe UI', 9, $bold)
        Button    = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
        Card      = [System.Drawing.Font]::new('Segoe UI', 10.5, $bold)
        Strip     = [System.Drawing.Font]::new('Segoe UI', 8.5, $bold)
        StripBtn  = [System.Drawing.Font]::new('Segoe UI', 8.5)
        Hint      = [System.Drawing.Font]::new('Segoe UI', 8.5)
        Mono      = [System.Drawing.Font]::new('Consolas', 9.5)
        MonoBold  = [System.Drawing.Font]::new('Consolas', 9.5, $bold)
        Term      = [System.Drawing.Font]::new('Consolas', 10)
        LogoBold  = [System.Drawing.Font]::new('Segoe UI', 26, $bold)
        LogoLight = [System.Drawing.Font]::new('Segoe UI Light', 26)
        HeadSub   = [System.Drawing.Font]::new('Segoe UI', 10)
        HeadSmall = [System.Drawing.Font]::new('Segoe UI', 8.5)
        HealthNum = [System.Drawing.Font]::new('Segoe UI', 20, $bold)
    }
}

function Remove-AppResources {
    foreach ($key in @($script:Fonts.Keys)) {
        try { $script:Fonts[$key].Dispose() } catch { }
    }
    try { Stop-DeepScan } catch { }
    try { if ($script:UI.DeepTimer) { $script:UI.DeepTimer.Stop(); $script:UI.DeepTimer.Dispose() } } catch { }
    try { if ($script:UI.LiveTimer) { $script:UI.LiveTimer.Stop(); $script:UI.LiveTimer.Dispose() } } catch { }
    try { if ($script:UI.ProgressTimer) { $script:UI.ProgressTimer.Stop(); $script:UI.ProgressTimer.Dispose() } } catch { }
    try { if ($script:UI.Form) { $script:UI.Form.Dispose() } } catch { }
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
#endregion HELPERS

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
    return ('{0}_{1}_{2}.pdf' -f (ConvertTo-SafeName $env:COMPUTERNAME 'racunalo'), (ConvertTo-SafeName (Get-ReportUserName) 'korisnik'), (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
    while (Test-Path -LiteralPath $path) {
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

#region TERMINAL / PROGRESS
function Write-Terminal {
    param(
        [AllowEmptyString()][string]$Text = '',
        [ValidateSet('Normal', 'Header', 'Info', 'Ok', 'Warn', 'Error')][string]$Level = 'Normal'
    )
    try {
        $rtb = $script:UI.Terminal
        if ($null -ne $rtb -and -not $rtb.IsDisposed) {
            $c = $script:Colors
            $color = $c.TermGreen
            if     ($Level -eq 'Header') { $color = $c.TermHeader }
            elseif ($Level -eq 'Ok')     { $color = $c.TermOk }
            elseif ($Level -eq 'Warn')   { $color = $c.TermWarn }
            elseif ($Level -eq 'Error')  { $color = $c.TermError }

            $line = $Text
            if ($Level -ne 'Normal') { $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text }

            if ($rtb.TextLength -gt 1500000) {
                # Ograničenje veličine: RichTextBox je ReadOnly pa se zaštita privremeno skida; reže se na kraju retka.
                $rtb.ReadOnly = $false
                try {
                    $newline = $rtb.Text.IndexOf("`n", 400000)
                    $cut = 400000
                    if ($newline -ge 0) { $cut = $newline + 1 }
                    $rtb.Select(0, $cut)
                    $rtb.SelectedText = ''
                    $rtb.ClearUndo()
                } finally {
                    $rtb.ReadOnly = $true
                }
            }
            $rtb.SelectionStart  = $rtb.TextLength
            $rtb.SelectionLength = 0
            $rtb.SelectionColor  = $color
            $rtb.AppendText($line + "`r`n")
            $rtb.SelectionColor  = $c.TermGreen
            $rtb.SelectionStart  = $rtb.TextLength
            $rtb.ScrollToCaret()
        }
    } catch { }
    Update-Ui
}

function Write-Banner {
    param([string]$Title)
    Write-Terminal '' 'Normal'
    Write-Terminal ('=' * 66) 'Normal'
    Write-Terminal ('>>> ' + $Title) 'Header'
    Write-Terminal ('=' * 66) 'Normal'
}

function Set-ProgressMode {
    param(
        [ValidateSet('Idle', 'Marquee', 'Value')][string]$Mode,
        [int]$Percent = 0
    )
    $track = $script:UI.ProgressTrack
    $fill  = $script:UI.ProgressFill
    $timer = $script:UI.ProgressTimer
    if ($null -eq $track -or $null -eq $fill -or $null -eq $timer) { return }

    $script:ProgressMode = $Mode
    if ($Mode -eq 'Idle') {
        $timer.Stop()
        $fill.Left  = 0
        $fill.Width = 0
    } elseif ($Mode -eq 'Marquee') {
        if (-not $timer.Enabled) {
            $fill.Width = [int]($track.Width * 0.2)
            $fill.Left  = 0
            $timer.Start()
        }
    } else {
        $timer.Stop()
        $pct = [Math]::Min(100, [Math]::Max(0, $Percent))
        $fill.Left  = 0
        $fill.Width = [int]($track.Width * $pct / 100)
    }
}

function Set-BusyState {
    param([bool]$Busy)
    $script:Busy = $Busy
    try {
        foreach ($button in $script:UI.ActionButtons) { $button.Enabled = (-not $Busy) }
        foreach ($control in $script:UI.ClientControls) { $control.Enabled = (-not $Busy) }
        $script:UI.BtnCancel.Enabled = $Busy
        $script:UI.Form.UseWaitCursor = $Busy
        $script:UI.BtnCancel.UseWaitCursor = $false
        if ($Busy) { Set-ProgressMode 'Marquee' } else { Set-ProgressMode 'Idle' }
        if (-not $Busy -and $script:FocusCompanyBox) {
            $script:FocusCompanyBox = $false
            try { [void]$script:UI.CompanyBox.Focus() } catch { }
        }
    } catch { }
}

function Stop-CurrentProcess {
    $proc = $script:CurrentProcess
    if ($null -ne $proc) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
    }
}

function Start-GuiTask {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Command,
        [string]$ConfirmMessage = ''
    )
    if ($script:Busy) { return }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $started   = $false
    try {
        if (-not [string]::IsNullOrEmpty($ConfirmMessage)) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $script:UI.Form, $ConfirmMessage, $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Terminal 'Radnja je otkazana od strane korisnika.' 'Warn'
                return
            }
        }

        $script:CancelRequested = $false
        Set-BusyState $true
        $started = $true
        Write-Banner $Title
        & $Command
        if ($script:CancelRequested) { Write-Terminal 'Zadatak je prekinut.' 'Warn' }
    } catch {
        Write-Terminal ('GREŠKA: {0}' -f $_.Exception.Message) 'Error'
    } finally {
        if ($started) {
            $stopwatch.Stop()
            Write-Terminal ('Gotovo. Trajanje: {0}' -f (Format-Duration $stopwatch.Elapsed)) 'Info'
            Set-BusyState $false
        }
    }
}
#endregion TERMINAL / PROGRESS

#region SYSTEM INFO
function New-InfoItem {
    param(
        [string]$Kind,
        [string]$Label = '',
        [string]$Value = '',
        [string]$Status = 'Normal',
        [double]$Percent = -1
    )
    return [pscustomobject]@{
        Kind    = $Kind
        Label   = $Label
        Value   = $Value
        Status  = $Status
        Percent = $Percent
        Height  = 0.0
        Y       = 0.0
    }
}

function Get-HealthLevel {
    param([string]$Health)
    if ($Health -eq 'Healthy') { return 'Good' }
    if ($Health -eq 'Unhealthy' -or $Health -eq 'Failed') { return 'Bad' }
    return 'Warn'
}

# Storage API vraća engleske nazive stanja; prevode se samo pri prikazu (boja se i dalje određuje iz izvorne vrijednosti).
function ConvertTo-HrHealth {
    param($Value, [switch]$Operational)
    if ($Operational) {
        $map = @{
            'OK' = 'U redu'; 'Degraded' = 'Smanjena izvedba'; 'Predictive Failure' = 'Predviđen kvar'; 'Lost Communication' = 'Izgubljena veza'
            'In Service' = 'U servisu'; 'Stressed' = 'Preopterećen'; 'No Contact' = 'Nema kontakta'
            'Other' = 'Ostalo'; 'Unknown' = 'Nepoznato'; 'Error' = 'Greška'; 'Non-Recoverable Error' = 'Nepopravljiva greška'
            'Starting' = 'Pokreće se'; 'Stopping' = 'Zaustavlja se'; 'Stopped' = 'Zaustavljeno'; 'Aborted' = 'Prekinuto'; 'Dormant' = 'Mirovanje'
            'Supporting Entity in Error' = 'Greška pomoćnog entiteta'; 'Completed' = 'Završeno'; 'Power Mode' = 'Način napajanja'; 'Relocating' = 'Premještanje'
            'Failed Media' = 'Kvar medija'; 'Split' = 'Podijeljeno'; 'Stale Metadata' = 'Zastarjeli metapodaci'; 'IO Error' = 'I/O greška'
            'Unrecognized Metadata' = 'Neprepoznati metapodaci'; 'Removing From Pool' = 'Uklanjanje iz skupa'; 'In Maintenance Mode' = 'Način održavanja'
            'Updating Firmware' = 'Ažuriranje firmwarea'; 'Device Hardware Error' = 'Greška hardvera uređaja'; 'Not Usable' = 'Neupotrebljivo'
            'Transient Error' = 'Privremena greška'; 'Starting Maintenance Mode' = 'Pokretanje načina održavanja'; 'Stopping Maintenance Mode' = 'Zaustavljanje načina održavanja'
            'Threshold Exceeded' = 'Prekoračen prag'; 'Abnormal Latency' = 'Povećana latencija'
        }
    } else {
        $map = @{ 'Healthy' = 'Ispravno'; 'Warning' = 'Upozorenje'; 'Unhealthy' = 'Neispravno'; 'Failed' = 'Kvar'; 'Unknown' = 'Nepoznato' }
    }
    $parts = foreach ($entry in @($Value)) {
        $text = [string]$entry
        if ($map.ContainsKey($text)) { $map[$text] } else { $text }
    }
    return (@($parts) -join ', ')
}

function Get-SystemInfoItems {
    # -Sink: popis koji pozivatelj može pročitati i ako prikupljanje istekne (djelomični rezultati); -ConsoleUser: prijavljeni korisnik (iz predmemorije roditelja).
    param([string]$ConsoleUser = '', $Sink = $null)
    $items = $Sink
    if ($null -eq $items) { $items = New-Object System.Collections.Generic.List[object] }
    $os    = $null

    # --- Operacijski sustav ---
    $items.Add((New-InfoItem 'Section' '' 'OPERACIJSKI SUSTAV'))
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $items.Add((New-InfoItem 'KV' 'Naziv' ([string]$os.Caption).Trim()))

        $display = ''
        try {
            $display = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name DisplayVersion -ErrorAction Stop).DisplayVersion
        } catch { }
        $versionText = '{0} (build {1})' -f $os.Version, $os.BuildNumber
        if (-not [string]::IsNullOrWhiteSpace($display)) { $versionText = '{0} / {1}' -f $versionText, $display }
        $items.Add((New-InfoItem 'KV' 'Verzija' $versionText))
        $items.Add((New-InfoItem 'KV' 'Arhitektura' ([string]$os.OSArchitecture)))
        $items.Add((New-InfoItem 'KV' 'Računalo' $env:COMPUTERNAME))
        $runAs = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ([string]::IsNullOrWhiteSpace($ConsoleUser)) {
            $items.Add((New-InfoItem 'KV' 'Korisnik' $runAs))
        } else {
            $items.Add((New-InfoItem 'KV' 'Korisnik' $ConsoleUser))
            if ($ConsoleUser -ne $runAs) { $items.Add((New-InfoItem 'KV' 'Alat pokrenut kao' $runAs)) }
        }

        $uptime = (Get-Date) - $os.LastBootUpTime
        $items.Add((New-InfoItem 'KV' 'Radi već' ('{0} d {1} h {2} min' -f $uptime.Days, $uptime.Hours, $uptime.Minutes)))
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Podaci o OS-u nisu dostupni: ' + $_.Exception.Message) 'Warn'))
    }

    # --- Hardver ---
    $items.Add((New-InfoItem 'Section' '' 'PROCESSOR, MBO & RAM'))
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $model = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        $items.Add((New-InfoItem 'KV' 'Model' $model))
    } catch { }
    try {
        $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        $boardText = ('{0} {1}' -f $board.Manufacturer, $board.Product).Trim()
        $items.Add((New-InfoItem 'KV' 'Matična ploča' $boardText))
    } catch {
        $items.Add((New-InfoItem 'KV' 'Matična ploča' 'nije dostupno' 'Warn'))
    }
    try {
        $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        foreach ($cpu in $cpus) {
            $cpuName = ([string]$cpu.Name -replace '\s+', ' ').Trim()
            $items.Add((New-InfoItem 'KV' 'Procesor' $cpuName))
            $items.Add((New-InfoItem 'KV' 'Jezgre / niti' ('{0} / {1}' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)))
        }
    } catch {
        $items.Add((New-InfoItem 'KV' 'Procesor' 'nije dostupno' 'Warn'))
    }
    # Opterećenje procesora: prosjek kratkog mjerenja (400 ms); u prozoru se zatim osvježava uživo (Update-LiveMeters).
    try {
        $idle1 = [uint64]0; $total1 = [uint64]0; $idle2 = [uint64]0; $total2 = [uint64]0
        if ([Auxilium.NativeMethods]::GetCpuTimes([ref]$idle1, [ref]$total1)) {
            Start-Sleep -Milliseconds 400
            if ([Auxilium.NativeMethods]::GetCpuTimes([ref]$idle2, [ref]$total2) -and $total2 -gt $total1) {
                $cpuLoad = 100.0 * (1.0 - (([double]($idle2 - $idle1)) / [double]($total2 - $total1)))
                $cpuLoad = [Math]::Min(100.0, [Math]::Max(0.0, $cpuLoad))
                $cpuStatus = 'Good'
                if ($cpuLoad -ge 90) { $cpuStatus = 'Bad' } elseif ($cpuLoad -ge 70) { $cpuStatus = 'Warn' }
                $items.Add((New-InfoItem 'Bar' 'CPU' ('{0:N0} % opterećenje' -f $cpuLoad) $cpuStatus $cpuLoad))
            }
        }
    } catch { }
    if ($null -ne $os) {
        try {
            $totalBytes = [double]$os.TotalVisibleMemorySize * 1KB
            $freeBytes  = [double]$os.FreePhysicalMemory * 1KB
            $freePct    = 0
            if ($totalBytes -gt 0) { $freePct = $freeBytes / $totalBytes * 100 }
            $ramStatus = 'Good'
            if ($freePct -lt 10) { $ramStatus = 'Bad' } elseif ($freePct -lt 20) { $ramStatus = 'Warn' }
            $items.Add((New-InfoItem 'KV' 'RAM ukupno' (Format-Bytes $totalBytes)))
            $items.Add((New-InfoItem 'KV' 'RAM slobodno' ('{0} ({1:N0} %)' -f (Format-Bytes $freeBytes), $freePct) $ramStatus))
            $items.Add((New-InfoItem 'Bar' 'RAM' ('{0:N0} % zauzeto' -f (100 - $freePct)) $ramStatus (100 - $freePct)))
        } catch { }
    }

    # --- Grafička kartica (GPU) ---
    $items.Add((New-InfoItem 'Section' '' 'GRAFIČKA KARTICA (GPU)'))
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        if ($gpus.Count -eq 0) {
            $items.Add((New-InfoItem 'Text' '' 'Nije pronađena nijedna grafička kartica.' 'Warn'))
        }
        $gpuIndex = 0
        foreach ($gpu in $gpus) {
            $gpuIndex++
            $gpuName = ([string]$gpu.Name).Trim()
            $nameStatus = 'Normal'
            if ($gpuName -match 'Basic Display|Basic Render') { $nameStatus = 'Warn' }
            $items.Add((New-InfoItem 'KV' ('GPU ' + $gpuIndex) $gpuName $nameStatus))
            if ($nameStatus -eq 'Warn') {
                $items.Add((New-InfoItem 'KV' '  Napomena' 'instaliran je osnovni Windows driver - nedostaje driver proizvođača' 'Warn'))
            }

            $driverText = [string]$gpu.DriverVersion
            if ($null -ne $gpu.DriverDate) { $driverText = '{0} ({1})' -f $driverText, ([datetime]$gpu.DriverDate).ToString('dd.MM.yyyy.') }
            if (-not [string]::IsNullOrWhiteSpace($driverText)) { $items.Add((New-InfoItem 'KV' '  Driver' $driverText)) }

            # AdapterRAM je 32-bitni i za kartice s 4 GB ili više pokazuje krivu vrijednost: tada se čita QWORD iz registra.
            $vramBytes = 0.0
            if ($null -ne $gpu.AdapterRAM) { $vramBytes = [double]$gpu.AdapterRAM }
            if ($vramBytes -le 0 -or $vramBytes -ge 4290000000) {
                try {
                    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                    foreach ($sub in (Get-ChildItem -LiteralPath $classKey -ErrorAction SilentlyContinue)) {
                        if ($sub.PSChildName -notmatch '^\d{4}$') { continue }
                        $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
                        if ($null -ne $props -and $props.DriverDesc -eq $gpu.Name -and $null -ne $props.'HardwareInformation.qwMemorySize') {
                            $vramBytes = [double]$props.'HardwareInformation.qwMemorySize'
                            break
                        }
                    }
                } catch { }
            }
            if ($vramBytes -gt 0) { $items.Add((New-InfoItem 'KV' '  VRAM' (Format-Bytes $vramBytes))) }

            if ($null -ne $gpu.CurrentHorizontalResolution -and [int]$gpu.CurrentHorizontalResolution -gt 0) {
                $mode = '{0} x {1}' -f $gpu.CurrentHorizontalResolution, $gpu.CurrentVerticalResolution
                if ($null -ne $gpu.CurrentRefreshRate -and [int]$gpu.CurrentRefreshRate -gt 0) { $mode = '{0} @ {1} Hz' -f $mode, $gpu.CurrentRefreshRate }
                $items.Add((New-InfoItem 'KV' '  Zaslon' $mode))
            }
            $gpuState = [string]$gpu.Status
            if (-not [string]::IsNullOrWhiteSpace($gpuState) -and $gpuState -ne 'OK') {
                $items.Add((New-InfoItem 'KV' '  Stanje' $gpuState 'Bad'))
            }
        }
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Podaci o grafičkoj kartici nisu dostupni: ' + $_.Exception.Message) 'Warn'))
    }

    # --- Logički diskovi ---
    $items.Add((New-InfoItem 'Section' '' 'DISKOVI (LOGIČKI)'))
    try {
        $volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop)
        if ($volumes.Count -eq 0) {
            $items.Add((New-InfoItem 'Text' '' 'Nema lokalnih diskova.' 'Warn'))
        }
        foreach ($vol in $volumes) {
            $size  = [double]$vol.Size
            $label = [string]$vol.DeviceID
            if ($size -le 0) {
                $items.Add((New-InfoItem 'KV' $label 'kapacitet nije dostupan (zaključan BitLocker / disk nije spreman?)' 'Warn'))
                continue
            }
            if ($null -eq $vol.FreeSpace) {
                $items.Add((New-InfoItem 'KV' $label ('{0} ukupno, slobodan prostor nije dostupan' -f (Format-Bytes $size)) 'Warn'))
                continue
            }
            $free    = [double]$vol.FreeSpace
            $freePct = $free / $size * 100
            $usedPct = 100 - $freePct
            $status  = 'Good'
            if ($freePct -lt 10) { $status = 'Bad' } elseif ($freePct -lt 20) { $status = 'Warn' }
            $items.Add((New-InfoItem 'KV' $label ('{0} slobodno od {1}' -f (Format-Bytes $free), (Format-Bytes $size)) $status))
            $items.Add((New-InfoItem 'Bar' '' ('{0:N0} % zauzeto' -f $usedPct) $status $usedPct))
        }
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Podaci o diskovima nisu dostupni: ' + $_.Exception.Message) 'Warn'))
    }

    # --- Zdravlje fizičkih diskova (Storage API) ---
    $items.Add((New-InfoItem 'Section' '' 'ZDRAVLJE DISKOVA (NVMe / SSD)'))
    try {
        $physical = @(Get-PhysicalDisk -ErrorAction Stop | Sort-Object { [int]$_.DeviceId })
        if ($physical.Count -eq 0) {
            $items.Add((New-InfoItem 'Text' '' 'Storage API nije vratio nijedan fizički disk.' 'Warn'))
        }
        foreach ($pd in $physical) {
            $media = [string]$pd.MediaType
            if ($media -eq 'Unspecified') { $media = '' }
            $kind = ('{0} {1}' -f $pd.BusType, $media).Trim()
            $title = '{0} ({1}, {2})' -f ([string]$pd.FriendlyName).Trim(), $kind, (Format-Bytes ([double]$pd.Size))
            $items.Add((New-InfoItem 'KV' ('Disk ' + $pd.DeviceId) $title))

            $health = [string]$pd.HealthStatus
            $level  = Get-HealthLevel $health
            $opText = ConvertTo-HrHealth $pd.OperationalStatus -Operational
            $healthText = ConvertTo-HrHealth $health
            if (-not [string]::IsNullOrWhiteSpace($opText)) { $healthText = '{0} / {1}' -f $healthText, $opText }
            $items.Add((New-InfoItem 'KV' '  Zdravlje' $healthText $level))

            try {
                $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
                if ($null -ne $rel) {
                    if ($null -ne $rel.Temperature) {
                        $tempStatus = 'Good'
                        if ($rel.Temperature -ge 70) { $tempStatus = 'Bad' } elseif ($rel.Temperature -ge 55) { $tempStatus = 'Warn' }
                        $items.Add((New-InfoItem 'KV' '  Temperatura' ('{0} °C' -f $rel.Temperature) $tempStatus))
                    }
                    if ($null -ne $rel.Wear) {
                        $wearStatus = 'Good'
                        if ($rel.Wear -ge 90) { $wearStatus = 'Bad' } elseif ($rel.Wear -ge 70) { $wearStatus = 'Warn' }
                        $items.Add((New-InfoItem 'KV' '  Istrošenost' ('{0} %' -f $rel.Wear) $wearStatus))
                    }
                    if ($null -ne $rel.PowerOnHours) {
                        $items.Add((New-InfoItem 'KV' '  Sati rada' ('{0:N0} h' -f $rel.PowerOnHours)))
                    }
                }
            } catch { }
        }
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Get-PhysicalDisk nije dostupan: ' + $_.Exception.Message) 'Warn'))
    }

    # --- Printeri (zadnji odjeljak: upit prema Print Spooleru ne smije blokirati ostale podatke) ---
    $items.Add((New-InfoItem 'Section' '' 'PRINTERI'))
    try {
        $runAsUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if (-not [string]::IsNullOrWhiteSpace($ConsoleUser) -and $ConsoleUser -ne $runAsUser) {
            $items.Add((New-InfoItem 'Text' '' ('Printeri su očitani za račun {0}; osobni (mrežni) printeri i zadani printer korisnika {1} mogu nedostajati ili se razlikovati.' -f $runAsUser, $ConsoleUser) 'Warn'))
        }
        $printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | Sort-Object -Property @{ Expression = { if ($_.Default) { 0 } else { 1 } } }, Name)
        if ($printers.Count -eq 0) {
            $items.Add((New-InfoItem 'Text' '' 'Nema instaliranih printera.'))
        }
        $printerStates = @{ 3 = 'spreman'; 4 = 'ispisuje'; 5 = 'zagrijava se'; 6 = 'ispis zaustavljen'; 7 = 'izvan mreže' }
        # DetectedErrorState: samo vrijednosti 3-8 su jednoznačne u obje Microsoftove tablice.
        $printerErrors = @{ 3 = 'malo papira'; 4 = 'nema papira'; 5 = 'malo tonera'; 6 = 'nema tonera'; 7 = 'otvorena vrata'; 8 = 'zaglavljen papir' }
        foreach ($printer in $printers) {
            $virtual = ([string]$printer.PortName -match '^(PORTPROMPT:|nul:|SHRFAX:|XPSPort:|FILE:|Microsoft\.Office)') -or ([string]$printer.Name -match '^((Microsoft Print to PDF|Microsoft XPS Document Writer|OneNote|Send To OneNote).*|Fax)$')
            $printerLabel = 'Printer'
            if ($printer.Default) { $printerLabel = 'Zadani' }
            $printerText = ([string]$printer.Name).Trim()
            if ($virtual) { $printerText += ' (virtualni)' }
            $items.Add((New-InfoItem 'KV' $printerLabel $printerText))
            if (-not $virtual) {
                if (-not [string]::IsNullOrWhiteSpace([string]$printer.DriverName)) { $items.Add((New-InfoItem 'KV' '  Driver' ([string]$printer.DriverName))) }
                if (-not [string]::IsNullOrWhiteSpace([string]$printer.PortName)) { $items.Add((New-InfoItem 'KV' '  Port' ([string]$printer.PortName))) }

                $pStatus = $null
                if ($null -ne $printer.PrinterStatus) { $pStatus = [int]$printer.PrinterStatus }
                $pError = 0
                if ($null -ne $printer.DetectedErrorState) { $pError = [int]$printer.DetectedErrorState }
                $pExtended = 0
                if ($null -ne $printer.ExtendedPrinterStatus) { $pExtended = [int]$printer.ExtendedPrinterStatus }

                $stateText  = 'spreman'
                $stateLevel = 'Good'
                if ($printer.WorkOffline -or $pStatus -eq 7 -or $pExtended -eq 7) {
                    $stateText = 'izvan mreže'; $stateLevel = 'Warn'
                } elseif ($printerErrors.ContainsKey($pError)) {
                    $stateText = $printerErrors[$pError]; $stateLevel = 'Warn'
                } elseif ($pError -gt 8) {
                    $stateText = ('greška pisača (kod {0})' -f $pError); $stateLevel = 'Warn'
                } elseif ($pExtended -eq 9) {
                    $stateText = 'greška pisača'; $stateLevel = 'Warn'
                } elseif ($pExtended -eq 8 -or $pStatus -eq 6) {
                    $stateText = 'pauziran / zaustavljen'; $stateLevel = 'Warn'
                } elseif ($null -eq $pStatus -or $pStatus -le 2) {
                    $stateText = 'status nepoznat'; $stateLevel = 'Normal'
                } elseif ($printerStates.ContainsKey($pStatus)) {
                    $stateText = $printerStates[$pStatus]
                    if ($pStatus -ge 6) { $stateLevel = 'Warn' }
                }
                $items.Add((New-InfoItem 'KV' '  Stanje' $stateText $stateLevel))
            }
        }
    } catch {
        $items.Add((New-InfoItem 'Text' '' ('Podaci o printerima nisu dostupni (servis Print Spooler?): ' + $_.Exception.Message) 'Warn'))
    }

    return $items
}

function Get-StatusColor {
    param([string]$Status)
    $c = $script:Colors
    if ($Status -eq 'Good') { return $c.Good }
    if ($Status -eq 'Warn') { return $c.Warn }
    if ($Status -eq 'Bad')  { return $c.Bad }
    if ($Status -eq 'Muted') { return $c.Muted }
    return $c.Text
}

function Add-RichText {
    param(
        $Rtb,
        [AllowEmptyString()][string]$Text,
        $Color,
        [bool]$Bold = $false,
        [int]$Indent = 0,
        [int]$Hanging = 0,
        [int[]]$Tabs = $null,
        [bool]$NewLine = $true
    )
    $Rtb.SelectionStart  = $Rtb.TextLength
    $Rtb.SelectionLength = 0
    $Rtb.SelectionColor  = $Color
    if ($Bold) { $Rtb.SelectionFont = $script:Fonts.MonoBold } else { $Rtb.SelectionFont = $script:Fonts.Mono }
    $Rtb.SelectionIndent        = $Indent
    $Rtb.SelectionHangingIndent = $Hanging
    if ($null -ne $Tabs) { $Rtb.SelectionTabs = $Tabs }
    if ($NewLine) { $Rtb.AppendText($Text + "`n") } else { $Rtb.AppendText($Text) }
}

function Show-SystemInfo {
    param($Items, [switch]$KeepScroll)
    $rtb = $script:UI.Status
    $c   = $script:Colors
    $firstLine = 0
    if ($KeepScroll) { try { $firstLine = [Auxilium.NativeMethods]::GetFirstVisibleLine($rtb.Handle) } catch { } }
    $rtb.Clear()
    $script:LiveRows = @{}

    $first = $true
    foreach ($it in $Items) {
        if ($it.Kind -eq 'Section') {
            if (-not $first) { Add-RichText $rtb '' $c.Text }
            Add-RichText $rtb $it.Value $c.Yellow -Bold $true -Indent 6
            Add-RichText $rtb (([string][char]0x2500) * 40) $c.Muted -Indent 6
        } elseif ($it.Kind -eq 'KV') {
            if ([regex]::IsMatch([string]$it.Value, '^(?:\\\\)?[^\s\\\-]{27,}')) {
                # Vrijednost koja počinje predugačkim nedjeljivim nizom (UNC naziv printera, URL porta) ne stane uz oznaku: RichEdit bi zalomio
                # sam tabulator i oznaka bi ostala sama u retku. Takva vrijednost ide u novi redak ispod oznake.
                Add-RichText $rtb $it.Label $c.Muted -Indent 6
                Add-RichText $rtb $it.Value (Get-StatusColor $it.Status) -Indent 112
            } else {
                Add-RichText $rtb ($it.Label + "`t") $c.Muted -Indent 6 -Hanging 106 -Tabs @(112) -NewLine $false
                Add-RichText $rtb $it.Value (Get-StatusColor $it.Status) -Indent 6 -Hanging 106 -Tabs @(112)
            }
        } elseif ($it.Kind -eq 'Bar') {
            $filled = [int][Math]::Round([Math]::Min(100, [Math]::Max(0, $it.Percent)) / 100 * 16)
            $bar = (([string][char]0x2588) * $filled) + (([string][char]0x2591) * (16 - $filled))
            if ([string]::IsNullOrEmpty($it.Label)) {
                Add-RichText $rtb ("`t" + $bar + ' ' + ('{0:N0} %' -f $it.Percent)) (Get-StatusColor $it.Status) -Indent 6 -Hanging 106 -Tabs @(112)
            } else {
                # Bar s oznakom (CPU / RAM) osvježava se uživo (Update-LiveMeters): postotak je fiksne širine pa se položaji redaka ne pomiču.
                Add-RichText $rtb ($it.Label + "`t") $c.Muted -Indent 6 -Hanging 106 -Tabs @(112) -NewLine $false
                $liveStart = $rtb.TextLength
                $liveText  = $bar + ' ' + ('{0,3:N0} %' -f $it.Percent)
                Add-RichText $rtb $liveText (Get-StatusColor $it.Status) -Indent 6 -Hanging 106 -Tabs @(112)
                $script:LiveRows[[string]$it.Label] = @{ Start = $liveStart; Length = $liveText.Length; Item = $it }
            }
        } else {
            Add-RichText $rtb $it.Value (Get-StatusColor $it.Status) -Indent 6
        }
        $first = $false
    }

    $rtb.SelectionStart  = 0
    $rtb.SelectionLength = 0
    $rtb.ScrollToCaret()
    if ($KeepScroll -and $firstLine -gt 0) { try { [Auxilium.NativeMethods]::ScrollToFirstVisibleLine($rtb.Handle, $firstLine) } catch { } }
    # Health Score se računa iz istih stavki koje se prikazuju.
    try { Update-HealthTile $Items } catch { }
}

# Prikupljanje podataka (CIM/Storage upiti) izvodi se u zasebnom runspaceu, a sučelje se pumpa dok se čeka.
# Vraća polje stavki, ili $null ako je prekinuto / isteklo vrijeme.
function Get-SystemInfoItemsAsync {
    param([bool]$HonorCancel = $true, [int]$TimeoutSeconds = 60)

    $names     = @('New-InfoItem', 'Get-HealthLevel', 'Format-Bytes', 'ConvertTo-HrHealth', 'Get-SystemInfoItems')
    $rs        = $null
    $ps        = $null
    $abandoned = $false
    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($name in $names) {
            $body = (Get-Item -LiteralPath ('function:' + $name)).ScriptBlock.ToString()
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($name, $body)))
        }
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        # Popis (List, ne ArrayList: njegov Add vraća indeks i zagadio bi izlaz) u koji funkcija odmah upisuje stavke: ako upit zapne,
        # sve što je do tada prikupljeno ostaje dostupno. Prijavljeni korisnik prosljeđuje se kao parametar (runspace nema vlastitu predmemoriju).
        $sink = New-Object System.Collections.Generic.List[object]
        [void]$ps.AddCommand('Get-SystemInfoItems').AddParameter('Sink', $sink).AddParameter('ConsoleUser', [string](Get-ConsoleUser))
        $async = $ps.BeginInvoke()

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $async.IsCompleted) {
            $stop = ($script:Closing -or ($HonorCancel -and $script:CancelRequested))
            if ($stop -or $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                $abandoned = $true
                $script:AbandonedRunspace = $true
                try { [void]$ps.BeginStop($null, $null) } catch { }
                if (-not $stop) {
                    Write-Terminal 'Prikupljanje podataka o sustavu je isteklo (WMI/CIM ne odgovara).' 'Warn'
                    $partial = @()
                    try { $partial = @($sink.ToArray()) } catch { }
                    if ($partial.Count -gt 0) {
                        $partial += (New-InfoItem 'Text' '' 'Prikupljanje je isteklo: prikazani su samo podaci prikupljeni do tada (WMI/CIM ne odgovara).' 'Warn')
                        return ,$partial
                    }
                }
                return $null
            }
            Update-Ui
            Start-Sleep -Milliseconds 25
        }
        $output = $ps.EndInvoke($async)
        return ,@($output)
    } finally {
        if (-not $abandoned) {
            try { if ($null -ne $ps) { $ps.Dispose() } } catch { }
            try { if ($null -ne $rs) { $rs.Dispose() } } catch { }
        }
    }
}

function Update-SystemStatus {
    param([switch]$IgnoreCancel, [switch]$SkipDeep)

    $rtb = $script:UI.Status
    if ($null -ne $rtb) {
        $rtb.Clear()
        Add-RichText $rtb 'Učitavanje podataka o sustavu...' $script:Colors.Muted -Indent 6
    }
    Write-Terminal 'Prikupljanje informacija o sustavu...' 'Info'

    $items = $null
    try {
        $items = Get-SystemInfoItemsAsync -HonorCancel (-not $IgnoreCancel)
    } catch {
        Write-Terminal ('  Pozadinsko prikupljanje nije uspjelo ({0}); koristim izravan način.' -f $_.Exception.Message) 'Warn'
        $items = @(Get-SystemInfoItems -ConsoleUser ([string](Get-ConsoleUser)))
    }

    if ($null -eq $items) {
        # Prekinuto ili isteklo vrijeme: zadržava se prethodni prikaz.
        if ($null -ne $rtb) {
            if (@($script:SysInfo).Count -gt 0) {
                Show-SystemInfo @(Get-CombinedInfoItems)
            } else {
                $rtb.Clear()
                Add-RichText $rtb 'Podaci o sustavu nisu učitani. Pritisnite "Osvježi".' $script:Colors.Muted -Indent 6
            }
        }
        return
    }

    $script:SysInfo = @($items)
    # Ažuriranja na čekanju i dnevnici (7 dana) prikupljaju se u pozadini; sučelje ostaje slobodno.
    if (-not $SkipDeep) { Start-DeepScan }
    if ($null -ne $rtb) { Show-SystemInfo @(Get-CombinedInfoItems) }
    Write-Terminal 'Status sustava je osvježen.' 'Ok'
    if (-not $SkipDeep -and $script:Deep.State -eq 'Running') {
        Write-Terminal 'Softver (Office, mail), ažuriranja na čekanju i dnevnici događaja (7 dana) učitavaju se u pozadini...' 'Info'
    }
}
#endregion SYSTEM INFO

#region DEEP SCAN
# Neinstalirana ažuriranja (Windows Update API) i dnevnici događaja za zadnjih 7 dana prikupljaju se u ZASEBNOM PowerShell procesu:
# može se prekinuti (Kill), ima vremensko ograničenje i ne drži sučelje. Rezultat dolazi kao JSON preko standardnog izlaza;
# svaki redak je KUMULATIVNI popis stavki (dnevnici se ispisuju prvi, pa još jednom zajedno s ažuriranjima), pa se pri isteku
# vremena (npr. zapela pretraga Windows Updatea) i dalje koristi ono što je do tada stiglo.
function Get-DeepScanScript {
    $source = @'
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
                try { $msg = [string]$first.Message } catch { }
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
        try { $m = [string]$ev.Message } catch { }
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
} catch { }
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
        try { $nla = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction Stop).UserAuthentication } catch { }
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
    try { $pp = (Get-ItemProperty ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $sidText)).ProfileImagePath; if ($pp) { $profilePath = $pp } } catch { }
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
} catch { }

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
} catch { }
$tokenFresh = $false
try {
    $tokDir = $profilePath + '\AppData\Local\Microsoft\Office\Licenses\5'
    if (Test-Path -LiteralPath $tokDir) {
        $tokenFresh = (@(Get-ChildItem -LiteralPath $tokDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-35) }).Count -gt 0)
    }
} catch { }
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
} catch { }
if ($defMail) { Add-Item 'KV' 'Zadani klijent' (Get-Clean $defMail 100) } else { Add-Item 'KV' 'Zadani klijent' 'nije postavljen' }
if ($officeRoot -and (Test-Path -LiteralPath ($officeRoot + '\OUTLOOK.EXE'))) {
    $ov = ''
    try { $ov = (Get-Item -LiteralPath ($officeRoot + '\OUTLOOK.EXE')).VersionInfo.FileVersion } catch { }
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
} catch { }
$mailFiles = @()
$seenDirs = @{}
foreach ($dir in $dirList) {
    $dk = $dir.ToLower()
    if ($seenDirs.ContainsKey($dk)) { continue }
    $seenDirs[$dk] = 1
    try {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $mailFiles += @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(ost|pst|nst)$' })
    } catch { }
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
    } catch { }

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
                    try { $uid = [string]$h.UpdateIdentity.UpdateID } catch { }
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
    } catch { }
} catch {
    Add-Item 'Text' '' ('Windows Update nije dostupan: ' + (Get-Clean $_.Exception.Message 120)) 'Warn'
}
$grpDone.wu = $true
Send-Items
'@
    # Skraćivanje (uvlake i prazni retci) da naredba ostane daleko ispod granice od 32 767 znakova.
    $lines = foreach ($line in ($source -split "`r?`n")) {
        $trimmed = $line.TrimStart()
        if ($trimmed.Length -gt 0) { $trimmed }
    }
    return ($lines -join "`n")
}

function New-RawReader {
    param([System.IO.Stream]$Stream)
    $reader = @{
        Stream = $Stream
        Buffer = New-Object 'byte[]' 8192
        Ms     = New-Object System.IO.MemoryStream
        Task   = $null
        Eof    = $false
    }
    $reader.Task = $Stream.ReadAsync($reader.Buffer, 0, $reader.Buffer.Length)
    return $reader
}

function Remove-DeepTempFile {
    $d = $script:Deep
    if ($d.TempFile) {
        try { [System.IO.File]::Delete([string]$d.TempFile) } catch { }
        $d.TempFile = $null
    }
}

function Stop-DeepScan {
    $d = $script:Deep
    if ($null -ne $d.Process) {
        try { if (-not $d.Process.HasExited) { $d.Process.Kill() } } catch { }
        try { $d.Process.Dispose() } catch { }
    }
    $d.Process = $null
    $d.Readers = @()
    Remove-DeepTempFile
    if ($d.State -eq 'Running') { $d.State = 'Cancelled' }
    if ($null -ne $script:UI.DeepTimer) { try { $script:UI.DeepTimer.Stop() } catch { } }
}

function Start-DeepScan {
    param([string]$ScriptText = '')

    Stop-DeepScan
    $d = $script:Deep
    $d.Items = @()
    $d.Error = ''
    try {
        if ([string]::IsNullOrEmpty($ScriptText)) { $ScriptText = Get-DeepScanScript }
        # Skripta je preduga za -EncodedCommand (granica 32 767 znakova): izvodi se iz privremene datoteke koja se briše nakon završetka.
        $psArgs = $null
        try {
            $tempScript = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('Auxilium_scan_{0}.ps1' -f [guid]::NewGuid().ToString('N')))
            [System.IO.File]::WriteAllText($tempScript, $ScriptText, (New-Object System.Text.UTF8Encoding($true)))
            $d.TempFile = $tempScript
            $psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $tempScript
        } catch {
            $writeError = $_.Exception.Message
            $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptText))
            if ($encoded.Length -gt 30000) { throw ('Privremena skripta nije mogla biti zapisana ({0}), a prevelika je za izravno izvođenje.' -f $writeError) }
            $psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = Resolve-SystemTool 'WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments              = $psArgs
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.WorkingDirectory       = $env:SystemRoot
        # Pozadinski proces čita podatke o Outlooku/programima iz registra PRIJAVLJENOG korisnika (ne administratora koji je pokrenuo alat).
        $consoleUser = [string](Get-ConsoleUser)
        if (-not [string]::IsNullOrWhiteSpace($consoleUser)) { $psi.EnvironmentVariables['AUX_CONSOLE_USER'] = $consoleUser }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $d.Process = $proc
        $d.Readers = @((New-RawReader $proc.StandardOutput.BaseStream), (New-RawReader $proc.StandardError.BaseStream))
        $d.Watch   = [System.Diagnostics.Stopwatch]::StartNew()
        $d.State   = 'Running'
        if ($null -ne $script:UI.DeepTimer) { $script:UI.DeepTimer.Start() }
    } catch {
        $d.State = 'Failed'
        $d.Error = $_.Exception.Message
    }
}

# Stavke prikupljene u pozadini + status (učitavanje / greška) za prikaz u panelu i PDF-u.
function Get-CombinedInfoItems {
    $combined = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($script:SysInfo)) { $combined.Add($item) }
    if ($combined.Count -eq 0) { return $combined }

    $d = $script:Deep
    $title = 'SOFTVER, UPDATE I DNEVNICI (7 DANA)'
    if ($d.State -eq 'Done') {
        foreach ($item in @($d.Items)) { $combined.Add($item) }
    } elseif ($d.State -eq 'Running') {
        $combined.Add((New-InfoItem 'Section' '' $title))
        $combined.Add((New-InfoItem 'Text' '' 'Učitavanje u pozadini (do dvije minute)...' 'Muted'))
    } elseif ($d.State -eq 'Failed' -or $d.State -eq 'Timeout' -or $d.State -eq 'Cancelled') {
        $combined.Add((New-InfoItem 'Section' '' $title))
        $reason = [string]$d.Error
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'prikupljanje je prekinuto' }
        $combined.Add((New-InfoItem 'Text' '' ('Nije dostupno: ' + $reason) 'Warn'))
    }
    return $combined
}

function Update-StatusPanel {
    $rtb = $script:UI.Status
    if ($null -eq $rtb -or $rtb.IsDisposed) { return }
    if (@($script:SysInfo).Count -eq 0) { return }
    Show-SystemInfo @(Get-CombinedInfoItems) -KeepScroll
}

# Čita sve što je pozadinski proces dosad ispisao.
function Read-DeepOutput {
    $d = $script:Deep
    foreach ($reader in @($d.Readers)) {
        while (-not $reader.Eof -and $null -ne $reader.Task -and $reader.Task.IsCompleted) {
            $count = 0
            if (-not $reader.Task.IsFaulted -and -not $reader.Task.IsCanceled) { $count = [int]$reader.Task.Result }
            if ($count -gt 0) {
                $reader.Ms.Write($reader.Buffer, 0, $count)
                $reader.Task = $reader.Stream.ReadAsync($reader.Buffer, 0, $reader.Buffer.Length)
            } else {
                $reader.Eof  = $true
                $reader.Task = $null
            }
        }
    }
}

# Izlaz pozadinskog procesa -> stavke. Vrijedi ZADNJI potpuni redak (kumulativni popis); nepoznate vrste stavki se odbacuju.
function ConvertFrom-DeepBytes {
    param([byte[]]$Bytes, [switch]$Killed)
    $text  = [System.Text.Encoding]::UTF8.GetString($Bytes)
    $lines = @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
    # Nakon nasilnog prekida zadnji redak može biti napola ispisan: odbacuje se ako nije završen novim retkom.
    if ($Killed -and -not $text.EndsWith("`n") -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    if ($lines.Count -eq 0) { throw 'nema potpunog retka s podacima' }
    # PowerShell 5.1 vraća JSON polje kao jedan objekt: ForEach-Object ga raspakira u pojedinačne stavke.
    $parsed = @($lines[$lines.Count - 1] | ConvertFrom-Json | ForEach-Object { $_ })
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $parsed) {
        $kind = [string]$entry.Kind
        if (@('Section', 'KV', 'Text') -notcontains $kind) { continue }
        $status = [string]$entry.Status
        if ([string]::IsNullOrWhiteSpace($status)) { $status = 'Normal' }
        $list.Add((New-InfoItem $kind ([string]$entry.Label) ([string]$entry.Value) $status))
    }
    if ($list.Count -eq 0) { throw 'prazan odgovor' }
    # Bez "," ispred: poziv se omata u @(...) pa bi povratno polje inače postalo polje unutar polja (ugniježđene stavke).
    return $list.ToArray()
}

# Razlog neuspjeha iz standardne pogreške pozadinskog procesa (blokiran skriptom, parse greška...). Putanje i korisničko ime se zamjenjuju
# oznakama jer poruka može završiti u izvještaju za klijenta.
function Get-DeepStderrHint {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    $text = ConvertFrom-ConsoleBytes $Bytes
    if ($text -match '^\s*#< CLIXML') { return '' }
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($ln in ($text -split "`r?`n")) {
        $s = $ln.Trim()
        if (-not $s) { continue }
        if ($s -match '^(At |\+ |Windows PowerShell|Copyright|Install the latest|Try the new)') { continue }
        $keep.Add($s)
    }
    $hint = (($keep.ToArray()) -join ' ')
    $hint = $hint.Replace([System.IO.Path]::GetTempPath(), '%TEMP%\')
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) { $hint = $hint.Replace($env:USERPROFILE, '%USERPROFILE%') }
    $hint = ($hint -replace '\s+', ' ').Trim()
    if ($hint.Length -gt 200) { $hint = $hint.Substring(0, 199) + '...' }
    if ($hint -match '(?i)malicious|virus|blocked|AppLocker|group policy') { $hint += ' (moguće blokirano sigurnosnim programom)' }
    return $hint
}

function Complete-DeepScan {
    $d = $script:Deep
    $bytes = @()
    if (@($d.Readers).Count -gt 0) { $bytes = $d.Readers[0].Ms.ToArray() }
    $errBytes = @()
    if (@($d.Readers).Count -gt 1) { $errBytes = $d.Readers[1].Ms.ToArray() }
    $exitCode = -1
    try { $exitCode = $d.Process.ExitCode } catch { }
    try { $d.Process.Dispose() } catch { }
    $d.Process = $null
    $d.Readers = @()
    Remove-DeepTempFile

    # Bez JSON-a na izlazu (i s pogreškom pri izlasku): skript je blokiran ili se nije mogao pokrenuti, pa se razlog traži u stderr-u.
    $noJson = $true
    if ($bytes.Length -gt 0) {
        $firstChar = [char]$bytes[0]
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $firstChar = '[' }
        if ($firstChar -eq '[' -or $firstChar -eq '{') { $noJson = $false } elseif ($exitCode -eq 0) { $noJson = $false }
    }
    if ($bytes.Length -eq 0 -or ($noJson -and $exitCode -ne 0)) {
        $d.State = 'Failed'
        $d.Error = ('pozadinski proces nije vratio podatke ili je blokiran (kod izlaza {0})' -f $exitCode)
        $hint = ''
        try { $hint = Get-DeepStderrHint $errBytes } catch { $hint = '' }
        if ($hint) { $d.Error += ': ' + $hint }
    } else {
        try {
            $d.Items = @(ConvertFrom-DeepBytes $bytes)
            $d.State = 'Done'
        } catch {
            $d.State = 'Failed'
            $d.Error = ('neispravan odgovor pozadinskog procesa: {0}' -f $_.Exception.Message)
        }
    }
    if ($null -ne $script:UI.DeepTimer) { try { $script:UI.DeepTimer.Stop() } catch { } }

    $message = 'Softver (Office, mail), ažuriranja na čekanju i dnevnici događaja (7 dana) su učitani.'
    $level   = 'Ok'
    if ($d.State -ne 'Done') {
        $message = 'Softver, ažuriranja i dnevnici nisu učitani: ' + $d.Error
        $level = 'Warn'
    }
    Update-StatusPanel
    Write-Terminal $message $level
}

# Istek vremena: proces se prekida, ali ono što je već stiglo (npr. dnevnici događaja dok je pretraga Windows Updatea zapela) se zadržava.
function Stop-DeepScanTimeout {
    param([string]$Why)
    $d = $script:Deep
    $partial = @()
    try {
        Read-DeepOutput
        if (@($d.Readers).Count -gt 0) { $partial = $d.Readers[0].Ms.ToArray() }
    } catch { }
    Stop-DeepScan

    $got = @()
    if ($partial.Length -gt 0) { try { $got = @(ConvertFrom-DeepBytes $partial -Killed) } catch { $got = @() } }
    if ($got.Count -gt 0) {
        # Pozadinski skript sam označava nedovršene skupine (softver / Windows Update) napomenom "nije dovršeno u zadanom roku",
        # pa roditelj ne pogađa uzrok i ne umeće vlastite oznake.
        $d.Items = $got
        $d.State = 'Done'
        $d.Error = ''
        Update-StatusPanel
        Write-Terminal 'Prikupljanje je isteklo: dio podataka nedostaje (vidi napomene u panelu i izvještaju).' 'Warn'
    } else {
        $d.State = 'Timeout'
        $d.Error = $Why
        Update-StatusPanel
        Write-Terminal ('Ažuriranja i dnevnici nisu učitani: ' + $Why) 'Warn'
    }
}

# Poziva ga tajmer sučelja (ili Wait-DeepScan): čita izlaz pozadinskog procesa i prati istek vremena.
function Update-DeepScan {
    $d = $script:Deep
    if ($d.State -ne 'Running') {
        if ($null -ne $script:UI.DeepTimer) { try { $script:UI.DeepTimer.Stop() } catch { } }
        return
    }
    try {
        Read-DeepOutput
        $allEof = (@($d.Readers | Where-Object { -not $_.Eof }).Count -eq 0)
        if ($allEof -and $d.Process.WaitForExit(0)) {
            Complete-DeepScan
            return
        }
        if ($d.Watch.Elapsed.TotalSeconds -gt $d.TimeoutSec) {
            Stop-DeepScanTimeout -Why ('isteklo vrijeme ({0} s)' -f $d.TimeoutSec)
        }
    } catch {
        Stop-DeepScan
        $d.State = 'Failed'
        $d.Error = $_.Exception.Message
        Update-StatusPanel
    }
}

# Čeka završetak pozadinskog prikupljanja uz pumpanje sučelja; prekid zadatka ne ubija prikupljanje.
function Wait-DeepScan {
    param([int]$TimeoutSeconds = 120)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($script:Deep.State -eq 'Running') {
        if (Test-StopRequested) { return $false }
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            Stop-DeepScanTimeout -Why ('isteklo vrijeme ({0} s)' -f $TimeoutSeconds)
            return ($script:Deep.State -eq 'Done')
        }
        Update-DeepScan
        Update-Ui
        Start-Sleep -Milliseconds 100
    }
    return ($script:Deep.State -eq 'Done')
}
#endregion DEEP SCAN


#region LOGS
# Izvoz svih Windows dnevnika događaja u TXT (uz izvještaj), pa brisanje svakog dnevnika TEK NAKON što je njegov izvoz uspješno zapisan i provjeren.
# $script:LogClearSelection: $null = svi dnevnici koji imaju zapise. Izbornik za odabir dnevnika dodaje se kasnije: dovoljno je postaviti popis
# naziva dnevnika (npr. @('System', 'Application')), a ostatak zadatka (izvoz, provjera, brisanje, popis) se ne mijenja.
function Get-LogChannelPlan {
    param($Selection = $null)
    $plan = New-Object System.Collections.Generic.List[object]
    $logs = @(Get-WinEvent -ListLog * -ErrorAction SilentlyContinue)
    foreach ($log in ($logs | Sort-Object -Property LogName)) {
        $records = 0
        if ($null -ne $log.RecordCount) { $records = [int64]$log.RecordCount }
        if ($records -le 0) { continue }
        $name = [string]$log.LogName
        $selected = $true
        if ($null -ne $Selection) { $selected = (@($Selection) -contains $name) }
        $plan.Add([pscustomobject]@{
            Name = $name; Records = $records; SizeBytes = [int64]$log.FileSize; Selected = $selected
            FileName = ''; Exported = $false; Events = 0; Bytes = 0; Cleared = $false; Note = ''
        })
    }
    return $plan.ToArray()
}

# Jedan dnevnik -> TXT (UTF-8 s BOM-om). wevtutil se pokreće s /uni:true (UTF-16), jer bi inače hrvatski znakovi bili izgubljeni (OEM kodna stranica);
# izlaz se tokom pretvara u UTF-8. Broj događaja određuje se iz zadnjeg retka "Event[N]". Vraća @{ Ok; Events; Bytes; Error }.
function Export-EventLogChannel {
    param([Parameter(Mandatory)][string]$Channel, [Parameter(Mandatory)][string]$Path)
    $result = [pscustomobject]@{ Ok = $false; Events = 0; Bytes = 0; Error = '' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = Resolve-SystemTool 'wevtutil.exe'
    $psi.Arguments              = ('qe "{0}" /f:text /uni:true' -f $Channel)
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $proc   = $null
    $writer = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $stream  = $proc.StandardOutput.BaseStream
        $writer  = New-Object System.IO.StreamWriter($Path, $false, (New-Object System.Text.UTF8Encoding($true)))
        $decoder = [System.Text.Encoding]::Unicode.GetDecoder()
        $buffer  = New-Object 'byte[]' 65536
        $chars   = New-Object 'char[]' 65537
        $first   = $true
        $tail    = ''
        $maxIndex = -1
        while ($true) {
            $read = $stream.ReadAsync($buffer, 0, $buffer.Length)
            while (-not $read.IsCompleted) {
                if (Test-StopRequested) {
                    try { $proc.Kill() } catch { }
                    $result.Error = 'prekinuto'
                    return $result
                }
                Update-Ui
                Start-Sleep -Milliseconds 10
            }
            $count = $read.Result
            if ($count -le 0) { break }
            $offset = 0
            if ($first) {
                $first = $false
                if ($count -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) { $offset = 2 }
            }
            $len = $decoder.GetChars($buffer, $offset, ($count - $offset), $chars, 0)
            if ($len -gt 0) {
                $writer.Write($chars, 0, $len)
                $text = $tail + [string]::new($chars, 0, $len)
                foreach ($m in [regex]::Matches($text, '(?m)^Event\[(\d+)\]')) {
                    $idx = [int]$m.Groups[1].Value
                    if ($idx -gt $maxIndex) { $maxIndex = $idx }
                }
                if ($text.Length -gt 24) { $tail = $text.Substring($text.Length - 24) } else { $tail = $text }
            }
        }
        $writer.Flush()
        $writer.Dispose()
        $writer = $null
        while (-not $proc.HasExited) { Update-Ui; Start-Sleep -Milliseconds 10 }
        $errText = ''
        try { $errText = ([string]$errTask.Result).Trim() } catch { }
        $result.Events = $maxIndex + 1
        $result.Bytes  = ([System.IO.FileInfo]$Path).Length
        if ($proc.ExitCode -ne 0) {
            $result.Error = 'wevtutil: ' + $(if ($errText) { $errText } else { 'izlazni kod ' + $proc.ExitCode })
        } elseif ($result.Bytes -le 3) {
            $result.Error = 'izvezena datoteka je prazna'
        } else {
            $result.Ok = $true
        }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($null -ne $writer) { try { $writer.Dispose() } catch { } }
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
    }
    return $result
}

# Briše jedan dnevnik (wevtutil cl). Odvojena funkcija da se u testovima može zamijeniti (testovi nikad ne brišu prave dnevnike).
function Clear-EventLogChannel {
    param([Parameter(Mandatory)][string]$Channel)
    $result = [pscustomobject]@{ Ok = $false; Error = '' }
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = Resolve-SystemTool 'wevtutil.exe'
        $psi.Arguments              = ('cl "{0}"' -f $Channel)
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            if ($watch.Elapsed.TotalSeconds -gt 90) { try { $proc.Kill() } catch { }; $result.Error = 'isteklo vrijeme'; return $result }
            Update-Ui
            Start-Sleep -Milliseconds 10
        }
        $errText = ''
        try { $errText = ([string]$errTask.Result).Trim() } catch { }
        if ($proc.ExitCode -eq 0) { $result.Ok = $true } else { $result.Error = $(if ($errText) { $errText } else { 'izlazni kod ' + $proc.ExitCode }) }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
    }
    return $result
}

function Write-LogManifest {
    param([string]$Path, $Plan, [string]$Stage)
    $nl = [Environment]::NewLine
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('Auxilium Informatika - izvoz dnevnika događaja')
    [void]$sb.AppendLine(('Računalo : {0}' -f $env:COMPUTERNAME))
    [void]$sb.AppendLine(('Korisnik : {0}' -f (Get-ReportUserName)))
    [void]$sb.AppendLine(('Datum    : {0}' -f (Get-Date).ToString('dd.MM.yyyy. HH:mm:ss')))
    [void]$sb.AppendLine(('Verzija  : {0}' -f $script:AppVersion))
    [void]$sb.AppendLine(('Stanje   : {0}' -f $Stage))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Dnevnik | zapisa prije izvoza | izvezeno događaja | datoteka | veličina | brisanje')
    foreach ($e in @($Plan)) {
        if (-not $e.Selected) { continue }
        $cleared = 'nije obrisan'
        if ($e.Cleared) { $cleared = 'obrisan' }
        $size = ''
        if ($e.Exported) { $size = Format-Bytes ([double]$e.Bytes) }
        $note = ''
        if ($e.Note) { $note = '  [' + $e.Note + ']' }
        [void]$sb.AppendLine(('{0} | {1} | {2} | {3} | {4} | {5}{6}' -f $e.Name, $e.Records, $e.Events, $e.FileName, $size, $cleared, $note))
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

function Invoke-EventLogClearTask {
    if (-not $script:IsAdmin) {
        Write-Terminal 'Brisanje dnevnika događaja traži administratorska prava (alat nije pokrenut kao administrator).' 'Error'
        return
    }
    if ($null -ne $script:UI.CompanyBox) { Set-ActiveCompany $script:UI.CompanyBox.Text }
    $company       = Get-ActiveCompany
    $folderCompany = $company
    if ([string]::IsNullOrWhiteSpace($company)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:UI.Form,
            ('Tvrtka / klijent nije postavljena (polje na vrhu prozora).' + [Environment]::NewLine + [Environment]::NewLine +
             'Želite li dnevnike izvesti u mapu "Nerazvrstano"?' + [Environment]::NewLine +
             '(Ne = povratak na unos tvrtke.)'),
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Terminal 'Izvoz i brisanje dnevnika je otkazano: upišite tvrtku / klijenta u polje na vrhu.' 'Warn'
            $script:FocusCompanyBox = $true
            $script:TaskNoResult    = $true
            return
        }
        $folderCompany = 'Nerazvrstano'
    }

    Write-Terminal '  Popis dnevnika događaja koji imaju zapise...' 'Info'
    $plan = @(Get-LogChannelPlan -Selection $script:LogClearSelection | Where-Object { $_.Selected })
    if (Test-StopRequested) { return }
    if ($plan.Count -eq 0) {
        Write-Terminal 'Nema dnevnika događaja sa zapisima (ili nijedan nije odabran).' 'Warn'
        $script:TaskNoResult = $true
        return
    }
    $totalRecords = [int64](($plan | Measure-Object -Property Records -Sum).Sum)
    $totalBytes   = [int64](($plan | Measure-Object -Property SizeBytes -Sum).Sum)

    $folder   = Get-CompanyFolder $folderCompany
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension((Get-ReportFileName)) + '_dnevnici'
    $dir      = [System.IO.Path]::Combine($folder, $baseName)
    $suffix   = 2
    while (Test-Path -LiteralPath $dir) {
        $dir = [System.IO.Path]::Combine($folder, ('{0}_{1}' -f $baseName, $suffix))
        $suffix++
    }
    $room = 258 - ($dir.Length + 1) - 4
    if ($room -lt 20) {
        throw ('Putanja mape za dnevnike je preduga ({0} znakova): {1}. Skratite naziv tvrtke ili pokrenite alat s mjesta bliže korijenu pogona.' -f $dir.Length, $dir)
    }
    $problem = Test-FolderWritable $folder
    if ($problem) {
        throw ('U mapu za izvještaje nije moguće pisati: {0} ({1}). Provjerite je li stick umetnut, nije li zaštićen od pisanja i postoji li pogon na kojem se nalazi mapa izvještaja.' -f $folder, $problem)
    }
    # Slobodan prostor: TXT je otprilike veličine samih dnevnika; traži se 30 % rezerve i 64 MB.
    $need = [int64]($totalBytes * 1.3) + 64MB
    $free = $null
    try {
        $root = [System.IO.Path]::GetPathRoot($dir)
        if (-not [string]::IsNullOrEmpty($root) -and -not $root.StartsWith('\\')) { $free = (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace }
    } catch { }
    if ($null -ne $free -and $free -lt $need) {
        throw ('Na odredišnom pogonu nema dovoljno slobodnog prostora za izvoz dnevnika: potrebno oko {0}, slobodno {1}. Dnevnici nisu dirani.' -f (Format-Bytes ([double]$need)), (Format-Bytes ([double]$free)))
    }

    $estMinutes = [Math]::Max(1, [int][Math]::Ceiling($totalRecords / 1500.0 / 60.0))
    $question = ('Alat će:' + [Environment]::NewLine +
        ('1) izvesti u TXT sve Windows dnevnike događaja koji imaju zapise ({0} dnevnika, ukupno {1} zapisa) u mapu:' -f $plan.Count, $totalRecords) + [Environment]::NewLine +
        $dir + [Environment]::NewLine + [Environment]::NewLine +
        '2) tek nakon uspješno zapisanog i provjerenog izvoza svakog dnevnika taj dnevnik OBRISATI.' + [Environment]::NewLine + [Environment]::NewLine +
        'Brisanje je NEPOVRATNO (uključujući dnevnik Security) i uklanja tragove o događajima u sustavu; ostaju samo TXT datoteke. ' +
        ('Izvoz traje oko {0} min.' -f $estMinutes) + [Environment]::NewLine + [Environment]::NewLine + 'Želite li nastaviti?')
    $answer = [System.Windows.Forms.MessageBox]::Show($script:UI.Form, $question, $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Terminal 'Izvoz i brisanje dnevnika je otkazano od strane korisnika (ništa nije izvezeno ni obrisano).' 'Warn'
        $script:TaskNoResult = $true
        return
    }

    [void][System.IO.Directory]::CreateDirectory($dir)
    Write-Terminal ('Izvoz u mapu: {0}' -f $dir) 'Info'

    # --- 1. Izvoz ---
    $used = @{}
    $index = 0
    foreach ($entry in $plan) {
        $index++
        if (Test-StopRequested) { break }
        $safe = ConvertTo-SafeName (($entry.Name -replace '[\\/]', '_')) 'dnevnik' ([Math]::Min(120, $room))
        $fileName = $safe + '.txt'
        $k = 2
        while ($used.ContainsKey($fileName.ToLowerInvariant())) { $fileName = ('{0}_{1}.txt' -f $safe, $k); $k++ }
        $used[$fileName.ToLowerInvariant()] = $true
        $entry.FileName = $fileName
        Set-ProgressMode 'Value' ([int](70.0 * ($index - 1) / $plan.Count))
        Write-Terminal ('[{0}/{1}] {2}: {3} zapisa...' -f $index, $plan.Count, $entry.Name, $entry.Records) 'Normal'
        $r = Export-EventLogChannel -Channel $entry.Name -Path ([System.IO.Path]::Combine($dir, $fileName))
        $entry.Events = $r.Events
        $entry.Bytes  = $r.Bytes
        if (Test-StopRequested) { break }
        if (-not $r.Ok) {
            $entry.Note = 'izvoz nije uspio: ' + $r.Error
            Write-Terminal ('  NIJE izvezeno: {0}' -f $r.Error) 'Warn'
            continue
        }
        # Provjera: broj izvezenih događaja mora odgovarati broju zapisa (dopušteno je više, jer dnevnik raste dok traje izvoz).
        if ($r.Events -lt ($entry.Records - 5) -and $r.Events -lt [Math]::Floor($entry.Records * 0.98)) {
            $entry.Note = ('provjera nije prošla: izvezeno {0} od {1} događaja' -f $r.Events, $entry.Records)
            Write-Terminal ('  Provjera nije prošla (izvezeno {0} od {1} događaja): dnevnik se NEĆE brisati.' -f $r.Events, $entry.Records) 'Warn'
            continue
        }
        $entry.Exported = $true
        Write-Terminal ('  izvezeno {0} događaja, {1}' -f $r.Events, (Format-Bytes ([double]$r.Bytes))) 'Ok'
    }
    $manifest = [System.IO.Path]::Combine($dir, '00-POPIS.txt')
    if (Test-StopRequested) {
        try { Write-LogManifest -Path $manifest -Plan $plan -Stage 'izvoz prekinut - nijedan dnevnik nije obrisan' } catch { }
        Write-Terminal 'Zadatak je prekinut tijekom izvoza: NIJEDAN dnevnik nije obrisan. Dosad izvezene datoteke ostaju u mapi.' 'Warn'
        return
    }
    $exported = @($plan | Where-Object { $_.Exported })
    $failed   = @($plan | Where-Object { -not $_.Exported })
    try { Write-LogManifest -Path $manifest -Plan $plan -Stage 'izvoz završen, brisanje u tijeku' } catch { Write-Terminal ('Popis (00-POPIS.txt) nije zapisan: {0}' -f $_.Exception.Message) 'Warn' }
    Write-Terminal ('Izvoz je završen: {0} od {1} dnevnika izvezeno{2}.' -f $exported.Count, $plan.Count, $(if ($failed.Count -gt 0) { ', ' + $failed.Count + ' nije' } else { '' })) 'Ok'
    if ($exported.Count -eq 0) {
        Write-Terminal 'Nijedan dnevnik nije uspješno izvezen: ništa se ne briše.' 'Error'
        return
    }

    # --- 2. Brisanje (samo dnevnika čiji je izvoz uspio; Security zadnji) ---
    $ordered = @($exported | Where-Object { $_.Name -ne 'Security' }) + @($exported | Where-Object { $_.Name -eq 'Security' })
    $done = 0
    $clearFailed = 0
    foreach ($entry in $ordered) {
        if (Test-StopRequested) { break }
        $done++
        Set-ProgressMode 'Value' ([int](70.0 + 30.0 * ($done - 1) / $ordered.Count))
        $r = Clear-EventLogChannel -Channel $entry.Name
        if ($r.Ok) {
            $entry.Cleared = $true
        } else {
            $clearFailed++
            $entry.Note = 'brisanje nije uspjelo: ' + $r.Error
            Write-Terminal ('  [{0}/{1}] {2}: brisanje NIJE uspjelo ({3})' -f $done, $ordered.Count, $entry.Name, $r.Error) 'Warn'
        }
    }
    $cleared = @($plan | Where-Object { $_.Cleared }).Count
    try { Write-LogManifest -Path $manifest -Plan $plan -Stage 'završeno' } catch { }
    Set-ProgressMode 'Value' 100
    if (Test-StopRequested) {
        Write-Terminal ('Brisanje je prekinuto: obrisano {0} od {1} izvezenih dnevnika.' -f $cleared, $exported.Count) 'Warn'
    } else {
        Write-Terminal ('Obrisano je {0} dnevnika događaja; TXT kopije su u mapi: {1}' -f $cleared, $dir) 'Ok'
    }
    if ($clearFailed -gt 0) { Write-Terminal ('{0} dnevnika nije bilo moguće obrisati (vidi gore i 00-POPIS.txt).' -f $clearFailed) 'Warn' }
    if ($failed.Count -gt 0) { Write-Terminal ('{0} dnevnika nije obrisano jer izvoz nije uspio ili provjera nije prošla.' -f $failed.Count) 'Warn' }
    Write-Terminal 'Napomena: ocjena stanja (Stabilnost) računa se iz dnevnika zadnjih 7 dana, pa je nakon brisanja povoljnija. Pritisnite "Osvježi" za novi izračun.' 'Info'
}
#endregion LOGS

#region LIVE METERS
# CPU i RAM barovi u statusu sustava osvježavaju se uživo (tajmer, svake 2 s): u retku se zamjenjuje samo tekst bara, uz očuvan položaj skrolanja i
# odabir. Opterećenje procesora računa se iz razlike dvaju očitanja GetSystemTimes (ne ovisi o jeziku Windowsa).
function Set-LiveRow {
    param([string]$Label, [double]$Percent, [string]$Status, [string]$Text)
    $row = $script:LiveRows[$Label]
    if ($null -eq $row) { return }
    $rtb = $script:UI.Status
    $pct = [Math]::Min(100.0, [Math]::Max(0.0, $Percent))
    $filled = [int][Math]::Round($pct / 100 * 16)
    $bar = (([string][char]0x2588) * $filled) + (([string][char]0x2591) * (16 - $filled)) + ' ' + ('{0,3:N0} %' -f $pct)
    if ($bar.Length -ne $row.Length) { return }
    $selStart = $rtb.SelectionStart
    $selLen   = $rtb.SelectionLength
    $firstLine = 0
    try { $firstLine = [Auxilium.NativeMethods]::GetFirstVisibleLine($rtb.Handle) } catch { }
    $rtb.Select($row.Start, $row.Length)
    $rtb.SelectedText = $bar
    $rtb.Select($row.Start, $row.Length)
    $rtb.SelectionColor = (Get-StatusColor $Status)
    $rtb.Select($selStart, $selLen)
    try { [Auxilium.NativeMethods]::ScrollToFirstVisibleLine($rtb.Handle, $firstLine) } catch { }
    # Stavke u $script:SysInfo su iste kao prikazane: PDF izvještaj tako dobiva najnovije vrijednosti.
    $row.Item.Percent = $pct
    $row.Item.Value   = $Text
    $row.Item.Status  = $Status
}

function Update-LiveMeters {
    $rtb = $script:UI.Status
    if ($null -eq $rtb -or $rtb.IsDisposed -or -not $rtb.IsHandleCreated -or $script:Closing) { return }
    $cpuPct = $null
    try {
        $idle = [uint64]0
        $total = [uint64]0
        if ([Auxilium.NativeMethods]::GetCpuTimes([ref]$idle, [ref]$total)) {
            $prev = $script:CpuPrev
            if ($null -ne $prev -and $total -gt $prev.Total) {
                $cpuPct = 100.0 * (1.0 - (([double]($idle - $prev.Idle)) / [double]($total - $prev.Total)))
            }
            $script:CpuPrev = @{ Idle = $idle; Total = $total }
        }
    } catch { }
    if ($script:LiveRows.Count -eq 0) { return }
    if ($null -ne $cpuPct) {
        $st = 'Good'
        if ($cpuPct -ge 90) { $st = 'Bad' } elseif ($cpuPct -ge 70) { $st = 'Warn' }
        Set-LiveRow 'CPU' $cpuPct $st ('{0:N0} % opterećenje' -f $cpuPct)
    }
    $mem = -1
    try { $mem = [int][Auxilium.NativeMethods]::GetMemoryLoad() } catch { }
    if ($mem -ge 0) {
        $st = 'Good'
        if ($mem -ge 90) { $st = 'Bad' } elseif ($mem -ge 80) { $st = 'Warn' }
        Set-LiveRow 'RAM' $mem $st ('{0:N0} % zauzeto' -f $mem)
    }
}
#endregion LIVE METERS

#region HEALTH
# Health Score (0-100): ocjena stanja računala iz stavki koje alat već prikuplja (statusi Good/Warn/Bad i brojači) uz popis razloga.
# Težine: Sigurnost 30, Diskovi 20, Stabilnost 15, Ažuriranja 15, Resursi 10, Licence 5, Pošta 5. Svako područje ima gornju granicu odbitka.
# Područje bez podataka (npr. pozadinsko prikupljanje nije dovršeno) ne ulazi u zbroj, a ocjena se označava kao djelomična.
function Get-HealthResult {
    param($Items)

    $sections = @{}
    $order = New-Object System.Collections.Generic.List[string]
    $current = $null
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        if ($it.Kind -eq 'Section') {
            $current = [string]$it.Value
            if (-not $sections.ContainsKey($current)) {
                $sections[$current] = New-Object System.Collections.Generic.List[object]
                $order.Add($current)
            }
        } elseif ($null -ne $current) {
            $sections[$current].Add($it)
        }
    }

    function Get-Sec {
        param([string]$Prefix)
        foreach ($n in $order) {
            if ($n.StartsWith($Prefix)) { return ,@($sections[$n].ToArray()) }
        }
        return $null
    }
    function Get-Rows {
        param($Sec, [string]$Label)
        if ($null -eq $Sec) { return @() }
        return @($Sec | Where-Object { $_.Kind -eq 'KV' -and ([string]$_.Label).Trim() -eq $Label })
    }
    function Get-Worst {
        param($Rows)
        $worst = 'Good'
        foreach ($r in @($Rows)) {
            if ($r.Status -eq 'Bad') { return 'Bad' }
            if ($r.Status -eq 'Warn') { $worst = 'Warn' }
        }
        return $worst
    }
    function Test-HasRows {
        param($Sec)
        return (($null -ne $Sec) -and (@($Sec | Where-Object { $_.Kind -eq 'KV' }).Count -gt 0))
    }
    function New-Cat {
        param([string]$Name, [int]$Max, [bool]$Avail)
        return [pscustomobject]@{ Name = $Name; Max = $Max; Avail = $Avail; Lost = 0; Items = (New-Object System.Collections.Generic.List[object]) }
    }
    function Lose {
        param($Cat, [int]$Points, [string]$Text)
        if ($Cat.Avail -and $Points -gt 0) {
            $Cat.Lost += $Points
            $Cat.Items.Add([pscustomobject]@{ Points = $Points; Text = $Text; Category = $Cat.Name })
        }
    }

    $cats = New-Object System.Collections.Generic.List[object]
    $sec  = Get-Sec 'SIGURNOST'
    $soft = Get-Sec 'SOFTVER I LICENCE'
    $dl   = Get-Sec 'DISKOVI'
    $dh   = Get-Sec 'ZDRAVLJE DISKOVA'
    $ev   = Get-Sec 'DNEVNICI'
    $wu   = Get-Sec 'WINDOWS UPDATE'
    $hw   = Get-Sec 'PROCESSOR'
    $os   = Get-Sec 'OPERACIJSKI'

    # --- Sigurnost (30) ---
    $cat = New-Cat 'Sigurnost' 30 (Test-HasRows $sec)
    if ($cat.Avail) {
        if ((Get-Worst (Get-Rows $sec 'Antivirus')) -eq 'Bad') { Lose $cat 10 'Antivirus nije pronađen ili je isključen' }
        $w = Get-Worst (Get-Rows $sec 'Definicije')
        if ($w -eq 'Bad') { Lose $cat 4 'Definicije antivirusa su zastarjele (više od 7 dana)' } elseif ($w -eq 'Warn') { Lose $cat 2 'Definicije antivirusa nisu najnovije' }
        $w = Get-Worst (Get-Rows $sec 'Vatrozid')
        if ($w -eq 'Bad') { Lose $cat 6 'Windows vatrozid je isključen' } elseif ($w -eq 'Warn') { Lose $cat 3 'Windows vatrozid je djelomično isključen (provjerite vatrozid antivirusa)' }
        if ((Get-Worst (Get-Rows $sec 'Šifriranje diska')) -ne 'Good') { Lose $cat 4 'Disk nije šifriran (BitLocker) na prijenosnom računalu' }
        # SMBv1 i RDP zajedno najviše 3 boda.
        $pairLeft = 3
        if ((Get-Worst (Get-Rows $sec 'SMBv1')) -eq 'Bad') { Lose $cat 2 'SMBv1 je uključen (zastario protokol)'; $pairLeft -= 2 }
        $w = Get-Worst (Get-Rows $sec 'RDP')
        if ($w -eq 'Bad') { Lose $cat ([Math]::Min(3, $pairLeft)) 'RDP je uključen bez NLA zaštite' } elseif ($w -eq 'Warn') { Lose $cat ([Math]::Min(1, $pairLeft)) 'RDP (udaljeni pristup) je uključen' }
        $w = Get-Worst (Get-Rows $soft 'Windows')
        if ($w -eq 'Bad') { Lose $cat 3 'Windows nije aktiviran' } elseif ($w -eq 'Warn') { Lose $cat 2 'Windows je u odgodi aktivacije' }
    }
    $cats.Add($cat)

    # --- Diskovi (20) ---
    $cat = New-Cat 'Diskovi' 20 ((Test-HasRows $dl) -or (Test-HasRows $dh))
    if ($cat.Avail) {
        $diskName = ''
        foreach ($r in @($dh)) {
            if ($r.Kind -ne 'KV') { continue }
            $lab = ([string]$r.Label).Trim()
            if ($lab -like 'Disk *') { $diskName = [string]$r.Value; if ($diskName.Length -gt 40) { $diskName = $diskName.Substring(0, 40) }; continue }
            if ($lab -eq 'Zdravlje') {
                if ($r.Status -eq 'Bad') { Lose $cat 20 ('Zdravlje fizičkog diska je loše: ' + $diskName) } elseif ($r.Status -eq 'Warn') { Lose $cat 10 ('Zdravlje fizičkog diska je upozorenje: ' + $diskName) }
            } elseif ($lab -eq 'Istrošenost') {
                if ($r.Status -eq 'Bad') { Lose $cat 6 ('SSD je istrošen 90 % ili više: ' + $diskName) } elseif ($r.Status -eq 'Warn') { Lose $cat 3 ('SSD je istrošen 70 % ili više: ' + $diskName) }
            } elseif ($lab -eq 'Temperatura') {
                if ($r.Status -eq 'Bad') { Lose $cat 3 ('Disk je pretopao (70 °C ili više): ' + $diskName) } elseif ($r.Status -eq 'Warn') { Lose $cat 1 ('Disk je topao (55 °C ili više): ' + $diskName) }
            }
        }
        $sysDrive = [string]$env:SystemDrive
        foreach ($r in @($dl)) {
            if ($r.Kind -ne 'KV' -or ($r.Status -ne 'Bad' -and $r.Status -ne 'Warn')) { continue }
            $isSys = ((-not [string]::IsNullOrEmpty($sysDrive)) -and ([string]$r.Label).StartsWith($sysDrive, [System.StringComparison]::OrdinalIgnoreCase))
            $lab = ([string]$r.Label).Trim()
            if ($r.Status -eq 'Bad') {
                if ($isSys) { Lose $cat 8 ('Sistemski disk ' + $lab + ' ima manje od 10 % slobodnog prostora') } else { Lose $cat 3 ('Disk ' + $lab + ' ima manje od 10 % slobodnog prostora') }
            } else {
                if ($isSys) { Lose $cat 4 ('Sistemski disk ' + $lab + ' ima manje od 20 % slobodnog prostora') } else { Lose $cat 1 ('Disk ' + $lab + ' ima manje od 20 % slobodnog prostora') }
            }
        }
    }
    $cats.Add($cat)

    # --- Stabilnost (15): dnevnici događaja zadnjih 7 dana ---
    $cat = New-Cat 'Stabilnost' 15 (@(Get-Rows $ev 'BSOD').Count -gt 0)
    if ($cat.Avail) {
        if ((Get-Worst (Get-Rows $ev 'BSOD')) -eq 'Bad') { Lose $cat 6 'Plavi ekran (BSOD) u zadnjih 7 dana' }
        foreach ($r in @(Get-Rows $ev 'Nepl. gašenja')) {
            $n = 0; [void][int]::TryParse(([string]$r.Value).Trim(), [ref]$n)
            if ($n -ge 3) { Lose $cat 4 ('Neočekivana gašenja računala: ' + $n) } elseif ($n -gt 0) { Lose $cat 2 ('Neočekivana gašenja računala: ' + $n) }
        }
        if ((Get-Worst (Get-Rows $ev 'Greške diska')) -eq 'Bad') { Lose $cat 4 'Greške diska u dnevniku sustava' }
        if ((Get-Worst (Get-Rows $ev 'WHEA (hardv.)')) -eq 'Bad') { Lose $cat 4 'Hardverske greške (WHEA) u dnevniku sustava' }
        foreach ($r in @(Get-Rows $ev 'Rušenja app')) {
            if ($r.Status -eq 'Good') { continue }
            $n = 0; if (([string]$r.Value) -match '^\s*(\d+)') { $n = [int]$Matches[1] }
            if ($n -ge 10) { Lose $cat 4 ('Česta rušenja aplikacija: ' + $n) } else { Lose $cat 2 ('Rušenja aplikacija: ' + $n) }
        }
        $critical = $false; $errorsTotal = 0
        foreach ($logName in @('System', 'Application')) {
            foreach ($r in @(Get-Rows $ev $logName)) {
                if ($r.Status -eq 'Bad') { $critical = $true }
                if (([string]$r.Value) -match 'grešaka:\s*(\d+)') { $errorsTotal += [int]$Matches[1] }
            }
        }
        if ($critical) { Lose $cat 3 'Kritične greške u dnevnicima (System / Application)' }
        if ($errorsTotal -ge 50) { Lose $cat 2 ('Puno grešaka u dnevnicima: ' + $errorsTotal) }
    }
    $cats.Add($cat)

    # --- Ažuriranja (15) ---
    $pending = @(Get-Rows $wu 'Na čekanju')
    $cat = New-Cat 'Ažuriranja' 15 ($pending.Count -gt 0)
    if ($cat.Avail) {
        $n = 0; if (([string]$pending[0].Value) -match '^\s*(\d+)') { $n = [int]$Matches[1] }
        if ($n -ge 10) { Lose $cat 12 ('Neinstaliranih ažuriranja: ' + $n) } elseif ($n -ge 5) { Lose $cat 8 ('Neinstaliranih ažuriranja: ' + $n) } elseif ($n -ge 1) { Lose $cat 4 ('Neinstaliranih ažuriranja: ' + $n) }
        if (@(Get-Rows $wu 'Restart').Count -gt 0) { Lose $cat 2 'Potreban je restart zbog ažuriranja' }
        foreach ($r in @(Get-Rows $wu 'Zadnjih 7 d')) {
            if (([string]$r.Value) -match '(\d+)\s+neuspjel') {
                $f = [int]$Matches[1]
                if ($f -ge 3) { Lose $cat 3 ('Neuspjeli pokušaji ažuriranja u 7 dana: ' + $f) } elseif ($f -ge 1) { Lose $cat 1 ('Neuspjeli pokušaji ažuriranja u 7 dana: ' + $f) }
            }
        }
    }
    $cats.Add($cat)

    # --- Resursi (10) ---
    $ram = @(Get-Rows $hw 'RAM slobodno')
    $up  = @(Get-Rows $os 'Radi već')
    $cat = New-Cat 'Resursi' 10 (($ram.Count -gt 0) -or ($up.Count -gt 0))
    if ($cat.Avail) {
        $w = Get-Worst $ram
        if ($w -eq 'Bad') { Lose $cat 5 'Slobodno je manje od 10 % RAM-a' } elseif ($w -eq 'Warn') { Lose $cat 2 'Slobodno je manje od 20 % RAM-a' }
        if ($up.Count -gt 0 -and ([string]$up[0].Value) -match '^\s*(\d+)\s*d') {
            $days = [int]$Matches[1]
            if ($days -ge 60) { Lose $cat 5 ('Računalo nije restartirano ' + $days + ' dana') } elseif ($days -ge 30) { Lose $cat 3 ('Računalo nije restartirano ' + $days + ' dana') }
        }
    }
    $cats.Add($cat)

    # --- Licence (5) ---
    $cat = New-Cat 'Licence' 5 (Test-HasRows $soft)
    if ($cat.Avail) {
        $w = Get-Worst (Get-Rows $soft 'Office licenca')
        if ($w -eq 'Bad') { Lose $cat 5 'Office licenca nije ispravna' } elseif ($w -eq 'Warn') { Lose $cat 3 'Office licenca traži provjeru (odgoda)' }
        if ((Get-Worst (Get-Rows $soft 'Office update')) -eq 'Warn') { Lose $cat 2 'Automatska ažuriranja Officea su isključena' }
    }
    $cats.Add($cat)

    # --- Pošta (5): velike Outlook datoteke ---
    $cat = New-Cat 'Pošta' 5 (Test-HasRows $soft)
    if ($cat.Avail) {
        $mail = @($soft | Where-Object { $_.Kind -eq 'KV' -and ([string]$_.Value) -match '\.(ost|pst|nst) \(promijenjeno' })
        $w = Get-Worst $mail
        if ($w -eq 'Bad') { Lose $cat 5 'Outlook datoteka od 45 GB ili više' } elseif ($w -eq 'Warn') { Lose $cat 2 'Outlook datoteka od 20 GB ili više' }
    }
    $cats.Add($cat)

    $availMax = 0; $lostTotal = 0; $partial = $false
    foreach ($c in $cats) {
        if ($c.Avail) { $availMax += $c.Max; $lostTotal += [Math]::Min($c.Max, $c.Lost) } else { $partial = $true }
    }
    if ($availMax -le 0) { return $null }
    $score = [int][Math]::Round(100.0 * ($availMax - $lostTotal) / $availMax)
    $label = 'LOŠE'
    if ($score -ge 90) { $label = 'ODLIČNO' } elseif ($score -ge 75) { $label = 'DOBRO' } elseif ($score -ge 50) { $label = 'UPOZORENJE' }
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cats) { foreach ($d in $c.Items) { $all.Add($d) } }
    $sorted = @($all | Sort-Object -Property @{ Expression = 'Points'; Descending = $true })
    return [pscustomobject]@{ Score = $score; Label = $label; Partial = $partial; Deductions = $sorted; Categories = @($cats.ToArray()) }
}

# Redovi za izvještaj (PDF): ocjena, traka i razlozi odbitka.
function Get-HealthReportItems {
    param($Health)
    $items = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Health) { return $items.ToArray() }
    $st = 'Warn'
    if ($Health.Score -ge 90) { $st = 'Good' } elseif ($Health.Score -lt 50) { $st = 'Bad' }
    $text = '{0} / 100 - {1}' -f $Health.Score, $Health.Label
    if ($Health.Partial) { $text += ' (djelomično: neka područja nisu provjerena)' }
    $items.Add((New-InfoItem 'SubSection' '' 'HEALTH/SECURITY SCORE'))
    $items.Add((New-InfoItem 'KV' 'Ocjena' $text $st))
    $items.Add((New-InfoItem 'Bar' '' ('{0} / 100' -f $Health.Score) $st ([double]$Health.Score)))
    foreach ($cat in @($Health.Categories)) {
        if (-not $cat.Avail) {
            $items.Add((New-InfoItem 'KV' $cat.Name 'nije provjereno' 'Muted'))
            continue
        }
        $earned = $cat.Max - [Math]::Min($cat.Max, $cat.Lost)
        $cs = 'Good'
        if ($cat.Lost -gt 0) { if ($cat.Lost -gt 0.4 * $cat.Max) { $cs = 'Bad' } else { $cs = 'Warn' } }
        $items.Add((New-InfoItem 'KV' $cat.Name ('{0} / {1}' -f $earned, $cat.Max) $cs))
    }
    $shown = 0
    foreach ($d in @($Health.Deductions)) {
        if ($shown -ge 8) { break }
        $ds = 'Normal'
        if ($d.Points -ge 8) { $ds = 'Bad' } elseif ($d.Points -ge 3) { $ds = 'Warn' }
        $items.Add((New-InfoItem 'KV' ('-' + $d.Points) ('{0}: {1}' -f $d.Category, $d.Text) $ds))
        $shown++
    }
    if (@($Health.Deductions).Count -eq 0) { $items.Add((New-InfoItem 'Text' '' 'Nema odbitaka: sve provjerene stavke su u redu.' 'Good')) }
    return $items.ToArray()
}

# Kartica "Health Score" na vrhu statusa sustava (ocjena, oznaka i tri najveća razloga odbitka).
function New-HealthTile {
    $c = $script:Colors
    $tile = New-Object Auxilium.BufferedPanel
    $tile.Dock      = 'Top'
    $tile.Height    = 96
    $tile.BackColor = $c.Header
    $tile.Add_Paint({ param($sender, $e) Invoke-HealthPaint $sender $e })
    $script:UI.HealthTile = $tile
    return $tile
}

function Invoke-HealthPaint {
    param($Sender, $E)
    $sf = $null
    $sfRight = $null
    try {
        $g = $E.Graphics
        $c = $script:Colors
        $f = $script:Fonts
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $w = $Sender.Width
        $h = $Sender.Height
        $lineColor = $c.Button
        if ($c.ContainsKey('Line')) { $lineColor = $c.Line }
        $pen = New-Object System.Drawing.Pen ($lineColor)
        try { $g.DrawRectangle($pen, 0, 0, ($w - 1), ($h - 1)) } finally { $pen.Dispose() }

        $health = $script:Health
        $ready = ($script:HealthState -eq 'Ready' -and $null -ne $health)
        $scoreText = [string][char]0x2013
        $labelText = 'NEMA PODATAKA'
        $numColor = $c.Muted
        if ($script:HealthState -eq 'Computing') {
            $scoreText = [string][char]0x2026
            $labelText = 'PROVJERA U TIJEKU'
        } elseif ($ready) {
            $scoreText = '{0} / 100' -f $health.Score
            $labelText = $health.Label
            if ($health.Partial) { $labelText += ' (djelomično)' }
            if ($health.Score -ge 90) { $numColor = $c.Good } elseif ($health.Score -ge 50) { $numColor = $c.Yellow } else { $numColor = $c.Bad }
        }

        $sf = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
        $sf.FormatFlags = $sf.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap
        $sf.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $sfRight = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
        $sfRight.FormatFlags = $sfRight.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap
        $sfRight.Alignment = [System.Drawing.StringAlignment]::Far
        $drawAt = {
            param([string]$Text, $Font, $Color, [double]$X, [double]$Y, [double]$Width, $Format)
            $brush = New-Object System.Drawing.SolidBrush ($Color)
            try { $g.DrawString($Text, $Font, $brush, (New-Object System.Drawing.RectangleF([single]$X, [single]$Y, [single][Math]::Max(10, $Width), [single]($Font.Height + 2))), $Format) } finally { $brush.Dispose() }
        }
        $fillRect = {
            param($Color, [double]$X, [double]$Y, [double]$Width, [double]$Height)
            $brush = New-Object System.Drawing.SolidBrush ($Color)
            try { $g.FillRectangle($brush, [single]$X, [single]$Y, [single]$Width, [single]$Height) } finally { $brush.Dispose() }
        }
        $inner = [double]($w - 28)
        & $drawAt 'Health/Security Score' $f.Ui $c.Text 14 8 $inner $sf
        & $drawAt $scoreText $f.HealthNum $numColor 14 24 $inner $sf

        # Bar ocjene: 20 segmenata (svaki 5 bodova), boja po razini.
        $segments = 20
        $gap = 2.0
        $segW = ($inner - $gap * ($segments - 1)) / $segments
        $lit = 0
        if ($ready) { $lit = [int][Math]::Round($health.Score / 100.0 * $segments) }
        for ($i = 0; $i -lt $segments; $i++) {
            $segColor = $lineColor
            if ($i -lt $lit) { $segColor = $numColor }
            & $fillRect $segColor (14 + $i * ($segW + $gap)) 62 $segW 8
        }
        & $drawAt $labelText $f.UiBold $c.Text 14 76 $inner $sf

        if ($ready) {
            # Mini-barovi po područjima (zadržano bodova / najviše bodova).
            $y = 98.0
            $nameW = 84.0
            $valW = 46.0
            $barX = 14.0 + $nameW + 4.0
            $barW = [Math]::Max(20.0, $inner - $nameW - $valW - 8.0)
            foreach ($cat in @($health.Categories)) {
                & $drawAt ([string]$cat.Name) $f.Hint $c.Muted 14 $y $nameW $sf
                & $fillRect $lineColor $barX ($y + 5) $barW 6
                if ($cat.Avail) {
                    $earned = $cat.Max - [Math]::Min($cat.Max, $cat.Lost)
                    $catColor = $c.Good
                    if ($cat.Lost -gt 0) { if ($cat.Lost -gt 0.4 * $cat.Max) { $catColor = $c.Bad } else { $catColor = $c.Yellow } }
                    if ($earned -gt 0) { & $fillRect $catColor $barX ($y + 5) ($barW * $earned / $cat.Max) 6 }
                    & $drawAt ('{0} / {1}' -f $earned, $cat.Max) $f.Hint $c.Muted ($barX + $barW + 4) $y $valW $sfRight
                } else {
                    & $drawAt ([string][char]0x2013) $f.Hint $c.Muted ($barX + $barW + 4) $y $valW $sfRight
                }
                $y += 14.0
            }
            # Tri najveća razloga odbitka.
            $y += 6.0
            $shown = 0
            foreach ($d in @($health.Deductions)) {
                if ($shown -ge 3) { break }
                & $drawAt ('-{0}  {1}' -f $d.Points, $d.Text) $f.Hint $c.Muted 14 $y $inner $sf
                $y += 15.0
                $shown++
            }
            if (@($health.Deductions).Count -eq 0) { & $drawAt 'Nema odbitaka: sve je u redu.' $f.Hint $c.Muted 14 $y $inner $sf }
        }
    } catch {
    } finally {
        if ($null -ne $sf) { $sf.Dispose() }
        if ($null -ne $sfRight) { $sfRight.Dispose() }
    }
}

# Poziva se nakon svakog iscrtavanja statusa: ocjena se računa iz istih stavki koje se prikazuju.
function Update-HealthTile {
    param($Items)
    $tile = $script:UI.HealthTile
    if ($null -eq $tile -or $tile.IsDisposed) { return }
    $script:Health = $null
    if (@($Items).Count -eq 0) {
        $script:HealthState = 'Loading'
    } elseif ($script:Deep.State -eq 'Running') {
        $script:HealthState = 'Computing'
    } else {
        try { $script:Health = Get-HealthResult $Items } catch { $script:Health = $null }
        $script:HealthState = 'Ready'
    }
    $height = 96
    if ($script:HealthState -eq 'Ready' -and $null -ne $script:Health) {
        $lines = [Math]::Max(1, [Math]::Min(3, @($script:Health.Deductions).Count))
        $height = 98 + 14 * @($script:Health.Categories).Count + 8 + 15 * $lines + 8
    }
    if ($tile.Height -ne $height) { $tile.Height = $height }
    $tile.Invalidate()
}
#endregion HEALTH

#region LIVE PROCESS
function ConvertFrom-ConsoleBytes {
    param([byte[]]$Bytes)
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($Bytes)
    } catch { }
    try {
        $oem = [System.Text.Encoding]::GetEncoding([int][Auxilium.NativeMethods]::GetOEMCP())
        return $oem.GetString($Bytes)
    } catch {
        return [System.Text.Encoding]::Default.GetString($Bytes)
    }
}

function New-OutputReader {
    param([System.IO.Stream]$Stream)
    $reader = @{
        Stream  = $Stream
        Buffer  = New-Object 'byte[]' 8192
        Task    = $null
        Pending = New-Object 'System.Collections.Generic.List[byte]'
        Mode    = $null
        Text    = ''
        Done    = $false
    }
    $reader.Task = $Stream.ReadAsync($reader.Buffer, 0, $reader.Buffer.Length)
    return $reader
}

function Write-ProcessLine {
    param([string]$Line)

    $text = ($Line -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '').TrimEnd()
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $script:LastProcessOutput.Add($text)

    # Retci koji sadrže samo postotak napretka (SFC, DISM...) pokreću traku napretka i ispisuju se rijetko.
    if ($text -match '^\D*(\d{1,3})(?:[.,]\d+)?\s*%\D*$') {
        $pct = [Math]::Min(100, [int]$Matches[1])
        Set-ProgressMode 'Value' $pct
        $bucket = [int][Math]::Floor($pct / 10)
        if ($bucket -eq $script:LastPctBucket) { return }
        $script:LastPctBucket = $bucket
    }
    [void]$script:LineBatch.Add('  ' + $text)
}

# Ispisuje nakupljene retke jednim pozivom (ScrollToCaret po retku bi jako usporio velik izlaz).
function Send-ProcessBatch {
    if ($script:LineBatch.Count -gt 0) {
        $block = $script:LineBatch -join "`r`n"
        $script:LineBatch.Clear()
        Write-Terminal $block 'Normal'
    }
}

function Write-ProcessText {
    param($Reader, [switch]$Flush)

    $idx = [Math]::Max($Reader.Text.LastIndexOf("`n"), $Reader.Text.LastIndexOf("`r"))
    $complete = ''
    if ($Flush) {
        $complete = $Reader.Text
        $Reader.Text = ''
    } elseif ($idx -ge 0) {
        $complete = $Reader.Text.Substring(0, $idx + 1)
        $Reader.Text = $Reader.Text.Substring($idx + 1)
    }
    if ($complete.Length -gt 0) {
        foreach ($line in ($complete -split '[\r\n]+')) { Write-ProcessLine $line }
        Send-ProcessBatch
    }
}

# Prepoznaje kodiranje izlaza: UTF-16LE (SFC) ima BOM ili NUL bajtove, a 8-bitni tekst konzole nikad ne sadrži NUL.
function Set-OutputReaderMode {
    param($Reader)
    $pending = $Reader.Pending
    if ($pending.Count -ge 2 -and [int]$pending[0] -eq 255 -and [int]$pending[1] -eq 254) {
        $pending.RemoveRange(0, 2)
        $Reader.Mode = 'Utf16'
        return
    }
    $Reader.Mode = 'Byte'
    foreach ($value in $pending) {
        if ($value -eq 0) { $Reader.Mode = 'Utf16'; break }
    }
}

# Dekodira izlaz procesa: SFC piše UTF-16LE, ostali alati UTF-8 ili OEM kodnu stranicu.
function Receive-OutputChunk {
    param($Reader, [int]$Count)

    $chunk = New-Object 'byte[]' $Count
    [System.Array]::Copy($Reader.Buffer, 0, $chunk, 0, $Count)
    $Reader.Pending.AddRange($chunk)

    if ($null -eq $Reader.Mode -and $Reader.Pending.Count -ge 4) { Set-OutputReaderMode $Reader }
    if ($null -eq $Reader.Mode) { return }

    if ($Reader.Mode -eq 'Utf16') {
        $even = $Reader.Pending.Count - ($Reader.Pending.Count % 2)
        if ($even -gt 0) {
            $bytes = $Reader.Pending.GetRange(0, $even).ToArray()
            $Reader.Pending.RemoveRange(0, $even)
            $Reader.Text += [System.Text.Encoding]::Unicode.GetString($bytes)
        }
    } else {
        $last = -1
        for ($i = $Reader.Pending.Count - 1; $i -ge 0; $i--) {
            $value = [int]$Reader.Pending[$i]
            if ($value -eq 10 -or $value -eq 13) { $last = $i; break }
        }
        if ($last -ge 0) {
            $bytes = $Reader.Pending.GetRange(0, $last + 1).ToArray()
            $Reader.Pending.RemoveRange(0, $last + 1)
            $Reader.Text += (ConvertFrom-ConsoleBytes $bytes)
        }
    }
    Write-ProcessText $Reader
}

function Complete-OutputReader {
    param($Reader)
    if ($Reader.Pending.Count -gt 0) {
        if ($null -eq $Reader.Mode) { Set-OutputReaderMode $Reader }
        $bytes = $Reader.Pending.ToArray()
        $Reader.Pending.Clear()
        if ($Reader.Mode -eq 'Utf16') {
            $even = $bytes.Length - ($bytes.Length % 2)
            if ($even -gt 0) { $Reader.Text += [System.Text.Encoding]::Unicode.GetString($bytes, 0, $even) }
        } else {
            $Reader.Text += (ConvertFrom-ConsoleBytes $bytes)
        }
    }
    Write-ProcessText $Reader -Flush
}

# Pokreće vanjski alat i uživo prosljeđuje izlaz u terminal, bez blokiranja sučelja.
function Invoke-LiveProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = ''
    )

    $script:LastPctBucket     = -1
    $script:LastProcessOutput = New-Object System.Collections.Generic.List[string]
    $script:LineBatch.Clear()

    if (-not (Test-Path -LiteralPath $FilePath)) { throw ('Alat nije pronađen: {0}' -f $FilePath) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.WorkingDirectory       = $env:SystemRoot

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $exitCode = -1
    $readers  = @()

    try {
        Write-Terminal ('> {0} {1}' -f [System.IO.Path]::GetFileName($FilePath), $Arguments) 'Info'
        [void]$proc.Start()
        $script:CurrentProcess = $proc
        $readers = @(
            (New-OutputReader $proc.StandardOutput.BaseStream),
            (New-OutputReader $proc.StandardError.BaseStream)
        )
        Set-ProgressMode 'Marquee'

        while ($true) {
            $active = $false
            $gotData = $false
            foreach ($reader in $readers) {
                if ($reader.Done) { continue }
                $active = $true
                if ($reader.Task.IsCompleted) {
                    $count = 0
                    if (-not $reader.Task.IsFaulted -and -not $reader.Task.IsCanceled) { $count = [int]$reader.Task.Result }
                    if ($count -gt 0) {
                        $gotData = $true
                        Receive-OutputChunk $reader $count
                        $reader.Task = $reader.Stream.ReadAsync($reader.Buffer, 0, $reader.Buffer.Length)
                    } else {
                        Complete-OutputReader $reader
                        $reader.Done = $true
                    }
                }
            }
            if (-not $active) { break }
            if (Test-StopRequested) {
                try { $proc.Kill() } catch { }
                Write-Terminal 'Proces je prekinut na zahtjev korisnika.' 'Warn'
                break
            }
            Update-Ui
            if (-not $gotData) { Start-Sleep -Milliseconds 20 }
        }

        while (-not $proc.WaitForExit(100)) {
            if (Test-StopRequested) { try { $proc.Kill() } catch { }; [void]$proc.WaitForExit(2000); break }
            Update-Ui
        }
        if ($proc.HasExited) { $exitCode = $proc.ExitCode }
    } finally {
        $script:CurrentProcess = $null
        try { Send-ProcessBatch } catch { }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        try { $proc.Dispose() } catch { }
    }
    return $exitCode
}
#endregion LIVE PROCESS

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

#region TASKS - CISCENJE
function ConvertTo-ExtendedPath {
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return ('\\?\UNC\' + $Path.Substring(2)) }
    return ('\\?\' + $Path)
}

function Remove-DirectoryTree {
    param([System.IO.DirectoryInfo]$Directory, $Result)

    try { $entries = $Directory.GetFileSystemInfos() } catch { $Result.Skipped++; return }

    foreach ($entry in $entries) {
        if (Test-StopRequested) { return }
        try {
            $isDir  = (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            $isLink = (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

            if ($isDir -and -not $isLink) {
                $skippedBefore = $Result.Skipped
                Remove-DirectoryTree -Directory $entry -Result $Result
                $keepKey = $entry.FullName
                if ($keepKey.StartsWith('\\?\')) { $keepKey = $keepKey.Substring(4) }
                if ($script:KeepDirs -and $script:KeepDirs.ContainsKey($keepKey.TrimEnd('\').ToLowerInvariant())) { continue }
                try {
                    if (($entry.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { $entry.Attributes = [System.IO.FileAttributes]::Directory }
                    $entry.Delete()
                    $Result.Folders++
                } catch {
                    # Mapa se nije mogla obrisati: broji se samo ako unutra nije već preskočena neka stavka.
                    if ($Result.Skipped -eq $skippedBefore) { $Result.Skipped++ }
                }
            } elseif ($isDir) {
                # Junction / simbolička veza: briše se samo veza, nikad sadržaj cilja.
                $entry.Delete()
                $Result.Folders++
            } else {
                $length = 0
                try { $length = $entry.Length } catch { }
                if ($entry.IsReadOnly) { $entry.IsReadOnly = $false }
                $entry.Delete()
                $Result.Files++
                $Result.Bytes += $length
            }
        } catch {
            $Result.Skipped++
        }
        Update-Ui
    }
}

function Remove-FolderContent {
    param([AllowNull()][AllowEmptyString()][string]$Path)

    $result = [pscustomobject]@{ Path = $Path; Files = 0; Folders = 0; Bytes = [long]0; Skipped = 0; Refused = $false; Reason = '' }
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $result.Refused = $true; $result.Reason = 'putanja nije zadana'; return $result
        }
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $result.Path = $full
        $leaf = [System.IO.Path]::GetFileName($full)
        $root = [System.IO.Path]::GetPathRoot($full)

        if ([string]::IsNullOrWhiteSpace($leaf) -or ($full + '\') -eq $root) {
            $result.Refused = $true; $result.Reason = 'korijen diska nije dopušten'; return $result
        }
        if ($leaf -notin @('Temp', 'Tmp', 'Download')) {
            $result.Refused = $true; $result.Reason = 'neočekivana lokacija (dopušteno: Temp, Tmp, Download)'; return $result
        }
        if (-not [System.IO.Directory]::Exists($full)) {
            $result.Refused = $true; $result.Reason = 'mapa ne postoji'; return $result
        }
        # Prošireni put (\\?\) omogućuje brisanje stavki dužih od MAX_PATH i imena koja završavaju točkom ili razmakom.
        $dir = New-Object System.IO.DirectoryInfo((ConvertTo-ExtendedPath $full))
        if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $result.Refused = $true; $result.Reason = 'mapa je simbolička veza / junction'; return $result
        }

        Remove-DirectoryTree -Directory $dir -Result $result
    } catch {
        $result.Refused = $true
        $result.Reason  = $_.Exception.Message
    }
    return $result
}

function Write-CleanupResult {
    param($Result, [string]$Label)
    if ($Result.Refused) {
        Write-Terminal ('  {0}: preskočeno - {1}' -f $Label, $Result.Reason) 'Warn'
        return
    }
    $level = 'Ok'
    if ($Result.Skipped -gt 0) { $level = 'Info' }
    Write-Terminal ('  {0}: obrisano {1} datoteka, {2} mapa, oslobođeno {3}; nije obrisano (u upotrebi/zaštićeno): {4}' -f `
        $Label, $Result.Files, $Result.Folders, (Format-Bytes ([double]$Result.Bytes)), $Result.Skipped) $level
}

function Get-TempFolderTargets {
    $targets    = New-Object System.Collections.Generic.List[string]
    $seen       = @{}
    $candidates = @($env:TEMP, [System.IO.Path]::GetTempPath(), (Join-Path $env:LOCALAPPDATA 'Temp'), (Join-Path $env:SystemRoot 'Temp'))
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try { $normalized = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\') } catch { continue }
        $key = $normalized.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $targets.Add($normalized) }
    }

    # Cilj koji leži unutar drugog cilja (npr. Temp\2 pod RDP-om) preskače se: roditelj ga ionako prazni.
    $final = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $targets) {
        $leaf  = [System.IO.Path]::GetFileName($candidate)
        $under = $false
        if (@('Temp', 'Tmp', 'Download') -notcontains $leaf) {
            foreach ($other in $targets) {
                if ($other -ne $candidate -and $candidate.StartsWith($other + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $under = $true; break }
            }
        }
        if (-not $under) { $final.Add($candidate) }
    }
    return $final
}

# Korak 1: korisnički i sistemski TEMP. Vraća broj obrisanih bajtova.
function Clear-TempFolders {
    $freed = [double]0

    # Aktivni TEMP/TMP ove sesije se prazni, ali se sama mapa ne briše (npr. Temp\2 pod RDP-om).
    $script:KeepDirs = @{}
    foreach ($active in @($env:TEMP, $env:TMP, [System.IO.Path]::GetTempPath())) {
        if ([string]::IsNullOrWhiteSpace($active)) { continue }
        try { $script:KeepDirs[[System.IO.Path]::GetFullPath($active).TrimEnd('\').ToLowerInvariant()] = $true } catch { }
    }
    try {
        foreach ($target in @(Get-TempFolderTargets)) {
            if (Test-StopRequested) { break }
            if (-not (Test-Path -LiteralPath $target)) { continue }
            $res = Remove-FolderContent -Path $target
            Write-CleanupResult $res $target
            $freed += [double]$res.Bytes
        }
    } finally {
        $script:KeepDirs = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP) -and -not (Test-Path -LiteralPath $env:TEMP)) {
        try { [void](New-Item -ItemType Directory -Path $env:TEMP -Force) } catch { }
    }
    return $freed
}

# Čeka stanje servisa uz pumpanje sučelja (ograničeno vrijeme, može se prekinuti).
function Wait-ServiceUi {
    param($Service, [string]$Target, [int]$Seconds = 30, [bool]$HonorCancel = $true)
    $until = (Get-Date).AddSeconds($Seconds)
    do {
        $Service.Refresh()
        if (([string]$Service.Status) -eq $Target) { return $true }
        Update-Ui
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $until -and -not ($HonorCancel -and (Test-StopRequested)))
    $Service.Refresh()
    return (([string]$Service.Status) -eq $Target)
}

# Korak 2: zaustavi wuauserv, očisti SoftwareDistribution\Download, ponovno pokreni wuauserv. Vraća broj obrisanih bajtova.
function Clear-UpdateCache {
    $freed       = [double]0
    $serviceName = 'wuauserv'
    $service     = $null
    try {
        $service = Get-Service -Name $serviceName -ErrorAction Stop
    } catch {
        Write-Terminal ('  Servis {0} nije pronađen: {1}' -f $serviceName, $_.Exception.Message) 'Warn'
        return $freed
    }

    $stopped = $false
    try {
        try {
            $service.Refresh()
            if (@('Stopped', 'StopPending') -notcontains ([string]$service.Status)) {
                Write-Terminal '  Zaustavljam servis Windows Update (wuauserv)...' 'Info'
                Stop-Service -Name $serviceName -Force -NoWait -ErrorAction Stop
            }
            $stopped = Wait-ServiceUi -Service $service -Target 'Stopped' -Seconds 30 -HonorCancel $true
        } catch {
            Write-Terminal ('  Servis se nije mogao zaustaviti: {0}' -f $_.Exception.Message) 'Warn'
        }

        if ($stopped) {
            Write-Terminal '  Servis je zaustavljen.' 'Ok'
            $download = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
            if (Test-Path -LiteralPath $download) {
                $res = Remove-FolderContent -Path $download
                Write-CleanupResult $res $download
                $freed += [double]$res.Bytes
            } else {
                Write-Terminal '  Mapa SoftwareDistribution\Download ne postoji.' 'Info'
            }
        } else {
            Write-Terminal '  Predmemorija nije očišćena jer se servis nije zaustavio.' 'Warn'
        }
    } finally {
        # Servis se uvijek vraća u rad, čak i ako je došlo do greške ili prekida.
        try {
            $svc = Get-Service -Name $serviceName -ErrorAction Stop
            $startType = ''
            try { $startType = [string]$svc.StartType } catch { }
            if ($startType -eq 'Disabled') {
                Write-Terminal '  Servis wuauserv je onemogućen (Disabled) - ostaje zaustavljen.' 'Warn'
            } else {
                if (([string]$svc.Status) -eq 'StopPending') {
                    Write-Terminal '  Čekam da se servis wuauserv zaustavi radi ponovnog pokretanja (prekid se primjenjuje nakon toga)...' 'Info'
                    [void](Wait-ServiceUi -Service $svc -Target 'Stopped' -Seconds 30 -HonorCancel $false)
                }
                $svc.Refresh()
                $state = [string]$svc.Status
                if ($state -eq 'StopPending') {
                    Write-Terminal '  Servis wuauserv se i dalje zaustavlja; ponovno pokretanje je preskočeno. Pokrenite ga ručno ako zatreba.' 'Warn'
                } else {
                    if ($state -eq 'Stopped') {
                        try {
                            $svc.Start()
                        } catch {
                            # Servis je mogao biti pokrenut izvana (npr. greška 1056); bitno je stvarno stanje, ne oblik iznimke.
                            $svc.Refresh()
                            if (@('Running', 'StartPending') -notcontains ([string]$svc.Status)) { throw }
                        }
                    }
                    if (Wait-ServiceUi -Service $svc -Target 'Running' -Seconds 30 -HonorCancel $false) {
                        Write-Terminal '  Servis Windows Update (wuauserv) je ponovno pokrenut.' 'Ok'
                    } else {
                        Write-Terminal '  Servis wuauserv nije prešao u stanje Running u roku od 30 s.' 'Warn'
                    }
                }
            }
        } catch {
            Write-Terminal ('  Servis wuauserv nije bilo moguće ponovno pokrenuti: {0}' -f $_.Exception.Message) 'Error'
        }
    }
    return $freed
}

# Korak 3: prazni koš za smeće (Shell API, bez dijaloga; pražnjenje ide na zasebnoj STA niti da sučelje ostane živo).
function Clear-RecycleBinContent {
    try {
        $binSize  = [long]0
        $binItems = [long]0
        $hr = [Auxilium.NativeMethods]::QueryRecycleBin([ref]$binSize, [ref]$binItems)
        if ($hr -eq 0 -and $binItems -eq 0) {
            Write-Terminal '  Koš za smeće je već prazan.' 'Info'
            return
        }
        if ($hr -eq 0) {
            Write-Terminal ('  Stavki u košu: {0}, ukupna veličina: {1}' -f $binItems, (Format-Bytes ([double]$binSize))) 'Info'
        }
        $task = [Auxilium.NativeMethods]::EmptyRecycleBinAsync()
        while (-not $task.IsCompleted -and -not $script:Closing) {
            Update-Ui
            Start-Sleep -Milliseconds 50
        }
        if (-not $task.IsCompleted) { return }
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
        $hr = [int]$task.Result
        if ($hr -eq 0) {
            Write-Terminal '  Koš za smeće je ispražnjen.' 'Ok'
        } else {
            Write-Terminal ('  Pražnjenje koša nije uspjelo (HRESULT 0x{0:X8}).' -f $hr) 'Warn'
        }
    } catch {
        Write-Terminal ('  Koš za smeće: {0}' -f $_.Exception.Message) 'Warn'
    }
}

function Invoke-CleanupTask {
    $systemDrive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($systemDrive)) { $systemDrive = 'C:' }
    $driveInfo  = New-Object System.IO.DriveInfo(($systemDrive + '\'))
    $freeBefore = [double]$driveInfo.AvailableFreeSpace
    $totalFreed = [double]0
    $touched    = $false

    try {
        Write-Terminal '1/4  Brisanje privremenih datoteka (korisnički i sistemski TEMP)...' 'Info'
        $touched = $true
        $totalFreed += [double](Clear-TempFolders)
        if (Test-StopRequested) { return }

        Write-Terminal '2/4  Windows Update predmemorija (wuauserv + SoftwareDistribution\Download)...' 'Info'
        $totalFreed += [double](Clear-UpdateCache)
        if (Test-StopRequested) { return }

        Write-Terminal '3/4  Pražnjenje koša za smeće...' 'Info'
        Clear-RecycleBinContent

        Write-Terminal '4/4  Sažetak...' 'Info'
        $freeAfter = [double]$driveInfo.AvailableFreeSpace
        Write-Terminal ('  Obrisano datoteka ukupno: {0}' -f (Format-Bytes $totalFreed)) 'Ok'
        Write-Terminal ('  Slobodno na {0} prije: {1}, poslije: {2}' -f $systemDrive, (Format-Bytes $freeBefore), (Format-Bytes $freeAfter)) 'Ok'
    } finally {
        # Status se osvježava i nakon prekida/greške jer su datoteke možda već obrisane.
        if ($touched -and -not $script:Closing) {
            try { Update-SystemStatus -IgnoreCancel -SkipDeep } catch { Write-Terminal ('Osvježavanje statusa nije uspjelo: {0}' -f $_.Exception.Message) 'Warn' }
        }
    }
}
#endregion TASKS - CISCENJE

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

#region TASKS - PDF
function New-ReportModel {
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add((New-InfoItem 'Section' '' '1. Podaci o izvještaju'))
    $items.Add((New-InfoItem 'KV' 'Izdavatelj' 'Auxilium Informatika - IT podrška'))
    $items.Add((New-InfoItem 'KV' 'Datum i vrijeme' ((Get-Date).ToString('dd.MM.yyyy. HH:mm:ss'))))
    if (-not [string]::IsNullOrWhiteSpace($script:ReportCompany)) {
        $items.Add((New-InfoItem 'KV' 'Tvrtka / klijent' $script:ReportCompany))
    }
    $items.Add((New-InfoItem 'KV' 'Računalo' $env:COMPUTERNAME))
    $runAs   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $console = Get-ConsoleUser
    if ([string]::IsNullOrWhiteSpace($console)) {
        $items.Add((New-InfoItem 'KV' 'Korisnik' $runAs))
    } else {
        $items.Add((New-InfoItem 'KV' 'Korisnik' $console))
        if ($console -ne $runAs) { $items.Add((New-InfoItem 'KV' 'Alat pokrenut kao' $runAs)) }
    }
    $items.Add((New-InfoItem 'KV' 'Verzija alata' $script:AppVersion))
    # Mjesto za odjeljak Health Score: popunjava se nakon prikupljanja podataka (niže).
    $healthAt = $items.Count
    $items.Add((New-InfoItem 'Spacer'))

    $items.Add((New-InfoItem 'Section' '' '2. Informacije o sustavu'))
    if (@($script:SysInfo).Count -eq 0) {
        # Status još nije učitan (prekid / istek vremena): ponovno prikupljanje u pozadini, uz mogućnost prekida.
        $fresh = Get-SystemInfoItemsAsync -TimeoutSeconds 20
        if ($null -ne $fresh) {
            $script:SysInfo = @($fresh)
            if ($null -ne $script:UI.Status) { Show-SystemInfo @(Get-CombinedInfoItems) }
        } elseif (Test-StopRequested) {
            return $null
        }
    }
    # Neinstalirana ažuriranja i dnevnici (7 dana): ako se još prikupljaju, čeka se (uz mogućnost prekida); ako nisu pokrenuta, pokreću se.
    if (@($script:SysInfo).Count -gt 0) {
        if ($script:Deep.State -eq 'Idle' -or $script:Deep.State -eq 'Cancelled') { Start-DeepScan }
        if ($script:Deep.State -eq 'Running') {
            Write-Terminal '  Čekam ažuriranja na čekanju i dnevnike događaja (pozadinsko prikupljanje)...' 'Info'
            [void](Wait-DeepScan -TimeoutSeconds 120)
            if (Test-StopRequested) { return $null }
        }
    }
    if (@($script:SysInfo).Count -eq 0) {
        $items.Add((New-InfoItem 'Text' '' 'Podaci o sustavu nisu bili dostupni (WMI/CIM nije odgovorio).' 'Warn'))
    }
    $inOsSection = $false
    foreach ($info in @(Get-CombinedInfoItems)) {
        if ($info.Kind -eq 'Section') {
            $inOsSection = ($info.Value -eq 'OPERACIJSKI SUSTAV')
            $items.Add((New-InfoItem 'SubSection' '' $info.Value))
        } elseif ($info.Kind -eq 'KV' -and $inOsSection -and @('Računalo', 'Korisnik', 'Alat pokrenut kao') -contains $info.Label) {
            # Ti podaci već stoje u odjeljku 1 (s prijavljenim korisnikom): ne ponavljaju se, da izvještaj ne navodi dva različita korisnika.
            continue
        } else {
            $items.Add((New-InfoItem $info.Kind $info.Label $info.Value $info.Status $info.Percent))
        }
    }
    # Health Score na vrh izvještaja (u odjeljak 1), iz istih stavki kao i odjeljak 2.
    $healthItems = @()
    try {
        $healthResult = Get-HealthResult @(Get-CombinedInfoItems)
        if ($null -ne $healthResult) {
            $healthItems = @(Get-HealthReportItems $healthResult)
        } else {
            $healthItems = @((New-InfoItem 'SubSection' '' 'HEALTH/SECURITY SCORE'), (New-InfoItem 'Text' '' 'Ocjena nije izračunana: nema dovoljno podataka o sustavu.' 'Warn'))
        }
    } catch {
        # Greška pri računanju ocjene ne smije tiho nestati: vidljiva je u izvještaju i u terminalu.
        $healthItems = @((New-InfoItem 'SubSection' '' 'HEALTH/SECURITY SCORE'), (New-InfoItem 'Text' '' ('Ocjena nije izračunana: ' + $_.Exception.Message) 'Warn'))
        Write-Terminal ('Health/Security Score nije izračunan: {0}' -f $_.Exception.Message) 'Warn'
    }
    if ($healthItems.Count -gt 0) { $items.InsertRange($healthAt, [object[]]$healthItems) }
    $items.Add((New-InfoItem 'Spacer'))

    $items.Add((New-InfoItem 'Section' '' '3. Dnevnik izvršenih zadataka (terminal)'))
    $lines = @()
    if ($null -ne $script:UI.Terminal) { $lines = @($script:UI.Terminal.Lines) }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
        if ($lines.Count -eq 1) { $lines = @() } else { $lines = $lines[0..($lines.Count - 2)] }
    }
    if ($lines.Count -eq 0) {
        $items.Add((New-InfoItem 'Text' '' 'Nema zabilježenih zadataka u terminalu.'))
    } else {
        foreach ($line in $lines) { $items.Add((New-InfoItem 'Log' '' ([string]$line))) }
    }
    return $items
}

function New-PdfBrush {
    param([int]$R, [int]$G, [int]$B)
    return (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($R, $G, $B)))
}

function Initialize-PdfState {
    param([System.Drawing.Printing.PrintDocument]$Doc, $Model)

    $bold = [System.Drawing.FontStyle]::Bold
    $p = @{ Error = $null; PageNo = 0 }
    # Ocjena za zaglavlje prve stranice (ista vrijednost kao red "Ocjena" u odjeljku Health/Security Score).
    $p.ScoreText   = ''
    $p.ScoreStatus = 'Normal'
    foreach ($modelItem in @($Model)) {
        if ($modelItem.Kind -eq 'KV' -and $modelItem.Label -eq 'Ocjena') {
            $p.ScoreText   = ([string]$modelItem.Value) -replace '\s*\(djelomično:.*\)\s*$', ' (djelomično)'
            $p.ScoreStatus = [string]$modelItem.Status
            break
        }
    }
    # Naslovni font logotipa kao u aplikaciji: Bahnschrift ako je instaliran, inače Segoe UI.
    $logoFamily = 'Segoe UI'
    try {
        foreach ($family in (New-Object System.Drawing.Text.InstalledFontCollection).Families) {
            if ($family.Name -eq 'Bahnschrift') { $logoFamily = 'Bahnschrift'; break }
        }
    } catch { }
    $p.Fonts = @{
        Body      = [System.Drawing.Font]::new('Segoe UI', 9)
        BodyBold  = [System.Drawing.Font]::new('Segoe UI', 9, $bold)
        Section   = [System.Drawing.Font]::new('Segoe UI', 12.5, $bold)
        Sub       = [System.Drawing.Font]::new('Segoe UI', 9.5, $bold)
        Mono      = [System.Drawing.Font]::new('Consolas', 7.5)
        Small     = [System.Drawing.Font]::new('Segoe UI', 8)
        LogoBold  = [System.Drawing.Font]::new($logoFamily, 22, $bold)
        LogoSub   = [System.Drawing.Font]::new('Segoe UI', 9.5)
        LogoLight = [System.Drawing.Font]::new('Segoe UI Light', 22)
        Title     = [System.Drawing.Font]::new('Segoe UI Semibold', 13)
    }
    $p.Brushes = @{
        Text    = New-PdfBrush 30 30 34
        Muted   = New-PdfBrush 105 105 115
        White   = New-PdfBrush 255 255 255
        Silver  = New-PdfBrush 192 192 200
        Red     = New-PdfBrush 220 30 60
        Yellow  = New-PdfBrush 255 204 0
        Band    = New-PdfBrush 20 20 24
        Log     = New-PdfBrush 244 244 246
        BarBack = New-PdfBrush 226 226 230
        Good    = New-PdfBrush 0 130 60
        Warn    = New-PdfBrush 190 120 0
        Bad     = New-PdfBrush 200 30 40
        HdrGood = New-PdfBrush 111 224 138
        HdrWarn = New-PdfBrush 255 201 74
        HdrBad  = New-PdfBrush 255 75 75
    }
    $p.Pens = @{
        Line = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(205, 205, 212)), 0.8
        Red  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(220, 30, 60)), 2.5
    }
    $p.Sf = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
    $p.SfRight = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
    $p.SfRight.Alignment = [System.Drawing.StringAlignment]::Far

    # Mjerenje u 1/100 inča (isto kao PrintPage Graphics): bitmap od 100 DPI s jedinicom Pixel.
    $p.Bmp = New-Object System.Drawing.Bitmap 8, 8
    $p.Bmp.SetResolution(100, 100)
    $p.Gm = [System.Drawing.Graphics]::FromImage($p.Bmp)
    $p.Gm.PageUnit = [System.Drawing.GraphicsUnit]::Pixel

    $paper = $Doc.DefaultPageSettings.PaperSize
    $p.PageW    = [double]$paper.Width
    $p.PageH    = [double]$paper.Height
    $p.ML       = 60.0
    $p.ContentW = $p.PageW - 120.0
    $p.LabelW   = 130.0
    $p.BandH    = 100.0
    $p.FirstTop = 125.0
    $p.ContTop  = 80.0
    $p.Bottom   = $p.PageH - 80.0

    $gm = $p.Gm; $f = $p.Fonts; $sf = $p.Sf
    $valueW = $p.ContentW - $p.LabelW
    $charW  = $gm.MeasureString(('M' * 200), $f.Mono, 100000, $sf).Width / 200.0
    $maxChars = [Math]::Max(20, [int][Math]::Floor($p.ContentW / $charW))
    $bodyH = $f.Body.GetHeight($gm)

    # Razvoj stavki (prelamanje redaka dnevnika) i izračun visina.
    $expanded = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Model) {
        if ($it.Kind -eq 'Log') {
            $text = (($it.Value -replace "`t", '    ') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
            if ($text.Length -eq 0) {
                $expanded.Add((New-InfoItem 'Log' '' ''))
            } else {
                # Prelamanje po riječima (monospace font); nastavci redaka uvučeni su za 4 znaka.
                $remaining = $text
                $firstLine = $true
                while ($remaining.Length -gt 0) {
                    $limit = $maxChars
                    if (-not $firstLine) { $limit = $maxChars - 4 }
                    if ($remaining.Length -le $limit) {
                        $chunk = $remaining
                        $remaining = ''
                    } else {
                        $cut = $remaining.LastIndexOf(' ', $limit - 1, $limit)
                        if ($cut -lt [int]($limit * 0.5)) { $cut = $limit }
                        $chunk = $remaining.Substring(0, $cut).TrimEnd()
                        $remaining = $remaining.Substring($cut).TrimStart()
                    }
                    if (-not $firstLine) { $chunk = '    ' + $chunk }
                    $expanded.Add((New-InfoItem 'Log' '' $chunk))
                    $firstLine = $false
                }
            }
        } else {
            $expanded.Add($it)
        }
    }

    $p.H = @{
        Section = $f.Section.GetHeight($gm) + 10.0
        Sub     = $f.Sub.GetHeight($gm) + 6.0
        Log     = $f.Mono.GetHeight($gm)
    }
    foreach ($it in $expanded) {
        if     ($it.Kind -eq 'Section')    { $it.Height = $p.H.Section }
        elseif ($it.Kind -eq 'SubSection') { $it.Height = $p.H.Sub }
        elseif ($it.Kind -eq 'KV') {
            $measured = $gm.MeasureString($it.Value, $f.Body, [int]$valueW, $sf).Height
            $it.Height = [Math]::Max($bodyH, $measured) + 3.0
        }
        elseif ($it.Kind -eq 'Bar')    { $it.Height = 12.0 }
        elseif ($it.Kind -eq 'Text')   { $it.Height = [Math]::Max($bodyH, $gm.MeasureString($it.Value, $f.Body, [int]$p.ContentW, $sf).Height) + 3.0 }
        elseif ($it.Kind -eq 'Spacer') { $it.Height = 8.0 }
        else                           { $it.Height = $p.H.Log }
    }

    # Straničenje.
    $pages = New-Object System.Collections.Generic.List[object]
    $cur   = New-Object System.Collections.Generic.List[object]
    $y     = $p.FirstTop
    for ($i = 0; $i -lt $expanded.Count; $i++) {
        $it   = $expanded[$i]
        $need = $it.Height
        if (($it.Kind -eq 'Section' -or $it.Kind -eq 'SubSection') -and ($i + 1) -lt $expanded.Count) { $need += $expanded[$i + 1].Height + 4.0 }
        if (($y + $need) -gt $p.Bottom -and $cur.Count -gt 0) {
            $pages.Add($cur)
            $cur = New-Object System.Collections.Generic.List[object]
            $y   = $p.ContTop
        }
        if ($cur.Count -eq 0 -and $it.Kind -eq 'Spacer') { continue }
        $it.Y = $y
        $cur.Add($it)
        $y += $it.Height
    }
    if ($cur.Count -gt 0 -or $pages.Count -eq 0) { $pages.Add($cur) }
    $p.Pages = $pages
    return $p
}

function Get-PdfBrush {
    param([string]$Status)
    $b = $script:Pdf.Brushes
    if ($Status -eq 'Good') { return $b.Good }
    if ($Status -eq 'Warn') { return $b.Warn }
    if ($Status -eq 'Bad')  { return $b.Bad }
    return $b.Text
}

function Write-PdfPage {
    param($E)

    $p  = $script:Pdf
    $g  = $E.Graphics
    $f  = $p.Fonts
    $b  = $p.Brushes
    $sf = $p.Sf
    $x  = $p.ML
    $w  = $p.ContentW
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    $pageNo = $p.PageNo
    $total  = $p.Pages.Count
    $stamp  = (Get-Date).ToString('dd.MM.yyyy. HH:mm')

    # --- Zaglavlje ---
    if ($pageNo -eq 0) {
        $g.FillRectangle($b.Band, 0, 0, $p.PageW, $p.BandH)
        $g.FillRectangle($b.Red, 0, $p.BandH, $p.PageW, 3)
        # Logotip: "AU" + crveni "X" + "ILIUM" + žuta "." naslovnim fontom, zatim "INFORMATIKA" manjim fontom s razmakom među slovima (kao u aplikaciji).
        $parts = @(
            @{ T = 'AU';    B = $b.White  },
            @{ T = 'X';     B = $b.Red    },
            @{ T = 'ILIUM'; B = $b.White  },
            @{ T = '.';     B = $b.Yellow }
        )
        $px = $x
        $py = 26.0
        $big = $f.LogoBold
        foreach ($part in $parts) {
            $g.DrawString($part.T, $big, $part.B, $px, $py, $sf)
            $px += $g.MeasureString($part.T, $big, 10000, $sf).Width
        }
        $px += 8.0
        $small = $f.LogoSub
        $bigAscent   = $big.FontFamily.GetCellAscent($big.Style) / [double]$big.FontFamily.GetEmHeight($big.Style) * $big.Size * 100.0 / 72.0
        $smallAscent = $small.FontFamily.GetCellAscent($small.Style) / [double]$small.FontFamily.GetEmHeight($small.Style) * $small.Size * 100.0 / 72.0
        $subY = $py + $bigAscent - $smallAscent
        foreach ($letter in 'INFORMATIKA'.ToCharArray()) {
            $ls = [string]$letter
            $g.DrawString($ls, $small, $b.Silver, $px, $subY, $sf)
            $px += $g.MeasureString($ls, $small, 10000, $sf).Width + 2.2
        }
        $titleRect = New-Object System.Drawing.RectangleF(($x + 250), 28, ($w - 250), 24)
        $g.DrawString('Izvještaj o dijagnostici sustava', $f.Title, $b.White, $titleRect, $p.SfRight)
        $subRect = New-Object System.Drawing.RectangleF(($x + 250), 54, ($w - 250), 18)
        $subText = '{0}  |  {1}' -f $env:COMPUTERNAME, $stamp
        if (-not [string]::IsNullOrWhiteSpace($script:ReportCompany)) { $subText = '{0}  |  {1}' -f $script:ReportCompany, $subText }
        $g.DrawString($subText, $f.Small, $b.Silver, $subRect, $p.SfRight)
        # Health/Security Score odmah u zaglavlju prve stranice (boja po razini).
        if (-not [string]::IsNullOrEmpty($p.ScoreText)) {
            $scoreBrush = $b.HdrGood
            if ($p.ScoreStatus -eq 'Warn') { $scoreBrush = $b.HdrWarn } elseif ($p.ScoreStatus -eq 'Bad') { $scoreBrush = $b.HdrBad }
            $valueW = $g.MeasureString($p.ScoreText, $f.Section, 10000, $sf).Width
            $valueRect = New-Object System.Drawing.RectangleF(($x + 250), 74, ($w - 250), 22)
            $g.DrawString($p.ScoreText, $f.Section, $scoreBrush, $valueRect, $p.SfRight)
            $labelRect = New-Object System.Drawing.RectangleF(($x + 250), 79, ($w - 250 - $valueW - 10), 16)
            $g.DrawString('HEALTH/SECURITY SCORE', $f.Small, $b.Silver, $labelRect, $p.SfRight)
        }
    } else {
        $g.DrawString('Auxilium Informatika - Izvještaj o dijagnostici sustava', $f.Small, $b.Muted, $x, 42, $sf)
        $rightRect = New-Object System.Drawing.RectangleF($x, 42, $w, 16)
        $rightText = $env:COMPUTERNAME
        if (-not [string]::IsNullOrWhiteSpace($script:ReportCompany)) { $rightText = '{0}  |  {1}' -f $script:ReportCompany, $env:COMPUTERNAME }
        $g.DrawString($rightText, $f.Small, $b.Muted, $rightRect, $p.SfRight)
        $g.DrawLine($p.Pens.Line, $x, 60, ($x + $w), 60)
    }

    # --- Sadržaj ---
    foreach ($it in $p.Pages[$pageNo]) {
        $y = $it.Y
        if ($it.Kind -eq 'Section') {
            $g.DrawString($it.Value, $f.Section, $b.Text, $x, ($y + 6), $sf)
            $lineY = $y + $it.Height - 2
            $g.DrawLine($p.Pens.Line, $x, $lineY, ($x + $w), $lineY)
            $g.DrawLine($p.Pens.Red, $x, $lineY, ($x + 48), $lineY)
        } elseif ($it.Kind -eq 'SubSection') {
            $g.DrawString($it.Value, $f.Sub, $b.Muted, $x, ($y + 4), $sf)
        } elseif ($it.Kind -eq 'KV') {
            $labelIndent = 0.0
            if ($it.Label.StartsWith('  ')) { $labelIndent = 14.0 }
            $g.DrawString($it.Label.Trim(), $f.BodyBold, $b.Muted, ($x + $labelIndent), $y, $sf)
            $rect = New-Object System.Drawing.RectangleF(($x + $p.LabelW), $y, ($w - $p.LabelW), $it.Height)
            $g.DrawString($it.Value, $f.Body, (Get-PdfBrush $it.Status), $rect, $sf)
        } elseif ($it.Kind -eq 'Bar') {
            if (-not [string]::IsNullOrEmpty($it.Label)) { $g.DrawString($it.Label.Trim(), $f.Small, $b.Muted, $x, ($y - 1), $sf) }
            $barW = 220.0
            $bx = $x + $p.LabelW
            $g.FillRectangle($b.BarBack, $bx, ($y + 2), $barW, 6)
            $fillW = $barW * [Math]::Min(100.0, [Math]::Max(0.0, $it.Percent)) / 100.0
            if ($fillW -gt 0) { $g.FillRectangle((Get-PdfBrush $it.Status), $bx, ($y + 2), $fillW, 6) }
            $g.DrawString($it.Value, $f.Small, $b.Muted, ($bx + $barW + 8), ($y - 1), $sf)
        } elseif ($it.Kind -eq 'Text') {
            $rect = New-Object System.Drawing.RectangleF($x, $y, $w, $it.Height)
            $g.DrawString($it.Value, $f.Body, (Get-PdfBrush $it.Status), $rect, $sf)
        } elseif ($it.Kind -eq 'Log') {
            $g.FillRectangle($b.Log, ($x - 4), $y, ($w + 8), $it.Height)
            if ($it.Value.Length -gt 0) { $g.DrawString($it.Value, $f.Mono, $b.Text, $x, $y, $sf) }
        }
    }

    # --- Podnožje ---
    $footY = $p.PageH - 55
    $g.DrawLine($p.Pens.Line, $x, $footY, ($x + $w), $footY)
    $g.DrawString(('Auxilium Informatika  |  IT podrška  |  generirano {0}' -f $stamp), $f.Small, $b.Muted, $x, ($footY + 6), $sf)
    $pageRect = New-Object System.Drawing.RectangleF($x, ($footY + 6), $w, 16)
    $g.DrawString(('Stranica {0} / {1}' -f ($pageNo + 1), $total), $f.Small, $b.Muted, $pageRect, $p.SfRight)

    $p.PageNo = $pageNo + 1
    $E.HasMorePages = ($p.PageNo -lt $total)
}

function Remove-PdfState {
    $p = $script:Pdf
    $script:Pdf = $null
    if ($null -eq $p) { return }
    foreach ($group in @('Fonts', 'Brushes', 'Pens')) {
        if ($p.ContainsKey($group)) {
            foreach ($key in @($p[$group].Keys)) { try { $p[$group][$key].Dispose() } catch { } }
        }
    }
    foreach ($key in @('Sf', 'SfRight', 'Gm', 'Bmp')) {
        try { if ($p.ContainsKey($key) -and $null -ne $p[$key]) { $p[$key].Dispose() } } catch { }
    }
}

function Test-PdfFileComplete {
    param([string]$Path)
    try {
        # FileShare.Read: otvaranje uspijeva tek kad spooler zatvori datoteku (inače bi sljedeće kopiranje dobilo sharing violation),
        # a istodobni čitači (antivirus, indeksiranje) ne smetaju.
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            if ($stream.Length -lt 64) { return $false }
            $count = [int][Math]::Min(1024, $stream.Length)
            [void]$stream.Seek(-$count, [System.IO.SeekOrigin]::End)
            $buffer = New-Object 'byte[]' $count
            $read = $stream.Read($buffer, 0, $count)
            return ([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read) -match '%%EOF')
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $false
    }
}

function Remove-FileQuiet {
    param([string]$Path, [int]$Retries = 20)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return }
            [System.IO.File]::Delete($Path)
            return
        } catch {
            Update-Ui
            Start-Sleep -Milliseconds 100
        }
    }
}

# Ispisuje izvještaj u privremenu PDF datoteku i tek nakon uspjeha je premješta na odabrano mjesto
# (neuspjeh ili prekid ne smiju uništiti postojeći izvještaj). Vraća FileInfo ili $null ako je prekinuto.
function Export-ReportToPdf {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PrinterName
    )

    $script:PdfCancelled = $false
    if (Test-StopRequested) { return $null }

    $model = New-ReportModel
    if ($null -eq $model) { return $null }
    $partial = Join-Path ([System.IO.Path]::GetTempPath()) ('Auxilium_{0}.pdf' -f [guid]::NewGuid().ToString('N'))
    $doc     = New-Object System.Drawing.Printing.PrintDocument
    try {
        $doc.PrinterSettings.PrinterName = $PrinterName
        if (-not $doc.PrinterSettings.IsValid) { throw ('Pisač "{0}" nije ispravno konfiguriran.' -f $PrinterName) }

        $directory = [System.IO.Path]::GetDirectoryName($Path)
        if (-not [string]::IsNullOrEmpty($directory) -and -not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }

        $doc.PrinterSettings.PrintToFile   = $true
        $doc.PrinterSettings.PrintFileName = $partial
        $doc.DocumentName                  = 'Auxilium Informatika - Izvještaj o dijagnostici sustava'
        $doc.PrintController               = New-Object System.Drawing.Printing.StandardPrintController

        foreach ($paper in $doc.PrinterSettings.PaperSizes) {
            if ($paper.Kind -eq [System.Drawing.Printing.PaperKind]::A4) { $doc.DefaultPageSettings.PaperSize = $paper; break }
        }
        $doc.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(0, 0, 0, 0)
        $doc.DefaultPageSettings.Landscape = $false

        $script:Pdf = Initialize-PdfState -Doc $doc -Model $model
        $pageCount  = $script:Pdf.Pages.Count
        $doc.add_PrintPage({
            param($sender, $e)
            try {
                # Sučelje se pumpa po stranici, a Prekini/zatvaranje prekidaju ispis.
                [System.Windows.Forms.Application]::DoEvents()
                if (Test-StopRequested) {
                    $script:PdfCancelled = $true
                    $e.Cancel = $true
                    $e.HasMorePages = $false
                    return
                }
                Write-PdfPage $e
            } catch {
                $script:Pdf.Error = $_.Exception.Message
                $e.HasMorePages = $false
            }
        })

        Write-Terminal ('  Stranica u izvještaju: {0}; ispis u datoteku...' -f $pageCount) 'Info'
        $doc.Print()
        if ($null -ne $script:Pdf -and $script:Pdf.Error) { throw ('Greška pri iscrtavanju izvještaja: ' + $script:Pdf.Error) }
        if ($script:PdfCancelled) { return $null }

        # Pisač "Microsoft Print to PDF" zapisuje datoteku asinkrono - čeka se da bude kompletna (prvo datoteka, tek onda prekid).
        $deadline = (Get-Date).AddSeconds([Math]::Max(40, 20 + $pageCount))
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            if ((Test-Path -LiteralPath $partial) -and (Test-PdfFileComplete $partial)) { $ready = $true; break }
            if (Test-StopRequested) { break }
            Update-Ui
            Start-Sleep -Milliseconds 150
        }
        if (-not $ready) {
            if (Test-StopRequested) { return $null }
            throw 'PDF datoteka nije stvorena u očekivanom roku. Provjerite pisač "Microsoft Print to PDF".'
        }

        # Kopiranje u odredišnu mapu (nova datoteka nasljeđuje ACL odredišta, radi i među volumenima), pa preimenovanje preko cilja.
        # Ako je cilj zaključan (npr. otvoren u pregledniku PDF-a), izvještaj se sprema pod zamjenskim imenom.
        # Kratko ime privremene datoteke (ne ovisi o imenu izvještaja) da putanja ne prijeđe MAX_PATH.
        $stageDir = [System.IO.Path]::GetDirectoryName($Path)
        if ([string]::IsNullOrEmpty($stageDir)) { $stageDir = (Get-Location).Path }
        $stage = [System.IO.Path]::Combine($stageDir, ('.aux-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 8)))
        $moved = $false
        $moveError = ''
        try {
            for ($i = 0; $i -lt 5 -and -not $moved; $i++) {
                try {
                    [System.IO.File]::Copy($partial, $stage, $true)
                    Move-Item -LiteralPath $stage -Destination $Path -Force -ErrorAction Stop
                    $moved = $true
                } catch {
                    $moveError = $_.Exception.Message
                    Update-Ui
                    Start-Sleep -Milliseconds 200
                }
            }
            if (-not $moved) {
                $altDir = [System.IO.Path]::GetDirectoryName($Path)
                if ([string]::IsNullOrEmpty($altDir)) { $altDir = (Get-Location).Path }
                $altBase = [System.IO.Path]::GetFileNameWithoutExtension($Path)
                $altExt  = [System.IO.Path]::GetExtension($Path)
                $alt = Join-Path $altDir ('{0}_{1}{2}' -f $altBase, (Get-Date -Format 'HHmmss'), $altExt)
                $n = 1
                while (Test-Path -LiteralPath $alt) {
                    $alt = Join-Path $altDir ('{0}_{1}_{2}{3}' -f $altBase, (Get-Date -Format 'HHmmss'), $n, $altExt)
                    $n++
                }
                try {
                    [System.IO.File]::Copy($partial, $alt, $false)
                } catch {
                    throw ('Odredišnu datoteku nije moguće prepisati (možda je otvorena u drugom programu), a ni zamjensko spremanje nije uspjelo: {0}' -f $_.Exception.Message)
                }
                Write-Terminal ('  Odredišnu datoteku nije bilo moguće zapisati (možda je otvorena u drugom programu); izvještaj je spremljen kao: {0}  [razlog: {1}]' -f $alt, $moveError) 'Warn'
                $Path = $alt
            }
        } finally {
            Remove-FileQuiet -Path $stage
        }
    } finally {
        Remove-PdfState
        $doc.Dispose()
        Remove-FileQuiet -Path $partial
    }
    return (Get-Item -LiteralPath $Path)
}

function Invoke-PdfTask {
    $printerName = 'Microsoft Print to PDF'
    $installed   = @([System.Drawing.Printing.PrinterSettings]::InstalledPrinters)
    if ($installed -notcontains $printerName) {
        Write-Terminal ('Pisač "{0}" nije instaliran.' -f $printerName) 'Error'
        Write-Terminal '  Uključite ga u: Windows značajke (optionalfeatures) -> Microsoft Print to PDF.' 'Warn'
        return
    }

    # Izvještaj se sprema automatski u mapu tvrtke: <korijen>\<Tvrtka>\<RACUNALO>_<korisnik>_<datum-vrijeme>.pdf
    if ($null -ne $script:UI.CompanyBox) { Set-ActiveCompany $script:UI.CompanyBox.Text }
    $company = Get-ActiveCompany
    if ([string]::IsNullOrWhiteSpace($company)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:UI.Form,
            ('Tvrtka / klijent nije postavljena (polje na vrhu prozora).' + [Environment]::NewLine + [Environment]::NewLine +
             'Želite li izvještaj spremiti u mapu "Nerazvrstano"?' + [Environment]::NewLine +
             '(Ne = povratak na unos tvrtke.)'),
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Terminal 'Generiranje PDF-a je otkazano: upišite tvrtku / klijenta u polje na vrhu.' 'Warn'
            # Polje je trenutno onemogućeno (zadatak je u tijeku): fokus se vraća u Set-BusyState kad zadatak završi.
            $script:FocusCompanyBox = $true
            return
        }
        $company = 'Nerazvrstano'
    }

    $file = Save-ReportForCompany -Company $company -PrinterName $printerName
    if ($null -eq $file) { return }
    [System.Windows.Forms.Application]::DoEvents()
    if (Test-StopRequested) {
        Write-Terminal ('Prekid je zatražen, ali je PDF već spremljen: {0}' -f $file.FullName) 'Warn'
        return
    }
    Write-Terminal ('PDF izvještaj je spremljen ({0}): {1}' -f (Format-Bytes ([double]$file.Length)), $file.FullName) 'Ok'

    $open = [System.Windows.Forms.MessageBox]::Show(
        $script:UI.Form,
        ('PDF izvještaj je spremljen:' + [Environment]::NewLine + $file.FullName + [Environment]::NewLine + [Environment]::NewLine + 'Želite li ga otvoriti?'),
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($open -eq [System.Windows.Forms.DialogResult]::Yes) {
        try { Start-Process -FilePath $file.FullName } catch { Write-Terminal ('Datoteku nije moguće otvoriti: {0}' -f $_.Exception.Message) 'Warn' }
    }
}
#endregion TASKS - PDF

#region UI
function Invoke-HeaderPaint {
    param($Sender, $E)
    try {
        $g = $E.Graphics
        $c = $script:Colors
        $f = $script:Fonts
        $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
        $big = New-Object System.Drawing.Size(2000, 100)
        $parts = @(
            @{ T = 'AUXILIUM';    F = $f.LogoBold;  C = $c.White  },
            @{ T = 'X';           F = $f.LogoBold;  C = $c.Red    },
            @{ T = '.';           F = $f.LogoBold;  C = $c.Yellow },
            @{ T = 'INFORMATIKA'; F = $f.LogoLight; C = $c.Silver }
        )
        $x = 18
        $h = [System.Windows.Forms.TextRenderer]::MeasureText($g, 'AUXILIUM', $f.LogoBold, $big, $flags).Height
        $y = [int](($Sender.Height - $h) / 2)
        foreach ($part in $parts) {
            $size = [System.Windows.Forms.TextRenderer]::MeasureText($g, $part.T, $part.F, $big, $flags)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $part.T, $part.F, (New-Object System.Drawing.Point($x, $y)), $part.C, $flags)
            $x += $size.Width
        }

        $rightFlags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Right
        $rect1 = New-Object System.Drawing.Rectangle(($Sender.Width - 420), 20, 402, 22)
        [System.Windows.Forms.TextRenderer]::DrawText($g, 'Dijagnostika i održavanje sustava', $f.HeadSub, $rect1, $c.Silver, $rightFlags)
        $adminText = 'standardni korisnik'
        if ($script:IsAdmin) { $adminText = 'administrator' }
        $rect2 = New-Object System.Drawing.Rectangle(($Sender.Width - 420), 44, 402, 18)
        [System.Windows.Forms.TextRenderer]::DrawText($g, ('v{0}  |  {1}  |  {2}' -f $script:AppVersion, $env:COMPUTERNAME, $adminText), $f.HeadSmall, $rect2, $c.Muted, $rightFlags)
    } catch { }
}

function New-AppIcon {
    try {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear($script:Colors.Header)
        $fontA = [System.Drawing.Font]::new('Segoe UI', 14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $sfmt = New-Object System.Drawing.StringFormat
        $sfmt.Alignment = [System.Drawing.StringAlignment]::Center
        $sfmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $white = New-Object System.Drawing.SolidBrush ($script:Colors.White)
        $red = New-Object System.Drawing.SolidBrush ($script:Colors.Red)
        $g.DrawString('A', $fontA, $white, (New-Object System.Drawing.RectangleF(0, 1, 20, 30)), $sfmt)
        $g.DrawString('X', $fontA, $red, (New-Object System.Drawing.RectangleF(13, 1, 19, 30)), $sfmt)
        $white.Dispose(); $red.Dispose(); $fontA.Dispose(); $sfmt.Dispose(); $g.Dispose()
        $handle = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($handle).Clone()
        [Auxilium.NativeMethods]::TryDestroyIcon($handle)
        $bmp.Dispose()
        return $icon
    } catch {
        return $null
    }
}

function New-FlatButton {
    param([string]$Text)
    $c = $script:Colors
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text         = $Text
    $btn.UseMnemonic  = $false
    $btn.Dock         = 'Fill'
    $btn.FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize         = 0
    $btn.FlatAppearance.MouseOverBackColor = $c.ButtonHot
    $btn.FlatAppearance.MouseDownBackColor = $c.ButtonDown
    $btn.BackColor    = $c.Button
    $btn.ForeColor    = $c.White
    $btn.Font         = $script:Fonts.Button
    $btn.Cursor       = [System.Windows.Forms.Cursors]::Hand
    $btn.Margin       = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
    $btn.UseVisualStyleBackColor = $false
    return $btn
}

function New-StripButton {
    param([string]$Text, [int]$Width)
    $c = $script:Colors
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text        = $Text
    $btn.UseMnemonic = $false
    $btn.Dock        = 'Right'
    $btn.Width       = $Width
    $btn.FlatStyle   = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize         = 0
    $btn.FlatAppearance.MouseOverBackColor = $c.ButtonHot
    $btn.FlatAppearance.MouseDownBackColor = $c.ButtonDown
    $btn.BackColor   = $c.Button
    $btn.ForeColor   = $c.White
    $btn.Font        = $script:Fonts.StripBtn
    $btn.Cursor      = [System.Windows.Forms.Cursors]::Hand
    $btn.Margin      = New-Object System.Windows.Forms.Padding(0)
    $btn.UseVisualStyleBackColor = $false
    return $btn
}

function New-CardGroup {
    param([string]$Title, [int]$Rows)
    $c = $script:Colors
    $group = New-Object Auxilium.CardBox
    $group.Text        = $Title
    $group.Dock        = 'Fill'
    $group.Font        = $script:Fonts.Card
    $group.ForeColor   = $c.White
    $group.BackColor   = $c.Card
    $group.Padding     = New-Object System.Windows.Forms.Padding(6, 4, 6, 6)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock        = 'Fill'
    $layout.BackColor   = $c.Card
    $layout.ColumnCount = 1
    $layout.RowCount    = $Rows
    [void]$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    for ($i = 0; $i -lt $Rows; $i++) {
        [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, (100 / $Rows)))
    }
    $group.Controls.Add($layout)
    return @{ Group = $group; Layout = $layout }
}

function New-TextArea {
    param([string]$Title, [System.Drawing.Color]$BackColor, [System.Drawing.Font]$Font, [System.Drawing.Color]$ForeColor)
    $c = $script:Colors

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.ReadOnly      = $true
    $rtb.Dock          = 'Fill'
    $rtb.BorderStyle   = 'None'
    $rtb.DetectUrls    = $false
    $rtb.WordWrap      = $true
    $rtb.ScrollBars    = 'Vertical'
    $rtb.Font          = $Font
    $rtb.BackColor     = $BackColor
    $rtb.ForeColor     = $ForeColor
    $rtb.Cursor        = [System.Windows.Forms.Cursors]::Default
    $rtb.HideSelection = $false
    $rtb.TabStop       = $false

    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock      = 'Fill'
    $inner.BackColor = $BackColor
    $inner.Padding   = New-Object System.Windows.Forms.Padding(4, 6, 2, 6)
    $inner.Controls.Add($rtb)

    $strip = New-Object System.Windows.Forms.Panel
    $strip.Dock      = 'Top'
    $strip.Height    = 30
    $strip.BackColor = $c.Card
    $strip.Padding   = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)

    $label = New-Object System.Windows.Forms.Label
    $label.Text        = $Title
    $label.UseMnemonic = $false
    $label.Dock        = 'Fill'
    $label.TextAlign   = 'MiddleLeft'
    $label.Font        = $script:Fonts.Strip
    $label.ForeColor   = $c.Silver
    $label.BackColor   = $c.Card
    $strip.Controls.Add($label)

    $container = New-Object System.Windows.Forms.Panel
    $container.Dock      = 'Fill'
    $container.BackColor = $BackColor
    $container.Controls.Add($inner)
    $container.Controls.Add($strip)

    return @{ Container = $container; Rtb = $rtb; Strip = $strip }
}

# Osvježava traku "Tvrtka / klijent": popis nedavnih tvrtki i putanju na koju će se spremiti izvještaj.
function Update-ClientBar {
    $box   = $script:UI.CompanyBox
    $label = $script:UI.PathLabel
    if ($null -eq $box -or $null -eq $label) { return }
    if ($script:UI.ClientUpdating) { return }
    $script:UI.ClientUpdating = $true
    try {
        $company = Get-ActiveCompany
        # Popis se ponovno gradi samo ako se stvarno promijenio (Items.Clear() poništava odabir i kvari kretanje strelicama).
        $wanted = @($script:Settings.Companies | ForEach-Object { [string]$_ })
        $have   = @($box.Items | ForEach-Object { [string]$_ })
        if ($wanted.Count -ne $have.Count -or ($wanted -join [string][char]0) -cne ($have -join [string][char]0)) {
            $box.Items.Clear()
            foreach ($known in $wanted) { [void]$box.Items.Add($known) }
        }
        if ($box.Text -ne $company) { $box.Text = $company }

        if ([string]::IsNullOrWhiteSpace($company)) {
            $label.Text = ('Izvještaji: upišite tvrtku / klijenta.  Korijen: {0}' -f (Get-ReportsRoot))
        } else {
            $folder = Get-CompanyFolder $company
            $kind   = Get-DriveKind $folder
            $tag    = ''
            if ($kind) { $tag = '[{0}] ' -f $kind }
            $label.Text = ('Izvještaji se spremaju u: {0}{1}' -f $tag, $folder)
        }
    } finally {
        $script:UI.ClientUpdating = $false
    }
}

function New-ClientBar {
    $c = $script:Colors
    $f = $script:Fonts

    $bar = New-Object System.Windows.Forms.TableLayoutPanel
    $bar.Dock        = 'Top'
    $bar.Height      = 46
    $bar.BackColor   = $c.Card
    $bar.Padding     = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
    $bar.ColumnCount = 5
    $bar.RowCount    = 1
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 132))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 300))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 112))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 132))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$bar.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $title = New-Object System.Windows.Forms.Label
    $title.Text        = 'TVRTKA / KLIJENT'
    $title.UseMnemonic = $false
    $title.Dock        = 'Fill'
    $title.TextAlign   = 'MiddleLeft'
    $title.Font        = $f.Strip
    $title.ForeColor   = $c.Yellow
    $title.BackColor   = $c.Card

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $combo.FlatStyle     = [System.Windows.Forms.FlatStyle]::Flat
    $combo.Font          = [System.Drawing.Font]::new('Segoe UI', 10.5)
    $combo.BackColor     = $c.Data
    $combo.ForeColor     = $c.White
    $combo.MaxLength     = 60
    $combo.Width         = 288
    $combo.Anchor        = [System.Windows.Forms.AnchorStyles]::Left
    $combo.Margin        = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)

    $btnOpen = New-FlatButton 'Otvori mapu'
    $btnOpen.Font   = $f.StripBtn
    $btnOpen.Margin = New-Object System.Windows.Forms.Padding(0, 1, 8, 1)
    $btnRoot = New-FlatButton 'Postavi mapu...'
    $btnRoot.Font   = $f.StripBtn
    $btnRoot.Margin = New-Object System.Windows.Forms.Padding(0, 1, 10, 1)

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text         = ''
    $pathLabel.UseMnemonic  = $false
    $pathLabel.AutoEllipsis = $true
    $pathLabel.Dock         = 'Fill'
    $pathLabel.TextAlign    = 'MiddleLeft'
    $pathLabel.Font         = $f.Hint
    $pathLabel.ForeColor    = $c.Silver
    $pathLabel.BackColor    = $c.Card

    $bar.Controls.Add($title, 0, 0)
    $bar.Controls.Add($combo, 1, 0)
    $bar.Controls.Add($btnOpen, 2, 0)
    $bar.Controls.Add($btnRoot, 3, 0)
    $bar.Controls.Add($pathLabel, 4, 0)

    $script:UI.CompanyBox     = $combo
    $script:UI.PathLabel      = $pathLabel
    $script:UI.ClientControls = @($combo, $btnOpen, $btnRoot)

    $combo.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $e.SuppressKeyPress = $true
            Set-ActiveCompany $script:UI.CompanyBox.Text
        }
    })
    $combo.Add_Leave({
        if (-not $script:Busy -and -not $script:Closing) { Set-ActiveCompany $script:UI.CompanyBox.Text }
    })
    $combo.Add_SelectionChangeCommitted({
        Set-ActiveCompany ([string]$script:UI.CompanyBox.SelectedItem) -KeepOrder
    })

    $btnOpen.Add_Click({
        try {
            Set-ActiveCompany $script:UI.CompanyBox.Text
            $company = Get-ActiveCompany
            $folder = Get-ReportsRoot
            if (-not [string]::IsNullOrWhiteSpace($company)) { $folder = Get-CompanyFolder $company }
            [void](Test-FolderWritable $folder)
            if (-not [System.IO.Directory]::Exists($folder)) { throw ('Mapa ne postoji i nije je moguće stvoriti: {0}' -f $folder) }
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
        } catch {
            Write-Terminal ('Mapu nije moguće otvoriti: {0}' -f $_.Exception.Message) 'Warn'
        }
    })

    $btnRoot.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $dialog.Description         = 'Odaberite korijensku mapu za izvještaje (npr. mapu na USB stiku). U njoj se za svaku tvrtku stvara zasebna mapa.'
            $dialog.ShowNewFolderButton = $true
            $current = Get-ReportsRoot
            if ([System.IO.Directory]::Exists($current)) { $dialog.SelectedPath = $current }
            if ($dialog.ShowDialog($script:UI.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
                Set-ReportsRoot $dialog.SelectedPath
                Update-ClientBar
                Write-Terminal ('Korijenska mapa izvještaja: {0}' -f (Get-ReportsRoot)) 'Info'
            }
        } catch {
            Write-Terminal ('Mapu nije moguće postaviti: {0}' -f $_.Exception.Message) 'Warn'
        } finally {
            $dialog.Dispose()
        }
    })

    return $bar
}

function New-MainForm {
    $c = $script:Colors
    $f = $script:Fonts

    Initialize-Portable

    [System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
        param($sender, $e)
        try { Write-Terminal ('NEOČEKIVANA GREŠKA: {0}' -f $e.Exception.Message) 'Error' } catch { }
    })

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $script:AppTitle
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox     = $false
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    # Zadana veličina je 1040x760; na zaslonima s manjom radnom površinom (skaliranje 125-150 %) ograničava se na nju.
    $workArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Control]::MousePosition).WorkingArea
    $form.Size            = New-Object System.Drawing.Size([Math]::Min(1040, $workArea.Width), [Math]::Min(760, $workArea.Height))
    $form.BackColor       = $c.Form
    $form.ForeColor       = $c.Text
    $form.Font            = $f.Ui
    $icon = New-AppIcon
    if ($null -ne $icon) { $form.Icon = $icon }
    $script:UI.Form = $form

    # --- Zaglavlje s logotipom ---
    $header = New-Object Auxilium.BufferedPanel
    $header.Dock      = 'Top'
    $header.Height    = 76
    $header.BackColor = $c.Header
    $header.Add_Paint({ param($sender, $e) Invoke-HeaderPaint $sender $e })

    # --- Zelena traka napretka ---
    $track = New-Object System.Windows.Forms.Panel
    $track.Dock      = 'Top'
    $track.Height    = 6
    $track.BackColor = $c.Track
    $fill = New-Object System.Windows.Forms.Panel
    $fill.BackColor = $c.Progress
    $fill.Left      = 0
    $fill.Top       = 0
    $fill.Height    = 6
    $fill.Width     = 0
    $track.Controls.Add($fill)
    $script:UI.ProgressTrack = $track
    $script:UI.ProgressFill  = $fill

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 25
    $timer.Add_Tick({
        $bar = $script:UI.ProgressFill
        $area = $script:UI.ProgressTrack
        $bar.Left += 14
        if ($bar.Left -gt $area.Width) { $bar.Left = -$bar.Width }
    })
    $script:UI.ProgressTimer = $timer

    # Tajmer koji prati pozadinsko prikupljanje (ažuriranja na čekanju i dnevnici događaja).
    $deepTimer = New-Object System.Windows.Forms.Timer
    $deepTimer.Interval = 400
    $deepTimer.Add_Tick({ try { Update-DeepScan } catch { } })
    $script:UI.DeepTimer = $deepTimer

    # Tajmer za uživo osvježavanje CPU i RAM barova u statusu sustava (svake 2 s).
    $liveTimer = New-Object System.Windows.Forms.Timer
    $liveTimer.Interval = 2000
    $liveTimer.Add_Tick({ try { Update-LiveMeters } catch { } })
    $script:UI.LiveTimer = $liveTimer
    $liveTimer.Start()

    # --- Tijelo ---
    $body = New-Object System.Windows.Forms.Panel
    $body.Dock      = 'Fill'
    $body.BackColor = $c.Form
    $body.Padding   = New-Object System.Windows.Forms.Padding(12)

    $main = New-Object System.Windows.Forms.TableLayoutPanel
    $main.Dock        = 'Fill'
    $main.BackColor   = $c.Form
    $main.ColumnCount = 1
    $main.RowCount    = 2
    [void]$main.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$main.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 190))
    [void]$main.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    # --- Kartice ---
    $cards = New-Object System.Windows.Forms.TableLayoutPanel
    $cards.Dock        = 'Fill'
    $cards.BackColor   = $c.Form
    $cards.ColumnCount = 3
    $cards.RowCount    = 1
    for ($i = 0; $i -lt 3; $i++) {
        [void]$cards.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 33.33))
    }
    [void]$cards.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $card1 = New-CardGroup '1. Sistem & Popravci' 3
    $btnSfc = New-FlatButton 'Pokreni SFC & DISM'
    $btnChk = New-FlatButton 'CHKDSK Provjera (R-O)'
    $card1.Layout.Controls.Add($btnSfc, 0, 0)
    $card1.Layout.Controls.Add($btnChk, 0, 1)

    $card2 = New-CardGroup '2. Čišćenje sustava' 3
    $btnClean = New-FlatButton 'Duboko Čišćenje (TEMP)'
    $btnLogs  = New-FlatButton 'Izvezi i obriši dnevnike'
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text        = 'Briše TEMP datoteke, Windows Update predmemoriju i koš. Dnevnike prvo izvozi u TXT uz izvještaj, pa tek onda briše. Traži potvrdu.'
    $hint.UseMnemonic = $false
    $hint.Dock        = 'Fill'
    $hint.TextAlign   = 'MiddleLeft'
    $hint.Font        = $f.Hint
    $hint.ForeColor   = $c.Muted
    $hint.BackColor   = $c.Card
    $hint.Padding     = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
    $card2.Layout.Controls.Add($btnClean, 0, 0)
    $card2.Layout.Controls.Add($btnLogs, 0, 1)
    $card2.Layout.Controls.Add($hint, 0, 2)

    $card3 = New-CardGroup '3. Mreža & Izvještaji' 3
    $btnNet = New-FlatButton 'Test Mreže & Ping'
    $btnPdf = New-FlatButton 'Generiraj PDF Izvještaj'
    $card3.Layout.Controls.Add($btnNet, 0, 0)
    $card3.Layout.Controls.Add($btnPdf, 0, 1)

    $card1.Group.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $card2.Group.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $card3.Group.Margin = New-Object System.Windows.Forms.Padding(0)
    $cards.Controls.Add($card1.Group, 0, 0)
    $cards.Controls.Add($card2.Group, 1, 0)
    $cards.Controls.Add($card3.Group, 2, 0)

    # --- Lijevi status i desni terminal ---
    $view = New-Object System.Windows.Forms.TableLayoutPanel
    $view.Dock        = 'Fill'
    $view.BackColor   = $c.Form
    $view.ColumnCount = 2
    $view.RowCount    = 1
    [void]$view.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 352))
    [void]$view.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$view.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $statusArea = New-TextArea 'STATUS SUSTAVA' $c.Data $f.Mono $c.Text
    $btnRefresh = New-StripButton 'Osvježi' 70
    $statusArea.Strip.Controls.Add($btnRefresh)
    # Kartica Health Score iznad popisa statusa (razmak od 8 px ispod nje).
    $healthSpacer = New-Object System.Windows.Forms.Panel
    $healthSpacer.Dock      = 'Top'
    $healthSpacer.Height    = 8
    $healthSpacer.BackColor = $c.Data
    $healthTile = New-HealthTile
    $statusArea.Rtb.Parent.Controls.Add($healthSpacer)
    $statusArea.Rtb.Parent.Controls.Add($healthTile)
    $statusArea.Container.Margin = New-Object System.Windows.Forms.Padding(0, 10, 10, 0)

    $termArea = New-TextArea 'TERMINAL' $c.TermBack $f.Term $c.TermGreen
    $btnCancel = New-StripButton 'Prekini' 70
    $btnClear  = New-StripButton 'Očisti' 70
    $btnCancel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
    $btnCancel.Enabled = $false
    $termArea.Strip.Controls.Add($btnCancel)
    $termArea.Strip.Controls.Add($btnClear)
    $termArea.Container.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)

    $view.Controls.Add($statusArea.Container, 0, 0)
    $view.Controls.Add($termArea.Container, 1, 0)

    $main.Controls.Add($cards, 0, 0)
    $main.Controls.Add($view, 0, 1)
    $body.Controls.Add($main)

    # Redoslijed: zadnje dodano s Dock=Top ide na sam vrh (zaglavlje, traka napretka, traka tvrtke, tijelo).
    $clientBar = New-ClientBar
    $form.Controls.Add($body)
    $form.Controls.Add($clientBar)
    $form.Controls.Add($track)
    $form.Controls.Add($header)

    # Redoslijed tipkom Tab: najprije polje tvrtke, zatim ostalo.
    $clientBar.TabIndex = 0
    $body.TabIndex      = 1

    $script:UI.Status        = $statusArea.Rtb
    $script:UI.Terminal      = $termArea.Rtb
    $script:UI.BtnCancel     = $btnCancel
    $script:UI.ActionButtons = @($btnSfc, $btnChk, $btnClean, $btnLogs, $btnNet, $btnPdf, $btnRefresh)

    # --- Događaji ---
    $btnSfc.Add_Click({ Start-GuiTask -Title 'SFC & DISM - provjera i popravak sustavnih datoteka' -Command 'Invoke-SfcDismTask' })
    $btnChk.Add_Click({ Start-GuiTask -Title 'CHKDSK - provjera diska (samo čitanje)' -Command 'Invoke-ChkdskTask' })
    $btnClean.Add_Click({
        Start-GuiTask -Title 'Duboko čišćenje sustava' -Command 'Invoke-CleanupTask' -ConfirmMessage (
            'Duboko čišćenje će trajno obrisati:' + [Environment]::NewLine +
            ' - privremene datoteke (korisnički i sistemski TEMP)' + [Environment]::NewLine +
            ' - Windows Update predmemoriju (SoftwareDistribution\Download)' + [Environment]::NewLine +
            ' - sadržaj koša za smeće' + [Environment]::NewLine + [Environment]::NewLine +
            'Datoteke koje su otvorene u drugim programima obično se preskaču. Prije čišćenja zatvorite druge programe i instalacije.' + [Environment]::NewLine + [Environment]::NewLine +
            'Želite li nastaviti?')
    })
    $btnNet.Add_Click({ Start-GuiTask -Title 'Test mreže i ping' -Command 'Invoke-NetworkTask' })
    $btnPdf.Add_Click({ Start-GuiTask -Title 'Generiranje PDF izvještaja' -Command 'Invoke-PdfTask' })
    $btnLogs.Add_Click({ Start-GuiTask -Title 'Izvoz i brisanje dnevnika događaja' -Command 'Invoke-EventLogClearTask' })
    $btnRefresh.Add_Click({ Start-GuiTask -Title 'Osvježavanje statusa sustava' -Command 'Update-SystemStatus' })
    $btnClear.Add_Click({ try { $script:UI.Terminal.Clear() } catch { } })
    $btnCancel.Add_Click({
        if ($script:Busy) {
            $script:CancelRequested = $true
            Write-Terminal 'Zatražen je prekid zadatka...' 'Warn'
            Stop-CurrentProcess
        }
    })

    $form.Add_FormClosing({
        param($sender, $e)
        if ($script:Busy) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $script:UI.Form, 'Zadatak je još u tijeku. Želite li ga prekinuti i zatvoriti aplikaciju?', $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
            $script:Closing = $true
            $script:CancelRequested = $true
            Stop-CurrentProcess
        }
    })

    $form.Add_Shown({
        try { [Auxilium.NativeMethods]::TryEnableDarkTitleBar($script:UI.Form.Handle) } catch { }
        try { [Auxilium.NativeMethods]::TrySetDarkScrollbars($script:UI.Status.Handle) } catch { }
        try { [Auxilium.NativeMethods]::TrySetDarkScrollbars($script:UI.Terminal.Handle) } catch { }
        $adminText = 'standardni korisnik (neke radnje neće raditi)'
        if ($script:IsAdmin) { $adminText = 'administrator' }
        Write-Terminal ('Auxilium Informatika - Dijagnostika i čišćenje sustava v{0}' -f $script:AppVersion) 'Header'
        Write-Terminal ('Računalo: {0} | Korisnik: {1} | Prava: {2}' -f $env:COMPUTERNAME, [Environment]::UserName, $adminText) 'Info'
        try {
            # Ako je UAC podignut drugim računom, Temp i koš koji se čiste pripadaju tom računu, a ne prijavljenom korisniku.
            $consoleUser = Get-ConsoleUser
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            if (-not [string]::IsNullOrWhiteSpace($consoleUser) -and $consoleUser -ne $me) {
                Write-Terminal ('Upozorenje: alat radi kao {0}, a prijavljen je {1}. Čišćenje se odnosi na Temp i koš računa {0}, ne računa {1}.' -f $me, $consoleUser) 'Warn'
            }
        } catch { }

        Write-Terminal ('Alat se pokreće iz: {0}  [{1}]' -f $script:AppRoot, (Get-DriveKind $script:AppRoot)) 'Info'
        if ($script:SettingsLoadError) { Write-Terminal ('Postavke nisu učitane (koriste se zadane): {0}' -f $script:SettingsLoadError) 'Warn' }
        try {
            Update-ClientBar
            $startCompany = Get-ActiveCompany
            if ([string]::IsNullOrWhiteSpace($startCompany)) {
                Write-Terminal 'Upišite tvrtku / klijenta u polje na vrhu: izvještaji se spremaju u njezinu mapu na stiku.' 'Warn'
            } else {
                Write-Terminal ('Aktivna tvrtka / klijent: {0}  ->  {1}' -f $startCompany, (Get-CompanyFolder $startCompany)) 'Info'
            }
        } catch {
            Write-Terminal ('Traka tvrtke nije inicijalizirana: {0}' -f $_.Exception.Message) 'Warn'
        }
        Write-Terminal 'Spremno. Odaberite radnju iz kartica iznad.' 'Normal'
        # Nakon početnog učitavanja fokus ide u polje tvrtke (Set-BusyState), a ne na posljednji gumb.
        $script:FocusCompanyBox = $true
        Start-GuiTask -Title 'Učitavanje podataka o sustavu' -Command 'Update-SystemStatus'
    })
}
#endregion UI

#region MAIN
try {
    Initialize-Resources
    New-MainForm
    [void]$script:UI.Form.ShowDialog()
} catch {
    try {
        [void][System.Windows.Forms.MessageBox]::Show(
            ('Došlo je do fatalne greške:' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message),
            'Auxilium Informatika',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch { }
} finally {
    Remove-AppResources
    # Zapeti WMI upit u napuštenom runspaceu (foreground nit) inače bi držao skriveni powershell.exe živim: tada se proces završava silom.
    if ($script:AbandonedRunspace) { [System.Environment]::Exit(0) }
}
#endregion MAIN
