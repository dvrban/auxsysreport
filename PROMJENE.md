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

### T1.6 (dijagnostički način): Set-StrictMode -Version 2 na zahtjev
- Uz skriptu se može staviti prazna datoteka **`Auxilium-StrictMode.on`**: tada alat radi pod `Set-StrictMode -Version 2` (zaglavlje terminala to javlja, a u dnevniku je `WARN` redak). Zadano je isključeno, pa terenski rad ostaje kakav je bio. Greške koje strogi način otkrije završavaju u dnevniku (`Write-Terminal` Error, `ThreadException`, `DEBUG` retci iz trijažiranih `catch` blokova).
- Statička analiza (AST) nad sastavljenom skriptom: nema čitanja varijabli koje se nigdje ne postavljaju (jedina 4 nalaza su ugniježđene funkcije koje čitaju varijable roditelja, što je dopušteno), nema `$script:` varijabli koje se čitaju a nikad ne dodjeljuju, a „kasno inicijalizirani“ nalazi (58) pregledani su i uglavnom su lažni alarmi (parametri ugniježđenih funkcija, dodjele u `try` s `continue`/`return` u `catch`). Neprovjereno ostaje: pristup nepostojećim svojstvima i `.Count` na `$null` (ovise o stvarnim podacima na Windowsu).
- Dok se na Windowsu ne prođe puni krug radnji pod strogim načinom bez grešaka u dnevniku, uključivanje po zadanom nije opravdano.

### T1.6 – prvi krug pod strogim načinom (Windows)
Prvo pokretanje s `Auxilium-StrictMode.on` otkrilo je dvije greške (PDF izvještaj i „Otvori mapu“ nisu radili samo u strogom načinu):
- `'ClientUpdating' cannot be found`: u strogom načinu čitanje nepostojećeg ključa hashtable baca iznimku (statička analiza varijabli to nije mogla vidjeti). `Update-ClientBar` je čitao `$script:UI.ClientUpdating` prije prve dodjele. Svi ključevi registra `$script:UI` sada se unaprijed postavljaju u GLOBAL STATE (Pester test provjerava da svaki `$script:UI.<Naziv>` iz izvora ima početni zapis). Bez strogog načina ponašanje je isto (`$null`).
- `'Signature' cannot be found` u `Set-LiveRow`: moj kod iz popravka treperenja; redak žive vrijednosti sada ima `Signature` od početka, a `Set-LiveRow` ne pretpostavlja da ključ postoji.
- Poduka: strogi način se ne može potpuno provjeriti statički (ovisi o redoslijedu izvođenja), pa se napreduje krugovima na Windowsu.
- **Health/Security Score ne izlazi (drugi krug, strogi način):** `Get-HealthResult` je padao jer `Get-Worst` (i petlje nad redcima diskova) iteriraju `@($Rows)`, a za prazan popis to je `@($null)` s jednim elementom `$null`, pa `$null.Status` u strogom načinu baca iznimku. `Update-HealthTile` tu iznimku guta (`catch { $script:Health = $null }`), pa je ocjena ostajala „NEMA PODATAKA“ i nakon što je skeniranje završilo. Dodane su provjere `$null` u tri petlje. Bez strogog načina `$null.Status` daje `$null`, pa ocjena tamo nije bila pogođena.
- Nova tehnika: `tests\Unit\StrictMode.Tests.ps1` pokreće čiste funkcije (`Get-HealthResult`, `Get-HealthReportItems`, `ConvertFrom-DeepBytes`, `New-ReportModel`) pod `Set-StrictMode -Version 2` s raznim ulazima; test pada na staroj verziji `60-Health.ps1` (provjereno). Time se strogi način može dijelom provjeravati već na Linuxu, bez kruga na Windowsu.

### T1.6 – strogi način je sada zadan
- Na Windowsu su pod `Set-StrictMode -Version 2` prošle sve radnje osim punog izvršavanja SFC/DISM/CHKDSK (provjereni su samo start i prekid): ocjena, PDF, JSON, test mreže, duboko čišćenje, izvoz i brisanje dnevnika. Dnevnik je bez `ERROR`/`DEBUG` redaka.
- Zato je strogi način **uključen po zadanom**; isključuje se praznom datotekom **`Auxilium-StrictMode.off`** uz skriptu (datoteka `.on` iz dijagnostičkog razdoblja više nije potrebna). Greške strogog načina radnja ispisuje u terminal i dnevnik, a ostatak alata radi dalje (svaka radnja ima `try/catch` u `Start-GuiTask`).
- Preostali rizik: nepokrenuti putovi (puni SFC/DISM/CHKDSK, rijetke grane) mogu otkriti nove greške; to se vidi kao `GREŠKA:` u terminalu i redak u dnevniku, a privremeno se zaobilazi datotekom `.off`.

## Faza 2 – Asinkroni rad

