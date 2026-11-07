// swift-tools-version:5.9
// ClamAwake 菜单栏壳 — SwiftPM 包定义（产物经 scripts/build-app.sh 组装为 .app）
import PackageDescription

let package = Package(
    name: "ClamAwake",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClamAwake",
            path: "Sources/ClamAwake"
        )
    ]
)
