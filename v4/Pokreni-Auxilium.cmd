@echo off
rem Auxilium Informatika - pokretac. Radi s bilo kojeg slova pogona (npr. s USB sticka); uz skriptu cuva postavke i izvjestaje.
set "AUXERR=%TEMP%\Auxilium-start-error.txt"
if exist "%AUXERR%" del "%AUXERR%" >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Auxilium-Dijagnostika.ps1" 2>"%AUXERR%"
if errorlevel 1 for %%A in ("%AUXERR%") do if %%~zA GTR 0 start "" notepad "%AUXERR%"
