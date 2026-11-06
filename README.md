# RunDock

Persistent native terminals and shared process control for humans and AI coding tools on macOS.

RunDock keeps development servers and interactive project shells available across AI turns. People and AI can inspect the same output, discover listening ports, and start, stop or restart managed jobs. Common development commands reuse an existing live server in the same directory, including switches between npm, pnpm, yarn and bun.

Built by [NEXUS TECHNOLOGY COMPANY LIMITED](https://nexustecs.com/). Native SwiftUI/AppKit and SwiftTerm; no web UI server.

## Install

Apple silicon, macOS 13 or later. Intel is not currently distributed.

Download the DMG from [GitHub Releases](https://github.com/nexus-tech-th/rundock/releases), or use the same repository as a Homebrew tap:

```sh
brew tap nexus-tech-th/rundock https://github.com/nexus-tech-th/rundock.git
brew install --cask nexus-tech-th/rundock/rundock
```

Homebrew links the bundled `rundock` CLI. For later upgrades:

```sh
brew update
brew upgrade --cask nexus-tech-th/rundock/rundock
```

Release publication is being prepared; the commands above require a published release and tracked cask. The final release notes identify signing/notarization status.

## Connect your AI

Open **Connect AI**, select a client and press **Connect**. Codex installs MCP and its routing skill together; start a new chat afterward. Supported installation flows include Codex, Claude Desktop/Code, Cursor, VS Code and Gemini CLI. Existing unrelated configuration is preserved; malformed or conflicting entries are left for review. Some clients need refresh/restart or tool approval.

Green **Connected** status comes from a real MCP session heartbeat. **Setup saved · waiting** means configuration was saved but the client has not connected. Last tool use is shown separately. Other local STDIO MCP clients can use `rundock mcp` through their own configuration; manual/version-specific integrations are documented in [the connector catalog](packaging/AI_CONNECTORS.md). Hosted web clients cannot directly access this local STDIO server.

Commands must be routed through RunDock. It does not intercept commands a client runs through another terminal tool, and a skill cannot force a model to use its tools.

## Run and reuse jobs

```sh
rundock run --cwd /absolute/project -- npm run dev
rundock shell --cwd /absolute/project --json
rundock list
rundock logs JOB_ID
rundock stop JOB_ID
```

`run` registers jobs automatically and reuses recognized live dev/start/preview roles in the same working directory. Workspace/config selectors and complex shell wrappers use conservative exact matching. Use `--new` only for an intentional parallel instance. `run --wait` returns a finite job’s exit code; long-running servers remain detached from the AI turn.

`rundock_shell` in MCP and `rundock shell` reconnect to the same project PTY. People and AI can send input and inspect output through that job ID. Keep a foreground server separate from a shell receiving new commands.

Closing a pane/window or quitting the app keeps managed processes running. **Stop All and Quit** explicitly stops them. A daemon crash/reboot does not adopt or automatically relaunch processes. Protocol upgrades preserve running jobs and require stopping/restarting the older daemon before using the new streaming/task features.

## AI task worktrees and Git

Open **AI Tasks & Git** to create a task from a local Git repository. Each task gets a branch and a separate worktree. Select files to inspect working-tree or staged diffs, stage/unstage, commit staged changes, or push the task branch. **Terminal** opens or reuses the task’s managed shell. No force push or source-checkout reset is performed.

```sh
rundock task ensure --repo /absolute/repository --task STABLE_TASK_KEY --name "Fix search" --client Codex --json
rundock task list --json
rundock shell --task RETURNED_TASK_ID --json
rundock run --task RETURNED_TASK_ID -- npm run dev
rundock git status --task RETURNED_TASK_ID --json
rundock git diff --task RETURNED_TASK_ID --path src/search.swift
```

AI clients use `rundock_task` and `rundock_git`. Reuse the same platform conversation/task key when resuming; RunDock returns the same workspace even when called from that worktree. Edit files in its returned path and pass the returned opaque task ID to run/shell/Git tools. An MCP connection ID is not a conversation ID. Clients without a stable task identifier must supply a stable key; RunDock cannot discover arbitrary chats or intercept editing outside its tools. Respect a worktree the user already selected rather than silently moving their task.

Task metadata lives alongside RunDock state; the worktrees share their repository’s Git objects. Worktree removal and branch merging remain ordinary Git operations. Push uses existing Git credentials without an interactive password prompt; configure credentials in the task terminal if needed. A timed-out Git operation requires checking repository/remote state before retrying.

## Native terminal and SSH

Visible terminals receive ordered output over a persistent Unix-socket stream, with bounded backpressure and reconnect offsets. Keyboard input has its own ordered queue. The native terminal enables SwiftTerm’s Metal renderer and reports the actual renderer in each pane. If Metal initialization fails, the pane shows the failure rather than claiming GPU acceleration. This is not iTerm engine parity.

⌘T opens a tab, ⌘D splits vertically, ⇧⌘D splits horizontally. Layout restores on reopen. **Terminal Appearance** follows an iTerm2 profile’s colors/font and reloads on activation; exported `.itermcolors` import is also available. Shell prompt themes come from shell configuration. iTerm keyboard mappings, transparency and full engine parity are not imported.

**SSH Hosts & SFTP** saves local host metadata and key paths. OpenSSH handles host verification and interactive password/passphrase prompts in a real terminal. `ssh-add` can load existing keys into the agent. SFTP browsing/transfers use trusted hosts and key/agent authentication; password-only interactive SFTP and cloud/team vaults are not included. Transfers stage before replacing a destination; remote atomic replacement requires the server’s OpenSSH rename extension.

Protected macOS folders may require selecting the exact project folder once through **Choose…**. A PID or listening port alone is not proof of application readiness.

## Updates

**RunDock → Check for Updates…** uses this repository’s public GitHub releases. Automatic checks run daily when enabled. The updater validates the release version and architecture-matched DMG link and shows release notes. It downloads a DMG; it does not silently replace the application or stop running jobs. Homebrew users can upgrade with `brew upgrade --cask nexus-tech-th/rundock/rundock`.

## Build and release

```sh
swift build --build-system native -c release
scripts/package-dmg.sh --skip-build
```

`VERSION` identifies the release. The packaging script embeds `nexus-tech-th/rundock` as its update repository. Signing defaults to ad hoc for local development; public notarized distribution requires a Developer ID Application identity and notary credentials. See [RELEASING.md](RELEASING.md) for the tag/draft/verification/promotion workflow. Local verification logs and workstation configuration are excluded from the public repository.

State lives in `~/Library/Application Support/RunDock` (or `PROCESSES_HOME`). Limits are 32 active processes, 256 automatic history records, 32 manually saved definitions, and roughly 8 MiB output per job. The oldest inactive automatic record is pruned; saved manual definitions are preserved. Descendants that deliberately leave the managed process group are outside stop guarantees.

## License and acknowledgments

RunDock is MIT licensed. SwiftTerm is MIT licensed and credited in About and bundled acknowledgments. Vendor icons identify their clients and remain separate from RunDock’s software license; see [asset provenance](packaging/ai-icons/README.md). No vendor endorsement is implied.
