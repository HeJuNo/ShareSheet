import Foundation
import SharesheetCore
import UIKit

/// Fetches a site's icon: the page's declared icon first, then `https://host/favicon.ico`.
struct FaviconFetcher: Sendable {
    private let fetcher: any ResourceFetching

    init(fetcher: any ResourceFetching = URLSessionFetcher(timeout: 10, maxBytes: 1_000_000)) {
        self.fetcher = fetcher
    }

    func fetch(host: String, iconURL: URL?) async -> Data? {
        var candidates: [URL] = []
        if let iconURL { candidates.append(iconURL) }
        if let fallback = URL(string: "https://\(host)/favicon.ico"), fallback != iconURL { candidates.append(fallback) }
        for url in candidates {
            guard let (data, _) = try? await fetcher.fetch(url), !data.isEmpty, UIImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }
}
