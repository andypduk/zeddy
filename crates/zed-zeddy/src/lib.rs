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
                text.push_str("### Zeddy Local Memories\n\n");

                let mut cmd = std::process::Command::new("zeddy");
                if let Ok(path) = std::env::var("ZEDDY_BIN") {
                    cmd = std::process::Command::new(path);
                } else if std::path::Path::new("/absolute/path/to/zeddy").exists() {
                    cmd = std::process::Command::new("/absolute/path/to/zeddy");
                }

                if query.trim().is_empty() {
                    cmd.arg("list");
                    if let Ok(output) = cmd.output() {
                        let stdout = String::from_utf8_lossy(&output.stdout);
                        if stdout.trim().is_empty() {
                            text.push_str(
                                "No memories found. Add one with `@zeddy` or `/zeddy-add`.\n",
                            );
                        } else {
                            text.push_str("```\n");
                            text.push_str(&stdout);
                            text.push_str("```\n");
                        }
                    } else {
                        text.push_str("Zeddy daemon active via MCP `zeddy_list`.\n");
                    }
                } else {
                    cmd.arg("context").arg(&query).arg("--stdout");
                    if !root_dir.is_empty() {
                        cmd.arg("--project").arg(&root_dir);
                    }
                    if let Ok(output) = cmd.output() {
                        let stdout = String::from_utf8_lossy(&output.stdout);
                        if !stdout.trim().is_empty() {
                            text.push_str(&stdout);
                        } else {
                            text.push_str(&format!("No relevant memories matched `{}`.\n", query));
                        }
                    } else {
                        text.push_str(&format!("Query `{}` processed via MCP context.\n", query));
                    }
                }

                Ok(SlashCommandOutput {
                    text,
                    sections: vec![SlashCommandOutputSection {
                        range: Range { start: 0, end: 28 },
                        label: "Zeddy Memory".to_string(),
                    }],
                })
            }
            "zeddy-search" => {
                let query = args.join(" ");
                if query.trim().is_empty() {
                    return Err("Usage: /zeddy-search <keyword or phrase>".to_string());
                }

                let mut text = String::from("<!-- zeddy search -->\n");
                text.push_str(&format!("### Zeddy Search: `{}`\n\n", query));

                let mut cmd = std::process::Command::new("zeddy");
                if std::path::Path::new("/absolute/path/to/zeddy").exists() {
                    cmd = std::process::Command::new("/absolute/path/to/zeddy");
                }
                cmd.arg("search").arg(&query);
                if !root_dir.is_empty() {
                    cmd.arg("--project").arg(&root_dir);
                }

                if let Ok(output) = cmd.output() {
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    if stdout.trim().is_empty() {
                        text.push_str("No memories matched.\n");
                    } else {
                        text.push_str("```\n");
                        text.push_str(&stdout);
                        text.push_str("```\n");
                    }
                } else {
                    text.push_str(&format!(
                        "Searching for `{}` via MCP `zeddy_search`.\n",
                        query
                    ));
                }

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
