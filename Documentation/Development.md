# Development

Squirrel is an Xcode project built with Swift 6 and SwiftUI. The project is generated from [project.yml](../project.yml) with XcodeGen, and Sparkle comes in through Swift Package Manager.

From the repository root:

```sh
open Squirrel.xcodeproj
xcodebuild test -project Squirrel.xcodeproj -scheme Squirrel -destination 'platform=macOS'
```

See the [documentation index](README.md) and [design notes](../DESIGN.md) for more context.
