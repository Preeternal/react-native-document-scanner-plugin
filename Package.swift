// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ReactNativeDocumentScannerPlugin",
  platforms: [.iOS(.v15)],
  products: [
    .library(
      name: "ReactNativeDocumentScannerPlugin",
      targets: ["ReactNativeDocumentScannerPlugin"]
    ),
  ],
  dependencies: [
    // React Native's SPM autolinker exposes this package through
    // ios/build/generated/autolinking/libs/ReactNativeDocumentScannerPlugin.
    .package(name: "ReactNative", path: "../../../../xcframeworks"),
    .package(name: "React-GeneratedCode", path: "../../../ios"),
  ],
  targets: [
    .target(
      name: "DocumentScannerImplementation",
      path: "ios",
      exclude: ["ReactNative"],
      sources: ["DocScanner", "DocumentScannerImplementation"],
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreImage"),
        .linkedFramework("DataDetection"),
        .linkedFramework("Foundation"),
        .linkedFramework("Photos"),
        .linkedFramework("UIKit"),
        .linkedFramework("Vision"),
        .linkedFramework("VisionKit"),
      ]
    ),
    .target(
      name: "ReactNativeDocumentScannerPlugin",
      dependencies: [
        "DocumentScannerImplementation",
        .product(name: "ReactHeaders", package: "ReactNative"),
        .product(name: "ReactNativeHeaders", package: "ReactNative"),
        .product(name: "ReactNativeDependenciesHeaders", package: "ReactNative"),
        .product(name: "ReactAppHeaders", package: "React-GeneratedCode"),
      ],
      path: "ios/ReactNative",
      sources: ["DocumentScanner.mm"],
      publicHeadersPath: ".",
      cSettings: [
        .headerSearchPath("."),
      ],
      cxxSettings: [
        .headerSearchPath("."),
        .unsafeFlags([
          "-DFOLLY_NO_CONFIG",
          "-DFOLLY_MOBILE=1",
          "-DFOLLY_USE_LIBCPP=1",
          "-DFOLLY_CFG_NO_COROUTINES=1",
          "-DFOLLY_HAVE_CLOCK_GETTIME=1",
          "-Wno-comma",
          "-Wno-shorten-64-to-32",
          "-DRN_FABRIC_ENABLED",
          "-fno-modules",
        ]),
        .define("DEBUG", .when(configuration: .debug)),
        .define("NDEBUG", .when(configuration: .release)),
      ],
      linkerSettings: [
        .linkedFramework("Foundation"),
        .linkedFramework("UIKit"),
      ]
    ),
  ],
  swiftLanguageModes: [.v5],
  cxxLanguageStandard: .cxx20
)
