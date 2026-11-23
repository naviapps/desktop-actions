// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "DesktopActionsConsumer",
  platforms: [.macOS(.v26)],
  dependencies: [.package(name: "desktop-actions", path: "../sdk")],
  targets: [
    .executableTarget(
      name: "DesktopActionsConsumer",
      dependencies: [
        .product(name: "DesktopActions", package: "desktop-actions"),
        .product(name: "DesktopActionsMacOS", package: "desktop-actions"),
        .product(name: "DesktopActionsSwiftUI", package: "desktop-actions"),
      ])
  ]
)
