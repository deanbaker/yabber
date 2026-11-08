import Foundation

/// Everything the app and the keyboard agree on. Compiled into both targets.
///
/// Signalling: Darwin notifications (no payload). Data: small JSON files in the App Group container.
///   keyboard → app: start, stop, cancel, ping   (current request id lives in request.json)
///   app → keyboard: status                       (state lives in status.json)
enum WF {
    static let appGroup = "group.com.deanbaker.wisprfree"
    static let urlScheme = "wisprfree"
    static let dictateURL = URL(string: "wisprfree://dictate")!

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    enum Note: String, CaseIterable {
        case start, stop, cancel, ping, status
        var name: String { "com.deanbaker.wisprfree." + rawValue }
    }

    enum File: String {
        case request = "request.json"
        case status = "status.json"
        case keyboard = "keyboard.json"
        case log = "debug.log"
    }
}

/// Written by the keyboard before it posts `start` or opens the app.
struct DictationRequest: Codable, Equatable {
    var id: UUID
    var createdAt: Date
}

/// Written by the app after every change, then `status` is posted.
struct AppStatus: Codable, Equatable {
    enum Phase: String, Codable {
        case idle, recording, transcribing, done, failed
    }

    var sessionActive = false
    var phase: Phase = .idle
    /// The request the phase refers to.
    var requestID: UUID?
    var text: String?
    var message: String?
    var recordingStartedAt: Date?
    var sessionEndsAt: Date?
    var modelReady = false
    var updatedAt = Date()
}

/// Keyboard-private bookkeeping that must survive the extension being torn down.
struct KeyboardState: Codable {
    var lastInsertedID: UUID?
}

enum SharedStore {
    private static func url(_ file: WF.File) -> URL? {
        WF.container?.appendingPathComponent(file.rawValue)
    }

    static func write<T: Encodable>(_ value: T, to file: WF.File) {
        guard let url = url(file) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            SharedLog.write("store", "write \(file.rawValue) failed: \(error)")
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from file: WF.File) -> T? {
        guard let url = url(file), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }
}

/// Cross-process Darwin notifications. Handlers run on the main queue.
final class DarwinCenter {
    static let shared = DarwinCenter()

    private var handlers: [String: () -> Void] = [:]
    private let center = CFNotificationCenterGetDarwinNotifyCenter()

    func post(_ note: WF.Note) {
        CFNotificationCenterPostNotification(center, CFNotificationName(note.name as CFString), nil, nil, true)
    }

    func observe(_ note: WF.Note, _ handler: @escaping () -> Void) {
        let isNew = handlers[note.name] == nil
        handlers[note.name] = handler
        guard isNew else { return }
        CFNotificationCenterAddObserver(
            center, Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let me = Unmanaged<DarwinCenter>.fromOpaque(observer).takeUnretainedValue()
                let key = name.rawValue as String
                DispatchQueue.main.async { me.handlers[key]?() }
            },
            note.name as CFString, nil, .deliverImmediately)
    }

    func removeAll() {
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        handlers = [:]
    }
}

/// Shared debug log in the App Group container, readable from the Mac with
/// `scripts/app.sh log`. Both processes append; capped at ~512 KB.
enum SharedLog {
    private static let queue = DispatchQueue(label: "SharedLog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ source: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(source)] \(message)\n"
        #if DEBUG
        print(line, terminator: "")
        #endif
        queue.async {
            guard let url = WF.container?.appendingPathComponent(WF.File.log.rawValue) else { return }
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            if lseek(fd, 0, SEEK_END) > 512 * 1024 {
                ftruncate(fd, 0)
            }
            // O_APPEND keeps concurrent appends from the two processes from interleaving.
            FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(Data(line.utf8))
        }
    }
}
