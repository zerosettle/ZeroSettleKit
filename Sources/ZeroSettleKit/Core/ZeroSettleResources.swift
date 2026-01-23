//
//  ZeroSettleResources.swift
//  ZeroSettleKit
//
//  Helper utilities for loading bundled package resources
//

import Foundation
import SwiftUI
import UIKit

/// Helper for loading ZeroSettleKit bundled resources
public enum ZeroSettleResources {

    // MARK: - Image Loading

    /// Load a UIImage from the package's asset catalog
    /// - Parameters:
    ///   - name: The name of the image asset
    ///   - compatibleWith: Optional trait collection
    /// - Returns: UIImage if found, nil otherwise
    public static func image(named name: String, compatibleWith: UITraitCollection? = nil) -> UIImage? {
        return UIImage(named: name, in: .module, compatibleWith: compatibleWith)
    }

    /// Load a SwiftUI Image from the package's asset catalog
    /// - Parameter name: The name of the image asset
    /// - Returns: SwiftUI Image from the package bundle
    public static func swiftUIImage(named name: String) -> Image {
        return Image(name, bundle: .module)
    }

    // MARK: - File Loading

    /// Load a JSON file from the package resources
    /// - Parameter name: The name of the JSON file (without extension)
    /// - Returns: Data from the JSON file
    /// - Throws: Error if file not found or cannot be read
    public static func loadJSON(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw ZeroSettleResourceError.fileNotFound(name: name, extension: "json")
        }
        return try Data(contentsOf: url)
    }

    /// Load a file from the package resources
    /// - Parameters:
    ///   - name: The name of the file (without extension)
    ///   - extension: The file extension
    /// - Returns: Data from the file
    /// - Throws: Error if file not found or cannot be read
    public static func loadFile(named name: String, withExtension extension: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: `extension`) else {
            throw ZeroSettleResourceError.fileNotFound(name: name, extension: `extension`)
        }
        return try Data(contentsOf: url)
    }

    /// Get URL for a resource file in the package
    /// - Parameters:
    ///   - name: The name of the file (without extension)
    ///   - extension: The file extension
    /// - Returns: URL if found, nil otherwise
    public static func url(forResource name: String, withExtension extension: String) -> URL? {
        return Bundle.module.url(forResource: name, withExtension: `extension`)
    }

    // MARK: - Common Assets

    /// Phantom wallet icon
    public static var phantomIcon: UIImage? {
        return image(named: "PhantomIcon")
    }

    /// Phantom wallet icon as SwiftUI Image
    public static var phantomIconSwiftUI: Image {
        return swiftUIImage(named: "PhantomIcon")
    }

    /// Coinbase wallet icon
    public static var coinbaseIcon: UIImage? {
        return image(named: "CoinbaseIcon")
    }

    /// Coinbase wallet icon as SwiftUI Image
    public static var coinbaseIconSwiftUI: Image {
        return swiftUIImage(named: "CoinbaseIcon")
    }

    /// Keypad icon for custom amount entry
    public static var keypadIcon: UIImage? {
        return image(named: "Keypad")
    }

    /// Keypad icon as SwiftUI Image
    public static var keypadIconSwiftUI: Image {
        return swiftUIImage(named: "Keypad")
    }
}

// MARK: - Error Types

public enum ZeroSettleResourceError: LocalizedError {
    case fileNotFound(name: String, extension: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let name, let ext):
            return "Resource file '\(name).\(ext)' not found in ZeroSettleKit bundle"
        }
    }
}

