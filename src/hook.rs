//! The one check every agent run carries (a Claude Code PreToolUse hook, set by
//! agent.rs): nothing is started in the background. An agent's turn is one
//! process that ends with its answer, so a background helper or command dies
//! with it and its work is lost (R1's art helper, 2026-11-12). Everything else
//! passes untouched; the refusal tells the agent what to do instead.

use std::io::{self, Read};

const REFUSED: &str = "Refused: nothing runs in the background here. Your turn is one process \
that ends when you answer, so a background helper or command is killed with it and its work \
is lost. Run it in the foreground (several helpers in one message still run side by side); \
work that must outlive your turn goes to a detached process (agent/rules.md).";

/// `hook background`: reads the tool call Claude Code hands a PreToolUse hook on
/// stdin; exit 2 with the reason refuses it and shows the reason to the agent.
pub(crate) fn background() -> io::Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let call: serde_json::Value = serde_json::from_str(&input).unwrap_or_default();
    if call.pointer("/tool_input/run_in_background").and_then(serde_json::Value::as_bool) == Some(true) {
        eprintln!("{REFUSED}");
        std::process::exit(2);
    }
    Ok(())
}

/// The settings an agent run is started with: the hook above on every tool that
/// can start something in the background, and no auto-memory (the memory in
/// this project's folder is the developers' notes; the agent's are the profile
/// and the rules).
pub(crate) fn settings(exe: &std::path::Path) -> String {
    let command = format!("\"{}\" hook background", exe.display());
    serde_json::json!({
        "autoMemoryEnabled": false,
        "hooks": { "PreToolUse": [ {
            "matcher": "Agent|Task|Bash|PowerShell",
            "hooks": [ { "type": "command", "command": command } ]
        } ] }
    })
    .to_string()
}
