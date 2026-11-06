// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Processes", platforms: [.macOS(.v13)],
    products: [.executable(name: "processes", targets: ["processes"]), .executable(name: "ProcessesApp", targets: ["ProcessesApp"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.13.0")],
    targets: [
        .target(name: "ProcessesProtocol"),
        .target(name: "ProcessesRuntime", dependencies: ["ProcessesProtocol"]),
        .executableTarget(name: "processes", dependencies: ["ProcessesProtocol", "ProcessesRuntime"]),
        .executableTarget(name: "ProcessesApp", dependencies: ["ProcessesProtocol", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "ProcessesTests", dependencies: ["ProcessesProtocol", "ProcessesRuntime"])
    ]
)
