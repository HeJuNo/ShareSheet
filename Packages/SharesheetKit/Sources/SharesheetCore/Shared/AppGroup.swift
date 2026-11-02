import Foundation

/// Locations inside the App Group container shared by the app and the share extension.
public enum AppGroup {
    /// From the app's or extension's Info.plist, where the project derives it from the team.
    public static let identifier = Bundle.main.object(forInfoDictionaryKey: "SharesheetAppGroup") as? String
        ?? "group.Sharesheet"

    /// Root of the shared App Group container, or nil when the entitlement is missing.
    public static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// `<container>/Inbox`, created on demand.
    public static func inboxURL() -> URL? {
        guard let container = containerURL() else { return nil }
        return directory(container.appendingPathComponent("Inbox", isDirectory: true))
    }

    /// `<container>/Library/index.sqlite`; the `Library` directory is created on demand.
    public static func indexURL() -> URL? {
        guard let container = containerURL() else { return nil }
        guard let library = directory(container.appendingPathComponent("Library", isDirectory: true)) else { return nil }
        return library.appendingPathComponent("index.sqlite")
    }

    private static func directory(_ url: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }
}
