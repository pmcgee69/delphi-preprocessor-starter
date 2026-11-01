@echo off
rem Builds delphipp.exe and RunTests.exe with Delphi alone.
rem   build.cmd           Win64, into delphi\bin
rem   build.cmd win32     Win32, into delphi\bin\win32
rem Run get-treesitter4d.cmd once first. From a RAD Studio command prompt, or
rem anywhere dcc64 and dcc32 are on the PATH.
setlocal
cd /d "%~dp0"
if not exist TreeSitter4D\delphi\TreeSitter.Api.pas (
  echo TreeSitter4D isn't here yet: run get-treesitter4d.cmd first
  exit /b 1
)
set DCC=dcc64
set OUT=bin
if /i "%~1"=="win32" (
  set DCC=dcc32
  set OUT=bin\win32
)
if not exist %OUT%\dcu mkdir %OUT%\dcu
for %%p in (delphipp RunTests) do (
  %DCC% -Q -B -E%OUT% -NU%OUT%\dcu "-NSSystem;Winapi" -UTreeSitter4D\delphi %%p.dpr || exit /b 1
)
echo built: %OUT%\delphipp.exe, %OUT%\RunTests.exe
