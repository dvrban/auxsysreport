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
