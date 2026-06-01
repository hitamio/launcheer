import CoreServices
import Foundation

final class ApplicationDirectoryMonitor {
    private let paths: [String]
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(urls: [URL], onChange: @escaping () -> Void) {
        self.paths = urls
            .map { $0.standardizedFileURL.path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<ApplicationDirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
            guard monitor.shouldReload(eventCount: eventCount, eventPaths: eventPaths) else { return }
            monitor.onChange()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.75,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func shouldReload(eventCount: Int, eventPaths: UnsafeMutableRawPointer) -> Bool {
        guard eventCount > 0 else { return false }
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return true }

        return paths.contains { path in
            path.hasSuffix(".app") || path.contains(".app/")
        }
    }
}
