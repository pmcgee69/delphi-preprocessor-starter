# The rules in the Delphi IDE: a `.dpps` source and a pre-build event

`Greet.dpps` is Delphi source the rules rewrite before dcc sees it. Before every build, the
project's pre-build event runs them and writes `Greet.pas` beside it; the IDE then builds as
usual. No IDE package, nothing installed: a project setting.

Here the rules make a unit dcc would refuse into one it compiles:

| In `Greet.dpps` | In `Greet.pas`, written from it |
|---|---|
| `unit Greet.dpps;`, so the IDE's tabs and lists tell the two apart | `unit Greet;` |
| two `uses` clauses, each with its comment | one clause (`uses-merge`) |
| `case G.Lang of 'en': … 'fr': …` (a `case` on strings) | an `if` chain (`case-of`) |
| `Assert(G.Times > 0)` | `Assert(G.Times > 0, 'Greet.dpps:26: G.Times > 0')` (`assert-message`) |
| footnotes after `end.`: `[Greeting] A greeting for G, …`, with `G:` and `Result:` lines | XMLDoc above `TGreeting` and `Greeting`, for Help Insight, and nothing after `end.` (`footnotes`) |

## Highlighting `.dpps` in the IDE

Once per machine, add `dpps` to the extensions the IDE reads as Delphi. Delphi 13's Options
dialog doesn't show that list (nor is it *IDE > File Association*, which is what Windows opens
with the IDE), so it's done in the registry. **Close the IDE first**, since it writes its options
back when it closes; then, in PowerShell:

```
$k = "HKCU:\Software\Embarcadero\BDS\37.0\Editor\Source Options\Borland.EditOptions.Pascal"
Set-ItemProperty $k "File Extensions" ((Get-ItemProperty $k)."File Extensions" + ";dpps")
```

The IDE then opens a `.dpps` file as Delphi, highlighted, and keeps the setting from then on.

## How the two files fit in the project

- **`Greet.dpps`, the source**, is in the project as a file the IDE doesn't compile (in
  `Hello.dproj`, `<None Include="Greet.dpps"/>`), so it's in the Project Manager, to open from
  there. `Hello.dpr` doesn't use it, so dcc never sees it; the build reads it through the
  pre-build event. (A `.pas` the program doesn't use can't stay like this: the IDE drops it from
  the project when it saves. Hence `.dpps`.)
- **`Greet.pas`, the output**, is what `Hello.dpr` uses: `uses Greet in 'Greet.pas';`. It
  needn't exist before a build, and isn't in the repository: the pre-build event writes it, then
  dcc compiles it. Until the first build the Project Manager shows it as missing.
- **Edit the source, never `Greet.pas`**, and keep `Greet.pas` closed: the IDE compiles an open
  file from its editor, not from disk, and the next build replaces it anyway.

(The source may also be called `Greet.dpps.pas`, which the IDE highlights without the setting
above, but which it won't keep in the project. Either way its header may say `unit Greet;` or
`unit Greet.dpps;`: `Greet.pas` is written with `unit Greet;`.)

## Try it

Needs the starter's `delphipp.exe`, built once with Delphi alone: in `..\..\delphi\`,
`get-treesitter4d.cmd`, then `build.cmd` or, in the IDE, `delphipp.dproj` built for Win64 (its
README). Either puts it in `..\..\delphi\bin\`, where this project's event looks. No Python.
(Or the Python side: see *The setting*.)

1. Open `Hello.dproj` in Delphi 13 and build it (Win32 or Win64). `Greet.pas` appears; the
   program prints `Bonjour, Delphi! Bonjour, Delphi!` and `G'day, Delphi!`.
2. Edit `Greet.dpps`: the next build writes `Greet.pas` again.
3. Give the `case` a range label, `'a'..'c': Hello := 'Hm';`. The build stops before dcc, and the
   Messages pane lists the rule's error on `Greet.dpps`, line and column:

   ```
   Greet.dpps(33,5): error DPPS-case-of: a range label in a case on strings or class types: write it as an if
   ```

   MSBuild adds a line of its own after it, that the command "exited with code 1". `Greet.pas`
   is left as it was.

The same from the command line, in a RAD Studio Command Prompt:

