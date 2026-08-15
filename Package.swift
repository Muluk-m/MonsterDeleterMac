// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MonsterDeleter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MonsterDeleter",
            path: "Sources/MonsterDeleter"
        )
    ]
)
