# Exploring the rules in Zed

[Zed](https://zed.dev) reads Delphi with the same grammar the rules use. This folder is an
extension that gives you highlighting from that grammar, and a language server that runs the
rules in `python\` as you type: what a rule reports appears on the code, what a rule would rewrite
appears with its new text, and a code action applies it.

## Setting it up

You need [Rust installed through rustup](https://rustup.rs): Zed compiles a dev extension itself.
And the Python side set up, as in the main README:

```
pip install -r python\requirements.txt
python tools\get-grammar.py
```

Then, in Zed:

1. Open this repository's folder (`File`, `Open Folder`). The server runs the rules from its
   `python\` folder, so yours are the ones you see.
2. Open the command palette (`Ctrl+Shift+P`), run `zed: install dev extension`, and choose this
   `zed\` folder. The first install downloads a compiler and the grammar, and takes a minute or so.

## A tour

Open [`tests\tour\Tour.dpr`](../tests/tour/Tour.dpr), a program with something for every rule.

- **Read what the rules say.** Each marked line has a message, on the line or in the diagnostics
  panel (`Ctrl+Shift+M`): `with` and `with-try` report; the others say what they would write.
- **Apply one.** Put the cursor anywhere in the file and open the code actions (`Ctrl+.`), to apply
  one rule to the file, or all of them. `Ctrl+Z` undoes it.
- **Compile it.** Open the tasks (`Alt+Shift+T`) and run **Rules: compile and run this file**. The
  rules are applied to a copy in a temporary folder and dcc64 compiles that, so a program Delphi
  couldn't compile as written runs. Errors are given on your file's lines. Needs `dcc64` on the path.
- **See the change.** The task **Rules: show what they change in this file** prints a diff.

Then try the cases in [`tests\cases\`](../tests/cases/), and write your own rule as the main README
describes. Save it, add it to `ALL`, and run `editor: restart language server` to see it on your
code. If a rule fails, the server keeps going, and the reason is in `zed: open log`.

## What it doesn't do

- The language server is the Python side's: it runs the Python rules. The Delphi rules are
  highlighted and have a task for their tests, but aren't what you see as you type.
- No completion, hover or go-to-definition: Delphi's own compiler isn't behind it. The rules only.
- Win64 only, with `dcc64`, and one file at a time: no `.dproj`, and a unit's own uses must be found
  beside it.
- A `.dpr` is run by the task; a unit is only compiled.
