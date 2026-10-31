import Foundation

public enum ICloudLocator {
    public static let containerIdentifier = "iCloud.com.luetgendorf.Sharesheet"

    /// The iCloud container's `Documents` directory (with `Unsorted` created), nil if iCloud is unavailable.
    public static func libraryRoot() async -> URL? {
        await Task.detached {
            let fm = FileManager.default
            guard let container = fm.url(forUbiquityContainerIdentifier: containerIdentifier) else { return nil }
            let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
            let unsorted = documents.appending(path: "Unsorted", directoryHint: .isDirectory)
            do {
                try fm.createDirectory(at: unsorted, withIntermediateDirectories: true)
            } catch {
                return nil
            }
            return documents
        }.value
    }
}
