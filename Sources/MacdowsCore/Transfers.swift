import Foundation

public enum OverwritePolicy: String, CaseIterable {
    case ask, overwrite, newer, skip
}

public struct TransferFile {
    public var relative: String
    public var source: String
    public var destination: String
    public var size: Int64
}

public struct TransferConflict {
    public var relative: String
    public var source: FileEntry
    public var destination: FileEntry
}

/// Everything a transfer will do, worked out before any byte moves.
public struct TransferPlan {
    public var directoriesToCreate: [String] = []
    public var files: [TransferFile] = []
    public var conflicts: [TransferConflict] = []
    public var sourceDirectories: [String] = []
    public var skipped: Set<String> = []

    public mutating func applyPolicy(_ policy: OverwritePolicy) {
        switch policy {
        case .ask, .overwrite:
            break
        case .skip:
            conflicts.forEach { skipped.insert($0.relative) }
        case .newer:
            for conflict in conflicts {
                guard let source = conflict.source.date, let destination = conflict.destination.date else {
                    // Without dates we cannot prove it is newer, so nothing gets replaced.
                    skipped.insert(conflict.relative)
                    continue
                }
                if source <= destination { skipped.insert(conflict.relative) }
            }
        }
    }
}

public enum TransferPlanner {
    /// Walks the selection and finds every file that would replace an existing one, also inside folders.
    public static func plan(selection: [FileEntry], from source: FileSource, sourceDirectory: String, to destination: FileSource, destinationDirectory: String) throws -> TransferPlan {
        var plan = TransferPlan()
        let existing = try destination.list(destinationDirectory)
        try walk(selection, source, sourceDirectory, destination, destinationDirectory, existing, prefix: "", depth: 0, &plan)
        return plan
    }

    private static func walk(_ entries: [FileEntry], _ source: FileSource, _ sourceDir: String, _ destination: FileSource, _ destinationDir: String, _ existing: [FileEntry], prefix: String, depth: Int, _ plan: inout TransferPlan) throws {
        // Symlink loops would otherwise never end.
        guard depth < 64 else { throw MCError("Folder structure is too deep: \(sourceDir)") }
        for entry in entries {
            let relative = prefix + entry.name
            let sourcePath = PathUtil.join(sourceDir, entry.name)
            let destinationPath = PathUtil.join(destinationDir, entry.name)
            let match = existing.first { $0.name == entry.name }
            if entry.isDirectory {
                if let match, !match.isDirectory {
                    plan.conflicts.append(TransferConflict(relative: relative, source: entry, destination: match))
                    continue
                }
                let children = try source.list(sourcePath)
                let inside: [FileEntry]
                if match != nil {
                    inside = try destination.list(destinationPath)
                } else {
                    plan.directoriesToCreate.append(destinationPath)
                    inside = []
                }
                plan.sourceDirectories.append(sourcePath)
                try walk(children, source, sourcePath, destination, destinationPath, inside, prefix: relative + "/", depth: depth + 1, &plan)
            } else {
                if let match {
                    plan.conflicts.append(TransferConflict(relative: relative, source: entry, destination: match))
                }
                plan.files.append(TransferFile(relative: relative, source: sourcePath, destination: destinationPath, size: entry.size))
            }
        }
    }
}

public struct BatchSnapshot {
    public var id: Int
    public var title: String
    public var totalBytes: Int64
    public var doneBytes: Int64
    public var fileCount: Int
    public var finishedFiles: Int
    public var failures: [String]
    public var isFinished: Bool
    public var isCancelled: Bool
    public var currentFile: String
}

/// Runs transfers in the background. The UI reads `snapshots()` on a timer.
public final class TransferEngine {
    private final class Batch {
        let id: Int
        let title: String
        let total: Int64
        let fileCount: Int
        var progress: [Int: Int64] = [:]
        var finished = 0
        var failures: [String] = []
        var done = false
        var cancelled = false
        var current = ""

        init(id: Int, title: String, total: Int64, fileCount: Int) {
            self.id = id
            self.title = title
            self.total = total
            self.fileCount = fileCount
        }
    }

    private let lock = NSLock()
    private var batches: [Batch] = []
    private var nextID = 1
    public var onBatchFinished: ((BatchSnapshot) -> Void)?

    public init() {}

    public func snapshots() -> [BatchSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return batches.map(snapshot)
    }

    private func snapshot(_ batch: Batch) -> BatchSnapshot {
        BatchSnapshot(id: batch.id, title: batch.title, totalBytes: batch.total, doneBytes: batch.progress.values.reduce(0, +), fileCount: batch.fileCount, finishedFiles: batch.finished, failures: batch.failures, isFinished: batch.done, isCancelled: batch.cancelled, currentFile: batch.current)
    }

