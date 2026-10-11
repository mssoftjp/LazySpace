import Darwin
import Foundation

/// A per-launch capability shared with CLI processes owned by this user.
/// The application support directory and the credential file must not be writable/readable by other users.
enum ControlCredential {
    private static let filename = "control-credential"
    private static let byteCount = 32

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes.withUnsafeMutableBytes { buffer in arc4random_buf(buffer.baseAddress, buffer.count) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ supplied: String, _ expected: String) -> Bool {
        let lhs = Array(supplied.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == byteCount * 2, rhs.count == byteCount * 2 else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    /// Deny entries cannot grant access. Refuse every allow or unknown entry rather
    /// than attempting to resolve ACL principals and effective permissions here.
    private static func hasNoGrantingACL(_ fd: Int32) -> Bool {
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            var index = ACL_FIRST_ENTRY.rawValue
            while acl_get_entry(acl, index, &entry) == 0 {
                guard let entry else { return false }
                var tag = ACL_UNDEFINED_TAG
                guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else { return false }
                index = ACL_NEXT_ENTRY.rawValue
            }
            return errno == EINVAL
        }
        return errno == ENOENT
    }

    private static func directory(_ root: URL) -> Int32? {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (info.st_mode & 0o022) == 0,
              hasNoGrantingACL(fd) else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Publish only after the server port has been created. An atomic replacement removes stale credentials.
    static func publish(_ credential: String, root: URL) -> Bool {
        guard credential.utf8.count == byteCount * 2, let dir = directory(root) else { return false }
        defer { close(dir) }
        let temporary = "\(filename).\(UUID().uuidString).tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var saved = false
        defer {
            close(fd)
            if !saved { _ = unlinkat(dir, temporary, 0) }
        }
        guard fchmod(fd, 0o600) == 0, hasNoGrantingACL(fd) else { return false }
        let bytes = Array(credential.utf8)
        let count = bytes.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return -1 }
                offset += written
            }
            return offset
        }
        guard count == bytes.count, fsync(fd) == 0,
              renameat(dir, temporary, dir, filename) == 0 else { return false }
        saved = true
        return true
    }

    static func read(root: URL) -> String? {
        guard let dir = directory(root) else { return nil }
        defer { close(dir) }
        let fd = openat(dir, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (info.st_mode & 0o077) == 0,
              info.st_size == byteCount * 2,
              hasNoGrantingACL(fd) else { return nil }
        var bytes = [UInt8](repeating: 0, count: byteCount * 2)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let received = Darwin.read(fd, base.advanced(by: offset), buffer.count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { return -1 }
                offset += received
            }
            return offset
        }
        guard count == bytes.count,
              bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Used only to choose a useful CLI error when the control port does not answer.
    /// The diagnostic deliberately does not require a private directory: unsafe
    /// permissions are one reason the running app may have refused to publish a port.
    static func instanceLockIsHeld(root: URL) -> Bool {
        let dir = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return false }
        defer { close(dir) }
        var directoryInfo = stat()
        guard fstat(dir, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return false }
        let lock = openat(dir, "instance.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0,
              lockInfo.st_uid == geteuid(),
              (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return false }
        if flock(lock, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(lock, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
