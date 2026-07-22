// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "printly",
    platforms: [
        // Keep in sync with printly.podspec (`s.platform`) — the two
        // manifests describe the same sources for the SPM and CocoaPods
        // consumers respectively.
        .iOS("13.0")
    ],
    products: [
        .library(name: "printly", targets: ["printly"])
    ],
    // No explicit Flutter dependency: the Flutter tooling injects the
    // framework for SPM builds on every version we support (>=3.35). The
    // newer `FlutterFramework` path-dependency style from the 3.44 template
    // does not resolve on 3.35–3.43, where the generated package that the
    // path points at does not exist yet.
    dependencies: [],
    targets: [
        .target(
            name: "printly",
            dependencies: [],
            resources: [
                // printly's native code uses no required-reason APIs
                // (CoreBluetooth only), so no PrivacyInfo.xcprivacy is
                // bundled. If one becomes necessary, add it under
                // Sources/printly/ and uncomment:
                // .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
