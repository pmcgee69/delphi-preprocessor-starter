# Exploring the rules in Zed

**No experience of Zed, Python or Rust needed.** This takes about 15 minutes, most of it downloads.
At the end you'll have Delphi code highlighted, messages from the rules appearing as you type, and a
program that Delphi can't compile on its own compiling and running. The same steps, with tick-boxes
and copy buttons: [DelphiPP in Zed](https://claude.ai/artifact/5gpt4nd8AD5bbmQ6mCafyW).

[Zed](https://zed.dev) is a free code editor. It doesn't replace the Delphi IDE, and it doesn't touch
your projects: you're only opening this folder of examples in it.

**The rules are here twice:** in Python (`python\`) and in Delphi (`delphi\`), the same rules giving
the same results, checked against the same tests. Zed runs the **Python** ones as you type, which is
why this guide installs Python. The Delphi ones are for using the rules from Delphi, or reading them
in Delphi: see "Where next" at the end.

This is for Windows. Commands below go in a **Command Prompt**: press the Windows key, type `cmd`,
press Enter.

## 1. Install three things

**Zed.** 

Download it from [zed.dev/download](https://zed.dev/download) and run the installer.

**Python.** 

Download it from [python.org/downloads](https://www.python.org/downloads/) and run the
installer. On its first screen, **tick "Add python.exe to PATH"** before you click Install. It's easy
to miss, and nothing below works without it.

**Rust.** 

Zed uses it to build the small extension in this folder - you won't need to write any. 
Download `rustup-init.exe` from [rustup.rs](https://rustup.rs) and run it. 
A black window asks questions: press Enter to accept the defaults. 
If it offers to install Visual Studio build tools, say yes.

To check they worked, open a **new** Command Prompt (an old one won't see them) and run:

```
python --version
rustup --version
```

Each should print a version number.

## 2. Get this project

**The easy way:** 

On the [project's page](https://github.com/pmcgee69/delphi-preprocessor-starter), click the green **Code** button, then **Download ZIP**. 
Unzip it somewhere with a short path, such as `C:\delphipp`, so that the folder holds `README.md` directly.

**Or with git:** 

`git clone https://github.com/pmcgee69/delphi-preprocessor-starter C:\delphipp`

Then, in your Command Prompt:

```
cd /d C:\delphipp
pip install -r python\requirements.txt
python tools\get-grammar.py
python tools\check-setup.py
```

The last command checks everything and tells you how to fix whatever is missing. 
When it says `All set`, carry on. It's fine if only `dcc64` and `dcc32` are missing: see "Compiling" below.

## 3. Open it in Zed

1. Start Zed. Choose **File, Open Folder** (the command may just be **Open** on the File menu), and
   pick `C:\delphipp`. Open that top folder, not a folder inside it.
2. Press **Ctrl+Shift+P**. This opens the *command palette*, a search box for everything Zed can do,
   and the one thing worth remembering. Type `install dev extension`, and select
   **zed: install dev extension**. 
From here on, "run **some: command**" means exactly this:    Ctrl+Shift+P, type its name, Enter.
3. Pick the `zed` folder inside `C:\delphipp`.

The first time, this takes a few minutes ... there is a progress message at the very bottom of the window: 
Zed is downloading a compiler and building the extension.

## 4. Take the tour

In the list of files on the left, open `tests`, then `tour`, then **Tour.dpr**. It's one program with
something for every example rule. You should see it in colour, with some code underlined.

**See what the rules say.** Hover the mouse over underlined code. Each rule says what it would write
instead. A `case` that case-of rewrites is underlined as a whole, and its hover is the whole `if`
chain, though the rewrite is an edit an arm (so each line keeps its number). To see them all in one list, open the command palette and run **diagnostics: deploy**.

(The checks, `with` and `with-try`, which report a problem rather than rewrite, are switched
off: add them back to `ALL` in `python\delphipp\rules\__init__.py` to see their warnings.) 

**Apply a rule.** Click on any line of the file, so the cursor is in it, and press **Ctrl+.** (Ctrl
and the full stop) for the *code actions*. Ctrl+. does nothing while the list of files on the left
has the focus; click in the file first, or right-click on a line and choose **Show Code Actions**. 
Choose **Apply case-of to this file**, and watch the `case` on
strings become `if`s. It rewrites the file you have open, in place, not a copy. 
Press **Ctrl+Z** to undo. Nothing changes until you choose it, and nothing is saved until you save.

**Compile it.** Press **Ctrl+Shift+P**, type `task spawn`, and select **task: spawn**. 
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
- **Read a rule.** They're short, in `python\delphipp\rules`: `double_quotes.py` is the smallest,
  `case_of.py` the fullest. [Building the QUOTES Rule](https://claude.ai/artifact/FKem1w4m1shY9nVNexdJvh)
  walks through writing one in Python, the side Zed runs; [Building the WITH Rule](https://claude.ai/artifact/BKj5CUoyiY6SmPsJ5ahf4J)
  does the same in Delphi.
- **Write your own**, as the main [README](../README.md#writing-a-rule) describes. After changing a
  rule, run **editor: restart language server** from the command palette to see the new behaviour.

The rules also exist in Delphi, in `delphi\`, doing the same thing. Those files are highlighted here,
and the task **Rules, the Delphi side: build and run its tests** runs them, after
`delphi\get-treesitter4d.cmd` once. What you see as you type comes from the Python ones.

## Compiling

The compile tasks need `dcc64`, Delphi's command-line compiler (`dcc32` for the Win32 task). It comes
with RAD Studio, and `tools\check-setup.py` tells you whether it can be found. As far as we know,
Delphi's free Community Edition doesn't include it. Without it you still get the highlighting, the
rules' messages and applying them, and only the compile tasks fail.

## If something goes wrong

| What you see | What to do |
|---|---|
| `'python' is not recognized` | Python wasn't added to PATH. Run its installer again, choose **Modify**, then **Add Python to environment variables**. Open a new Command Prompt |
| Python opens the Microsoft Store | Same cure: install from python.org, with the PATH box ticked |
| No colours, or plain text | Check the status bar at the bottom right says **Delphi**. If it says Pascal, click it and choose Delphi. Make sure you opened the top folder |
| Colours, but no underlines or messages | Run `python tools\check-setup.py`. Then, in Zed, run **zed: open log** from the command palette and look for `delphipp` |
| Installing the extension fails | Check `rustup --version` works in a new Command Prompt, close Zed completely, and try again. Run **zed: open log** for the reason. If it mentions `wasm32-wasip2`, run `rustup target add wasm32-wasip2` |
| A task says `dcc64` isn't recognized | See "Compiling" above. RAD Studio's `bin` and `bin64` folders must be on your PATH: restart Zed after adding them |
| A message about the grammar | Run `python tools\get-grammar.py`, then **editor: restart language server** |

## What it doesn't do

- **No completion, hover help or go-to-definition.** Delphi's own compiler isn't behind this: only the
  rules. It's for exploring and writing rules, not a replacement for the IDE.
- **One file at a time** when compiling, with no `.dproj`. Units it uses must be beside it.
- **Tasks and messages use the Python rules.** See "Where next" for the Delphi ones.
