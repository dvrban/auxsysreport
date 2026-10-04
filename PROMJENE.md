# Auxilium Informatika – dijagnostika: razvoj nakon izdanja v4

Izdanja v1–v4: vidi `v4\PROMJENE.md` (`v4\` je nepromjenjiva kopija izdanja v4 i ne mijenja se).
Ovdje se bilježi neobjavljeni rad prema izdanju v5 (Faza 0 „Temelji“ iz izvještaja o reviziji v0.04). Jedan tiket = jedan commit = jedan unos.

## Neobjavljeno (prema v5)

### T0.1 – Podjela izvora u `src\`
- Izvor varijante „Ljuska“ podijeljen je iz jedne datoteke od 6606 redaka u 22 dijela po regijama (`src\01-Header.ps1` … `src\90-Main.ps1`),
  a tijela dvaju here-stringova izdvojena su u `src\native\Native.cs` (C#) i `src\deep\DeepScan.ps1` (dijete-skripta dubokog skeniranja).
- **Ponašanje alata nije izmijenjeno:** dijelovi se sastavljaju natrag u `v4\Auxilium-Dijagnostika-Ljuska.ps1` bajt po bajt (SHA-256 `D8E2DDDC…EA2F4`)
  i definiraju istih 122 funkcije najviše razine. Provjera: `tests\Test-SrcSplit.ps1`.
- Pravila sastavljanja, kodiranje (UTF-8 s BOM-om, CRLF) i raspored: `src\README.md`. `.gitattributes` štiti BOM i CRLF u `src\` i `tests\`.
- Još nema `build.ps1` (T0.2): alat se i dalje pokreće iz `v4\`. Varijanta „Original“ (`Auxilium-Dijagnostika.ps1`) nije dirana (T3.3).
