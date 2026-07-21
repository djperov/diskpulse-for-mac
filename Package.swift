// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MestoNaMak",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MestoNaMak", targets: ["MestoNaMak"])],
    targets: [
        .executableTarget(
            name: "MestoNaMak",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
