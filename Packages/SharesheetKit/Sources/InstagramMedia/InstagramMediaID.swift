import Foundation

/// Instagram encodes a post's numeric media id in its shortcode (base64 with `-` and `_`).
public enum InstagramMediaID {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    public static func string(for shortcode: String) -> String? {
        guard !shortcode.isEmpty else { return nil }
        var value: UInt64 = 0
        for character in shortcode {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            let (multiplied, overflowed) = value.multipliedReportingOverflow(by: 64)
            let (sum, overflowedAgain) = multiplied.addingReportingOverflow(UInt64(index))
            guard !overflowed, !overflowedAgain else { return nil }
            value = sum
        }
        return String(value)
    }
}
