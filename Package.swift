import PackageDescription

let package = Package(
  name: "SourceKittenDaemon",

  targets: [
    Target(name: "SourceKittenDaemon"),
    Target(name: "sourcekittend", dependencies: [.Target(name: "SourceKittenDaemon")])
  ],

  dependencies: [
    .Package(url: "https://github.com/Carthage/Commandant.git", versions: Version(0, 12, 0)..<Version(0, 12, .max)),
    .Package(url: "https://github.com/jpsim/SourceKitten.git", Version(0, 18, 1)),
    .Package(url: "https://github.com/vapor/vapor.git", Version(2, 2, 2)),
    .Package(url: "https://github.com/nanzhong/Xcode.swift.git", Version(0, 4, 1))
  ],

  exclude: [
    "Tests/SourceKittenDaemonTests/Fixtures/Sources"
  ]
)
