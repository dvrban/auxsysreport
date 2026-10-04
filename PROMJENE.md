# Auxilium Informatika – dijagnostika: razvoj nakon izdanja v4

Izdanja v1–v4: vidi `v4\PROMJENE.md` (`v4\` je nepromjenjiva kopija izdanja v4 i ne mijenja se).
Ovdje se bilježi neobjavljeni rad prema izdanju v5 (Faza 0 „Temelji“ iz izvještaja o reviziji v0.04). Jedan tiket = jedan commit = jedan unos.

## Neobjavljeno (prema v5)

### T0.1 – Podjela izvora u `src\`
- Izvor varijante „Ljuska“ podijeljen je iz jedne datoteke od 6606 redaka u 22 dijela po regijama (`src\01-Header.ps1` … `src\90-Main.ps1`),
  a tijela dvaju here-stringova izdvojena su u `src\native\Native.cs` (C#) i `src\deep\DeepScan.ps1` (dijete-skripta dubokog skeniranja).
- **Ponašanje alata nije izmijenjeno:** dijelovi se sastavljaju natrag u `v4\Auxilium-Dijagnostika-Ljuska.ps1` bajt po bajt (SHA-256 `D8E2DDDC…EA2F4`)
  i definiraju istih 122 funkcije najviše razine. Provjera: `tests\Test-SrcSplit.ps1`.
- Pravila sastavljanja, kodiranje (UTF-8 s BOM-om, CRLF) i raspored: `src\README.md`. `.gitattributes` štiti BOM i CRLF u `src\`, `tests\`, `v4\` i u ovoj datoteci (`-text`).
- Još nema `build.ps1` (T0.2): alat se i dalje pokreće iz `v4\`. Varijanta „Original“ (`Auxilium-Dijagnostika.ps1`) nije dirana (T3.3).

### T0.2 – `build.ps1`
- `build.ps1` sastavlja `src\` u `dist\Auxilium-Dijagnostika-Ljuska.ps1` (UTF-8 s BOM-om, CRLF) i piše `dist\MANIFEST.txt` (SHA-256, git hash). Bez parametara rezultat je **bajt-identičan v4** (SHA-256 `D8E2DDDC…EA2F4`).
- `-BuildNumber N` mijenja samo redak `$script:BuildNumber`. Build pada ako oznaka ugrađenog dijela nije u izvoru točno jednom, ako datoteka nema BOM ili ima prekid retka koji nije CRLF, ili ako se sastavljena datoteka odnosno `deep\DeepScan.ps1` ne parsira.
- Odstupanje od skice u izvještaju: git hash se ne umeće u izvornik (to bi promijenilo bajtove; ide u T1.12), nego samo u MANIFEST. `dist\` je u `.gitignore`. Harnessi iz izvještaja nisu u repozitoriju, pa kriterij „harnessi prolaze nad `dist\`“ još nije provjeren; zamjenjuje ga jednakost SHA-256 s v4.

### T0.3 – PSScriptAnalyzer s baselineom
- `PSScriptAnalyzerSettings.psd1`: samo pravila koja pogađaju stvarne nalaze (prazan `catch`, nekorištene varijable i parametri, `$global:`, dodjela automatskoj varijabli `$sender`, aliasi, `Invoke-Expression`, WMI cmdleti). Pozicijski parametri, ShouldProcess i jednina imenica (oko 270 nalaza) su šum i isključeni su.
- `tests\Invoke-Analyze.ps1` analizira sastavljenu skriptu **i `src\deep\DeepScan.ps1`** (PSSA inače ne vidi dijete-skriptu jer je u alatu običan tekst). Nalaz se prepoznaje po ključu „datoteka | pravilo | funkcija | poruka“, ne po retku, pa pomak redaka ne stvara nove nalaze. Baseline (`tests\pssa-baseline.json`, 151 nalaz, PSSA 1.22.0): 115 praznih `catch` u skripti + 15 u dijete-skripti, 6 × `$global:target`, 9 × `$sender`, 4 nekorištena parametra, 2 nekorištene varijable.
- Novi nalaz ruši `build.ps1` (preskače se uz upozorenje ako PSSA nije instaliran; `-RequireAnalyzer` ga traži, `-SkipAnalyze` preskače). Popravak ispisuje napomenu; `-UpdateBaseline` spušta baseline.
- Napomena: PSSA broji 130 praznih `catch` (115 + 15), a izvještaj 122; razlika je u definiciji (PSSA broji i blokove samo s komentarom). Baseline ovisi o verziji PSSA.

### T0.4 – AST provjera ubačenih funkcija
- `tests\Test-Closure.ps1` iz AST-a sastavljene skripte računa potpuno zatvaranje ovisnosti korijenskih funkcija koje se izvode u runspaceu (`Get-SystemInfoItems`, `Get-InventoryData`) i uspoređuje ga s ručnim popisima u `Get-SystemInfoItemsAsync` i `Get-InventoryDataAsync`. Pada ako funkcija nedostaje na popisu ili ako ubačena funkcija koristi `$script:`/`$global:`. Trenutno se zatvaranje točno poklapa s popisima (5 + 2 funkcije).
- Pokreće se iz `build.ps1` (`-SkipClosureCheck` preskače). Nova pomoćna funkcija u `Get-SystemInfoItems` sada ruši build, a ne runtime.
- Odstupanje od izvještaja: runtime kod i dalje koristi ručne popise (zamjena automatskim `Get-FunctionClosure` ide u T2.1 uz `Invoke-BackgroundRunspace`; bez Windowsa je ne mogu isprobati). Provjera parsiranja dijete-skripte već je u `build.ps1` (T0.2). Provjera neinicijaliziranih `$script:` varijabli nije napravljena.
- Upozorenje za T1.5: `Write-AppLog` koristi `$script:`, pa ga ubačene funkcije ne smiju zvati; ova provjera će to uhvatiti.

### T0.5 – Pester temelj
- `tests\Invoke-Tests.ps1` pokreće Pester 5 testove iz `tests\Unit\` (22 testa, 3 preskočena na Linuxu): `Format-Bytes`, `ConvertTo-SafeName`, `ConvertFrom-DeepBytes` (uključujući `-Killed` i prazan ulaz), `New-InfoItem`, `Get-HealthLevel`, `Get-HealthResult` i `Get-TempFolderTargets` (samo Windows).
- Testovi ne dot-sourceaju cijele dijelove (`04-Elevation` i `90-Main` pokreću UAC i prozor), nego `tests\Unit\TestHelpers.ps1` AST-om izdvaja samo tražene funkcije iz `src\`. Ne trebaju build.
- Zlatni skupovi za `Get-HealthResult` izračunati su **ručno** iz pravila v0.04 (npr. antivirus + vatrozid + 12 ažuriranja = 38 / LOŠE), a ne snimljeni sa stvarnih računala: snimanje fixturea (`Export-Clixml`) traži Windows i ostaje za T2.8/T2.9.
- `build.ps1` pokreće testove ako je instaliran Pester 5 (`-SkipTests`). Windows PowerShell 5.1 ima ugrađen Pester 3: `Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck`.

### T0.6 – Windows Sandbox
- `test\Start-Sandbox.ps1` iz predloška `test\Auxilium.wsb` izrađuje `Auxilium.generated.wsb` s punom putanjom `dist\` (nije u gitu) i pokreće Sandbox; `test\README.md` ima kontrolnu listu (UAC, EN jezik, bez Officea, PDF, prekid, izlaz).
- `build.ps1` sada u `dist\` kopira i pokretač `Pokreni-Auxilium-Ljuska.cmd` (bajt-kopija iz `src\launcher\`) i upisuje ga u `MANIFEST.txt`.
- Ručni pregled u Sandboxu **nije izvršen** (nema Windowsa); kriterij „alat se podigne na admina i napravi PDF“ ostaje za provjeru na Windowsu.

## Faza 1 – Stabilizacija (prva izmjena koda nakon v4)

Od ove točke `src\` se razlikuje od v4. `tests\Test-SrcSplit.ps1` (bajt-identičnost s v4) je ukinut kao dovršen; bajt-identičnost je dokazana u T0.1/T0.2 (commitovi `3d01514`, `2a2f869`). Zamjenjuju ga `build.ps1`, Pester testovi i PSSA baseline. Sve ispod provjereno je statički i Pester testovima na PowerShellu 7 (Linux); **ponašanje u pravom prozoru na Windowsu nije isprobano**.

- **T1.1** `Update-SystemStatus`: uz svako `$rtb.Clear()` resetira se `$script:LiveRows` (živi CPU/RAM bar više ne piše na stare pomake dok je panel u stanju „Učitavanje…“).
- **T1.2** Redoslijed oslobađanja: `Remove-AppResources` sada prvo zaustavlja skeniranje i timere, oslobađa formu, pa tek onda fontove (`Remove-AppFonts`) i `FontCollection`. `Initialize-Resources` na početku oslobađa fontove prethodnog poziva (drugi poziv više ne curi 16 fontova).
- **T1.3** `Get-SystemInfoItemsAsync`: sink je `BlockingCollection[object]` umjesto `List[object]` (`.Add` i `.ToArray()` su thread-safe; `ToArray()` postoji na `BlockingCollection`, što je provjereno i testom s istodobnim pisanjem iz runspacea, 50 ponavljanja).
- **T1.4** `Invoke-CleanupTask`: prije koraka 2 (zaustavljanje `wuauserv`) čeka završetak pozadinskog skeniranja (do 30 s); ako skeniranje nije završilo uspješno, nakon čišćenja se ponavlja (`Update-SystemStatus` bez `-SkipDeep`). N2 je bila PRETPOSTAVKA (nije reproducirano): ovo je zaštita, ne dokazan popravak.
- **T1.7** Svih 8 preostalih `Get-CimInstance` poziva dobilo je `-OperationTimeoutSec 10` (7 u `Get-SystemInfoItems`, 1 u ELEVATION); Pester test provjerava da nijedan poziv ne ostane bez roka.
- **T1.10** `Invoke-LiveProcess`: nakon `Kill` čekanje do 2 s ide u petlji `WaitForExit(100)` + `Update-Ui` (bez zamrzavanja).
- PSSA baseline spušten (nalazi manje za 2 prazna `catch`). Novi Pester testovi: `tests\Unit\Regression.Tests.ps1`.
- **T1.5 (djelomično)** Dnevnik na stiku: `Write-AppLog` piše u `<stick>\Dnevnik\Auxilium_<datum>.log` (zadnjih 10 datoteka; nezapisiv stick ga tiho isključuje). `Format-AppLogLine` je čista funkcija: ne ovisi o `ScriptStackTrace` (nacrt iz izvještaja bi pod `Set-StrictMode -Version 2` bacio iznimku za obične iznimke) i zamjenjuje putanje profila (`%USERPROFILE%`, i za druge korisnike). U dnevnik idu: sva `Warn`/`Error` upozorenja iz terminala (`Write-Terminal`), stack trace zadatka koji je pao, `ThreadException`, greške dubokog skeniranja, pogreške iz runspaceova (`$ps.Streams.Error`) i redak o pokretanju (verzija, prava; bez imena računala i korisnika).
  - **Nije napravljeno:** kriterij „0 praznih `catch` bez komentara“. 130 praznih `catch` (PSSA) ostaje; njih pokriva baseline, a ne dnevnik. Funkcije ubačene u runspace (`Get-SystemInfoItems`, `Get-InventoryData`, dijete-skripta) ne smiju zvati `Write-AppLog` (koristi `$script:`; `Test-Closure.ps1` to hvata), pa im greške idu samo kroz `$ps.Streams.Error`. Svaki prazan `catch` treba posebno procijeniti (namjerno ili greška): to je zaseban posao.
- **T1.8** Privremena skripta dubokog skeniranja više nije u `%TEMP%` (zapisiv i procesima srednje razine integriteta istog korisnika, a pozadinski proces nasljeđuje povišeni token), nego u `%ProgramData%\Auxilium\run-<guid>\scan.ps1`. Mapa ima ACL samo za Administrators i SYSTEM (bez nasljeđivanja); nadređena mapa `Auxilium` se ne koristi ako joj vlasnik nije administrator/SYSTEM. Neposredno prije `Start()` datoteka se čita natrag i uspoređuje bajt po bajt (SHA-256); neslaganje baca grešku (zatim vrijedi stari rezervni put `-EncodedCommand` ako je skripta dovoljno kratka, inače skeniranje ne počinje). Mapa se briše uz skriptu, a zaostale `run-*` starije od 1 dana brišu se pri sljedećem pokretanju. Alat se uvijek izvodi povišeno (ELEVATION), pa ACL ne smeta; **ACL nije isproban na Windowsu** (Pester test je preskočen na Linuxu). Provjera hasha sama po sebi ne zatvara prozor između usporedbe i otvaranja datoteke; zatvara ga ACL.
- **T1.12** Otisak alata: prvih 8 znakova SHA-256 vlastite skripte (`Get-ToolFingerprint`) prikazuje se u zaglavlju terminala, u retku „Verzija alata“ u PDF-u (npr. `0.04 (D8E2DDDC)`) i u dnevniku, pa se vidi koje je izdanje napravilo izvještaj. JSON (`toolVersion`, shema `auxilium-inventar/1`) nije mijenjan. Zaglavlje PDF-a iz kriterija izvještaja („v0.07 (a1b2c3d)“, git hash) nije napravljeno: git hash se ne umeće u izvornik, a otisak je neovisan o gitu.
- **Ispravak dokumentacije (N5):** u `v4\PROMJENE.md` (nepromjenjivo izdanje) piše da se verzija prikazuje kao broj/10 (v1 = 0.1); u kodu je broj/100 (v1 = 0.01, v4 = 0.04). Vrijedi kod.
- **T1.9** `Get-ConsoleUser` koristi WTS API (`WTSGetActiveConsoleSessionId` + `WTSQuerySessionInformationW`, nova metoda `Auxilium.NativeMethods.GetConsoleUserName`) umjesto CIM-a: prvi prikaz statusa više ne radi WMI poziv na UI niti. Oblik rezultata je isti (`DOMENA\korisnik`; prazan niz = nitko nije prijavljen). CIM ostaje samo kao rezerva kad native poziv ne uspije. C# isječak je preveden u izolaciji (Linux, bez WinForms) i uspješno se prevodi; **sam WTS poziv nije izvršen na Windowsu**. Semantika je ista kao kod CIM-a (konzolna sesija, ne RDP sesije).

### Faza 1: što NIJE napravljeno i zašto
- **T1.6 `Set-StrictMode -Version 2`:** izvještaj sam procjenjuje 20–40 popravaka u 6600 redaka bez ijednog UI testa; bez Windowsa to bi bila slijepa promjena koja može srušiti alat pri prvom pokretanju (npr. `$script:` varijable koje se čitaju prije inicijalizacije, svojstva koja ne postoje). Treba je raditi uz pokretanje na Windowsu.
- **T1.11 rezultat zadatka umjesto nuspojave (N4):** provjera koda pokazuje da razinu `Error` ispisuje samo 5 mjesta (`50-Logs.ps1` ×2, `74-TasksNetwork.ps1` ×3) i da svako stvarno prijavljuje neuspjeh; scenarij „upozorenje razine Error uspješnog zadatka“ iz izvještaja u v0.04 ne postoji. Preostali rizik („greška bez ispisa ostaje zelena“) rješava se trijažom praznih `catch`, ne novim protokolom. Refaktoriranje 9 zadataka zato nije opravdano bez primjera.
- **T1.5 kriterij „0 praznih `catch` bez komentara“** (vidi gore) i **T1.12 git hash u zaglavlju PDF-a** (zamijenjeno otiskom skripte).
- **Sandbox UAC test** (cilj faze) i svi ručni testovi na Windowsu: nisu izvršeni.

### Nalaz s Windowsa (prvo pokretanje na pravom računalu)
- Potvrđeno u radu: `build.ps1` na Windows PowerShellu 5.1, pokretanje i UAC, dnevnik na stiku (nema `ERROR` zapisa), prekid zadatka bez zamrzavanja, ocjena se računa, PDF nastaje, nema zaostalog procesa. (Ispravljeno usput: `$PSScriptRoot` je u zadanoj vrijednosti parametra bio prazan.)
- **Treptanje kolone statusa:** `Show-SystemInfo` je brisao i gradio panel redak po redak uz vidljivo iscrtavanje. Sada se iscrtavanje isključuje tijekom gradnje (`NativeMethods.SetRedraw`, `WM_SETREDRAW`) i uvijek uključuje u `finally`; isto za živi CPU/RAM bar (`Set-LiveRow`). Ovo je korak 1 iz T2.4; skraćivanje samog vremena gradnje (jedan RTF niz) nije napravljeno. Treba potvrditi na Windowsu.
- Zasivljeni gumbi dok čišćenje čeka skeniranje su očekivani (zadatak je u tijeku; `Set-BusyState`).
- **Treptanje svakih par sekundi, nepravilno (drugi krug):** uzrok je `Set-LiveRow`: tajmer živih barova (2 s) je prepisivao redak s CPU/RAM barom (odabir + zamjena teksta + boja) pri svakom otkucaju, a nepravilan razmak dolazi od toga što se prikaz mijenja samo kad se postotak promijeni. Sada se redak prepisuje samo kad se promijeni bar ili boja (potpis `bar|status`; stavka za PDF se ipak osvježava), a nakon prepisivanja iscrtava se samo pojas tog retka, ne cijela kolona (prethodni `Invalidate()` na cijeloj kontroli je mogao i sam izazvati treptaj). Pester testovi s lažnom kontrolom broje prepisivanja. Treba potvrditi na Windowsu.

### T1.5 (dovršenje): trijaža 124 praznih `catch`
Svaki prazni `catch` u `src\` (i u dijete-skripti) pregledan je i razvrstan; dodatnih 14 su stavljena ručno.
- **18 → zapis u dnevnik** (`Write-AppLog 'Debug' '<kontekst>' $_`): neuspjeh je informativan, a kod se izvodi na UI niti (ispis u terminal, `Set-BusyState`, zdravlje (`Update-HealthTile`), crtanje zaglavlja/kartice/trake, živi CPU/RAM, zapis popisa dnevnika, provjera slobodnog prostora, ponovno stvaranje TEMP-a, tajmeri…).
- **106 → `catch { <# namjerno: razlog #> }`:** oslobađanje resursa, `Kill`/`Stop` koji je možda već gotov, kozmetika sučelja, kod koji se izvodi prije definicije `Write-AppLog` (kodiranje, ELEVATION, NATIVE, MAIN), funkcije ubačene u runspace (`Get-SystemInfoItems`, inventar: nema dnevnika, polje se izostavlja) i cijela dijete-skripta (zaseban proces).
- Pester test sada traži da **svaki** prazan `catch` ima `namjerno:` s razlogom (kriterij „0 praznih `catch` bez komentara“ je ispunjen), i da funkcije ubačene u runspace ne zovu `Write-AppLog`.
- `Write-AppLog` spaja uzastopne jednake zapise („prethodni zapis ponovljen još N puta“), da greška u tajmeru ili crtanju ne napuni dnevnik.
- PSSA baseline spušten za 20 nalaza. Ponašanje alata se nije mijenjalo osim što greške iz navedenih mjesta sada završavaju u dnevniku. Treba potvrditi na Windowsu (alat se i dalje pokreće, dnevnik bez poplave).
