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
