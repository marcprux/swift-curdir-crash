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

default:
    usage()
}

log("scenario \(scenario) completed without crashing")
exit(0)
