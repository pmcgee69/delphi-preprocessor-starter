# Exploring the rules in Zed

**No experience of Zed needed, and no Python or Rust for the extension.** This takes about 15
minutes, most of it downloads.
At the end you'll have Delphi code highlighted, messages from the rules appearing as you type, and a
program that Delphi can't compile on its own compiling and running. The same steps, with tick-boxes
and copy buttons: [DelphiPP in Zed](https://claude.ai/artifact/5gpt4nd8AD5bbmQ6mCafyW).

[Zed](https://zed.dev) is a free code editor. It doesn't replace the Delphi IDE, and it doesn't touch
your projects: you're only opening this folder of examples in it.

**The rules are here twice:** in Python (`python\`) and in Delphi (`delphi\`), the same rules giving
the same results, checked against the same tests. Zed runs the **Delphi** ones as you type:
`delphi\bin\delphipp.exe --lsp`, built by `delphi\build.cmd`. The extension's small piece of Rust
comes already built, as `zed\extension.wasm`, so Rust isn't needed either. Python is only for the
compile tasks in step 4 and the Python rules (and Zed can run those as you type instead: see
"Using the Python rules in Zed" at the end).

This is for Windows. Commands below go in a **Command Prompt**: press the Windows key, type `cmd`,
press Enter.

## 1. Install what's needed

**Zed.** 

Download it from [zed.dev/download](https://zed.dev/download) and run the installer.

**Git.** Zed uses it to fetch the Delphi grammar for highlighting, and `delphi\get-treesitter4d.cmd`
uses it too. From [git-scm.com](https://git-scm.com/download/win), with the installer's defaults.

**Delphi's command-line compiler**, `dcc64`, which comes with RAD Studio, to build `delphipp.exe`
(see "Compiling" below).

**Python, only for the compile tasks.** Download it from
[python.org/downloads](https://www.python.org/downloads/) and run the installer. On its first
screen, **tick "Add python.exe to PATH"** before you click Install.

To check, open a **new** Command Prompt (an old one won't see them) and run:

```
git --version
where dcc64
python --version
```

Each should print something other than an error (the last only if you installed Python).

## 2. Get this project

**The easy way:** 

On the [project's page](https://github.com/pmcgee69/delphi-preprocessor-starter), click the green **Code** button, then **Download ZIP**. 
Unzip it somewhere with a short path, such as `C:\delphipp`, so that the folder holds `README.md` directly.

**Or with git:** 

`git clone https://github.com/pmcgee69/delphi-preprocessor-starter C:\delphipp`

Then, in your Command Prompt, build the language server, `delphi\bin\delphipp.exe`:

```
cd /d C:\delphipp\delphi
get-treesitter4d.cmd
build.cmd
```

It should end with `built: bin\delphipp.exe, bin\RunTests.exe`. Only if you installed Python, for
the compile tasks:

```
cd /d C:\delphipp
pip install -r python\requirements.txt
python tools\get-grammar.py
python tools\check-setup.py
```

The last command checks the Python side and tells you how to fix whatever is missing.

## 3. Open it in Zed

1. Start Zed. Choose **File, Open Folder** (the command may just be **Open** on the File menu), and
   pick `C:\delphipp`. Open that top folder, not a folder inside it.
2. Press **Ctrl+Shift+P**. This opens the *command palette*, a search box for everything Zed can do,
   and the one thing worth remembering. Type `install dev extension`, and select
   **zed: install dev extension**. 
From here on, "run **some: command**" means exactly this:    Ctrl+Shift+P, type its name, Enter.
3. Pick the `zed` folder inside `C:\delphipp`.

The first time, this takes a few minutes ... there is a progress message at the very bottom of the window: 
Zed is fetching the Delphi grammar and downloading a C compiler of its own to build it. Nothing of
Rust is built: the extension's code is `zed\extension.wasm`, already built.

## 4. Take the tour

In the list of files on the left, open `tests`, then `tour`, then **Tour.dpr**. It's one program with
something for every example rule. You should see it in colour, with some code underlined.

**See what the rules say.** Hover the mouse over underlined code. Each rule says what it would write
instead. A `case` that case-of rewrites is underlined as a whole, and its hover is the whole `if`
chain, though the rewrite is an edit an arm (so each line keeps its number). To see them all in one list, open the command palette and run **diagnostics: deploy**.

(The two checks, `with` and `with-try`, are written but switched off, so Zed doesn't show them.)

**Apply a rule.** Click on any line of the file, so the cursor is in it, and press **Ctrl+.** (Ctrl
and the full stop) for the *code actions*. Ctrl+. does nothing while the list of files on the left
has the focus; click in the file first, or right-click on a line and choose **Show Code Actions**. 
Choose **Apply case-of to this file**, and watch the `case` on
strings become `if`s. It rewrites the file you have open, in place, not a copy. 
Press **Ctrl+Z** to undo. Nothing changes until you choose it, and nothing is saved until you save.

**Compile it** (this needs Python). Press **Ctrl+Shift+P**, type `task spawn`, and select **task: spawn**. 
A second list opens, of the tasks this folder defines: choose **Rules: compile and run this file**. 
A terminal opens at the bottom. Delphi can't compile `Tour.dpr` as written: it has
no `case` on strings and no property without `read` or `write`. 
The rules rewrite a copy in a temporary folder, and that compiles and runs:

```
Ada: a greeting, a farewell, something else
strings
and 'quoted'
```

Your `Tour.dpr` isn't changed. **Rules: show what they change in this file** shows the rewrite.

**Break something.** Just after `begin` is a line `// Oops;`. 
Delete its `//`, save with **Ctrl+S**, and compile again. 
The error names the line in *your* file, line 44, though the compiler saw the rewritten copy. 
Put the `//` back afterwards.

## 5. Where next

- **The other examples** are in `tests\cases`, a folder per rule. Each has an input (`basic.pas`) and
  the expected output (`basic.out.pas`).
- **Read a rule.** They're short, in `delphi\` (`DelphiPP.Rule.*.pas`) and `python\delphipp\rules`:
  double-quotes is the smallest, case-of the fullest. [Building the QUOTES Rule](https://claude.ai/artifact/FKem1w4m1shY9nVNexdJvh)
  walks through writing one in Python; [Building the WITH Rule](https://claude.ai/artifact/BKj5CUoyiY6SmPsJ5ahf4J)
  does the same in Delphi.
- **Write your own**, as the main [README](../README.md#writing-a-rule) describes: register it in
  `delphi\DelphiPP.Rules.pas`, run `delphi\build.cmd`, then **editor: restart language server** from
  the command palette to see it. (`build.cmd` can't replace `delphipp.exe` while Zed is running it:
  restart the language server after building, or build with Zed closed, if it says the file is in
  use.) The task **Rules, the Delphi side: build and run its tests** builds and tests them.

## Which delphipp.exe Zed runs

1. The one named in Zed's settings, if any (below).
2. In this folder, or a copy of it (a folder with `delphi\delphipp.dpr`): its own
   `delphi\bin\delphipp.exe`, so the rules you add are the ones you see.
3. `delphipp.exe` on the PATH, for any other folder: put `C:\delphipp\delphi\bin` on your PATH
   and every Delphi file you open in Zed gets the rules.

To name one, run **zed: open settings** and add:

```json
"lsp": { "delphipp": { "binary": { "path": "C:\\delphipp\\delphi\\bin\\delphipp.exe" } } }
```

## Using the Python rules in Zed

The same setting runs any server, the Python one too (with Python and `python\requirements.txt`
installed), for writing rules in Python without building anything:

```json
"lsp": { "delphipp": { "binary": {
  "path": "python",
  "arguments": ["-m", "delphipp.lsp"],
  "env": { "PYTHONPATH": "C:\\delphipp\\python" }
} } }
```

## Compiling

`dcc64`, Delphi's command-line compiler, builds `delphipp.exe`, and the compile tasks use it too
(`dcc32` for the Win32 task). It comes with RAD Studio. As far as we know, Delphi's free Community
Edition doesn't include it: build `delphipp.exe` in the IDE instead, by opening
`delphi\delphipp.dproj` and building it for Win64 (it builds into the same `delphi\bin\`), or use
the Python rules in Zed (above). Without either you still get the highlighting.

## If something goes wrong

| What you see | What to do |
|---|---|
| `'python' is not recognized` | Python wasn't added to PATH. Run its installer again, choose **Modify**, then **Add Python to environment variables**. Open a new Command Prompt |
| Python opens the Microsoft Store | Same cure: install from python.org, with the PATH box ticked |
| No colours, or plain text | Check the status bar at the bottom right says **Delphi**. If it says Pascal, click it and choose Delphi. Make sure you opened the top folder |
| Colours, but no underlines or messages | Check `delphi\bin\delphipp.exe` exists (step 2). Then, in Zed, run **zed: open log** from the command palette and look for `delphipp` |
| Installing the extension fails | Check `git --version` works in a new Command Prompt, close Zed completely, and try again. Run **zed: open log** for the reason |
| `build.cmd` can't write `delphipp.exe` | Zed is running it: run **editor: restart language server** just after building, or close Zed and build again |
| A task says `dcc64` isn't recognized | See "Compiling" above. RAD Studio's `bin` and `bin64` folders must be on your PATH: restart Zed after adding them |
| A message about the grammar, from a task | Run `python tools\get-grammar.py` |

## What it doesn't do

- **No completion, hover help or go-to-definition.** Delphi's own compiler isn't behind this: only the
  rules. It's for exploring and writing rules, not a replacement for the IDE.
- **One file at a time** when compiling, with no `.dproj`. Units it uses must be beside it.
- **The compile tasks need Python** (they use the Python rules). What you see as you type uses
  the Delphi ones.

## Changing the extension's code

`zed\extension.wasm` is built from `zed\rust\src\lib.rs`, which only says which program Zed
starts. To change it you need Rust ([rustup.rs](https://rustup.rs)): run `zed\rust\build.cmd`,
which writes a new `extension.wasm`. Installing the extension never builds it: Zed builds Rust
only when it finds a `Cargo.toml` beside `extension.toml`, and there isn't one.
