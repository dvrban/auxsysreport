#Requires -Version 5.1
<#
.SYNOPSIS
    T3.4 - iscrtava rukom crtane dijelove sučelja (zaglavlje, kartica Health/Security Score) u PNG pri različitim skaliranjima zaslona.

.DESCRIPTION
    Poziva prave funkcije Invoke-HeaderPaint i Invoke-HealthPaint iz src\ na Bitmapu (bez forme), pri 100 %, 150 % i 200 %, i sprema PNG-ove u -OutDir.
    Služi za vizualnu provjeru da se crtež skalira proporcionalno (razmaci, trake, tekst bez preklapanja).
    Na Windowsu (Windows PowerShell 5.1) fontovi se u točkama skaliraju s DPI-jem sami. Na Linuxu (PowerShell 7.2 s libgdiplus i uključenim
    System.Drawing.EnableUnixSupport) to ne vrijedi: tamo treba -ScaleFonts, koji fontove unaprijed množi faktorom (emulacija Windowsa).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Render-Paint.ps1 -OutDir $env:TEMP\aux-render
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'aux-render'),
    [double[]]$Scales = @(1.0, 1.5, 2.0),
    [string]$FontFamily = 'Segoe UI',
    [switch]$ScaleFonts
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
Add-Type -AssemblyName System.Drawing
. (Join-Path $root 'Unit\TestHelpers.ps1')
. ([scriptblock]::Create((Get-AuxFunctionText 'Invoke-HeaderPaint', 'Invoke-HealthPaint', 'Get-HealthResult', 'New-InfoItem')))
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }

function Write-AppLog { param($Level, $Message, $Err) Write-Warning ('{0} {1} {2}' -f $Level, $Message, $Err) }
function New-Col { param([int]$R, [int]$G, [int]$B) return [System.Drawing.Color]::FromArgb($R, $G, $B) }
$script:Colors = @{ Header = (New-Col 17 24 38); Card = (New-Col 22 31 48); Text = (New-Col 232 236 245); Muted = (New-Col 139 147 169); Yellow = (New-Col 255 201 74)
    LogoRed = (New-Col 230 57 70); Line = (New-Col 42 53 80); Button = (New-Col 22 31 48); Good = (New-Col 111 224 138); Bad = (New-Col 255 75 75) }
function New-TestFont { param([double]$Size, [string]$Style = 'Regular') return [System.Drawing.Font]::new($FontFamily, [single]$Size, [System.Drawing.FontStyle]$Style, [System.Drawing.GraphicsUnit]::Point) }
function Set-TestFonts { param([double]$K)
    $script:Fonts = @{ Ui = (New-TestFont (9 * $K)); UiBold = (New-TestFont (9 * $K) 'Bold'); Hint = (New-TestFont (8.5 * $K)); LogoBold = (New-TestFont (22 * $K) 'Bold')
        LogoLight = (New-TestFont (10 * $K)); HeadSub = (New-TestFont (10 * $K)); HeadSmall = (New-TestFont (8.5 * $K)); HealthNum = (New-TestFont (21 * $K) 'Bold') }
}
$script:IsAdmin = $true
$script:AppVersion = '0.04'
function Add-Sec { param([string]$n) return (New-InfoItem 'Section' '' $n) }
function Add-Row { param([string]$l, [string]$v, [string]$s) return (New-InfoItem 'KV' $l $v $s) }
$items = @((Add-Sec 'SIGURNOST'), (Add-Row 'Antivirus' 'nije pronađen' 'Bad'), (Add-Row 'Vatrozid' 'uključen' 'Good'), (Add-Sec 'WINDOWS UPDATE'),
    (Add-Row 'Na čekanju' '5 ažuriranja' 'Warn'), (Add-Row 'Zadnjih 7 d' '3 neuspjela pokušaja' 'Warn'), (Add-Sec 'DISKOVI'), (Add-Row 'C:' '100 GB' 'Good'))
$script:Health = Get-HealthResult $items
$script:HealthState = 'Ready'

foreach ($s in $Scales) {
    $script:DpiScale = $s
    $k = 1.0
    if ($ScaleFonts) { $k = $s }
    Set-TestFonts $k
    $res = 96.0
    if (-not $ScaleFonts) { $res = 96.0 * $s }   # Windows: razlučivost bitmape određuje veličinu fonta u točkama

    $w = [int](1040 * $s); $h = [int](76 * $s)
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $bmp.SetResolution([single]$res, [single]$res)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($script:Colors.Header)
    Invoke-HeaderPaint ([pscustomobject]@{ Width = $w; Height = $h }) ([pscustomobject]@{ Graphics = $g })
    $g.Dispose()
    $bmp.Save((Join-Path $OutDir ('header_{0}.png' -f $s)), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    $cats = @($script:Health.Categories).Count
    $w = [int](340 * $s); $h = [int][Math]::Round((98 + 14 * $cats + 8 + 15 * 3 + 8) * $s)
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $bmp.SetResolution([single]$res, [single]$res)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($script:Colors.Card)
    Invoke-HealthPaint ([pscustomobject]@{ Width = $w; Height = $h }) ([pscustomobject]@{ Graphics = $g })
    $g.Dispose()
    $bmp.Save((Join-Path $OutDir ('health_{0}.png' -f $s)), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ('Skaliranje {0}: zapisano u {1}' -f $s, $OutDir)
}
