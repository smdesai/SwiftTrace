import Foundation
#if SWIFT_PACKAGE
import SwiftTraceGuts
#endif

extension SwiftTrace {
    private static var fileIndex: Int = 0
    private static var fileSize: Int = 0
    private static var fd: Int32 = 0
    private static var map: UnsafeMutableRawPointer?
    private static var pageSize = 100 * 4096
    private static var traceDirPath: String = ""
    private static var traceFile: String = ""
    private static var semaphore = DispatchSemaphore(value: 1)
    public static var logActualParam: Bool = false


    @objc open class func trace(using file: String, at path: String, logParam: Bool = false) {
        traceDirPath = path == nil ? "" : path + "/"
        traceFile = file
        logActualParam = logParam
        fileIndex = lastUsedIndex(dir: path, file: file) + 1

        let path = String(format: "%@%@.%04d", traceDirPath, traceFile, fileIndex)
        fd = openTrace(file: path)
    }

    class func openTrace(file: String)  -> Int32 {
        fileSize = 0
        fd = open(file, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd != -1 else {
            print("\(#function): unable to open file for write: \(String(describing: strerror(errno)))")
            return -1
        }

        var sbuf: stat = stat()
        guard stat(file, &sbuf) != -1 else {
            close(fd)
            print("\(#function): stat failed: \(String(describing: strerror(errno)))")
            return -1
        }

        fileSize = Int(sbuf.st_size)
        map = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard map != MAP_FAILED else {
            close(fd)
            print("\(#function): mmap failed: \(String(describing: strerror(errno)))")
            return -1
        }

        guard ftruncate(fd, off_t(pageSize)) != -1 else {
            close(fd);
            print("\(#function): ftruncate failed: \(strerror(errno))")
            return -1
        }
        write(fd, "", 1)

        return fd
    }

    class func lastUsedIndex(dir: String, file: String) -> Int {
        var maxIndex = 0
        let dirEnum = FileManager.default.enumerator(atPath: dir)
        while let name = dirEnum?.nextObject() as? String {
            if name.starts(with: file) {
                let s = name.suffix(4)
                maxIndex = max(Int(s) ?? 0, maxIndex)
            }
        }
        if maxIndex == 9999 {
            removeAllTraceFiles(prefix: file)
            maxIndex = 0
        }
        return maxIndex
    }
    
    class func removeAllTraceFiles(prefix: String) {
        let fileManager = FileManager.default
        do {
            let filePaths = try fileManager.contentsOfDirectory(atPath: traceDirPath)
            for filePath in filePaths {
                if filePath.starts(with: prefix) {
                    try fileManager.removeItem(atPath: traceDirPath + filePath)
                }
            }
        } catch {
            print("\(#function): could not clear trace files: \(error)")
        }
    }

    @objc open class func closeTrace() {
        semaphore.wait()
        msync(map, Int(fd), MS_SYNC)
        if munmap(map, fileSize) == -1 {
            print("\(#function): munmap failed: \(String(describing: strerror(errno)))")
        }
        close(fd)
        fd = -1
        semaphore.signal()
    }

    class func addEntry(entry: String) {
        guard fd != -1 else {
            return
        }
        semaphore.wait()
        if fileSize + entry.count < pageSize {
            memcpy(map! + fileSize, entry.cString(using: String.Encoding.utf8), entry.count)
            fileSize += entry.count
            semaphore.signal()
        } else {
            msync(map, Int(fd), MS_SYNC)
            if munmap(map, fileSize) == -1 {
                print("\(#function): munmap failed: \(String(describing: strerror(errno)))")
            }
            close(fd)
            fileIndex += 1
            let path = String(format: "%@%@.%04d", traceDirPath, traceFile, fileIndex)
            fd = openTrace(file: path)
            semaphore.signal()
            if fd != -1 {
                addEntry(entry: entry)
            }
        }
    }
    
    open class func addTrace(time: Int64, threadId: String, depth: Int, method: String) {
        let data = String(format: "%ld,%@,%d,%@\n", time, threadId, depth, method)
        addEntry(entry: data)
    }

    open class func updateLastElapsed(elapsed: Int, threadId: String) {
        let data = String(format: "@,%@,%ld\n", threadId, elapsed)
        addEntry(entry: data)
    }
}
