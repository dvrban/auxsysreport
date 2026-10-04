# Auxilium Informatika – dijagnostika: popis izdanja

## Označavanje verzija
Izdanja se broje v1, v2, v3 … U aplikaciji se prikazuju kao broj/10 s jednom decimalom:
v1 = **0.1**, v2 = **0.2**, … v9 = 0.9, v10 = **1.0**, v23 = 2.3.
U skripti se mijenja samo `$script:BuildNumber`; prikazana verzija (zaglavlje, terminal, „Verzija alata“, `toolVersion` u JSON-u) računa se iz njega.

Svako izdanje čuva se kao nepromjenjiva kopija u `Verzije\vN\` (i kao `Verzije\Auxilium-vN.zip`).

## v1 (prikazuje se kao 0.01)
Dvije varijante, obje s istim funkcijama alata:
- **Auxilium-Dijagnostika.ps1** (`Pokreni-Auxilium.cmd`) – izvorni izgled.
- **Auxilium-Dijagnostika-Ljuska.ps1** (`Pokreni-Auxilium-Ljuska.cmd`) – stil Auxilium web aplikacije, status sustava lijevo preko cijele visine, gumb „Izvezi JSON“ i JSON uz svaki PDF.

Zajedničko:
- Prenosiv rad s USB stika; izvještaji u `Izvjestaji\<Tvrtka>\` imenovani RAČUNALO_korisnik_datum-vrijeme.
- Status sustava: OS, procesor/MBO/RAM, GPU, diskovi, zdravlje diskova, printeri.
- Pozadinsko prikupljanje: softver i licence (Windows, Office, mail, OST/PST), instalirani programi, ažuriranja na čekanju, dnevnici događaja 7 dana.
- SFC & DISM (uz DISM RestoreHealth kad je spremište komponenti popravljivo), CHKDSK (samo čitanje), duboko čišćenje, test mreže, PDF izvještaj.
- Odjeljak statusa „PROCESSOR, MBO & RAM“.

## v2 (prikazuje se kao 0.02)
Health Score u obje varijante (i u PDF izvještaju):
- Ocjena 0–100 s oznakom ODLIČNO / DOBRO / UPOZORENJE / LOŠE i tri najveća razloga odbitka, kartica na vrhu „Status sustava“.
- Težine: Sigurnost 30, Diskovi 20, Stabilnost 15, Ažuriranja 15, Resursi 10, Licence 5, Pošta 5 (svako područje ima gornju granicu odbitka).
- Novi odjeljak **SIGURNOST** (pozadinsko prikupljanje): antivirus i definicije, Windows vatrozid, BitLocker sistemskog diska (strože za laptope), SMBv1, RDP.
- Ocjena se računa nakon završetka pozadinskog prikupljanja (do tada „provjera u tijeku“); područja bez podataka ne ulaze u zbroj i ocjena se označi kao djelomična.
- PDF: ocjena, traka i razlozi odbitka na početku izvještaja, te odjeljak SIGURNOST. JSON za IT Inventar nije mijenjan.

## v3 (prikazuje se kao 0.03)
- **Živi CPU i RAM barovi** u odjeljku „Processor, MBO & RAM“, u istom stilu kao barovi diskova; osvježavaju se sami svake 2 s (opterećenje procesora iz GetSystemTimes, ne ovisi o jeziku Windowsa; RAM iz GlobalMemoryStatusEx). Skrolanje i odabrani tekst u panelu ostaju netaknuti.
- **Health/Security Score** (novo ime): uz broj i oznaku bar od 20 segmenata u boji razine, mini-barovi po područjima (Sigurnost 30 / Diskovi 20 / Stabilnost 15 / Ažuriranja 15 / Resursi 10 / Licence 5 / Pošta 5) i tri najveća razloga odbitka.
- **PDF**: odjeljak „HEALTH/SECURITY SCORE“ (ocjena, bar, bodovi po područjima, razlozi), a CPU i RAM barovi s najnovijim vrijednostima ulaze u izvještaj.

## v4 (prikazuje se kao 0.04)
- **Izvezi i obriši dnevnike** (novi gumb u kartici „Čišćenje sustava“): izvozi SVE Windows dnevnike događaja koji imaju zapise u TXT (UTF-8) u mapu `<Tvrtka>\<RAČUNALO>_<korisnik>_<datum>_dnevnici\` uz izvještaj, s popisom `00-POPIS.txt`. Svaki dnevnik se briše tek nakon što je njegov izvoz zapisan i provjeren (broj događaja); Security zadnji. Traži potvrdu (zadano „Ne“), administratorska prava i provjerava slobodan prostor. „Prekini“ tijekom izvoza ne briše ništa.
  Predviđen je izbornik za odabir dnevnika (kasnije): dovoljno je postaviti `$script:LogClearSelection` na popis naziva.
- **PDF izvještaj**: novi logotip (AU + crveni X + ILIUM + žuta točka + razmaknuti INFORMATIKA) i **Health/Security Score u zaglavlju prve stranice**; ako se ocjena ne može izračunati, to se vidi u izvještaju (a ne nestane tiho).
- Kartice: tri reda u svim karticama (poravnati gumbi), traka kartica viša za 54 px.