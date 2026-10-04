# test\ – ručni pregled u Windows Sandboxu

Windows Sandbox je jedini jeftin način da se alat isproba na **čistom Windowsu, s pravim UAC-om, bez Officea i s drukčijim jezikom**, bez instalacije i VM licence.

```powershell
.\build.ps1
.\test\Start-Sandbox.ps1        # izrađuje test\Auxilium.generated.wsb (nije u gitu) i pokreće Sandbox
```

`dist\` je u Sandboxu u `C:\Auxilium` (zapisivo: alat uz skriptu sprema postavke i izvještaje, pa se oni pojavljuju i u `dist\` na računalu), a pokretač se pokreće sam. Mreža je isključena; za test mreže uklonite `<Networking>Disable</Networking>` u predlošku `Auxilium.wsb`.
Windows Sandbox treba Windows 10/11 Pro, Enterprise ili Education i uključenu značajku „Windows Sandbox“.

## Kontrolna lista

- [ ] **UAC:** alat traži podizanje na administratora i otvara prozor (Sandbox je prijavljen kao administrator pa UAC traži samo potvrdu).
- [ ] **Čist Windows bez Officea:** odjeljak „Softver i licence“ ne pada; Office/Outlook su prikazani kao nisu instalirani.
- [ ] **Jezik:** promijenite jezik/regiju u Sandboxu na engleski (en-US) i ponovno pokrenite: nazivi stanja i brojevi se i dalje ispravno čitaju; ocjena se računa.
- [ ] **Health/Security Score:** nakon pozadinskog prikupljanja ocjena nije „provjera u tijeku“.
- [ ] **PDF:** „PDF izvještaj“ izrađuje PDF i JSON; `Microsoft Print to PDF` postoji u Sandboxu. Izvještaji se spremaju u `C:\Auxilium\Izvjestaji\<Tvrtka>\` (to je `dist\Izvjestaji\` na računalu).
- [ ] **Prekid:** „Prekini“ tijekom SFC/DISM vraća sučelje bez zamrzavanja.
- [ ] **Izlaz:** zatvaranje prozora zatvara proces (Task Manager: nema `powershell.exe` koji visi).

Rezultate upišite uz izdanje u `PROMJENE.md`. Ovaj pregled **nije** automatiziran: ne može se izvesti na Linuxu ni u CI-ju.
