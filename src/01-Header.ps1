#Requires -Version 5.1
<#
.SYNOPSIS
    Auxilium Informatika - Dijagnostika i čišćenje sustava (WinForms GUI) - varijanta "Ljuska" (stil Auxilium web aplikacije + JSON izvoz).

.DESCRIPTION
    Samostalna aplikacija za IT podršku tvrtke "Auxilium Informatika".
      * automatsko podizanje na administratorska prava (UAC)
      * status sustava (OS, hardver, GPU, printeri, diskovi, zdravlje NVMe/SSD preko Get-PhysicalDisk)
      * softver: Windows/Office licence i verzije, zadani mail klijent, Outlook profili i OST/PST datoteke, popis instaliranih programa
      * neinstalirana Windows ažuriranja i dnevnici događaja za zadnjih 7 dana (prikupljaju se u pozadini)
      * SFC & DISM, CHKDSK (samo čitanje), duboko čišćenje, test mreže
      * PDF izvještaj preko [System.Drawing.Printing] i pisača "Microsoft Print to PDF"
      * uz svaki PDF i JSON datoteka za uvoz u web aplikaciju "IT Inventar" (schema auxilium-inventar/1); gumb "Izvezi JSON"
        izrađuje samo JSON, bez PDF-a
      * izgled: tamna plošna tema (paleta Auxilium web aplikacije: jantarni i tirkizni naglasci, obrubi od 1 px, natpisi velikim slovima);
        fontovi Bahnschrift / Segoe UI / Consolas, a ako uz skriptu postoji mapa "Fonts" s datotekama Orbitron*.ttf / Sora*.ttf, koriste se i oni

    PORTABLE (USB stick): alat radi s bilo kojeg slova pogona i ništa ne instalira na računalo.
      <stick>\Pokreni-Auxilium-Ljuska.cmd       pokretač ove varijante (dvoklik)
      <stick>\Auxilium-Dijagnostika-Ljuska.ps1  ova skripta
      <stick>\Auxilium-Postavke.json            zadnja tvrtka, popis tvrtki, korijen izvještaja (nastaje sam; dijeli se s osnovnom verzijom)
      <stick>\Izvjestaji\<Tvrtka>\<RACUNALO>_<korisnik>_<datum-vrijeme>.pdf   i uz njega istoimeni .json za IT Inventar
      <stick>\Fonts\Orbitron*.ttf, Sora*.ttf    neobavezno (privatni fontovi, ne instaliraju se u Windows)
    Tvrtka / klijent se bira u polju na vrhu prozora; PDF (i JSON) se sprema automatski u mapu te tvrtke.

    Datoteka je spremljena kao UTF-8 s BOM-om kako bi hrvatski dijakritici (Š, Ž, Č, Ć, Đ)
    bili ispravno prikazani u Windows PowerShell 5.1.

.NOTES
    Pokretanje: desni klik -> "Run with PowerShell" ili
    powershell.exe -ExecutionPolicy Bypass -File .\Auxilium-Dijagnostika-Ljuska.ps1
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

