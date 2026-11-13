// Zed starts a language server only through an extension's code: this is that code, and all it
// does is say which program to start. It is built once into ..\extension.wasm, which is in the
// repo, so installing the extension needs no Rust (build.cmd, for whoever changes this file).
//
// The server is delphipp.exe --lsp, the Delphi side's: no Python either. Which delphipp.exe:
//   1. the one Zed's settings name, "lsp": { "delphipp": { "binary": { "path": ... } } },
//      with its own "arguments" (default --lsp) and "env": any server, the Python one too
//   2. in this repo, or a copy of it (a folder with delphi\delphipp.dpr): its own
//      delphi\bin\delphipp.exe, built by build.cmd, so the rules you add are the ones that run
//   3. delphipp.exe on the PATH, for any other folder
use zed_extension_api::{self as zed, settings::LspSettings, LanguageServerId, Result};

struct Delphipp;

impl zed::Extension for Delphipp {
    fn new() -> Self {
        Delphipp
    }

    fn language_server_command(
        &mut self,
        id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let lsp = vec!["--lsp".to_string()];
        if let Some(binary) = LspSettings::for_worktree(id.as_ref(), worktree)
            .ok()
            .and_then(|s| s.binary)
        {
            if let Some(path) = binary.path {
                return Ok(zed::Command {
                    command: path,
                    args: binary.arguments.unwrap_or(lsp),
                    env: binary.env.unwrap_or_default().into_iter().collect(),
                });
            }
        }
        if worktree.read_text_file("delphi/delphipp.dpr").is_ok() {
            let sep = match zed::current_platform().0 {
                zed::Os::Windows => "\\",
                _ => "/",
            };
            let root = worktree.root_path();
            let root = root.trim_end_matches(['/', '\\']);
            return Ok(zed::Command {
                command: [root, "delphi", "bin", "delphipp.exe"].join(sep),
                args: lsp,
                env: vec![],
            });
        }
        if let Some(path) = worktree.which("delphipp") {
            return Ok(zed::Command { command: path, args: lsp, env: vec![] });
        }
        Err("delphipp: no delphipp.exe. Build it (delphi\\build.cmd) and put its folder on the \
             PATH, or name it in Zed's settings: \"lsp\": { \"delphipp\": { \"binary\": \
             { \"path\": \"C:\\\\...\\\\delphipp.exe\" } } }"
            .to_string())
    }
}

zed::register_extension!(Delphipp);
