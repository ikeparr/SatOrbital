// swift-tools-version: 6.0
import PackageDescription

// The pure orbit model can be tested on a Mac without an iOS simulator.
let package = Package(
    name: "SatOrbitalMath",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [.library(name: "OrbitMath", targets: ["OrbitMath"])],
    targets: [
        .target(name: "CSGP4", path: "Vendor/CSGP4", exclude: ["LICENSE"], publicHeadersPath: "include"),
        .target(name: "OrbitMath", dependencies: ["CSGP4"], path: "SatOrbital", exclude: ["Resources", "Scene", "Views", "SatOrbitalApp.swift"]),
        .testTarget(name: "OrbitMathTests", dependencies: ["OrbitMath"], path: "Tests/OrbitMathTests", resources: [.copy("Fixtures")])
    ]
)
