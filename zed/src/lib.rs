// Zed starts a language server only through an extension's code: this starts the rules', from
// the python folder of the project open in Zed, so your own rules are the ones that run.
use zed_extension_api::{self as zed, LanguageServerId, Result};

struct Delphipp;

impl zed::Extension for Delphipp {
    fn new() -> Self {
        Delphipp
    }

    fn language_server_command(
        &mut self,
        _id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        Ok(zed::Command {
            command: worktree.which("python").unwrap_or_else(|| "python".to_string()),
            args: vec!["-m".to_string(), "delphipp.lsp".to_string()],
            env: vec![("PYTHONPATH".to_string(), format!("{}/python", worktree.root_path()))],
        })
    }
}

zed::register_extension!(Delphipp);
