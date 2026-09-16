// Minimal reproducer for a SIGSEGV observed inside Foundation's current-directory
// accessor on Swift 6.4 / Linux.
//
// Observed in the wild as:
//
//   *** Program crashed: Bad pointer dereference at 0x0000000000000023 ***
//   Thread 1 "DispatchWorker" crashed:
//    0  _FileManagerImpl.linkItem(at:to:)                in libFoundationEssentials.so
//    1  FileManager.createSymbolicLink(at:withDestinationURL:)
//    2  FileManager.linkItem(at:to:)
//    3  LocalFileSystem.currentWorkingDirectory.getter   in swift-tools-support-core
//
// Frame 3 is `FileManager.default.currentDirectoryPath`; the Foundation frames
// above it are most likely nearest-symbol misattribution in the stripped .so.
//
// Each scenario is meant to be run as its own process (see scripts/run-probes.sh)
// so that a crash in one does not hide the results of the others.

import Foundation
import Dispatch

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Output
//
// Logging goes through stderr with an explicit flush rather than through
// Foundation, so that the last line before a segfault is never lost in a buffer
// and so that the logging path itself is not part of what is under test.

func log(_ message: String) {
    fputs(message + "\n", stderr)
    fflush(stderr)
}

// MARK: - The call under test

func readCurrentDirectoryPath(_ tag: String) {
    log("  [\(tag)] calling FileManager.default.currentDirectoryPath ...")
    let cwd = FileManager.default.currentDirectoryPath
    log("  [\(tag)] returned \"\(cwd)\" (\(cwd.utf8.count) bytes)")
}

/// The raw syscall, for comparison: if `getcwd` reports a failure here but
/// Foundation crashes instead of returning empty, the bug is Foundation's
/// handling of that failure.
func readRawGetcwd(_ tag: String) {
    var buffer = [CChar](repeating: 0, count: 4096)
    if getcwd(&buffer, buffer.count) == nil {
        log("  [\(tag)] getcwd() failed, errno=\(errno)")
    } else {
        log("  [\(tag)] getcwd() returned \"\(String(cString: buffer))\"")
    }
}

/// Replicates swift-tools-support-core's `LocalFileSystem.currentWorkingDirectory`
/// *exactly*, which is what the crashing call site actually ran. Reading
/// `currentDirectoryPath` is only its first line; on a platform without the ObjC
/// runtime it then takes a `fileSystemRepresentation`, reads through it, and
/// deallocates it by hand:
///
///     let cwdStr = FileManager.default.currentDirectoryPath
///     guard !cwdStr.isEmpty else { return nil }
///     let fsr: UnsafePointer<Int8> = cwdStr.fileSystemRepresentation
///     defer { fsr.deallocate() }
///     return try? AbsolutePath(validating: String(cString: fsr))
///
/// That allocate/read/free sequence is the part worth suspecting: it is manual
/// memory management against an ownership contract (corelibs-foundation returns
/// an owned pointer that the caller frees), and Swift 6.4 moved Linux Foundation
/// onto the swift-foundation rewrite underneath it.
func tscCurrentWorkingDirectory(_ tag: String) {
    let cwdStr = FileManager.default.currentDirectoryPath
    log("  [\(tag)] currentDirectoryPath == \"\(cwdStr)\" (\(cwdStr.utf8.count) bytes)")

    guard !cwdStr.isEmpty else {
        log("  [\(tag)] empty; TSC returns nil without going any further")
        return
    }

#if _runtime(_ObjC)
    log("  [\(tag)] ObjC runtime: TSC validates the String directly, no manual free")
    _ = cwdStr.count
#else
    log("  [\(tag)] taking fileSystemRepresentation ...")
    let fsr: UnsafePointer<Int8> = cwdStr.fileSystemRepresentation
    defer {
        log("  [\(tag)] deallocating the fileSystemRepresentation ...")
        fsr.deallocate()
    }
    let roundTripped = String(cString: fsr)
    log("  [\(tag)] round-tripped \"\(roundTripped)\"")
#endif
}

