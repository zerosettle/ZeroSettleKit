//
//  Data+Encoding.swift
//  ZeroSettleCore
//
//  Data extensions for hex and Base58 encoding.
//

import Foundation

public extension Data {
    /// Convert data to hex string
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Initialize from hex string
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }

        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

// MARK: - Base58 Encoding

public enum Base58 {
    private static let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    private static let alphabetArray = Array(alphabet)
    private static let radix = UInt64(alphabetArray.count)

    public static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var zerosCount = 0

        for byte in bytes {
            if byte != 0 { break }
            zerosCount += 1
        }

        let size = (bytes.count - zerosCount) * 138 / 100 + 1
        var encoded = [UInt8](repeating: 0, count: size)

        for i in zerosCount..<bytes.count {
            var carry = Int(bytes[i])
            var j = size - 1
            while j >= 0 {
                carry += 256 * Int(encoded[j])
                encoded[j] = UInt8(carry % 58)
                carry /= 58
                if carry == 0 && encoded[j] == 0 { break }
                j -= 1
            }
        }

        var skipZeros = true
        var result = String(repeating: "1", count: zerosCount)
        for byte in encoded {
            if skipZeros && byte == 0 { continue }
            skipZeros = false
            result.append(alphabetArray[Int(byte)])
        }

        return result
    }

    public static func decode(_ string: String) -> Data? {
        var zeros = 0

        for char in string {
            if char != "1" { break }
            zeros += 1
        }

        let size = string.count * 733 / 1000 + 1
        var decoded = [UInt8](repeating: 0, count: size)

        for char in string {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            var carry = alphabet.distance(from: alphabet.startIndex, to: index)
            var i = size - 1
            while i >= 0 {
                carry += 58 * Int(decoded[i])
                decoded[i] = UInt8(carry % 256)
                carry /= 256
                if carry == 0 && decoded[i] == 0 { break }
                i -= 1
            }
        }

        // Skip leading zeros in output
        var skipZeros = true
        var result = Data(repeating: 0, count: zeros)
        for byte in decoded {
            if skipZeros && byte == 0 { continue }
            skipZeros = false
            result.append(byte)
        }

        return result
    }
}
