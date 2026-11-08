import CoreServices
import Foundation

/// Tells when something inside one folder changes: a file added, removed, renamed or written to.
/// Changes deeper down are ignored, they do not alter what the panel lists.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var folder = ""
    private var onChange: (() -> Void)?

    deinit { stop() }

    func watch(_ path: String, onChange: @escaping () -> Void) {
        // realpath, not resolvingSymlinksInPath: events say /private/tmp, which Foundation would shorten to /tmp.
        let real = realpath(path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
        self.onChange = onChange
        guard real != folder || stream == nil else { return }
        stop()
        folder = real
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let events = (0..<min(count, list.count)).map { (list[$0], flags[$0]) }
            watcher.received(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(nil, callback, &context, [real] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        folder = ""
    }

    private func received(_ events: [(String, FSEventStreamEventFlags)]) {
        let slashed = { (path: String) in (path.hasSuffix("/") ? path : path + "/").lowercased() }
        let mine = slashed(folder)
        let changed = events.contains { path, flags in
            let event = slashed(path)
            if event == mine { return true }
            // The folder itself was moved or deleted, or the system lost track and asks for a fresh look.
            let lost = flags & UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs) != 0
            return lost && mine.hasPrefix(event)
        }
        if changed { onChange?() }
    }
}
