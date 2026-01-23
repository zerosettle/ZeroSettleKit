# ZeroSettleKit Resources

This directory contains bundled resources for the ZeroSettleKit Swift Package.

## Structure

```
Resources/
├── Assets.xcassets/          # Image assets (processed by Xcode)
│   ├── PhantomIcon.imageset/
│   ├── CoinbaseIcon.imageset/
│   └── Contents.json
├── sample-config.json        # Example JSON configuration
└── README.md                 # This file
```

## Adding New Resources

### Images

1. **Create a new .imageset folder** inside `Assets.xcassets/`:
   ```bash
   mkdir -p Assets.xcassets/MyIcon.imageset
   ```

2. **Add your images** (1x, 2x, 3x scales):
   - `myicon.png` (1x)
   - `myicon@2x.png` (2x)
   - `myicon@3x.png` (3x)

3. **Create Contents.json**:
   ```json
   {
     "images" : [
       {
         "filename" : "myicon.png",
         "idiom" : "universal",
         "scale" : "1x"
       },
       {
         "filename" : "myicon@2x.png",
         "idiom" : "universal",
         "scale" : "2x"
       },
       {
         "filename" : "myicon@3x.png",
         "idiom" : "universal",
         "scale" : "3x"
       }
     ],
     "info" : {
       "author" : "xcode",
       "version" : 1
     }
   }
   ```

### JSON Files

Simply add `.json` files directly to the `Resources/` directory.

### Other Files

Add any other resource files (`.txt`, `.plist`, etc.) directly to the `Resources/` directory.

## Loading Resources in Code

### Using ZeroSettleResources Helper

The `ZeroSettleResources` helper provides convenient methods:

```swift
import ZeroSettleKit

// Load images
let phantomIcon = ZeroSettleResources.phantomIcon
let coinbaseIcon = ZeroSettleResources.coinbaseIcon

// SwiftUI images
Image(uiImage: ZeroSettleResources.phantomIcon!)
// or
ZeroSettleResources.phantomIconSwiftUI

// Load custom images
let myImage = ZeroSettleResources.image(named: "MyIcon")

// Load JSON
let jsonData = try ZeroSettleResources.loadJSON(named: "sample-config")
let config = try JSONDecoder().decode(Config.self, from: jsonData)

// Load other files
let data = try ZeroSettleResources.loadFile(named: "myfile", withExtension: "txt")
```

### Using Bundle.module Directly

You can also use `Bundle.module` directly:

```swift
// UIKit images
let image = UIImage(named: "PhantomIcon", in: .module, compatibleWith: nil)

// SwiftUI images
Image("PhantomIcon", bundle: .module)

// Files
if let url = Bundle.module.url(forResource: "sample-config", withExtension: "json") {
    let data = try Data(contentsOf: url)
}
```

## Package.swift Configuration

The resources are declared in `Package.swift`:

```swift
.target(
    name: "ZeroSettleKit",
    dependencies: [...],
    path: "Sources/ZeroSettleKit",
    resources: [
        .process("Resources")  // Processes Assets.xcassets + copies other files
    ]
)
```

### .process vs .copy

- **`.process("Resources")`**: Processes `Assets.xcassets` (optimizes images) and copies other files
- **`.copy("Resources")`**: Copies everything as-is without processing

Use `.process` for most cases (recommended).

## Troubleshooting

### Resources not loading?

1. **Reset Package Caches** in Xcode:
   - File > Packages > Reset Package Caches

2. **Clean build folder**:
   - Product > Clean Build Folder (Cmd+Shift+K)

3. **Verify Bundle.module**:
   ```swift
   print(Bundle.module.bundlePath)
   print(Bundle.module.resourcePath ?? "No resource path")
   ```

4. **Check file exists**:
   ```swift
   if let url = Bundle.module.url(forResource: "myfile", withExtension: "json") {
       print("Found: \(url)")
   } else {
       print("Not found")
   }
   ```

### Common Issues

- ❌ Using `Bundle.main` instead of `Bundle.module`
- ❌ Wrong target in Package.swift
- ❌ Typo in resource name
- ❌ Missing Contents.json in .imageset
- ❌ Images not in Assets.xcassets

## Best Practices

1. **Always use `Bundle.module`** for package resources
2. **Use Assets.xcassets** for images (better optimization)
3. **Provide all scales** (@1x, @2x, @3x) for best quality
4. **Use the helper class** (`ZeroSettleResources`) for common assets
5. **Keep resources organized** in subdirectories
6. **Document new resources** in this README

## Examples

### Adding a MetaMask Icon

1. Create the imageset:
   ```bash
   mkdir -p Assets.xcassets/MetaMaskIcon.imageset
   ```

2. Add images and Contents.json

3. Update `ZeroSettleResources.swift`:
   ```swift
   public static var metamaskIcon: UIImage? {
       return image(named: "MetaMaskIcon")
   }
   ```

4. Use in code:
   ```swift
   let icon = ZeroSettleResources.metamaskIcon
   ```

### Loading Custom Configuration

```swift
// 1. Add config.json to Resources/
// 2. Define your model
struct AppConfig: Codable {
    let version: String
    let features: [String: Bool]
}

// 3. Load and decode
let data = try ZeroSettleResources.loadJSON(named: "config")
let config = try JSONDecoder().decode(AppConfig.self, from: data)
```

