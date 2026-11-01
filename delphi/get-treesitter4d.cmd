@echo off
rem Fetches TreeSitter4D for the Delphi side, with what Windows 10 and later
rem already have (git, curl, certutil, tar): its Delphi units, from the tag,
rem and its C compiled, from the same release, checked against its SHA-256.
rem Everything lands in delphi\TreeSitter4D (ignored by git).
rem   get-treesitter4d.cmd
setlocal
cd /d "%~dp0"
set VER=0.1.0
set SHA=f01847c5bf5faf9cbd1c89981bc2c32339133ffd7ca94044ec2068f5564cf2d1
set ZIP=TreeSitter4D-%VER%-objects.zip
set URL=https://github.com/pmcgee69/TreeSitter4D/releases/download/v%VER%/%ZIP%
rem Windows' own tar reads zip files; another on the PATH (Git's) may not
set TAR=%SystemRoot%\System32\tar.exe

if exist TreeSitter4D\obj\ts_lib.o (
  echo TreeSitter4D is here already: delete delphi\TreeSitter4D to fetch it again
  goto :eof
)
if not exist TreeSitter4D\delphi\TreeSitter.Api.pas (
  git clone --quiet --depth 1 --branch v%VER% https://github.com/pmcgee69/TreeSitter4D.git TreeSitter4D || exit /b 1
)
echo downloading %URL%
curl --silent --show-error --location --fail -o TreeSitter4D\%ZIP% %URL% || exit /b 1

rem certutil prints the hash on its second line
for /f "skip=1 delims=" %%h in ('certutil -hashfile TreeSitter4D\%ZIP% SHA256') do (
  if not defined GOT set GOT=%%h
)
set GOT=%GOT: =%
if /i not "%GOT%"=="%SHA%" (
  echo the download's SHA-256 is %GOT%, not %SHA%: nothing unzipped
  exit /b 1
)
"%TAR%" -xf TreeSitter4D\%ZIP% -C TreeSitter4D || exit /b 1
echo done: TreeSitter4D %VER%, its objects in delphi\TreeSitter4D\obj