    public func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        batches.filter { !$0.done }.forEach { $0.cancelled = true }
    }

    public func clearFinished() {
        lock.lock(); defer { lock.unlock() }
        batches.removeAll { $0.done }
    }

    public func start(plan: TransferPlan, title: String, source: FileSource, destination: FileSource, move: Bool, parallel: Int) {
        let files = plan.files.filter { !plan.skipped.contains($0.relative) && !isInsideSkipped($0.relative, plan.skipped) }
        lock.lock()
        let batch = Batch(id: nextID, title: title, total: max(1, files.reduce(0) { $0 + $1.size }), fileCount: files.count)
        nextID += 1
        batches.append(batch)
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            self.run(batch, plan: plan, files: files, source: source, destination: destination, move: move, parallel: max(1, parallel))
        }
    }

    private func isInsideSkipped(_ relative: String, _ skipped: Set<String>) -> Bool {
        var path = relative
        while let slash = path.lastIndex(of: "/") {
            path = String(path[..<slash])
            if skipped.contains(path) { return true }
        }
        return false
    }

    private func run(_ batch: Batch, plan: TransferPlan, files: [TransferFile], source: FileSource, destination: FileSource, move: Bool, parallel: Int) {
        var folderFailed = false
        for directory in plan.directoriesToCreate {
            do {
                try destination.makeDirectory(directory)
            } catch {
                folderFailed = true
                record(batch, failure: "\(directory): \(error.localizedDescription)")
            }
        }

        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: parallel)
        for (index, file) in files.enumerated() {
            slots.wait()
            if isCancelled(batch) { slots.signal(); break }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { slots.signal(); group.leave() }
                self.setCurrent(batch, file.relative)
                do {
                    try self.copy(file, index: index, batch: batch, source: source, destination: destination)
                    if move { try source.removeFile(file.source) }
                    self.finish(batch, index: index, size: file.size)
                } catch let error as MCError where error.isCancelled {
                    // Cancelling is not a failure worth reporting per file.
                } catch {
                    self.record(batch, failure: "\(file.relative): \(error.localizedDescription)")
                }
            }
        }
        group.wait()

        lock.lock()
        let clean = batch.failures.isEmpty && !batch.cancelled && !folderFailed
        lock.unlock()
        if move && clean && plan.skipped.isEmpty {
            // Children come after their parents in the list, so walking backwards empties folders first.
            for directory in plan.sourceDirectories.reversed() { try? source.removeEmptyDirectory(directory) }
        }

        lock.lock()
        batch.done = true
        batch.current = ""
        let finalSnapshot = snapshot(batch)
        lock.unlock()
        DispatchQueue.main.async { self.onBatchFinished?(finalSnapshot) }
    }

    private func copy(_ file: TransferFile, index: Int, batch: Batch, source: FileSource, destination: FileSource) throws {
        let progress: ProgressHandler = { [weak self] bytes in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            batch.progress[index] = bytes
            return !batch.cancelled
        }
        if !destination.isRemote {
            // A cancelled or broken download must never damage the existing file.
            let target = URL(fileURLWithPath: file.destination)
            let partial = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".mcpart")
            defer { try? FileManager.default.removeItem(at: partial) }
            try source.download(file.source, to: partial, progress: progress)
            _ = try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
        } else if !source.isRemote {
            try destination.upload(URL(fileURLWithPath: file.source), to: file.destination, progress: progress)
        } else {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try source.download(file.source, to: temporary) { progress($0 / 2) }
            try destination.upload(temporary, to: file.destination) { progress(file.size / 2 + $0 / 2) }
        }
    }

    private func isCancelled(_ batch: Batch) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return batch.cancelled
    }

    private func setCurrent(_ batch: Batch, _ name: String) {
        lock.lock(); defer { lock.unlock() }
        batch.current = name
    }

    private func finish(_ batch: Batch, index: Int, size: Int64) {
        lock.lock(); defer { lock.unlock() }
        batch.progress[index] = size
        batch.finished += 1
    }

    private func record(_ batch: Batch, failure: String) {
        lock.lock(); defer { lock.unlock() }
        batch.failures.append(failure)
    }
}

/// Recursive size. Local folders use the same file sizes Finder's Get Info adds up.
public struct SizeTotals {
    public var bytes: Int64 = 0
    public var bytesOnDisk: Int64 = 0
    public var files = 0
    public var folders = 0
    public init() {}
}

public enum SizeCalculator {
    public static func total(of entries: [FileEntry], in directory: String, source: FileSource, isCancelled: () -> Bool) throws -> SizeTotals {
        var totals = SizeTotals()
        for entry in entries {
            if isCancelled() { throw MCError("Cancelled", isCancelled: true) }
            let path = PathUtil.join(directory, entry.name)
            if !entry.isDirectory {
                totals.files += 1
                totals.bytes += entry.size
                if !source.isRemote, let local = localFile(path) { totals.bytesOnDisk += local.onDisk }
            } else if entry.isSymlink {
                totals.files += 1
            } else {
                totals.folders += 1
                if source.isRemote {
                    let inner = try total(of: source.list(path), in: path, source: source, isCancelled: isCancelled)
                    totals.bytes += inner.bytes
                    totals.files += inner.files
                    totals.folders += inner.folders
                } else {
                    localTree(path, &totals, isCancelled: isCancelled)
                }
            }
        }
        return totals
    }

    private static func localFile(_ path: String) -> (size: Int64, onDisk: Int64)? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        guard let values else { return nil }
        return (Int64(values.fileSize ?? 0), Int64(values.totalFileAllocatedSize ?? 0))
    }

    private static func localTree(_ path: String, _ totals: inout SizeTotals, isCancelled: () -> Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return }
        for case let url as URL in walker {
            if isCancelled() { return }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                totals.folders += 1
            } else {
                totals.files += 1
                totals.bytes += Int64(values.fileSize ?? 0)
                totals.bytesOnDisk += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
    }
}

public enum SourceFactory {
    public static func make(site: Site, password: String) -> FileSource {
        site.proto == .ssh ? SSHClient(site: site, password: password, hops: SiteStore().hops(for: site)) : FTPClient(site: site, password: password)
    }
}
