// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "X3FStudio",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Blank (blank.is) sign-in, storage and tables
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.5.1"),
    ],
    targets: [
        .executableTarget(
            name: "X3FStudio",
            dependencies: [.product(name: "Supabase", package: "supabase-swift")],
            path: "Sources/X3FStudio",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ]
)
