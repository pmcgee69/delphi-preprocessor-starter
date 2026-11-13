# delphi-preprocessor-starter

A starting point for your own preprocessor and rules on **standard Delphi**: checks that
report, and rewrites that change the source, with Delphi parsed by
[tree-sitter](https://tree-sitter.github.io/). Write a rule in a few lines, test it against
expected output, then run it over a whole codebase to see what it does before trusting it.

In **Python** ([`python\`](python/)) and in **Delphi** ([`delphi\`](delphi/), on
[TreeSitter4D](https://github.com/pmcgee69/TreeSitter4D)): the same engine and rules, checked
against the same tests in [`tests\cases\`](tests/cases/). Over Delphi 13's `source\rtl\common`
the two give the same messages, line for line, and the same files, byte for byte. Use either,
or both.

## Try it in Zed

**The rules run in [Zed](https://zed.dev), a free editor, as you type.** Open a Delphi file and it
is highlighted; the rules underline what they would change, hovering shows the new text, Ctrl+.
applies it, and a task compiles and runs the result with dcc64. No experience of Zed needed, and
neither Python nor Rust for the extension: about fifteen minutes, mostly downloads.

| To | Go to |
|---|---|
| Set it up, step by step, from nothing | [`zed\README.md`](zed/README.md), the guide |
| Follow along with tick-boxes and copy buttons | [DelphiPP in Zed](https://claude.ai/artifact/5gpt4nd8AD5bbmQ6mCafyW), the same guide as one page |
| Write a rule and see it in Zed | [Building the QUOTES Rule](https://claude.ai/artifact/FKem1w4m1shY9nVNexdJvh), the Python walkthrough |

Zed runs the Delphi rules as you type (`delphipp.exe --lsp`), or the Python ones if you choose; the
compile tasks use the Python ones.

## In the Delphi IDE

**A `.dpps` file is Delphi source the rules rewrite before dcc sees it.** A pre-build event
writes the `.pas` the program uses from it (`X.dpps` gives `X.pas`); the IDE builds as usual,
and a rule's errors and warnings are in the Messages pane, on the source's line. No package to
install: a project setting, and one editor setting so the IDE highlights `.dpps` as Delphi.
[`examples\ide\`](examples/ide/) is a project to open and build, with a `case` on strings that
the rules make into Delphi dcc accepts. dcc's own errors name the `.dpps` and its lines too
(the generated `.pas` carries dcc's `{$LINE N 'file'}`), so a double-click opens the source
and the debugger steps through it: [the video](https://youtu.be/LJM2JrihDWU). Its footnotes
after `end.` become XMLDoc, so Help Insight on `Greeting` shows the summary, the parameter and
the result written there ([the screenshot](examples/ide/footnotes-help-insight.png)). And an
enum marked `[Derive(ToString)]` gets a `ToString`, whose lines name the attribute's. The
footnotes and derive in the IDE: [the second video](https://youtu.be/-hhXFSDIgsY).

## New to it? 
Start with the hand-held walkthrough:
[Building the WITH Rule](https://claude.ai/artifact/BKj5CUoyiY6SmPsJ5ahf4J), an illustrated
owner's manual in 15 pages. It builds the Delphi `with` rule step by step, from a sample file and
its tree - to a tested rule, then runs it over Delphi's own RTL, and finally shows a rule for two kinds
of nodes.

On the Python side:
[Building the QUOTES Rule](https://claude.ai/artifact/FKem1w4m1shY9nVNexdJvh), its sibling in 14
pages, builds the simplest rewrite there is, `double-quotes`, from a sample and its tree to a tested
rule, then shows it in Zed, and what it does to Delphi's own RTL.

## The promise

**A file no rule changes comes out byte for byte as it went in.** Rules don't edit text: they
propose replacements of byte ranges, and the engine applies them all at once, refusing two
that overlap. So a rule touches what it means to and nothing else, and its output differs from
its input only where it says so. `tools\survey.py --pass-through` checks the promise over any
folder.

## Getting started

**With Delphi alone** (Delphi 13; Win64 or Win32):

```
cd delphi
get-treesitter4d.cmd                 rem once: TreeSitter4D's units and its compiled C
build.cmd                            rem bin\delphipp.exe and bin\RunTests.exe
bin\RunTests.exe                     rem the tests
bin\delphipp.exe --list              rem the rules
bin\delphipp.exe ..\tests\cases\with rem run them over a file or folder
```

Or build `delphipp.exe` in the IDE: after `get-treesitter4d.cmd`, open `delphi\delphipp.dproj`
and build it. It writes to the same `bin\` as `build.cmd`. More in [`delphi\README.md`](delphi/README.md).

**With Python** 3.10 or later (64-bit or 32-bit), on Windows:

```
pip install -r python\requirements.txt
python tools\get-grammar.py             rem the Delphi grammar, compiled, from a TreeSitter4D release
cd python
python -m delphipp --list                               rem the rules
python -m delphipp ..\tests\cases\case-of\errors.pas    rem run them over a file or folder: messages
python -m delphipp -o ..\out ..\tests\cases\assert-message\basic.pas
                                                        rem and the rewritten files, under out\
```

`get-grammar.py` downloads the DLLs of a [TreeSitter4D release](https://github.com/pmcgee69/TreeSitter4D/releases),
checks its SHA-256, and puts them in `build\`. No C compiler is needed: py-tree-sitter loads
the grammar's DLL directly.

**In [Zed](https://zed.dev):** see [Try it in Zed](#try-it-in-zed) above.

## The example rules

The two checks, `with` and `with-try`, are written but switched off: they are left out of `ALL` in
`python\delphipp\rules\__init__.py`, the list of the rules that run, and out of `AllRules` in
`delphi\DelphiPP.Rules.pas`. Add them back to have them run.

- **`with`** (`python\delphipp\rules\with_statement.py`), a check: every `with` statement,
  reported with its objects, since each name inside it could belong to any of them.
- **`assert-message`** (`python\delphipp\rules\assert_message.py`), a rewrite:
  `Assert(Count > 0)` becomes `Assert(Count > 0, 'Orders.pas:41: Count > 0')`, so a failed
  assertion says where and what. In a `.dpps` source it gains the condition alone,
  `Assert(Count > 0, 'Count > 0')`: the `.pas` written from it carries `{$LINE}`, so Delphi's
  own text already names the `.dpps` and its line. One with a message already, and a method
  that happens to be called `Assert`, are left alone.
- **`with-try`** (`python\delphipp\rules\with_and_try.py`), a check of two kinds of nodes:
  how one rule handles more than one. `Visit` asks the node's kind and hands it on to a
  procedure for each: `with`, as above, and `try`, where an empty `except` (which swallows
  every exception) or an empty `finally` is reported. 
- **`uses-merge`** (`python\delphipp\rules\uses_merge.py`), a rewrite: lets a
  section have several `uses` clauses, which Delphi doesn't, and merges them into one, so
  each need can have its own clause and comment. The standard grammar already parses them;
  no new syntax is needed:

  ```pascal
  uses System.SysUtils, System.Classes;        uses System.SysUtils, System.Classes,
  uses System.Types;                     ->      System.Types;
  ```

  Clauses with a compiler directive between them are left alone, since they may be
  alternatives (one per platform), as in Delphi's own RTL.
- **`case-of`** (`python\delphipp\rules\case_of.py`), a rewrite: `case` on strings, and on
  class types, written as the `if` chain Delphi compiles. A case on a `Char`, or any other
  ordinal, is left alone. Every line stays where it was, so dcc's messages and the debugger
  name each arm's own line:

  ```pascal
  case s of                      begin
    'hello', 'hi' : x := 1;        if (s = 'hello') or (s = 'hi') then x := 1
    sWorld        : x := 3;  ->    else if s = sWorld then x := 3
  else                           else
    x := 0;                        x := 0;
  end;                           end;

  case x.ClassType of            begin
    TStringList : k := 1;    ->    if x.ClassType = TStringList then k := 1
    TList       : k := 2;          else if x.ClassType = TList then k := 2
  end;                           end;
  ```
  An arm whose statement is an `if` with no `else` is put in `begin … end`, so the next arm's
  `else` isn't taken by it.

- **`auto-property`** (`python\delphipp\rules\auto_property.py`), a rewrite: a property with
  no field and no `read` or `write` gains all three:

  ```pascal
  TPerson = class                        TPerson = class
  public                                 private
    property Name: string;      ->         FName: string;
  end;                                   public
                                           property Name: string read FName write FName;
                                         end;
  ```
- **`double-quotes`** (`python\delphipp\rules\double_quotes.py`), a rewrite, the simplest
  there is, to learn from rather than to use: each `"` inside a string becomes `''`, so
  `'say "hi"'` becomes `'say ''hi'''`. One kind of node, and its whole text replaced.
- **`footnotes`** (`python\delphipp\rules\footnotes.py`), a rewrite: footnotes after `end.`
  become XMLDoc on what they name, for Help Insight, and leave the `.pas`. A footnote names a
  routine, a type or a member (`[TPerson.Greet]`); an indented `Name:` line describes a
  parameter, `Result:` a function's result:

  ```pascal
  function Greeting(const Name: string): string;     /// <summary>Says hello.</summary>
  ...                                                 /// <param name="Name">who to greet.</param>
  end.                                       ->       function Greeting(const Name: string): string;
                                                      ...
  [Greeting] Says hello.                              end.
    Name: who to greet.
  ```

  A description can run over several lines; a line indented deeper than its `Name:` line
  always goes on with it, a colon in it or not. A name declared nowhere or overloaded, a
  parameter the routine doesn't have, or XMLDoc already there is an error. Text after `end.` that doesn't start with a footnote is left alone.
  The Delphi editor highlights that text as code, so a lone `'` starts a string to the end of
  the line: write `''`, as in a string (`G''day`), and the XMLDoc has `'`.
- **`derive`** (`python\delphipp\rules\derive.py`), a rewrite: `[Derive(ToString)]` on an
  enumeration writes it a `ToString`, as a record helper, with the names qualified so
  `{$SCOPEDENUMS ON}` changes nothing:

  ```pascal
  type                                    type
    [Derive(ToString)]                      TSize = (Small, Large);
    TSize = (Small, Large);       ->        TSizeHelper = record helper for TSize
                                              function ToString: string;
                                            end;
                                          ...
                                          function TSizeHelper.ToString: string;
                                          begin
                                            case Self of
                                              TSize.Small: Result := 'Small';
                                              TSize.Large: Result := 'Large';
                                            else
                                              Result := '';
                                            end;
                                          end;
  ```

  An attribute is Delphi already, so the grammar parses it. A helper of the type's own would
  hide this one (a type has one in scope at a time). `ToString` is the only one so far.

`uses-merge`, `case-of` and `auto-property` come from Vincent Parrett's
[*Delphi language enhancements*](https://www.finalbuilder.com/resources/blogs/delphi-language-enhancements)
(2016): features Delphi lacks whose syntax the standard grammar already parses, so a rewrite
can supply them.

Over Delphi 13's `source\rtl\common` (105 files, the grammar can't parse 8):

```
python tools\survey.py "...\source\rtl\common" --pass-through
105 files; the grammar can't parse 8
pass-through: 105 of 105 byte for byte the same

python tools\survey.py "...\source\rtl\common"
105 files; the grammar can't parse 8
files changed: 15
      62 messages from with-try
      55 messages from with
```

## Writing a rule

A rule is a small class:

```python
class WithStatement:
    name = 'with'                  # chosen with --rules with; named in its messages
    kinds = ('with',)              # the node types it wants to see

    def visit(self, node, ctx):    # called for each, in source order
        ctx.report(node, 'a message')               # or 'error' / 'hint' as level=
        # ctx.replace(node, 'new text')
        # ctx.insert_before(node, '…') / ctx.insert_after(node, '…')
```

1. **Find the node types.** Print a sample's tree, a node a line; the grammar's names are what
   `kinds` lists and what `node.type` returns:

   ```
   cd python
   python -m delphipp --tree ..\tests\cases\double-quotes\basic.pas
   ```

   It prints what `delphi\bin\delphipp.exe --tree` prints, line for line.

   `node.child_by_field_name('entity')`, `node.named_children`, `ctx.text(node)` and
   `ctx.line(node)` take you around it.
2. **Write the rule** in `python\delphipp\rules\`, and add it to `ALL` in `rules\__init__.py`.
3. **Test it.** Put inputs in `tests\cases\<rule name>\`, run
   `python python\tests\run.py --update` to write what the rule does now (`.out.pas` when it
   changes the file, `.diag` for its messages, `.edits` for the ranges it replaces, which is
   what an editor shows), read them, and keep them. From then on
   `python python\tests\run.py` checks the rule still does exactly that.
4. **Run it over real code** with `tools\survey.py`, and read what it changed before you let it
   change anything that matters. A rewrite should compile: try the output with dcc64.

## What the grammar can't parse

tree-sitter's Delphi grammar reads nearly all real Delphi, but not all: a file it can't parse
gets an error message from `parser`, and the rules still run on the parts it can. Conditional
compilation is read as written, all branches at once, so a file whose `{$IFDEF}` branches only
make sense one at a time can fail to parse.

## Where this comes from

It is the core of [delfc](https://github.com/pmcgee69/DelfPascal), the transpiler from Delf
(Delphi with a stricter type system) to plain Delphi: the same promise, that a file with nothing
to rewrite comes out unchanged, checked over tens of thousands of files of real Delphi.

## Licence

MIT. The grammar ([tree-sitter-delphi13](https://github.com/Alexl-git/tree-sitter-delphi13)) and
tree-sitter are MIT too; `get-grammar.py` puts their licences in `build\licenses\`.
