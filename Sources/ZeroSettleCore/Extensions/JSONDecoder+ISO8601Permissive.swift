//
//  JSONDecoder+ISO8601Permissive.swift
//  ZeroSettleCore
//
//  Permissive ISO 8601 date decoding strategy that accepts:
//    - Plain RFC 3339 / ISO 8601:                 2026-05-22T03:09:39Z
//    - Fractional seconds (milliseconds):         2026-05-22T03:09:39.997Z
//    - Sub-millisecond precision (e.g. micros):   2026-05-22T03:09:39.997253+00:00
//
//  Apple's `.iso8601` strategy uses ISO8601DateFormatter with at most
//  `.withFractionalSeconds`, which only accepts exactly three fractional digits.
//  The IAP API emits microsecond precision, so the strict strategy throws on
//  every entitlement decode. This strategy tries the standard formatters first
//  and, as a last resort, truncates fractional digits to three before retrying
//  — keeping the value exact to millisecond precision rather than failing.
//

import Foundation

public extension JSONDecoder.DateDecodingStrategy {

    /// Permissive ISO 8601 strategy that tolerates sub-millisecond precision.
    /// See file header for the formats it accepts.
    static let iso8601Permissive: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)

        if let date = ISO8601.withFractionalSeconds.date(from: raw) { return date }
        if let date = ISO8601.plain.date(from: raw) { return date }

        // Truncate >3 fractional digits ("2026-05-22T03:09:39.997253+00:00"
        // → "2026-05-22T03:09:39.997+00:00") and retry. Loses sub-millisecond
        // precision but is exact at the millisecond.
        let trimmed = raw.replacingOccurrences(
            of: #"(\.\d{3})\d+"#,
            with: "$1",
            options: .regularExpression
        )
        if let date = ISO8601.withFractionalSeconds.date(from: trimmed) { return date }
        if let date = ISO8601.plain.date(from: trimmed) { return date }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognized ISO 8601 date: \(raw)"
        )
    }

    private enum ISO8601 {
        static let withFractionalSeconds: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        static let plain: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()
    }
}
