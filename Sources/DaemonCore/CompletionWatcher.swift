import Foundation

public final class CompletionWatcher: CompletionWatching {
    private let doneDirectoryURL: URL
    private let fileManager: FileManager

    public init(doneDir: String = "~/.flowdeck-daemon/done/") {
        self.doneDirectoryURL = URL(fileURLWithPath: NSString(string: doneDir).expandingTildeInPath)
        self.fileManager = .default
    }

    public func checkAndProcess(dispatcher: EventDispatching) throws {
        guard fileManager.fileExists(atPath: doneDirectoryURL.path) else {
            return
        }

        let files = try fileManager.contentsOfDirectory(
            at: doneDirectoryURL,
            includingPropertiesForKeys: nil
        )
        for fileURL in files {
            let eventId = try Self.decode(fileName: fileURL.lastPathComponent)
            try dispatcher.markDone(id: eventId)
            try fileManager.removeItem(at: fileURL)
        }
    }

    public static func signalDone(
        id: String,
        doneDir: String = "~/.flowdeck-daemon/done/"
    ) throws {
        let doneDirectoryURL = URL(
            fileURLWithPath: NSString(string: doneDir).expandingTildeInPath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: doneDirectoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = doneDirectoryURL.appendingPathComponent(encode(id: id))
        try Data().write(to: fileURL, options: .atomic)
    }

    private static func encode(id: String) -> String {
        let data = Data(id.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(fileName: String) throws -> String {
        var base64 = fileName
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        guard
            let data = Data(base64Encoded: base64),
            let value = String(data: data, encoding: .utf8)
        else {
            throw CompletionWatcherError.invalidDoneFileName(fileName: fileName)
        }

        return value
    }
}

public enum CompletionWatcherError: LocalizedError, Equatable {
    case invalidDoneFileName(fileName: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidDoneFileName(fileName):
            return "Invalid done filename: \(fileName)"
        }
    }
}
