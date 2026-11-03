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
        // The open folder's rules first; then the clone this extension was built from, for a
        // folder without them (a file opened from elsewhere, or another project). Zed builds
        // through its link to the zed folder, so Python follows the link before going up:
        // Windows reads link\.. as the folder holding the link
        let launch = format!(
            "import os, sys, runpy; \
             sys.path.append(os.path.join(os.path.dirname(os.path.realpath(r'{}')), 'python')); \
             runpy.run_module('delphipp.lsp', run_name='__main__', alter_sys=True)",
            env!("CARGO_MANIFEST_DIR")
        );
        Ok(zed::Command {
            command: worktree.which("python").unwrap_or_else(|| "python".to_string()),
            args: vec!["-c".to_string(), launch],
            env: vec![("PYTHONPATH".to_string(), format!("{}/python", worktree.root_path()))],
        })
    }
}

zed::register_extension!(Delphipp);
