// swift-tools-version: 6.4
import PackageDescription

func dependency(_ name: String, environment: String, revision: String) -> Package.Dependency {
  if let path = Context.environment[environment], !path.isEmpty {
    return .package(path: path)
  }
  return .package(url: "https://github.com/naviapps/\(name).git", revision: revision)
}

let package = Package(
  name: "DesktopActions",
  platforms: [.macOS(.v26)],
  products: [
    .library(
      name: "DesktopActions",
      targets: ["DesktopActions"]
    ),
    .library(
      name: "DesktopActionsMacOS",
      targets: ["DesktopActionsMacOS"]
    ),
    .library(name: "DesktopActionsSwiftUI", targets: ["DesktopActionsSwiftUI"]),
  ],
  dependencies: [
    dependency(
      "desktop-applications", environment: "DESKTOP_APPLICATIONS_PACKAGE_PATH",
      revision: "6598e592b6625c5ac1fb6de6c36e7c25c3e9e238"),
    .package(
      url: "https://github.com/swiftlang/swift-subprocess.git",
      .upToNextMinor(from: "1.0.2")
    ),
    dependency(
      "window-management", environment: "WINDOW_MANAGEMENT_PACKAGE_PATH",
      revision: "60308da2d5049866da91c9f01a72bdc70c93da04"
    ),
  ],
  targets: [
    .binaryTarget(name: "CDesktopActions", path: "Artifacts/CDesktopActions.xcframework"),
    .target(
      name: "DesktopActions",
      dependencies: [
        "CDesktopActions", .product(name: "WindowManagement", package: "window-management"),
      ]
    ),
    .target(
      name: "DesktopActionsMacOS",
      dependencies: [
        .product(name: "DesktopApplications", package: "desktop-applications"),
        .product(name: "DesktopApplicationsMacOS", package: "desktop-applications"),
        "DesktopActions",
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "WindowManagement", package: "window-management"),
        .product(name: "WindowManagementMacOS", package: "window-management"),
      ]
    ),
    .target(name: "DesktopActionsSwiftUI", dependencies: ["DesktopActions"]),
    .testTarget(
      name: "DesktopActionsSwiftUITests",
      dependencies: ["DesktopActionsSwiftUI", "DesktopActions"]
    ),
    .testTarget(
      name: "DesktopActionsTests",
      dependencies: [
        "DesktopActions",
        .product(name: "WindowManagement", package: "window-management"),
      ]
    ),
    .testTarget(
      name: "DesktopActionsMacOSTests",
      dependencies: [
        "DesktopActions",
        "DesktopActionsMacOS",
        .product(name: "DesktopApplications", package: "desktop-applications"),
        .product(name: "WindowManagement", package: "window-management"),
        .product(name: "WindowManagementMacOS", package: "window-management"),
      ]
    ),
  ]
)