### T2.1 – `Invoke-BackgroundRunspace`
- Zajednički kostur pozadinskog runspacea (stvaranje, ubacivanje funkcija, petlja s pumpanjem sučelja, prekid/istek, čišćenje) izvučen je iz `Get-SystemInfoItemsAsync` i `Get-InventoryDataAsync` u jednu funkciju `Invoke-BackgroundRunspace` (`40-SystemInfo.ps1`). Vraća `State` = `Completed` / `Cancelled` / `TimedOut` i `Output`; pri prekidu i isteku runspace se i dalje napušta (zapeti WMI poziv se ne može prekinuti), a pozivatelj čita svoj sink. Pozivatelji su sada ~15 redaka: sink i obrada djelomičnog rezultata ostaju kod njih.
- Ponašanje je isto kao prije (isti `InitialSessionState.CreateDefault()`, isti ishodi). Jedina razlika: pogreške iz runspacea (`$ps.Streams.Error`) idu u dnevnik za oba poziva.
- `tests\Test-Closure.ps1` više ne koristi fiksan popis mjesta: iz AST-a pronalazi svaki poziv `Invoke-BackgroundRunspace` i provjerava njegov `-Functions` prema zatvaranju poziva `-Command`.
- Pester testovi `BackgroundRunspace.Tests.ps1` pokreću pravi runspace (i na Linuxu): rezultat i parametri, istek vremena (sink zadržava prikupljeno), prekid korisnika, `-HonorCancel`, greške u dnevniku, nedostajuća ubačena funkcija.
- Nije napravljeno iz nacrta 4.1: red poruka za napredak (`ConcurrentQueue`), automatsko zatvaranje ovisnosti u runtimeu (`Get-FunctionClosure`; provjera ostaje pri buildu) i `CreateDefault2()` (brži start, ali se ne može isprobati bez Windowsa).
- PSSA baseline: 3 prazna `catch` preseljena u novu funkciju, a 6 nalaza manje u starim (neto −3).

### T2.3 – popis dnevnika u pozadini
- `Get-WinEvent -ListLog *` (B2: 0,6–0,7 s, na sporom disku i više, bez pumpanja sučelja) sada se izvodi u pozadinskom runspaceu preko `Invoke-BackgroundRunspace` (nova ubačena funkcija `Get-LogChannelInfo`); `Get-LogChannelPlan` iz rezultata gradi plan kao i prije (isti filtri i sortiranje).
- Prekid daje prazan plan (pozivatelj već provjerava `Test-StopRequested`); istek (60 s) je sada **greška** („Popis dnevnika događaja nije dobiven…“), a ne tiha poruka „nema dnevnika“.
- Pester testovi s lažnim runspaceom (`LogChannelPlan.Tests.ps1`); provjera ubačenih funkcija sama je pronašla novo mjesto poziva. Ispravljen je i bug u `Test-Closure.ps1` (`HashSet` s jednim elementom se raspakirao pod strogim načinom).
- Treba potvrditi na Windowsu: **Izvezi i obriši dnevnike** (odbiti potvrdu je dovoljno) mora pokazati popis i dalje raditi, a sučelje ostati živo tijekom popisa.

### T2.7 (prvi korak): mjerenje dubokog skeniranja
- Prije prepisivanja dijete-skripte u paralelnu (RunspacePool, ~600 redaka bez mogućnosti pokretanja na Linuxu) uvedeno je **mjerenje**: dijete-skripta bilježi kumulativno vrijeme nakon svake skupine (dnevnici, sigurnost, softver, Windows Update) i ispisuje ga u stderr kao `AUXTIMING dnevnici=…;sigurnost=…;softver=…;update=…`; roditelj (`Complete-DeepScan`) ga pretvara u trajanje po skupini i upisuje u dnevnik: `Duboko skeniranje, trajanje po skupinama: dnevnici 3.0 s, sigurnost 2.5 s, softver 4.3 s, update 4.9 s (ukupno 14.7 s)`. `Get-DeepStderrHint` preskače taj redak.
- Svrha: ako ukupno vrijeme dominira jedna skupina (npr. pretraga Windows Updatea), paralelizacija neće dati ocjenu za ~8 s i ne isplati se riskirati; odluka o T2.7 ide na temelju stvarnih brojeva sa Windowsa. Ponašanje alata se ne mijenja.

## Faza 3 – Modernizacija sučelja

