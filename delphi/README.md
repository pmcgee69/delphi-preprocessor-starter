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
bin\delphipp.exe FOLDER              rem run them: messages
bin\delphipp.exe -o OUT FOLDER       rem and the rewritten files, under OUT
```

`get-treesitter4d.cmd` uses what Windows 10 and later have (git, curl, certutil, tar): it
clones TreeSitter4D at its release tag for `TreeSitter.Api.pas`, downloads the release's
objects, checks their SHA-256, and unzips them where that unit links them with `{$L}`.
Everything lands in `delphi\TreeSitter4D\`, which git ignores.

| File | What |
|---|---|
| `DelphiPP.Engine.pas` | the engine: `Run`, `TRule`, `TContext`, `TNode`, `TMessage` |
| `DelphiPP.Rule.WithStatement.pas` | the `with` check |
| `DelphiPP.Rule.AssertMessage.pas` | the `assert-message` rewrite |
| `DelphiPP.Rules.pas` | the list of rules: add yours here |
| `delphipp.dpr` | the command line |
| `RunTests.dpr` | the tests |

## The two sides agree

A rule written in both languages has to give the same output and the same messages, and the
shared tests check that: `RunTests.exe` reads the expected files the Python side wrote, and passes.
Over Delphi 13's `source\rtl\common` (105 files) the two sides' messages are the same line for
line, and every rewritten file is the same byte for byte, on Win64 and Win32.

## Writing a rule in Delphi

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

`Node.Kind`, `Node.Child(I)`, `Node.ChildCount`, `Node.Field('args')` and `Ctx.Text(Node)` take
you around the tree; the node types are the grammar's, as the main README shows how to print.
Add the rule's unit to `DelphiPP.Rules.pas` and to the two `.dpr` files' uses, give it a test
folder in `..\tests\cases\<name>\`, and `RunTests.exe --update` writes its expected files (or the
Python side's `run.py --update`, when it has the rule too).
