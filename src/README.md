# src\ – izvor alata (varijanta „Ljuska“)

Izvor varijante „Ljuska“ podijeljen je iz jedne datoteke (v0.04, 6606 redaka) u dijelove po regijama (`#region` … `#endregion`).
Podjela je **mehanička** (tiket T0.1): nijedan redak koda nije izmijenjen, a dijelovi se sastavljaju natrag u
`v4\Auxilium-Dijagnostika-Ljuska.ps1` **bajt po bajt** (SHA-256 `D8E2DDDC…EA2F4`). Izdanje `v4\` ostaje nepromijenjeno.

Gradi se s `build.ps1` u korijenu repozitorija (T0.2): `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1` daje `dist\Auxilium-Dijagnostika-Ljuska.ps1`.

## Raspored

| Datoteka | Sadržaj | Redci u v0.04 |
|---|---|---|
| `01-Header.ps1` | `#Requires`, opis (comment-based help), `$ErrorActionPreference` | 1–37 |
| `02-Encoding.ps1` | regija ENCODING | 38–44 |
| `03-Bootstrap.ps1` | učitavanje sklopova WinForms/Drawing, postavke aplikacije, `Test-IsAdministrator` | 45–61 |
| `04-Elevation.ps1` | regija ELEVATION (UAC, ponovno pokretanje u STA) | 62–107 |
| `05-Native.ps1` | regija NATIVE (`Add-Type`); C# je u `native\Native.cs` | 108–549 |
| `06-GlobalState.ps1` | regija GLOBAL STATE (`$script:BuildNumber`, varijable stanja) | 550–593 |
| `10-Helpers.ps1` | HELPERS | 594–794 |
| `20-Portable.ps1` | PORTABLE (USB stick, postavke) | 795–1015 |
| `30-Terminal.ps1` | TERMINAL / PROGRESS | 1016–1185 |
| `40-SystemInfo.ps1` | SYSTEM INFO | 1186–1695 |
| `45-DeepScan.ps1` | DEEP SCAN; dijete-skripta je u `deep\DeepScan.ps1` | 1696–2605 |
| `50-Logs.ps1` | LOGS | 2606–2924 |
| `55-LiveMeters.ps1` | LIVE METERS | 2925–2983 |
| `60-Health.ps1` | HEALTH (Health/Security Score) | 2984–3364 |
| `65-LiveProcess.ps1` | LIVE PROCESS | 3365–3584 |
| `70-TasksSystem.ps1` | TASKS - SISTEM | 3585–3644 |
| `72-TasksCleanup.ps1` | TASKS - CISCENJE | 3645–3955 |
| `74-TasksNetwork.ps1` | TASKS - MREZA | 3956–4167 |
| `78-Export.ps1` | EXPORT (inventar, JSON) | 4168–5215 |
| `80-TasksPdf.ps1` | TASKS - PDF | 5216–5836 |
| `85-Ui.ps1` | UI (`New-MainForm`, crtanje) | 5837–6587 |
| `90-Main.ps1` | MAIN (`ShowDialog`, čišćenje pri izlasku) | 6588–6606 |
| `native\Native.cs` | tijelo C# here-stringa iz `05-Native.ps1` | 138–531 |
| `deep\DeepScan.ps1` | tijelo here-stringa dijete-skripte iz `45-DeepScan.ps1` | 1703–2300 |

