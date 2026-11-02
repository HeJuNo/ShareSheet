import Foundation

public enum ICloudLocator {
    /// From the app's or extension's Info.plist, where the project derives it from the team.
    public static let containerIdentifier = Bundle.main.object(forInfoDictionaryKey: "SharesheetICloudContainer") as? String
        ?? "iCloud.Sharesheet"

    /// The iCloud container's `Documents` directory (with `Unsorted` created), nil if iCloud is unavailable.
    public static func libraryRoot() async -> URL? {
        await Task.detached {
            let fm = FileManager.default
            guard let container = fm.url(forUbiquityContainerIdentifier: containerIdentifier) ?? simulatorContainer()
            else { return nil }
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

    /// The simulator has no iCloud account, so it keeps the library in the App Group container instead,
    /// where the app and the share extension both reach it. Devices always use iCloud.
    private static func simulatorContainer() -> URL? {
        #if targetEnvironment(simulator)
        AppGroup.containerURL()?.appending(path: "SimulatorLibrary", directoryHint: .isDirectory)
        #else
        nil
        #endif
    }
}
