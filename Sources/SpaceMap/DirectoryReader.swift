import Foundation
import Darwin

/// File metadata shared by directory enumeration and the single-path checks before Trash.
struct FileMetadata {
    let identity: FileID
    let modified: timespec
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let kind: EntryKind
    let multiLink: Bool
}

extension FileMetadata {
    init(_ s: stat) {
        let type = s.st_mode & S_IFMT
        self.init(identity: FileID(s), modified: s.st_mtimespec, logicalBytes: s.st_size,
                  allocatedBytes: type == S_IFDIR ? 0 : Int64(s.st_blocks) * 512,
                  kind: type == S_IFDIR ? .directory : type == S_IFLNK ? .link : .file,
                  multiLink: type != S_IFDIR && s.st_nlink > 1)
    }
}

struct DirectoryMember {
    let name: String
    let metadata: FileMetadata?
}

/// The same buffer serves every directory in a scan. No file descriptors survive a listing.
final class DirectoryReader {
    private let capacity = 64 * 1024
    private let buffer: UnsafeMutableRawPointer
    private let common = UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME |
                         ATTR_CMN_MODTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID | ATTR_CMN_ERROR)
    private let file = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)

    init() { buffer = .allocate(byteCount: capacity, alignment: 8) }
    deinit { buffer.deallocate() }

    func members(at url: URL) throws -> [DirectoryMember] {
        let fd = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = common | attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrs.fileattr = file
        var members: [DirectoryMember] = []
        while true {
            try Task.checkCancellation()
            let count = getattrlistbulk(fd, &attrs, buffer, capacity, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count == 0 { return members }
            if count < 0 {
                if errno == EINTR { continue }
                // Some volumes cannot provide bulk attributes. Restart the whole listing
                // before visiting any children, so a partial batch cannot duplicate a file.
                return try namesOnly(url)
            }
            var offset = 0
            for _ in 0..<count {
                let remaining = capacity - offset
                guard remaining >= 4 else { return try namesOnly(url) }
                let record = UnsafeRawPointer(buffer + offset)
                let length = Int(record.loadUnaligned(as: UInt32.self))
                guard length >= 4, length <= remaining,
                      let member = decode(record, length: length) else { return try namesOnly(url) }
                members.append(member)
                offset += length
            }
        }
    }

    private func namesOnly(_ url: URL) throws -> [DirectoryMember] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).map { DirectoryMember(name: $0, metadata: nil) }
    }

    private func decode(_ record: UnsafeRawPointer, length: Int) -> DirectoryMember? {
        // Darwin packs fields on 4-byte boundaries, including 64-bit times and sizes.
        // RETURNED_ATTRS and ERROR precede all other fields, then bitmap order applies.
        var cursor = 4
        func read<T>(_ t: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard cursor + size <= length else { return nil }
            defer { cursor += size }
            return record.loadUnaligned(fromByteOffset: cursor, as: t)
        }
        guard let valid = read(attribute_set_t.self), let error = read(UInt32.self) else { return nil }
        let nameOffset = cursor
        guard valid.commonattr & UInt32(ATTR_CMN_NAME) != 0, let ref = read(attrreference_t.self) else { return nil }
        let start = nameOffset + Int(ref.attr_dataoffset), size = Int(ref.attr_length)
        guard start >= cursor, size > 1, start + size <= length else { return nil }
        let chars = UnsafeRawBufferPointer(start: record + start, count: size - 1)
        guard let name = String(bytes: chars, encoding: .utf8) else { return nil }
        let fallback = DirectoryMember(name: name, metadata: nil)
        guard error == 0, valid.commonattr & common == common, valid.fileattr & file == file,
              let device = read(dev_t.self), let type = read(UInt32.self), type == VREG.rawValue,
              let birth = read(timespec.self), let modified = read(timespec.self),
              let flags = read(UInt32.self), flags & UInt32(UF_COMPRESSED) == 0,
              let inode = read(ino_t.self), let links = read(UInt32.self),
              let allocated = read(Int64.self), let logical = read(Int64.self) else { return fallback }
        // Directories (including firmlinks and mounts), symlinks, special files and
        // compressed files use lstat to retain the same identity and size semantics.
        let info = FileMetadata(identity: FileID(device: device, inode: inode, birth: birth),
                                modified: modified, logicalBytes: logical, allocatedBytes: allocated,
                                kind: .file, multiLink: links > 1)
        return DirectoryMember(name: name, metadata: info)
    }
}
