# ZeroSettleKit Resources - Usage Examples

Complete examples of how to load and use bundled resources in ZeroSettleKit.

## Table of Contents

- [Image Loading](#image-loading)
- [JSON Loading](#json-loading)
- [Custom File Loading](#custom-file-loading)
- [SwiftUI Examples](#swiftui-examples)
- [UIKit Examples](#uikit-examples)
- [Error Handling](#error-handling)

---

## Image Loading

### Method 1: Using ZeroSettleResources Helper (Recommended)

```swift
import ZeroSettleKit

// Load pre-defined icons
let phantomIcon = ZeroSettleResources.phantomIcon
let coinbaseIcon = ZeroSettleResources.coinbaseIcon

// Load custom images
let customIcon = ZeroSettleResources.image(named: "MyCustomIcon")

// With trait collection
let darkModeIcon = ZeroSettleResources.image(
    named: "MyIcon",
    compatibleWith: UITraitCollection(userInterfaceStyle: .dark)
)
```

### Method 2: Using Bundle.module Directly

```swift
import UIKit

// UIKit
let icon = UIImage(named: "PhantomIcon", in: .module, compatibleWith: nil)

// With trait collection
let icon = UIImage(
    named: "PhantomIcon",
    in: .module,
    compatibleWith: UITraitCollection(userInterfaceStyle: .dark)
)
```

---

## JSON Loading

### Example 1: Simple JSON Loading

```swift
import ZeroSettleKit
import Foundation

// Load JSON data
do {
    let jsonData = try ZeroSettleResources.loadJSON(named: "sample-config")
    
    // Parse as dictionary
    if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
        print("Version:", json["version"] ?? "unknown")
    }
} catch {
    print("Failed to load JSON:", error)
}
```

### Example 2: Decoding to Codable Model

```swift
import ZeroSettleKit
import Foundation

// 1. Define your model
struct NetworkConfig: Codable {
    let version: String
    let description: String
    let networks: [String: Network]
    let features: [String: Bool]
    
    struct Network: Codable {
        let name: String
        let rpc: String
    }
}

// 2. Load and decode
func loadNetworkConfig() throws -> NetworkConfig {
    let data = try ZeroSettleResources.loadJSON(named: "sample-config")
    let config = try JSONDecoder().decode(NetworkConfig.self, from: data)
    return config
}

// 3. Use it
do {
    let config = try loadNetworkConfig()
    print("Version:", config.version)
    print("Mainnet RPC:", config.networks["mainnet"]?.rpc ?? "N/A")
    print("Phantom enabled:", config.features["phantom"] ?? false)
} catch {
    print("Error:", error)
}
```

### Example 3: Async Loading

```swift
import ZeroSettleKit
import Foundation

actor ConfigLoader {
    private var cachedConfig: NetworkConfig?
    
    func loadConfig() async throws -> NetworkConfig {
        if let cached = cachedConfig {
            return cached
        }
        
        let data = try ZeroSettleResources.loadJSON(named: "sample-config")
        let config = try JSONDecoder().decode(NetworkConfig.self, from: data)
        cachedConfig = config
        return config
    }
}

// Usage
Task {
    let loader = ConfigLoader()
    let config = try await loader.loadConfig()
    print("Loaded config version:", config.version)
}
```

---

## Custom File Loading

### Text Files

```swift
import ZeroSettleKit
import Foundation

// Load a text file
do {
    let data = try ZeroSettleResources.loadFile(named: "terms", withExtension: "txt")
    if let text = String(data: data, encoding: .utf8) {
        print(text)
    }
} catch {
    print("Failed to load text file:", error)
}
```

### Property Lists

```swift
import ZeroSettleKit
import Foundation

// Load a plist file
do {
    let data = try ZeroSettleResources.loadFile(named: "config", withExtension: "plist")
    if let plist = try PropertyListSerialization.propertyList(
        from: data,
        format: nil
    ) as? [String: Any] {
        print("Plist contents:", plist)
    }
} catch {
    print("Failed to load plist:", error)
}
```

### Getting File URLs

```swift
import ZeroSettleKit

// Get URL for a resource
if let url = ZeroSettleResources.url(forResource: "sample-config", withExtension: "json") {
    print("Resource URL:", url)
    
    // Use with other APIs that need URLs
    let data = try Data(contentsOf: url)
}
```

---

## SwiftUI Examples

### Example 1: Using Pre-defined Icons

```swift
import SwiftUI
import ZeroSettleKit

struct WalletIconView: View {
    var body: some View {
        VStack(spacing: 20) {
            // Using helper
            ZeroSettleResources.phantomIconSwiftUI
                .resizable()
                .frame(width: 50, height: 50)
            
            ZeroSettleResources.coinbaseIconSwiftUI
                .resizable()
                .frame(width: 50, height: 50)
        }
    }
}
```

### Example 2: Using Bundle.module

```swift
import SwiftUI

struct CustomIconView: View {
    var body: some View {
        Image("PhantomIcon", bundle: .module)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 40)
    }
}
```

### Example 3: Dynamic Icon Loading

```swift
import SwiftUI
import ZeroSettleKit

struct DynamicWalletIcon: View {
    let walletType: WalletType
    
    enum WalletType {
        case phantom, coinbase, metamask
        
        var iconName: String {
            switch self {
            case .phantom: return "PhantomIcon"
            case .coinbase: return "CoinbaseIcon"
            case .metamask: return "MetaMaskIcon"
            }
        }
    }
    
    var body: some View {
        if let uiImage = ZeroSettleResources.image(named: walletType.iconName) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 50, height: 50)
        } else {
            // Fallback
            Image(systemName: "wallet.pass.fill")
                .resizable()
                .frame(width: 50, height: 50)
        }
    }
}
```

### Example 4: Loading Config in SwiftUI

```swift
import SwiftUI
import ZeroSettleKit

struct ConfigView: View {
    @State private var config: NetworkConfig?
    @State private var error: Error?
    
    var body: some View {
        VStack {
            if let config = config {
                Text("Version: \(config.version)")
                Text("Description: \(config.description)")
            } else if let error = error {
                Text("Error: \(error.localizedDescription)")
                    .foregroundColor(.red)
            } else {
                ProgressView("Loading...")
            }
        }
        .onAppear {
            loadConfig()
        }
    }
    
    private func loadConfig() {
        do {
            let data = try ZeroSettleResources.loadJSON(named: "sample-config")
            config = try JSONDecoder().decode(NetworkConfig.self, from: data)
        } catch {
            self.error = error
        }
    }
}
```

---

## UIKit Examples

### Example 1: UIImageView

```swift
import UIKit
import ZeroSettleKit

class WalletViewController: UIViewController {
    private let iconImageView = UIImageView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Using helper
        iconImageView.image = ZeroSettleResources.phantomIcon
        
        // Or using Bundle.module
        iconImageView.image = UIImage(named: "PhantomIcon", in: .module, compatibleWith: nil)
        
        // Configure
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        view.addSubview(iconImageView)
    }
}
```

### Example 2: UIButton with Icon

```swift
import UIKit
import ZeroSettleKit

class WalletButton: UIButton {
    init(walletType: String) {
        super.init(frame: .zero)
        
        let icon = ZeroSettleResources.image(named: "\(walletType)Icon")
        setImage(icon, for: .normal)
        
        imageView?.contentMode = .scaleAspectFit
        imageEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// Usage
let phantomButton = WalletButton(walletType: "Phantom")
let coinbaseButton = WalletButton(walletType: "Coinbase")
```

### Example 3: Loading Config in UIKit

```swift
import UIKit
import ZeroSettleKit

class ConfigViewController: UIViewController {
    private var config: NetworkConfig?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        loadConfiguration()
    }
    
    private func loadConfiguration() {
        do {
            let data = try ZeroSettleResources.loadJSON(named: "sample-config")
            config = try JSONDecoder().decode(NetworkConfig.self, from: data)
            updateUI()
        } catch {
            showError(error)
        }
    }
    
    private func updateUI() {
        guard let config = config else { return }
        title = "Version \(config.version)"
        // Update other UI elements
    }
    
    private func showError(_ error: Error) {
        let alert = UIAlertController(
            title: "Error",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
```

---

## Error Handling

### Handling Resource Loading Errors

```swift
import ZeroSettleKit
import Foundation

func loadResourceSafely() {
    do {
        let data = try ZeroSettleResources.loadJSON(named: "config")
        // Process data
    } catch ZeroSettleResourceError.fileNotFound(let name, let ext) {
        print("Resource not found: \(name).\(ext)")
        // Use default configuration
    } catch {
        print("Unexpected error: \(error)")
    }
}
```

### Providing Fallbacks

```swift
import ZeroSettleKit
import UIKit

func loadIconWithFallback(named name: String) -> UIImage {
    if let icon = ZeroSettleResources.image(named: name) {
        return icon
    } else {
        // Return system icon as fallback
        return UIImage(systemName: "wallet.pass.fill")!
    }
}

// Usage
let icon = loadIconWithFallback(named: "PhantomIcon")
```

### Validating Resources at Launch

```swift
import ZeroSettleKit

func validateResources() -> Bool {
    let requiredImages = ["PhantomIcon", "CoinbaseIcon"]
    let requiredFiles = ["sample-config"]
    
    // Check images
    for imageName in requiredImages {
        guard ZeroSettleResources.image(named: imageName) != nil else {
            print("Missing required image: \(imageName)")
            return false
        }
    }
    
    // Check JSON files
    for fileName in requiredFiles {
        do {
            _ = try ZeroSettleResources.loadJSON(named: fileName)
        } catch {
            print("Missing or invalid JSON: \(fileName)")
            return false
        }
    }
    
    return true
}

// Call at app launch
if !validateResources() {
    fatalError("Required resources are missing")
}
```

---

## Advanced Examples

### Caching Loaded Resources

```swift
import ZeroSettleKit
import Foundation

class ResourceCache {
    static let shared = ResourceCache()
    
    private var imageCache: [String: UIImage] = [:]
    private var jsonCache: [String: Data] = [:]
    private let lock = NSLock()
    
    func image(named name: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        
        if let cached = imageCache[name] {
            return cached
        }
        
        if let image = ZeroSettleResources.image(named: name) {
            imageCache[name] = image
            return image
        }
        
        return nil
    }
    
    func json(named name: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        
        if let cached = jsonCache[name] {
            return cached
        }
        
        let data = try ZeroSettleResources.loadJSON(named: name)
        jsonCache[name] = data
        return data
    }
}

// Usage
let icon = ResourceCache.shared.image(named: "PhantomIcon")
let config = try ResourceCache.shared.json(named: "sample-config")
```

### Resource Manager

```swift
import ZeroSettleKit
import Foundation

public class ZeroSettleResourceManager {
    public static let shared = ZeroSettleResourceManager()
    
    private init() {}
    
    // MARK: - Icons
    
    public enum WalletIcon: String {
        case phantom = "PhantomIcon"
        case coinbase = "CoinbaseIcon"
        case metamask = "MetaMaskIcon"
        
        public var image: UIImage? {
            ZeroSettleResources.image(named: rawValue)
        }
    }
    
    public func icon(for wallet: WalletIcon) -> UIImage? {
        return wallet.image
    }
    
    // MARK: - Configuration
    
    public func loadConfiguration<T: Decodable>(named name: String, as type: T.Type) throws -> T {
        let data = try ZeroSettleResources.loadJSON(named: name)
        return try JSONDecoder().decode(type, from: data)
    }
}

// Usage
let phantomIcon = ZeroSettleResourceManager.shared.icon(for: .phantom)
let config = try ZeroSettleResourceManager.shared.loadConfiguration(
    named: "sample-config",
    as: NetworkConfig.self
)
```

---

## Testing Resources

### Unit Test Example

```swift
import XCTest
@testable import ZeroSettleKit

class ResourceTests: XCTestCase {
    
    func testPhantomIconExists() {
        let icon = ZeroSettleResources.phantomIcon
        XCTAssertNotNil(icon, "Phantom icon should exist")
    }
    
    func testCoinbaseIconExists() {
        let icon = ZeroSettleResources.coinbaseIcon
        XCTAssertNotNil(icon, "Coinbase icon should exist")
    }
    
    func testSampleConfigLoads() throws {
        let data = try ZeroSettleResources.loadJSON(named: "sample-config")
        XCTAssertFalse(data.isEmpty, "Config data should not be empty")
        
        let config = try JSONDecoder().decode(NetworkConfig.self, from: data)
        XCTAssertEqual(config.version, "1.0.0")
    }
    
    func testInvalidResourceThrows() {
        XCTAssertThrowsError(
            try ZeroSettleResources.loadJSON(named: "nonexistent")
        ) { error in
            XCTAssertTrue(error is ZeroSettleResourceError)
        }
    }
}
```

---

## Best Practices

1. **Always use `Bundle.module`** for package resources, never `Bundle.main`
2. **Use the helper class** for common resources (cleaner API)
3. **Provide fallbacks** for missing resources
4. **Cache frequently used resources** to improve performance
5. **Validate critical resources** at app launch
6. **Handle errors gracefully** with user-friendly messages
7. **Use type-safe enums** for resource names when possible
8. **Test resource loading** in unit tests

---

## Common Pitfalls

❌ **Wrong**: Using `Bundle.main`
```swift
let image = UIImage(named: "PhantomIcon", in: .main, compatibleWith: nil)
```

✅ **Correct**: Using `Bundle.module`
```swift
let image = UIImage(named: "PhantomIcon", in: .module, compatibleWith: nil)
```

---

❌ **Wrong**: Hardcoding resource paths
```swift
let path = "/path/to/Resources/icon.png"
```

✅ **Correct**: Using Bundle APIs
```swift
let url = Bundle.module.url(forResource: "icon", withExtension: "png")
```

---

❌ **Wrong**: Not handling errors
```swift
let data = try! ZeroSettleResources.loadJSON(named: "config")
```

✅ **Correct**: Proper error handling
```swift
do {
    let data = try ZeroSettleResources.loadJSON(named: "config")
} catch {
    // Handle error or provide fallback
}
```

