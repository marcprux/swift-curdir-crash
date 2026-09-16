// swift-tools-version: 5.9
// A deliberately dependency-free package: the point is to exercise Foundation's
// current-directory accessor and nothing else, and to stay buildable with both
// the glibc toolchain and the static-linux (musl) Swift SDK.
import PackageDescription

let package = Package(
    name: "swift-curdir-crash",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "curdir-probe"),
    ]
)