### T3.7 – watchdog sučelja i mjerenje pokretanja
- Novi dio `src\56-Watchdog.ps1`: tajmer od 100 ms na UI niti (pokreće se kad se prozor prikaže) mjeri razmak između otkucaja; razmak od 400 ms naviše znači da sučelje nije reagiralo i zapisuje se u dnevnik uz naziv zadatka koji je tada radio (`Sučelje nije reagiralo 650 ms (zadatak: Osvježavanje statusa sustava)`), najviše 50 zapisa po pokretanju; razmaci duži od 2 min (mirovanje računala) se ignoriraju. `Start-GuiTask` sada pamti naziv zadatka (`$script:CurrentTask`).
- Mjerenje pokretanja (podatak za T3.5, keš prevedenog C#): u dnevniku je redak `Pokretanje do prikaza prozora: N ms (prevođenje C#: M ms)`. Mjeri se u povišenom procesu (od učitavanja sklopova do prikaza prozora), bez prvog neprivilegiranog procesa i UAC-a.
- Neovisna provjera (3 recenzenta + skeptici) potvrdila je tri problema, svi ispravljeni: watchdog je vlastiti zapis u dnevnik ubrajao u sljedeći razmak (na sporom stiku lanac zapisa do ograničenja od 50), pa se štoperica sada ponovno pokreće nakon zapisa; lažna štoperica u testu nije imala semantiku `Restart` (test je prolazio i uz pokvaren watchdog); granice praga (399/400 ms) i mirovanja (120000/120001 ms) nisu bile pokrivene. Novi test pada na staroj verziji koda (provjereno mutacijom).

### T3.4 – ispravan DPI (skaliranje zaslona 125–175 %)
- Odluka vlasnika: ima računala sa skaliranjem iznad 100 %. Dosad je alat bio „DPI-nesvjestan“: Windows je cijeli prozor rastezao kao sliku (zamućen tekst). Sada je **sustavno svjestan DPI-ja** (`NativeMethods.EnableDpiAwareness` = `SetProcessDPIAware`, poziva se prije prvog prozora u `90-Main.ps1`), pa su tekst i crteži oštri.
- Raspored je i dalje napisan u 96-DPI jedinicama; forma ima `AutoScaleDimensions = 96,96` i `AutoScaleMode = Dpi` (standardni obrazac oblikovatelja obrazaca), a faktor `$script:DpiScale` (1,0 pri 100 %) množi sve što je izraženo u pikselima izvan kontrola: **zaglavlje** i **kartica ocjene** (rukom crtani dijelovi), **uvlake i tabulatori** RichTextBoxa u `Add-RichText`, **visina kartice ocjene** (`Update-HealthTile`), korak **marquee trake** i **početna veličina prozora** (radna površina se dijeli s faktorom da prozor ne prelazi zaslon). Pri 100 % je sve identično kao prije.
- Isključuje se praznom datotekom **`Auxilium-Dpi.off`** uz skriptu (vraća staro ponašanje). U dnevniku je redak `Zaslon: skaliranje …, AutoScaleFactor …, prozor …, radna površina …` za dijagnostiku.
- Provjera: Pester (`Dpi.Tests.ps1`: faktor, uvlake, visina kartice, ožičenje) i **stvarno iscrtavanje** pravih funkcija za crtanje pri 100/150/200 % (`tests\Render-Paint.ps1`; pregledane slike: razmaci, trake i tekst su proporcionalni, bez preklapanja). **Nije isprobano:** sam WinForms raspored (`AutoScaleMode` na pravoj formi) na zaslonu s 125–150 %: to treba potvrditi snimkom zaslona.

### T3.6 – odabir dnevnika za izvoz i brisanje
- Odluka vlasnika: treba dijalog za odabir koji se Windows dnevnici događaja izvoze i brišu. Novi dio `src\52-LogSelection.ps1`: nakon popisa dnevnika (T2.3) pokazuje se modalni dijalog s popisom (kvačice, broj zapisa i veličina po dnevniku), gumbima **Odaberi sve**, **Poništi sve**, **Samo System i Application** i zbirnim retkom („Odabrano: N od M dnevnika, X zapisa, Y MB“). Gumb **Izvezi i obriši odabrano** je onemogućen dok ništa nije označeno; Esc i **Odustani** prekidaju radnju prije ikakvog izvoza.
- Zadano su označeni **svi** dnevnici sa zapisima (kao dosad), odnosno oni iz prethodnog odabira u istoj sesiji (`$script:LogClearSelection`). Postojeća **završna potvrda** (s gumbom Ne kao zadanim, putanjom mape i brojkama) ostaje iza odabira, pa su zaštite dvije.
- Ako dijalog zakaže (iznimka), radnja se **prekida** (greška u terminalu i dnevniku), a ne nastavlja sa „svim dnevnicima“: radnja je razorna. Dijalog je DPI-svjestan (isti `AutoScaleMode = Dpi` kao glavni prozor, a širine stupaca se računaju iz stvarne širine popisa).
- Ispravak ranijeg opisa: potvrdni dijalog ove radnje dolazi **nakon** popisa dnevnika, ne prije (zato je odbijanje potvrde u ranijem testu već izvelo i popis iz T2.3).
- Čista logika (zadani odabir, filtriranje plana, sažetak, „uobičajeni“ dnevnici) i ožičenje pokriveni su Pester testovima; **sam dijalog nije isproban na Windowsu** (WinForms se ne može pokrenuti na Linuxu).
