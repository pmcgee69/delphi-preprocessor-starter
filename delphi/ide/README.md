# The rules in the Delphi IDE's editor

`DelphiPPIDE.bpl`, an IDE package: in an open `.dpps` file (or `.dpps.pas`), it shows what the
rules do, as you type, as Zed does.

- **What a rule would change** is underlined with a dotted line: the `case` on strings that
  `case-of` writes as an `if` chain. **Where a rule adds text** has a small solid caret: the
  place `assert-message` adds its text.
- **A rule that fails** on the text (half typed, say) is said after line 1, and nothing else is
  shown until the text is one it can read.
- **A rule's error, warning or hint** has a wavy underline where it is (red, amber or grey), and
  its text in italics after the end of the line, as
  `case-of: a range label in a case on strings or class types: write it as an if`.
- **`.dpps` is highlighted as Delphi:** the package adds `dpps` to the editor's Delphi
  extensions, so the registry step in [`examples\ide\README.md`](../../examples/ide/README.md)
  isn't needed.

The rules run inside the IDE, on the editor's text, each time it changes: the Delphi engine and
rules (`..\DelphiPP.Engine.pas`, `..\DelphiPP.Rules.pas`), and the same ones the pre-build event
runs (the Python side's `ALL`). Nothing is written to disk; the build still writes the `.pas`.

## Build it

From a RAD Studio Command Prompt (after `..\get-treesitter4d.cmd`, once):

```
build.cmd
```

It builds one for each of Delphi 13's IDEs: `bin\win32\DelphiPPIDE.bpl` for the 32-bit IDE
(`Studio\37.0\bin\bds.exe`), `bin\win64\DelphiPPIDE.bpl` for the 64-bit one (`bin64\bds.exe`).

## Install it

*Component > Install Packages > Add*, and choose the `.bpl` for the IDE you run. It's listed as
*DelphiPP: the rules in the editor*. Open a `.dpps` file, as `examples\ide\Greet.dpps`.

To remove it: the same dialog, select it, *Remove*. Close the IDE before building it again:
Windows doesn't let a loaded `.bpl` be replaced.

If the IDE won't start with it, remove it from the registry with the IDE closed: the value
named after the `.bpl`'s path under `HKCU\Software\Embarcadero\BDS\37.0\Known Packages` (32-bit
IDE) or `Known Packages x64` (64-bit).

## Test it without the IDE

`MarksTest.dpr` prints what the package would mark in a file, as text:

```
dcc64 -Q -B -Ebin\test -NUbin\test "-NSSystem;Winapi" -U.. -U..\TreeSitter4D\delphi MarksTest.dpr
bin\test\MarksTest.exe ..\..\examples\ide\Greet.dpps
```

```
  24    Assert(G.Times > 0);            // assert-message: gains its text, file and line
                          ^
  26    case G.Lang of                  // case-of: a case on strings, which dcc refuses, as an if chain
        ..............
  27      'en': Hello := 'Hello';
          .......................
```

## Not yet

- **Hover**, to show the text a rule writes, as Zed does.
- **Tabs**: a tab is counted as one column, so on a line with tabs before a mark, the mark is
  drawn too far left.
- **Only `.dpps` and `.dpps.pas` files.** A plain `.pas` isn't marked: the rules would mark
  every `Assert` in every unit you open.
