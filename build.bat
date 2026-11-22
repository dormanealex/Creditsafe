@echo off
rem ------------------------------------------------------------------
rem  build.bat - compile creditsafe.prg avec Harbour (hbmk2)
rem  Si Harbour n'est pas trouve automatiquement, indiquez son dossier :
rem     set HB_DIR=C:\hb32
rem ------------------------------------------------------------------
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "HB_BIN="

rem 1) dossier impose par HB_DIR
if defined HB_DIR if exist "%HB_DIR%\bin\hbmk2.exe" set "HB_BIN=%HB_DIR%\bin"

rem 2) hbmk2 deja dans le PATH
if not defined HB_BIN (
   for /f "delims=" %%F in ('where hbmk2.exe 2^>nul') do if not defined HB_BIN set "HB_BIN=%%~dpF"
)

rem 3) emplacements habituels
if not defined HB_BIN (
   for %%D in (C:\hb32 C:\hb34 C:\hb30 C:\harbour C:\harbour32 C:\harbour34 C:\hb C:\harbour-core) do (
      if not defined HB_BIN if exist "%%D\bin\hbmk2.exe" set "HB_BIN=%%D\bin"
      if not defined HB_BIN if exist "%%D\bin\win\mingw\hbmk2.exe" set "HB_BIN=%%D\bin\win\mingw"
   )
)

rem 4) recherche sur tout le disque C: (peut prendre une minute)
if not defined HB_BIN (
   echo Recherche de hbmk2.exe sur C:\ ...
   for /f "delims=" %%F in ('where /r C:\ hbmk2.exe 2^>nul') do if not defined HB_BIN set "HB_BIN=%%~dpF"
)

if not defined HB_BIN (
   echo.
   echo *** Harbour introuvable : installez Harbour 3.2 ou lancez :
   echo        set HB_DIR=C:\chemin\vers\harbour
   echo        build.bat
   pause
   exit /b 1
)
if "%HB_BIN:~-1%"=="\" set "HB_BIN=%HB_BIN:~0,-1%"
set "PATH=%HB_BIN%;%PATH%"

rem compilateur C MinGW livre avec Harbour (si present)
for %%M in ("%HB_BIN%\..\comp\mingw\bin" "%HB_BIN%\..\comp\mingw64\bin" "%HB_BIN%\..\comp\mingw32\bin" "%HB_BIN%\..\..\..\comp\mingw\bin" "%HB_BIN%\..\..\..\comp\mingw64\bin") do (
   if exist "%%~M\gcc.exe" set "PATH=%%~fM;!PATH!"
)

echo Harbour : %HB_BIN%
echo Compilation de creditsafe.prg ...
echo.
hbmk2 creditsafe.hbp > build.log 2>&1
set "RC=%ERRORLEVEL%"
type build.log
echo.
if not "%RC%"=="0" (
   echo *** ECHEC de la compilation - le detail est dans build.log
   pause
   exit /b 1
)
echo OK : creditsafe.exe a ete cree.
pause
exit /b 0
