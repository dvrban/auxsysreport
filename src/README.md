# src\ – izvor alata (varijanta „Ljuska“)

Izvor varijante „Ljuska“ podijeljen je iz jedne datoteke (v0.04, 6606 redaka) u dijelove po regijama (`#region` … `#endregion`).
Podjela je **mehanička** (tiket T0.1): ni jedan redak koda nije izmijenjen, a dijelovi se sastavljaju natrag u
`v4\Auxilium-Dijagnostika-Ljuska.ps1` **bajt po bajt** (SHA-256 `D8E2DDDC…EA2F4`). Izdanje `v4\` ostaje nepromijenjeno.

Ovdje se još ne gradi ništa: `build.ps1` dolazi u T0.2. Do tada se alat i dalje pokreće iz `v4\`.

## Raspored

| Datoteka | Sadržaj | Redci u v0.04 |
|---|---|---|
| `01-Header.ps1` | `#Requires`, opis (comment-based help), `$ErrorActionPreference` | 1–37 |
| `02-Encoding.ps1` | regija ENCODING | 38–44 |
| `03-Bootstrap.ps1` | učitavanje sklopova WinForms/Drawing, postavke aplikacije, `Test-IsAdministrator` | 45–61 |
| `04-Elevation.ps1` | regija ELEVATION (UAC, ponovno pokretanje u STA) | 62–107 |
| `05-Native.ps1` | regija NATIVE (`Add-Type`); C# je u `native\Native.cs` | 108–549 |
| `06-GlobalState.ps1` | regija GLOBAL STATE (`$script:BuildNumber`, registri) | 550–593 |
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
   svojim prekidom retka i praznim retkom između regija.
2. Svaka datoteka čita se kao UTF-8 (BOM se odbacuje); sastavljena datoteka piše se kao **UTF-8 s BOM-om i CRLF**.
3. Redak `#<<NATIVE_CS>>#` zamjenjuje se cijelim sadržajem `native\Native.cs`, a redak `#<<DEEP_SCAN>>#` cijelim sadržajem
   `deep\DeepScan.ps1` (oznaka zajedno s krajem retka ← cijela datoteka zajedno s krajem zadnjeg retka). Svaka oznaka postoji u dijelovima
   točno jednom. Datoteke su tijela here-stringova `@'…'@`: ne smiju sadržavati redak koji počinje s `'@`.

## Kodiranje i krajevi redaka

Sve datoteke u `src\` su UTF-8 **s BOM-om** i **CRLF** (kao i izvornik): bez BOM-a Windows PowerShell 5.1 hrvatska slova (Š, Ž, Č, Ć, Đ)
čita kao ANSI. `.gitattributes` označava `src\` i `tests\` kao `-text`, pa Git ne mijenja krajeve redaka ni na jednom računalu
(inače bi `core.autocrlf` mogao pokvariti bajt-identičnost). Pri uređivanju sačuvajte BOM i CRLF.

## Provjera

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SrcSplit.ps1
```

Provjerava SHA-256 sastavljene datoteke prema izdanju, isti popis od 122 funkcije najviše razine (AST) i da se svaki dio parsira bez grešaka.
Vrijedi samo dok `src\` odgovara izdanju v0.04; poslije prve izmjene koda zamjenjuju je `build.ps1` i Pester testovi (T0.2, T0.5).

## Za sljedeće tikete

- `04-Elevation.ps1` i `90-Main.ps1` izvode radnje pri učitavanju (podizanje na administratora, otvaranje prozora): za Pester (T0.5) treba ih
  izuzeti iz dot-sourcea, kao što to danas rade harnessi (regex po regijama).
- `$PSScriptRoot` koristi se u `10-Helpers.ps1` i `20-Portable.ps1` za pronalaženje mape izdanja. Sastavljena datoteka u `dist\` radi
  ispravno, ali dot-source dijelova iz `src\` daje mapu `src\`.
- `04-Elevation.ps1` ponovno pokreće `$PSCommandPath`: izvor iz `src\` ne može se pokretati izravno, samo sastavljena datoteka.
