import XCTest
import ProcessesProtocol

final class ServiceIdentityTests: XCTestCase {
    func testConservativeRoleInference() {
        for command in ["npm run dev", "pnpm dev", "yarn dev", "bun run dev", "vite", "next dev", "'npm' 'run' 'dev' -- --port 5173"] {
            XCTAssertEqual(ServiceIdentity.reuseKey(command: command), "server:dev", command)
        }
        for command in ["npm start", "pnpm start", "bun run start"] { XCTAssertEqual(ServiceIdentity.reuseKey(command: command), "server:start") }
        XCTAssertEqual(ServiceIdentity.reuseKey(command: "yarn preview"), "server:preview")
        XCTAssertEqual(ServiceIdentity.reuseKey(command: "exec '/bin/zsh' -l"), "shell")
        for command in ["npm run dev --workspace api", "npm run dev --workspace=web", "npm run dev -wapi", "pnpm --filter api dev", "npm run dev --prefix /tmp", "npm run dev --workspaces", "pnpm dev --dir=/app", "pnpm dev -C/app", "pnpm dev -Fweb", "npm run dev --cwd web", "vite --config vite.config.js", "next dev -c config.js", "npm run dev --help", "pnpm dev --version", "npm run dev && echo done", "npm run dev; echo hello", "npm run dev $(whoami)", "npm run build", "vite client", "next dev other-project", "exec /bin/sh -c echo", "'npm run dev", "echo test"] {
            XCTAssertNil(ServiceIdentity.reuseKey(command: command), command)
        }
    }
}
