import Darwin
import Foundation

func openLog(_ url: URL) throws -> FileHandle {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
        close(descriptor)
        throw POSIXError(.EINVAL)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

func readLog(_ url: URL, size: Int, consume: (Data) -> Void) throws {
    let file = try openLog(url)
    let maximumLineSize = 8 * 1024 * 1024
    var remaining = size
    var pending = Data()
    var discardingLine = false

    while remaining > 0, let chunk = try file.read(upToCount: min(remaining, 256 * 1024)), !chunk.isEmpty {
        remaining -= chunk.count
        var start = chunk.startIndex
        while let end = chunk[start...].firstIndex(of: 10) {
            let part = chunk[start..<end]
            if !discardingLine && pending.count + part.count <= maximumLineSize {
                if pending.isEmpty {
                    consume(part)
                } else {
                    pending.append(part)
                    consume(pending)
                }
            }
            pending.removeAll(keepingCapacity: true)
            discardingLine = false
            start = end + 1
        }
        if !discardingLine && pending.count + chunk.endIndex - start <= maximumLineSize {
            pending.append(chunk[start...])
        } else {
            pending.removeAll(keepingCapacity: true)
            discardingLine = true
        }
    }
    if !discardingLine && !pending.isEmpty { consume(pending) }
}

func timestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        ?? (try? Date.ISO8601FormatStyle().parse(value))
}
