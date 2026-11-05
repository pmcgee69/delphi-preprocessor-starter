# The rules in the Delphi IDE: a `.dpps` file and a pre-build event

`Greet.dpps` is Delphi source the rules rewrite before dcc sees it. Before every build, the
project's pre-build event runs them and writes `Greet.pas` beside it; the IDE then builds as
usual. No IDE package, nothing installed: a project setting.

Here two rules make a unit dcc would refuse into one it compiles:

| In `Greet.dpps` | In `Greet.pas`, written from it |
|---|---|
| `case G.Lang of 'en': … 'fr': …` (a `case` on strings) | an `if` chain (`case-of`) |
| `Assert(G.Times > 0)` | `Assert(G.Times > 0, 'Greet.dpps:24: G.Times > 0')` (`assert-message`) |

## Try it

Needs Python and the grammar, as in the main README's *With Python* (`get-grammar.py` once).

1. Open `Hello.dproj` in Delphi 13 and build it (Win32 or Win64). `Greet.pas` appears; the
   program prints `Bonjour, Delphi! Bonjour, Delphi!` and `G'day, Delphi!`.
2. Edit `Greet.dpps`, not `Greet.pas`: the next build writes `Greet.pas` again.
3. Give the `case` a range label, `'a'..'c': Hello := 'Hm';`. The build stops before dcc, and the
   Messages pane lists the rule's error on `Greet.dpps`, line and column:

   ```
   Greet.dpps(30,5): error DPPS-case-of: a range label in a case on strings or class types: write it as an if
   ```

   MSBuild adds a line of its own after it, that the command "exited with code 1".

The same from the command line, in a RAD Studio Command Prompt:

```
msbuild Hello.dproj /p:Platform=Win64
```

## The setting

*Project > Options > Building > Build Events > Pre-build events*, in `Hello.dproj` as
`PreBuildEvent`:

```
set PYTHONPATH=$(MSBuildProjectDirectory)\..\..\python
python -m delphipp --msbuild "$(MSBuildProjectDirectory)\Greet.dpps"
```

- `--msbuild` writes each warning and error as `file(line,col): error DPPS-rule: text`, which
  MSBuild reads, and so the Messages pane lists. A hint stays plain, in the Output pane.
- `Greet.pas` is written only when it changes, so the IDE isn't told a file changed when it
  hasn't.
- The event runs from the output folder: hence `$(MSBuildProjectDirectory)` in every path.
- Code insight doesn't run build events: it reads the `Greet.pas` of the last build.

## Not yet

- **dcc's own messages name `Greet.pas`**, and its lines: where a rewrite adds lines
  (`case-of` here adds two), they are that many below the `.dpps` line. Mapping them back to the
  `.dpps` is next.
- **No highlighting for `.dpps`** in the IDE's editor; it opens as plain text. Opening it as Delphi
  (*Tools > Options > Editor > Language*, adding the extension) is untested.
- **The Delphi engine** (`bin\delphipp.exe`) instead of Python: the same line, once it has
  `--msbuild` and `.dpps`.