```
msbuild Hello.dproj /p:Platform=Win64
```

## The setting

*Project > Options > Building > Build Events > Pre-build events*, in `Hello.dproj` as
`PreBuildEvent`:

```
"$(MSBuildProjectDirectory)\..\..\delphi\bin\delphipp.exe" --msbuild "$(MSBuildProjectDirectory)\Greet.dpps"
```

The Python side does the same (it did this first), with Python and the grammar as in the main
README's *With Python*:

```
set PYTHONPATH=$(MSBuildProjectDirectory)\..\..\python
python -m delphipp --msbuild "$(MSBuildProjectDirectory)\Greet.dpps"
```

The two give the same messages, the same exit status and the same `Greet.pas`, byte for byte:
checked on `Greet.dpps` as it is, with the range label above, with a UTF-8 BOM, and named
`Greet.dpps.pas`.

- `--msbuild` writes each warning and error as `file(line,col): error DPPS-rule: text`, which
  MSBuild reads, and so the Messages pane lists. A hint stays plain, in the Output pane.
- `Greet.pas` is written only when it changes, so the IDE isn't told a file changed when it
  hasn't.
- **dcc's own messages name `Greet.dpps`, and its lines**, through dcc's `{$LINE N 'file'}`
  (below).
- The event runs from the output folder: hence `$(MSBuildProjectDirectory)` in every path.
- Code insight doesn't run build events: it reads the `Greet.pas` of the last build.

## dcc's messages on the source's lines: `{$LINE}`

A rewrite can change the number of lines (`case-of` here adds two), so `Greet.pas`'s lines
aren't `Greet.dpps`'s. dcc has a directive, `{$LINE N 'file'}`, that the docwiki's list of
directives leaves out (found by trying it, 11 Nov; RemObjects' Elements documents one): the
next line is line N of that file, and the rest of the directive's own line N − 1 (as C's
`#line`). `Greet.pas` is written with one before everything, naming `Greet.dpps` by its full
path, and one after each edit that changes the number of lines; none adds a line:

```pascal
{$LINE 2 'D:\…\examples\ide\Greet.dpps'}unit Greet;
…
  else
    Hello := 'G''day';{$LINE 34}
```

So, with nothing to set up, dcc's errors, warnings and hints name `Greet.dpps` and its line, in
the IDE's Messages pane and in msbuild's output; an `Assert` without a message names the
`.dpps` and its line; and the debug information (the `.map`, the `.rsm`) gives its lines
as `Greet.dpps`'s. Checked with dcc64 and dcc32 37.0 and msbuild: an undeclared identifier
planted on line 35 of `Greet.dpps` comes out as

```
Greet.dpps(35): error E2003: Undeclared identifier: 'Undefined1' [...\Hello.dproj]
```

where it was `Greet.pas(37)`. In the IDE (Delphi 13, 11 Nov 2026), a mistake on line 26 shows
in the Messages pane as `[dcc64 Error] Greet.dpps(26): E2008 Incompatible types`;
double-clicking it opens `Greet.dpps` at that line, and stepping into the unit in the debugger
shows `Greet.dpps`. The [video](https://youtu.be/LJM2JrihDWU) shows it.

- **Inside a rewritten statement the lines are near, not exact**: the `if` chain `case-of`
  writes, with the comment it moves, has nine lines for the `case`'s seven, numbered on from
  the `case`'s, so an error in
  the `'fr'` arm (line 29) is given as line 31. After the statement they are exact again.
- **The name is the file's full path**, as the directive ends it at the first quote: a path
  with a `'` in it is left out, and the messages name `Greet.pas`, on `Greet.dpps`'s lines.
- **In code `{$IFDEF}` leaves out**, a directive after an edit there is left out too (checked:
  dcc skips it): an edit in such a part that changes the number of lines leaves the lines after
  it off by that many, when the part is left out.

## Not yet

- **The IDE only highlights the source, by its words:** Error Insight doesn't check a `.dpps`
  file, so where it uses what only the rules accept (the `case` on strings) nothing is
  underlined, which here is what we want. The rules' own messages come at the build. (As
  `Greet.dpps.pas` it is checked, and the `case` is underlined as Delphi dcc can't compile.)
