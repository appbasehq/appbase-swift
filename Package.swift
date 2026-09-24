// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AppbaseAnalytics",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [.library(name: "AppbaseAnalytics", targets: ["AppbaseAnalytics"])],
  targets: [
    .target(name: "AppbaseAnalytics", resources: [.process("Resources")]),
  ]
)