/// The same allocate/read/free cycle, repeated. A mismatched ownership contract
/// corrupts the heap rather than faulting on the spot, so a single pass can look
/// perfectly healthy while the same code in a long-lived process does not.
func fileSystemRepresentationLoop(_ tag: String, iterations: Int) {
    let cwdStr = FileManager.default.currentDirectoryPath
    guard !cwdStr.isEmpty else {
        log("  [\(tag)] empty current directory; nothing to do")
        return
    }

    var ballast: [[UInt8]] = []
    for iteration in 0 ..< iterations {
#if _runtime(_ObjC)
        // Darwin exposes this on NSString, and the pointer is autoreleased
        // rather than owned, so it must not be freed here.
        _ = (cwdStr as NSString).fileSystemRepresentation
#else
        let fsr: UnsafePointer<Int8> = cwdStr.fileSystemRepresentation
        _ = String(cString: fsr)
        fsr.deallocate()
#endif
        // Interleave unrelated allocations, so that a bad free has something to
        // damage and the damage has a chance to surface.
        if iteration % 64 == 0 {
            ballast.append([UInt8](repeating: 0xAB, count: 4096))
            if ballast.count > 32 { ballast.removeFirst() }
        }
    }
    log("  [\(tag)] completed \(iterations) fileSystemRepresentation cycles")
}

/// Builds a directory as deeply nested as the platform allows and moves into it,
/// so the path is long enough to push the conversion past any small fixed-size
/// buffer. PATH_MAX differs by platform (1024 on Darwin, 4096 on Linux), so this
/// grows until the filesystem says no rather than assuming a depth.
@discardableResult
func changeIntoDeeplyNestedDirectory(maximumLevels: Int = 128) -> String {
    var path = "/tmp/curdir-probe-deep-\(getpid())"
    guard mkdir(path, 0o755) == 0 else {
        log("  mkdir(\(path)) failed, errno=\(errno)")
        exit(70)
    }

    for level in 0 ..< maximumLevels {
        let candidate = path + "/level-\(level)-padding-padding-padding"
        if mkdir(candidate, 0o755) != 0 {
            // ENAMETOOLONG just means this platform's ceiling has been reached,
            // which is exactly the depth wanted; anything else is a real problem.
            if errno == ENAMETOOLONG { break }
            log("  mkdir at level \(level) failed, errno=\(errno)")
            exit(70)
        }
        path = candidate
    }

    guard chdir(path) == 0 else {
        log("  chdir into the nested path failed, errno=\(errno)")
        exit(70)
    }
    log("  working directory is now a \(path.utf8.count)-byte path")
    return path
}

// MARK: - Environment manipulation

/// Creates a scratch directory and makes it the process working directory,
/// mirroring how swift-build runs a custom task with `cd <dependency checkout>`.
@discardableResult
func changeIntoScratchDirectory() -> String {
    let path = "/tmp/curdir-probe-\(getpid())-\(UInt32.random(in: 0 ..< .max))"
    guard mkdir(path, 0o755) == 0 else {
        log("  mkdir(\(path)) failed, errno=\(errno)")
        exit(70)
    }
    guard chdir(path) == 0 else {
        log("  chdir(\(path)) failed, errno=\(errno)")
        exit(70)
    }
    log("  working directory is now \(path)")
    return path
}

/// Removes the directory the process is currently sitting in. `getcwd` is then
/// expected to fail with ENOENT, which is the classic way to get a null pointer
/// back from the underlying C call.
func removeCurrentDirectory(_ path: String) {
    guard rmdir(path) == 0 else {
        log("  rmdir(\(path)) failed, errno=\(errno)")
        exit(70)
    }
    log("  removed the working directory while it is still the cwd")
}

// MARK: - Thread contexts
//
// The crash was reported on a thread named "DispatchWorker" underneath an async
// call, so the same read is exercised from the main thread, from a Dispatch
// worker, and from a detached Task.

func onDispatchWorker(_ body: @escaping () -> Void) {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        body()
        done.signal()
    }
    done.wait()
}

func inDetachedTask(_ body: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        body()
        done.signal()
    }
    done.wait()
}

