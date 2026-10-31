import Foundation

/// Removes tracking parameters from shared URLs.
public enum URLCleaner {
    private static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "twclid", "igshid", "mc_cid", "mc_eid",
        "yclid", "_hsenc", "_hsmi", "ref_src", "si",
    ]

    /// Returns `url` without tracking query items. Scheme, host, path and fragment are kept as-is,
    /// the remaining query items keep their order, and the `?` is dropped when none remain.
    public static func clean(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems else { return url }
        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return url }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    private static func isTracking(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("utm_") || trackingNames.contains(lowered)
    }
}
