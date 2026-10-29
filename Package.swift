// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DoorCore", platforms: [.macOS(.v13), .iOS(.v16)], products: [.library(name: "DoorCore", targets: ["DoorCore"])], targets: [.target(name: "DoorCore", path: "Core"), .testTarget(name: "DoorCoreTests", dependencies: ["DoorCore"], path: "Tests")])
