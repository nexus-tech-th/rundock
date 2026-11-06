import Foundation

/// Conservative classification: shell operators and expansions never receive a role.
public enum ServiceIdentity {
    public static func reuseKey(command: String) -> String? {
        guard let tokens = tokenize(command), !tokens.isEmpty else { return nil }
        let selectors = ["--workspace", "--workspaces", "--prefix", "--dir", "--filter", "--cwd", "--config", "-w", "-C", "-F", "-c"]
        let information = ["--help", "-h", "--version", "-v"]
        guard !tokens.dropFirst().contains(where: { argument in
            information.contains(argument) || selectors.contains(where: { option in
                argument == option || argument.hasPrefix(option + "=") || (option.count == 2 && argument.hasPrefix(option) && argument.count > option.count)
            })
        }) else { return nil }
        var args = tokens
        let executable = URL(fileURLWithPath: args.removeFirst()).lastPathComponent
        if executable == "exec" {
            guard let shell = args.first, ["/bin/sh", "/bin/zsh", "/bin/bash"].contains(shell), args.dropFirst().allSatisfy({ $0 == "-l" || $0 == "--login" }) else { return nil }
            return "shell"
        }
        if executable == "vite" {
            guard let first = args.first else { return "server:dev" }
            if first == "preview" { return "server:preview" }
            if ["--help", "-h", "--version", "-v"].contains(first) { return nil }
            return first.hasPrefix("-") ? "server:dev" : nil
        }
        if executable == "next", args.first == "dev", (args.count < 2 || args[1].hasPrefix("-")) { return "server:dev" }
        guard ["npm", "pnpm", "yarn", "bun"].contains(executable) else { return nil }
        if args.first == "run" { args.removeFirst() }
        guard let action = args.first else { return nil }
        switch action {
        case "dev": return "server:dev"
        case "start": return "server:start"
        case "preview": return "server:preview"
        default: return nil
        }
    }
    private static func tokenize(_ command: String) -> [String]? {
        enum State { case normal, single, double }
        var state = State.normal, escaped = false, active = false, token = "", result: [String] = []
        for c in command {
            // Reject metacharacters even when quoted: false negatives are safe.
            if ";&|<>()$`\n\r".contains(c) { return nil }
            if escaped { token.append(c); active = true; escaped = false; continue }
            switch state {
            case .normal:
                if c == "\\" { escaped = true; active = true }
                else if c == "'" { state = .single; active = true }
                else if c == "\"" { state = .double; active = true }
                else if c.isWhitespace { if active { result.append(token); token = ""; active = false } }
                else { token.append(c); active = true }
            case .single:
                if c == "'" { state = .normal } else { token.append(c) }
            case .double:
                if c == "\"" { state = .normal }
                else if c == "\\" { escaped = true }
                else { token.append(c) }
            }
        }
        guard state == .normal, !escaped else { return nil }
        if active { result.append(token) }
        return result
    }
}
