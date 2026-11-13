@echo off
rem Builds delphipp.exe and RunTests.exe with Delphi alone.
rem   build.cmd           Win64, into delphi\bin
rem   build.cmd win32     Win32, into delphi\bin\win32
rem   build.cmd test      and then runs the tests (Zed's task: no && needed of its shell)
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
set TEST=
for %%a in (%*) do (
  if /i "%%~a"=="win32" (
    set DCC=dcc32
    set OUT=bin\win32
  )
  if /i "%%~a"=="test" set TEST=1
)
if not exist %OUT%\dcu mkdir %OUT%\dcu
rem Zed's language server may be running delphipp.exe, which Windows won't let dcc overwrite,
rem but will let us rename: the old one runs on till Zed restarts it, and is deleted next time
del /q %OUT%\delphipp.old-*.exe 2>nul
if exist %OUT%\delphipp.exe move /y %OUT%\delphipp.exe %OUT%\delphipp.old-%RANDOM%.exe >nul
for %%p in (delphipp RunTests) do (
  %DCC% -Q -B -E%OUT% -NU%OUT%\dcu "-NSSystem;Winapi" -UTreeSitter4D\delphi %%p.dpr || exit /b 1
)
rem the old one now, unless it is still running
del /q %OUT%\delphipp.old-*.exe 2>nul
echo built: %OUT%\delphipp.exe, %OUT%\RunTests.exe
if defined TEST %OUT%\RunTests.exe
