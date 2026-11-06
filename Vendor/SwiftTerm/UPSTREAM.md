# SwiftTerm vendor record

- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Version: 1.13.0
- Upstream checkout revision: `8e7a1e154f470e19c709a00a8768df348ba5fc43`
- Included upstream files: `Sources/SwiftTerm/**` and `LICENSE` only.
- Local patch: `Apple/Metal/MetalTerminalRenderer.swift` resolves the Metal shader resource from the app's `Contents/Resources/SwiftTerm_SwiftTerm.bundle` in packaged macOS apps before considering other bundles. In app mode it never evaluates SwiftPM's generated `Bundle.module`, which assumes a build-tree resource bundle. Non-app SwiftPM executables retain the `Bundle.module` lookup. Existing framework and main-bundle candidates remain available.
