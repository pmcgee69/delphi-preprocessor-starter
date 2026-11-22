@echo off
rem Builds the IDE packages for both of Delphi 13's IDEs, into one folder each:
rem   bin\win32\DelfNavIDE.bpl, DelphiPPIDE.bpl   for the 32-bit IDE (Studio\37.0\bin\bds.exe)
rem   bin\win64\DelfNavIDE.bpl, DelphiPPIDE.bpl   for the 64-bit IDE (Studio\37.0\bin64\bds.exe)
rem DelphiPPIDE (the rules) requires DelfNavIDE (navigation, and TreeSitter4D's unit), built
rem first from the submodule ..\DelfNav: each unit in one package, so both install together.
rem Install DelfNavIDE first, then DelphiPPIDE, from the same folder.
rem Run ..\get-treesitter4d.cmd once first. From a RAD Studio command prompt, or
rem anywhere dcc32 and dcc64 are on the PATH. Close the IDE first if it has the
rem packages loaded: Windows keeps a loaded .bpl from being written.
setlocal
cd /d "%~dp0"
if not exist ..\TreeSitter4D\delphi\TreeSitter.Api.pas (
  echo TreeSitter4D isn't here yet: run ..\get-treesitter4d.cmd first
  exit /b 1
)
if not exist ..\DelfNav\delphi\ide\DelfNavIDE.dpk (
  echo DelfNav isn't here yet: run "git submodule update --init" in the repository
  exit /b 1
)
rem DelfNavIDE.dpk finds TreeSitter4D beside itself, in DelfNav\delphi\TreeSitter4D: this
rem repository's copy, through a junction (no second download)
if not exist ..\DelfNav\delphi\TreeSitter4D\delphi\TreeSitter.Api.pas (
  mklink /J ..\DelfNav\delphi\TreeSitter4D ..\TreeSitter4D >nul || exit /b 1
)
for %%p in (win32 win64) do (
  if not exist bin\%%p\dcu mkdir bin\%%p\dcu
)
rem dcc reads a package's "in" paths from the current folder, so DelfNavIDE from its own
set HERE=%CD%
pushd ..\DelfNav\delphi\ide
dcc32 -Q -B -LE"%HERE%\bin\win32" -LN"%HERE%\bin\win32" -NU"%HERE%\bin\win32\dcu" "-NSSystem;Winapi;Vcl" DelfNavIDE.dpk || (popd & exit /b 1)
dcc64 -Q -B -LE"%HERE%\bin\win64" -LN"%HERE%\bin\win64" -NU"%HERE%\bin\win64\dcu" "-NSSystem;Winapi;Vcl" DelfNavIDE.dpk || (popd & exit /b 1)
popd
dcc32 -Q -B -LEbin\win32 -LNbin\win32 -NUbin\win32\dcu -Ubin\win32 "-NSSystem;Winapi;Vcl" DelphiPPIDE.dpk || exit /b 1
dcc64 -Q -B -LEbin\win64 -LNbin\win64 -NUbin\win64\dcu -Ubin\win64 "-NSSystem;Winapi;Vcl" DelphiPPIDE.dpk || exit /b 1
echo built: bin\win32\DelfNavIDE.bpl and DelphiPPIDE.bpl, bin\win64\DelfNavIDE.bpl and DelphiPPIDE.bpl
rem build.cmd install: both copied to the IDE's own package folders, which are on the PATH, so
rem Windows finds DelfNavIDE.bpl whenever DelphiPPIDE.bpl is loaded. Install from there.
if /i not "%~1"=="install" exit /b 0
if not defined BDSCOMMONDIR (
  echo BDSCOMMONDIR isn't set: run from a RAD Studio command prompt
  exit /b 1
)
for %%f in (DelfNavIDE DelphiPPIDE) do (
  copy /y bin\win32\%%f.bpl "%BDSCOMMONDIR%\Bpl\" >nul || exit /b 1
  copy /y bin\win64\%%f.bpl "%BDSCOMMONDIR%\Bpl\Win64\" >nul || exit /b 1
)
echo installed: %BDSCOMMONDIR%\Bpl and %BDSCOMMONDIR%\Bpl\Win64, DelfNavIDE.bpl and DelphiPPIDE.bpl
