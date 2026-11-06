# RunDock MCP client setup reference

Checked against vendor documentation on 2026-11-06. These are client integrations; model providers such as OpenAI, Anthropic, or Google are not themselves MCP clients. An MCP-compatible client can use RunDock when it supports a local stdio server and its execution environment can access the RunDock helper and runtime. Configuration alone is not a verified connection or a tool-use test. Availability, workspace trust, organization policy, and the installation location can affect support. No configuration was changed by preparing this document.

The example executable is `/Applications/RunDock.app/Contents/Helpers/rundock`, with `mcp` as its sole argument. Use the actual absolute helper path when RunDock is installed elsewhere; do not invoke it through a shell string. Merge a named server into existing configuration rather than replacing user settings. Restart or reconnect the relevant client and test a tool call.

## Connector catalog

| Client | macOS configuration | Local stdio shape or method | Primary documentation |
|---|---|---|---|
| Codex CLI / IDE | `~/.codex/config.toml`; project `.codex/config.toml` | TOML below; shared across CLI and IDE | [OpenAI MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | Common `mcpServers` JSON below | [MCP local servers](https://modelcontextprotocol.io/docs/develop/connect-local-servers) |
| Claude Code | project `.mcp.json`, or user config `~/.claude.json` managed by `claude mcp add --scope user` | Common `mcpServers` JSON below; use the client CLI for user scope | [Claude Code MCP](https://code.claude.com/docs/en/mcp) |
| Cursor | `~/.cursor/mcp.json`; project `.cursor/mcp.json` | Common `mcpServers` JSON below | [Cursor MCP](https://docs.cursor.com/context/model-context-protocol) |
| Gemini CLI | `~/.gemini/settings.json`; project `.gemini/settings.json` | Common `mcpServers` JSON below | [Gemini CLI MCP](https://geminicli.com/docs/tools/mcp-server/) |
| VS Code local harness | project `.vscode/mcp.json`; user-profile `mcp.json` via VS Code command palette | `servers` JSON below; docs now label VS Code-format destinations deprecated in guided flow | [VS Code MCP](https://code.visualstudio.com/docs/agent-customization/mcp-servers) |
| GitHub Copilot global | `$COPILOT_HOME/mcp-config.json`, or `~/.copilot/mcp-config.json` if unset | Portable `mcpServers` format; review current Copilot schema and client version | [VS Code MCP](https://code.visualstudio.com/docs/agent-customization/mcp-servers) |
| OpenCode | `~/.config/opencode/opencode.json` or project `opencode.json` | Version-dependent JSON below; verify the installed major version first | [V1](https://thdxr.dev.opencode.ai/docs/mcp-servers/) · [V2 migration](https://dev.opencode.ai/v2/docs/migrate-v1/) |
| Windsurf | MCP support/path could not be verified from current accessible official documentation in this research; use the client’s current MCP settings and vendor docs | Manual, version-dependent | [Windsurf documentation](https://docs.windsurf.com/) |
| ChatGPT desktop | Settings → MCP servers → Add server → STDIO; desktop/local execution where available | Enter executable and argument through the UI | [OpenAI MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) |
| ChatGPT web | Custom apps use remote MCP; local config and local stdio are not directly read by hosted web chat | A separately built reachable secure remote transport is needed; RunDock currently exposes local stdio | [OpenAI custom apps](https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt) |
| Other MCP clients | Follow that client’s documented settings | Configure stdio command and argument separately; compatibility requires testing | [MCP specification](https://modelcontextprotocol.io/) |

ChatGPT desktop plugin distribution is a distinct pathway: OpenAI documents desktop-only local MCP plugins, with public submission restricted to approved partners. This restriction does not by itself mean the direct desktop MCP settings above are unavailable. See [desktop-only plugins](https://developers.openai.com/plugins/deploy/desktop-only).

### Common JSON (Claude Desktop, Claude Code, Cursor, Gemini CLI)

```json
{"mcpServers":{"rundock":{"command":"/Applications/RunDock.app/Contents/Helpers/rundock","args":["mcp"]}}}
```

For Claude Code the user-scoped command is `claude mcp add --scope user --transport stdio rundock -- /Applications/RunDock.app/Contents/Helpers/rundock mcp`. The same shape in project `.mcp.json` is project-scoped. Claude Code's config is separate from Claude Desktop's.

### Codex TOML

```toml
[mcp_servers.rundock]
command = "/Applications/RunDock.app/Contents/Helpers/rundock"
args = ["mcp"]
```

### VS Code local harness JSON

```json
{"servers":{"rundock":{"type":"stdio","command":"/Applications/RunDock.app/Contents/Helpers/rundock","args":["mcp"]}}}
```

### OpenCode: check major version

V1: `{"mcp":{"rundock":{"type":"local","command":["/Applications/RunDock.app/Contents/Helpers/rundock","mcp"],"enabled":true}}}`

V2: `{"mcp":{"servers":{"rundock":{"type":"local","command":["/Applications/RunDock.app/Contents/Helpers/rundock","mcp"],"disabled":false}}}}`

The shape and enablement flags differ. Do not automatically write either until the installed client version is known.

## Scope and limits

RunDock's local tools operate on the user's machine with that user's permissions. Connecting an MCP server does not guarantee that any particular model will call its tools, bypass client approvals, or access a remote machine. Desktop protected folders may require the operating system's ordinary file access approval. Neither a model/provider account nor a remote webpage receives access merely because it shares a vendor name with a local client.

Brand asset provenance and restrictions are recorded in [ai-icons/README.md](ai-icons/README.md). The vendor assets are separate from RunDock's software license and their inclusion is not a claim of vendor endorsement or of redistribution rights.