Brojevi u nazivima daju redoslijed sastavljanja i imaju razmake za nove dijelove. Samo `src\*.ps1` (bez podmapa) su dijelovi;
`native\` i `deep\` sadrže tijela here-stringova.

## Pravila sastavljanja (ugovor za `build.ps1`, T0.2)

1. Dijelovi `src\*.ps1` spajaju se redom po nazivu (ordinalno, ne po jezičnim pravilima), **bez razdjelnika**: svaki dio već završava
   svojim prekidom retka i praznim retkom (retcima) do sljedeće regije. Ti prazni retci su dio sadržaja: `45-DeepScan.ps1` namjerno završava s dva,
   a `90-Main.ps1` s nijednim; uređivač koji briše završne prazne retke promijenio bi sastavljene bajtove.
2. Svaka datoteka čita se kao UTF-8 (BOM se odbacuje); sastavljena datoteka piše se kao **UTF-8 s BOM-om i CRLF**.
3. Redak `#<<NATIVE_CS>>#` zamjenjuje se cijelim sadržajem `native\Native.cs`, a redak `#<<DEEP_SCAN>>#` cijelim sadržajem
   `deep\DeepScan.ps1`. Zamjenjuje se oznaka **zajedno s krajem njezina retka**, a umeće se cijela datoteka **zajedno s krajem njezina zadnjeg retka**.
   Svaka oznaka postoji u dijelovima točno jednom. Datoteke su tijela here-stringova `@'…'@`: ne smiju sadržavati redak koji počinje s `'@`.
   Zamjena mora biti **doslovna** (`String.Replace`): `-replace` i `[regex]::Replace` tumače `$_` i `$'` u `DeepScan.ps1` kao oznake zamjene
   i daju pokvarenu datoteku od oko 9,7 MB.

## Kodiranje i krajevi redaka

Sve datoteke u `src\` su UTF-8 **s BOM-om** i **CRLF** (kao i izvornik): bez BOM-a Windows PowerShell 5.1 hrvatska slova (Š, Ž, Č, Ć, Đ)
čita kao ANSI. `.gitattributes` označava `src\`, `tests\`, `v4\` i korijenski `PROMJENE.md` kao `-text`, pa Git ne mijenja krajeve redaka ni na jednom računalu
(inače bi `core.autocrlf` mogao pokvariti bajt-identičnost novih datoteka ili izdanja `v4\`); `whitespace=cr-at-eol` sprječava da `git diff --check`
CR javlja kao suvišan razmak. Pri uređivanju sačuvajte BOM i CRLF: `tests\Test-SrcSplit.ps1` to provjerava za svaku datoteku u `src\`.

## Provjera

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SrcSplit.ps1
```

Provjerava BOM i CRLF svake datoteke, SHA-256 sastavljene datoteke prema izdanju, isti popis od 122 funkcije najviše razine (AST)
i da se svaki dio parsira bez grešaka.
Vrijedi samo dok `src\` odgovara izdanju v0.04; poslije prve izmjene koda zamjenjuju je `build.ps1` i Pester testovi (T0.2, T0.5).

## Za sljedeće tikete

- Pri učitavanju izvode radnje, a ne samo definiraju funkcije: `02-Encoding.ps1` (kodiranje konzole), `03-Bootstrap.ps1` (postavke WinForms za cijeli proces),
  `04-Elevation.ps1` (podizanje na administratora, ponovno pokretanje i `exit`), `05-Native.ps1` (`Add-Type` prevodi C#; pri neuspjehu `exit 1`),
  `06-GlobalState.ps1` i `90-Main.ps1` (otvara prozor). Za Pester (T0.5) ih treba izuzeti iz dot-sourcea; izvještaj o reviziji navodi da to danas
  rade harnessi (regex po regijama), a njih u ovom repozitoriju nema.
- `` koristi se u `10-Helpers.ps1` i `20-Portable.ps1` za pronalaženje mape izdanja: dot-source dijelova iz `src\` daje mapu `src\`,
  a sastavljena datoteka daje mapu u kojoj leži. `04-Elevation.ps1` ponovno pokreće ``, pa se izvor iz `src\` ne može pokretati
  izravno, samo sastavljena datoteka.
- Skin sloj (T3.3) mora se umetnuti **prije** `90-Main.ps1`: `90-Main.ps1` otvara prozor i ne vraća se dok se on ne zatvori, a paleta `:Colors`
  puni se u `Initialize-Resources` (`10-Helpers.ps1`) i koristi u `30-`, `40-`, `60-` i `85-`. Dio koji bi došao iza `90-Main.ps1` izvršio bi se tek nakon zatvaranja prozora.
- Pester testovi još ne postoje (T0.5). Izvor se ne pokreće izravno: pokreće se `dist\` ili `v4\`.
