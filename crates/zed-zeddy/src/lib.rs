use zed_extension_api::{
    self as zed, process::Command, settings::ContextServerSettings, ContextServerId, Extension,
    Project, Range, Result, SlashCommand, SlashCommandOutput, SlashCommandOutputSection, Worktree,
};

struct ZeddyExtension;

impl Extension for ZeddyExtension {
    fn new() -> Self {
        Self
    }

    fn context_server_command(
        &mut self,
        context_server_id: &ContextServerId,
        project: &Project,
    ) -> Result<Command> {
        let id_str = context_server_id.as_ref();

        // 1. Check user configured settings in Zed settings.json
        if let Ok(settings) = ContextServerSettings::for_project(id_str, project) {
            if let Some(command_settings) = settings.command {
                if let Some(path) = command_settings.path {
                    return Ok(Command {
                        command: path,
                        args: command_settings.arguments.unwrap_or_default(),
                        env: command_settings
                            .env
                            .unwrap_or_default()
                            .into_iter()
                            .collect(),
                    });
                }
            }
        }

        // 2. Discover in standard macOS / system binary paths
        let standard_candidates = [
            "/Applications/Zeddy.app/Contents/MacOS/zeddy-mcp",
            "/usr/local/bin/zeddy-mcp",
            "/opt/homebrew/bin/zeddy-mcp",
        ];

        for candidate in standard_candidates {
            if std::fs::metadata(candidate).is_ok() {
                return Ok(Command {
                    command: candidate.to_string(),
                    args: vec![],
                    env: vec![],
                });
            }
        }

        // 3. Fallback to binary on PATH
        Ok(Command {
            command: "zeddy-mcp".to_string(),
            args: vec![],
            env: vec![],
        })
    }

    fn run_slash_command(
        &self,
        command: SlashCommand,
        args: Vec<String>,
        worktree: Option<&Worktree>,
    ) -> std::result::Result<SlashCommandOutput, String> {
        let root_dir = worktree.map(|w| w.root_path()).unwrap_or_default();

        match command.name.as_str() {
            "zeddy" => {
                let query = args.join(" ");
                let mut text = String::from("<!-- zeddy: memory context -->\n");
                text.push_str("Zeddy local memory MCP is active.\n");
                if !root_dir.is_empty() {
                    text.push_str(&format!("Project: {}\n", root_dir));
                }
                if !query.is_empty() {
                    text.push_str(&format!("Query filter: {}\n", query));
                }
                text.push_str(
                    "Ask your assistant: memories are auto-queried via `zeddy_context` MCP tool.",
                );

                Ok(SlashCommandOutput {
                    text,
                    sections: vec![SlashCommandOutputSection {
                        range: Range { start: 0, end: 30 },
                        label: "Zeddy Memory".to_string(),
                    }],
                })
            }
            "zeddy-search" => {
                let query = args.join(" ");
                if query.trim().is_empty() {
                    return Err("Usage: /zeddy-search <keyword or phrase>".to_string());
                }

                let text = format!(
                    "<!-- zeddy search -->\nSearching local memory for: `{}`\nUse the assistant with `@zeddy` or `zeddy_search` MCP tool to inspect matching snippets.",
                    query
                );

                Ok(SlashCommandOutput {
                    text,
                    sections: vec![SlashCommandOutputSection {
                        range: Range { start: 0, end: 21 },
                        label: "Zeddy Search".to_string(),
                    }],
                })
            }
            _ => Err(format!("Unknown slash command: {}", command.name)),
        }
    }
}

zed::register_extension!(ZeddyExtension);
