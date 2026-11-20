import CoreServices
import Foundation

/// Paths to revisit. A directory event invalidates its subtree as well as its ancestors' totals.
struct ChangedPaths {
    private var branches: Set<String> = []
    private var ancestors: Set<String> = []

    mutating func add(_ path: String) {
        var current = path.lowercased().precomposedStringWithCanonicalMapping
        branches.insert(current)
        while ancestors.insert(current).inserted && current != "/" {
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { break }
        }
    }

    func affects(_ path: String) -> Bool {
        var current = path.lowercased().precomposedStringWithCanonicalMapping
        if ancestors.contains(current) { return true }
        while !current.isEmpty {
            if branches.contains(current) { return true }
            if current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }
}

struct JournalPoint: Codable, Equatable {
    let uuid: String
    let event: UInt64
    let device: dev_t
    let mount: String
    let prefix: String
}

enum ChangeJournal {
    // Use the writable Data volume for the startup disk. Its firmlinks expose the
    // same relative paths in the startup namespace. Other volumes use their mount point.
    static func checkpoint(for url: URL) -> JournalPoint? {
        let data = URL(fileURLWithPath: "/System/Volumes/Data")
        let probe = url.path == "/" ? data : url
        var fs = statfs()
        guard statfs(probe.path, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              let status = try? fileStatus(probe),
              let uuid = FSEventsCopyUUIDForDevice(status.st_dev) else { return nil }
        let mount = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        let fd = open(probe.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH_NOFIRMLINK, &bytes) == 0 else { return nil }
        let path = String(cString: bytes)
        let prefix: String
        if path == mount { prefix = "" }
        else if mount == "/" { prefix = String(path.dropFirst()) }
        else if path.hasPrefix(mount + "/") { prefix = String(path.dropFirst(mount.count + 1)) }
        else { return nil }
        // Take the cursor BEFORE reading the filesystem, so changes during a scan
        // will be replayed next time even if that directory had already been visited.
        let event = FSEventsGetLastEventIdForDeviceBeforeTime(status.st_dev, Date().timeIntervalSince1970)
        guard event != 0 else { return nil }
        return JournalPoint(uuid: CFUUIDCreateString(nil, uuid) as String, event: event,
                            device: status.st_dev, mount: mount, prefix: prefix)
    }

    private final class Batch {
        let root: String
        let prefix: String
        var paths = ChangedPaths()
        var valid = true
        let historyReady = DispatchSemaphore(value: 0)
        var latest: UInt64 = 0
        init(root: String, prefix: String) { self.root = root; self.prefix = prefix }
        func receive(_ path: String, flags: UInt32, id: UInt64) {
            let lost = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                       kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged |
                       kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            if flags & UInt32(lost) != 0 { valid = false }
            if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                historyReady.signal()
                return
            }
            latest = max(latest, id)
            let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let suffix: Substring
            if relative == prefix { suffix = "" }
            else if prefix.isEmpty { suffix = relative[...] }
            else if relative.lowercased().hasPrefix(prefix.lowercased() + "/") {
                suffix = relative.dropFirst(prefix.count + 1)
            } else {
                // Unexpected spelling or an event coalesced above our watched path.
                paths.add(root)
                return
            }
            let absolute = suffix.isEmpty ? root : (root == "/" ? "/" : root + "/") + suffix
            paths.add(absolute)
        }
    }

    private static func withStream<T>(_ stream: FSEventStreamRef?, queue: DispatchQueue,
                                      perform: (FSEventStreamRef) -> T?) -> T? {
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        let started = FSEventStreamStart(stream)
        defer {
            if started { FSEventStreamStop(stream) }
            FSEventStreamInvalidate(stream)
            queue.sync {}
            FSEventStreamRelease(stream)
        }
        return started ? perform(stream) : nil
    }

    private static func waitForDelivery(_ signal: DispatchSemaphore) -> Bool {
        let deadline = DispatchTime.now() + 3
        while !Task.isCancelled && DispatchTime.now() < deadline {
            if signal.wait(timeout: .now() + .milliseconds(100)) == .success { return true }
        }
        return false
    }

    private final class JournalMarker {
        let name = ".journal-" + UUID().uuidString
        let delivered = DispatchSemaphore(value: 0)
    }

    // HistoryDone ends replay, and FlushSync drains events already queued by the
    // daemon. Neither establishes that the daemon has consumed the latest kernel
    // events yet. Wait for a later, identifiable event in our own cache first.
    private static func synchronize(at directory: URL) -> Bool {
        let marker = JournalMarker()
        let queue = DispatchQueue(label: "SpaceMap.event-marker")
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(marker).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, count, rawPaths, _, _ in
            guard let context else { return }
            let marker = Unmanaged<JournalMarker>.fromOpaque(context).takeUnretainedValue()
            let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count where String(cString: paths[index]).hasSuffix("/" + marker.name) {
                marker.delivered.signal()
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let stream = FSEventStreamCreate(nil, callback, &context, [directory.path] as CFArray,
                                         FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, flags)
        return withExtendedLifetime(marker) {
            withStream(stream, queue: queue) { _ in
                let path = directory.appendingPathComponent(marker.name).path
                let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
                guard fd >= 0 else { return false }
                close(fd)
                defer { unlink(path) }
                return waitForDelivery(marker.delivered)
            } ?? false
        }
    }

    static func changes(since old: JournalPoint, to now: JournalPoint, root: URL,
                        synchronizeAt directory: URL) -> (paths: ChangedPaths, latest: UInt64)? {
        guard old.uuid == now.uuid, old.device == now.device, old.mount == now.mount,
              old.prefix == now.prefix, old.event <= now.event, synchronize(at: directory) else { return nil }
        let batch = Batch(root: root.path, prefix: now.prefix)
        let queue = DispatchQueue(label: "SpaceMap.event-history")
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(batch).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, count, rawPaths, flags, ids in
            guard let context else { return }
            let batch = Unmanaged<Batch>.fromOpaque(context).takeUnretainedValue()
            let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for i in 0..<count { batch.receive(String(cString: paths[i]), flags: flags[i], id: ids[i]) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
        let stream = FSEventStreamCreateRelativeToDevice(nil, callback, &context, now.device,
                                                          [now.prefix] as CFArray, old.event, 0.05, flags)
        return withExtendedLifetime(batch) {
            withStream(stream, queue: queue) { stream in
                guard waitForDelivery(batch.historyReady) else { return nil }
                FSEventStreamFlushSync(stream)
                return queue.sync { batch.valid ? (batch.paths, max(old.event, batch.latest)) : nil }
            }
        }
    }
}
