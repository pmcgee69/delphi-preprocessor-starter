# The Delphi side

The same engine and rules as `..\python\`, in Delphi, on
[TreeSitter4D](https://github.com/pmcgee69/TreeSitter4D). Nothing but Delphi is needed: no
Python, no C compiler.

```
get-treesitter4d.cmd                 rem once: TreeSitter4D's units and its compiled C
build.cmd                            rem Win64: bin\delphipp.exe, bin\RunTests.exe
build.cmd win32                      rem Win32: bin\win32\
bin\RunTests.exe                     rem the tests, ..\tests\cases, shared with the Python side
bin\delphipp.exe --list              rem the rules
bin\delphipp.exe --tree FILE         rem a file's tree: the kinds of node a rule can ask for
bin\delphipp.exe FOLDER              rem run them: messages
bin\delphipp.exe -o OUT FOLDER       rem and the rewritten files, under OUT
bin\delphipp.exe X.dpps              rem write X.pas beside it, rewritten (X.dpps.pas too)
bin\delphipp.exe --msbuild X.dpps    rem the same, messages as MSBuild reads them: a pre-build event
```

The last is what an IDE project's pre-build event runs (`..\examples\ide\`), so a project needs
no Python.

Or in the IDE: open `delphipp.dproj` and build, Win64 or Win32. It builds into the same
`bin\` and `bin\win32\` as `build.cmd`, with TreeSitter4D's units on its search path
(`get-treesitter4d.cmd` first, as for `build.cmd`). `..\examples\ide\`'s pre-build event runs
`bin\delphipp.exe`, the Win64 build. The project is only `delphipp.dpr` (`RunTests` is still
`build.cmd`'s); the `.res` the IDE writes beside it is unused, as the program has no `{$R}`,
and ignored by git.

`get-treesitter4d.cmd` uses what Windows 10 and later have (git, curl, certutil, tar): it
clones TreeSitter4D at its release tag for `TreeSitter.Api.pas`, downloads the release's
objects, checks their SHA-256, and unzips them where that unit links them with `{$L}`.
Everything lands in `delphi\TreeSitter4D\`, which git ignores.

| File | What |
|---|---|
| `DelphiPP.Engine.pas` | the engine: `Run` (and `RunWithEdits`, the edits too), `TRule`, `TContext`, `TNode`, `TMessage` |
| `DelphiPP.Rule.WithStatement.pas` | the `with` check |
| `DelphiPP.Rule.AssertMessage.pas` | the `assert-message` rewrite |
| `DelphiPP.Rule.WithAndTry.pas` | the `with-try` check: one rule, two Kinds, a procedure for each |
| `DelphiPP.Rule.UsesMerge.pas` | the `uses-merge` rewrite: several `uses` clauses in a section merged into one |
| `DelphiPP.Rule.CaseOf.pas` | the `case-of` rewrite: `case` on strings or class types, as an `if` chain |
| `DelphiPP.Rule.AutoProperty.pas` | the `auto-property` rewrite: a property with no `read` or `write` gains a field and both |
| `DelphiPP.Rule.DoubleQuotes.pas` | the `double-quotes` rewrite, the simplest: each `"` inside a string becomes `''` |
| `DelphiPP.Rule.Footnotes.pas` | the `footnotes` rewrite: footnotes after `end.` become XMLDoc on what they name |
| `DelphiPP.Rule.Derive.pas` | the `derive` rewrite: `[Derive(ToString)]` on an enumeration writes it a `ToString` |
| `DelphiPP.Rules.pas` | the list of rules: add yours here |
| `delphipp.dpr` | the command line |
| `RunTests.dpr` | the tests |
| [`ide\`](ide/) | an IDE package: the rules in the editor, in a `.dpps` file, as you type |

## The two sides agree

A rule written in both languages has to give the same output and the same messages, and the
shared tests check that: `RunTests.exe` reads the expected files the Python side wrote, and passes.
Over Delphi 13's `source\rtl\common` (105 files) the two sides' messages are the same line for
line, and every rewritten file is the same byte for byte, on Win64 and Win32.

A rule can also be Delphi's alone: its tests sit in `tests\cases\` with the others, and the
Python runner skips a folder whose rule it doesn't have, saying so.

## Writing a rule in Delphi

The hand-held walkthrough is
[Building the WITH Rule](https://claude.ai/artifact/BKj5CUoyiY6SmPsJ5ahf4J): this rule, built
step by step, in 15 illustrated pages. Then read `DelphiPP.Rule.WithStatement.pas`: its comment
says how a rule works and how that one was made, step by step. In short:

1. **Write a small sample** with the thing in it.
2. **Look at its tree**, to find the Kind of node your rule is about:
   `bin\delphipp.exe --tree sample.pas`. Each line is a node: its Kind, then a leaf's text or a
   branch's line number.
3. **Write the class**, below: `Kinds` lists that Kind, and `Visit` looks around the node and
   reports, or proposes an edit.
4. **Register it** in `DelphiPP.Rules.pas`: its unit in the uses, its class in `AllRules`. That's
   the only place.
5. **Build, run, test**: `build.cmd`; `bin\delphipp.exe --rules yourname sample.pas`; put the sample
   in `..\tests\cases\yourname\`, run `bin\RunTests.exe --update` to write what the rule does now,
   read it, and keep it.

```pascal
type
  TWithStatement = class(TRule)
  public
    function Name: string; override;                // 'with': chosen with --rules, named in messages
    function Kinds: TArray<string>; override;       // ['with']: the node types it wants
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

procedure TWithStatement.Visit(const Node: TNode; Ctx: TContext);
begin
  Ctx.Report(Node, 'a message');                    // or 'error' / 'hint' as a third argument
  // Ctx.Replace(Node, 'new text');  Ctx.InsertBefore(...);  Ctx.InsertAfter(...)
end;
```

`Node.Kind`, `Node.Child(I)`, `Node.ChildCount`, `Node.Line` and `Ctx.Text(Node)` take you around
the tree, and `--tree` shows what's there. A rule in both languages shares its test folder: either
side's `--update` writes the expected files, and both must pass them.
