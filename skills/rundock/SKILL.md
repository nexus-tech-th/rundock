---
name: rundock
description: Route project commands through RunDock so AI and the user share managed jobs, logs, status, and history.
---

# RunDock

When this skill is available, run project commands through the `rundock` CLI so the user and AI can inspect and control the same jobs in the RunDock app. Do not ask the user to name a project, service, actor, or session before each run. Derive the working directory from the active project/worktree, use the command being run as the job identity, and use the supplied actor name only when one is already available. The CLI reuses recognized server roles within the same working directory and falls back to exact-command matching for other commands.

## Run project commands

Locate `rundock` on PATH. If unavailable, use the existing helper at `/Applications/RunDock.app/Contents/Helpers/rundock` or `~/Applications/RunDock.app/Contents/Helpers/rundock`. When connected through MCP, prefer the available RunDock tools rather than requiring a separate CLI installation. Never guess a missing executable path.

Use `rundock run --cwd DIR -- program args...` for a command. Use `--command SHELL_STRING` only when shell syntax such as pipes, redirects, or chaining is required.

- Keep development servers and other intentionally long-running project processes detached from the AI turn. Their managed status, output, and history remain visible in RunDock.
- Before starting a server, inspect existing jobs for the active directory. Reuse a running development server and its discovered port; inspect its logs instead of creating a replacement at the next available port. RunDock recognizes common dev/start/preview commands in the same directory, including changes between npm/pnpm/yarn/bun. Complex shell wrappers use exact matching, so pass the real cwd and executable directly.
- Use `rundock shell --cwd DIR --json` or MCP `rundock_shell` to create or reconnect to the project's persistent interactive shell. Send input and read output through the returned job ID. The human and AI share that PTY; do not type shell commands into a foreground dev server. Use a separate finite `run --wait` job when an exit code is needed.
- Use `run --new` / MCP `forceNew: true` only when the user explicitly requests a parallel instance. A new task, code edit, or model turn is not a reason to duplicate a live server or stop it.
- Use `--wait` for short builds, tests, linters, and other finite commands. Read its exit status and report failures accurately.
- Use `--json` when structured output is useful.
- Do not create an `add`/`start` form workflow for routine project commands; `run` creates or reuses the managed job automatically.
- Once connected, route project commands through RunDock. Ordinary one-off reads and file edits do not need process management.

## Shared control and scope

Use `rundock list` and `rundock logs ID` to inspect jobs and `rundock stop ID` only for a job in the scope of the user's request. The user and AI share the same managed jobs, status, output, completion results, errors, and history. Leave unrelated jobs running. Never place credentials in commands, recorded metadata, event messages, or environment dumps; rely on the project's existing secret mechanism.

RunDock can manage only commands routed through this integration. It does not capture shell commands run outside it, and installing this skill does not guarantee that every AI client or model will follow it.

## Connect MCP clients

RunDock exposes a local stdio MCP server through `rundock mcp`. Use the app's **Connect AI** catalog to review the client-specific setup and install only after the user chooses that client. Clients using a supported JSON config get a `rundock` server entry merged into their existing config; unrelated settings are preserved, identical setup can be repeated safely, and conflicting entries or JSONC files must be handled manually. Review the exact path and backup notice shown by the app.

**Connect Codex** uses the installed Codex CLI to inspect and add the MCP server, then installs the bundled routing skill in the same action. An identical existing MCP entry or skill is a no-op; a conflicting entry is left for manual review. Start a new chat afterward. Claude Code uses its installed CLI with user scope; an existing entry is never replaced. OpenCode configuration varies by version and needs manual review. ChatGPT web needs remote MCP and cannot connect to this local stdio server directly; supported desktop versions may offer local STDIO setup. Use each client's documentation link from the app rather than assuming every client accepts the same config format.

## macOS protected folders

If a GUI-launched RunDock daemon stalls on a project inside Documents, Desktop, or Downloads, select that exact folder once through the app's **Choose…** control. Use the normal folder picker; do not change privacy settings or request Full Disk Access. A running PID alone does not prove the command started successfully.
