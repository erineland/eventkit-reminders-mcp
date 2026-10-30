// swift-tools-version:5.9
import PackageDescription

// No dependencies: the MCP stdio protocol is small enough to speak directly, and EventKit ships with macOS.
let package = Package(
    name: "eventkit-reminders-mcp",
    platforms: [.macOS(.v14)],   // requestFullAccessToReminders
    targets: [
        .executableTarget(name: "eventkit-reminders-mcp", path: "Sources/eventkit-reminders-mcp"),
    ]
)