func concurrentReads(count: Int) {
    let group = DispatchGroup()
    for _ in 0 ..< count {
        DispatchQueue.global().async(group: group) {
            _ = FileManager.default.currentDirectoryPath
        }
    }
    group.wait()
    log("  [concurrent] \(count) concurrent reads completed")
}

// MARK: - Scenarios

let scenarios = [
    "main-thread",
    "dispatch-thread",
    "task",
    "chdir",
    "chdir-dispatch",
    "chdir-task",
    "deleted",
    "deleted-dispatch",
    "deleted-task",
    "concurrent",
    "getcwd",
    "tsc-exact",
    "tsc-exact-dispatch",
    "tsc-exact-task",
    "tsc-exact-chdir",
    "tsc-exact-deep-cwd",
    "fsr-loop",
    "fsr-loop-dispatch",
    "fsr-loop-concurrent",
]

func usage() -> Never {
    log("usage: curdir-probe <scenario>")
    log("scenarios: \(scenarios.joined(separator: ", "))")
    exit(64)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else { usage() }
let scenario = arguments[1]

if scenario == "--list" {
    print(scenarios.joined(separator: "\n"))
    exit(0)
}
guard scenarios.contains(scenario) else { usage() }

#if canImport(Musl)
let libc = "musl"
#elseif canImport(Glibc)
let libc = "glibc"
#else
let libc = "darwin"
#endif
log("scenario \(scenario) [libc: \(libc), PWD env: \(ProcessInfo.processInfo.environment["PWD"] ?? "<unset>")]")

switch scenario {
case "main-thread":
    readCurrentDirectoryPath("main")

case "dispatch-thread":
    onDispatchWorker { readCurrentDirectoryPath("dispatch") }

case "task":
    inDetachedTask { readCurrentDirectoryPath("task") }

case "chdir":
    changeIntoScratchDirectory()
    readCurrentDirectoryPath("main")

case "chdir-dispatch":
    changeIntoScratchDirectory()
    onDispatchWorker { readCurrentDirectoryPath("dispatch") }

case "chdir-task":
    changeIntoScratchDirectory()
    inDetachedTask { readCurrentDirectoryPath("task") }

case "deleted":
    let path = changeIntoScratchDirectory()
    removeCurrentDirectory(path)
    readRawGetcwd("main")
    readCurrentDirectoryPath("main")

case "deleted-dispatch":
    let path = changeIntoScratchDirectory()
    removeCurrentDirectory(path)
    onDispatchWorker {
        readRawGetcwd("dispatch")
        readCurrentDirectoryPath("dispatch")
    }

case "deleted-task":
    let path = changeIntoScratchDirectory()
    removeCurrentDirectory(path)
    inDetachedTask {
        readRawGetcwd("task")
        readCurrentDirectoryPath("task")
    }

case "concurrent":
    concurrentReads(count: 64)

case "getcwd":
    readRawGetcwd("main")

case "tsc-exact":
    tscCurrentWorkingDirectory("main")

case "tsc-exact-dispatch":
    onDispatchWorker { tscCurrentWorkingDirectory("dispatch") }

case "tsc-exact-task":
    inDetachedTask { tscCurrentWorkingDirectory("task") }

case "tsc-exact-chdir":
    changeIntoScratchDirectory()
    onDispatchWorker { tscCurrentWorkingDirectory("dispatch") }

case "tsc-exact-deep-cwd":
    changeIntoDeeplyNestedDirectory()
    onDispatchWorker { tscCurrentWorkingDirectory("dispatch") }

case "fsr-loop":
    fileSystemRepresentationLoop("main", iterations: 20_000)

case "fsr-loop-dispatch":
    onDispatchWorker { fileSystemRepresentationLoop("dispatch", iterations: 20_000) }

case "fsr-loop-concurrent":
    let group = DispatchGroup()
    for worker in 0 ..< 8 {
        DispatchQueue.global().async(group: group) {
            fileSystemRepresentationLoop("worker-\(worker)", iterations: 5_000)
        }
    }
    group.wait()

default:
    usage()
}

log("scenario \(scenario) completed without crashing")
exit(0)
