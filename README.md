# swift-curdir-crash

A minimal reproducer for a SIGSEGV observed inside Foundation's current-directory
accessor on Swift 6.4 / Linux.

## The crash being chased

A Swift command-line tool built with Swift 6.4 on Linux crashed while a build
system invoked it as a subprocess:

```
*** Program crashed: Bad pointer dereference at 0x0000000000000023 ***
Thread 1 "DispatchWorker" crashed:
 0  _FileManagerImpl.linkItem(at:to:)                in libFoundationEssentials.so
 1  FileManager.createSymbolicLink(at:withDestinationURL:)
 2  FileManager.linkItem(at:to:)
 3  LocalFileSystem.currentWorkingDirectory.getter   in swift-tools-support-core
```

Frame 3 is `swift-tools-support-core`'s `LocalFileSystem.currentWorkingDirectory`,
which is nothing more than:

```swift
let cwdStr = FileManager.default.currentDirectoryPath
```

The Foundation frames above it name symbols that accessor does not call, so they
are most likely nearest-symbol misattribution inside the stripped shared library.

The same binary did not crash when the tool was invoked by a different build
system, and a build of the same tool with Swift 6.3.3 did not crash under either.
That leaves two candidate variables, which is what this repository exists to
separate: the **Swift version** (6.4 moved Linux Foundation onto the
swift-foundation rewrite) and the **state of the working directory** at the
moment of the call.

## What it probes

`curdir-probe` reads `FileManager.default.currentDirectoryPath` under a range of
conditions, one scenario per invocation:

| Scenario | What it covers |
| --- | --- |
| `main-thread` | The plain case, on the main thread. |
| `dispatch-thread` | From a Dispatch worker — the crashing thread was named `DispatchWorker`. |
| `task` | From a detached `Task`, as the real caller was in an async context. |
| `chdir`, `chdir-dispatch`, `chdir-task` | After `chdir` into a fresh directory, mirroring a build system running a task with `cd <some checkout>`. |
| `deleted`, `deleted-dispatch`, `deleted-task` | After the working directory has been removed, so that `getcwd` fails and returns null. |
| `concurrent` | 64 simultaneous reads, to rule the accessor's thread-safety in or out. |
| `getcwd` | The raw syscall, with no Foundation involved, as a control. |
| `tsc-exact`, `tsc-exact-dispatch`, `tsc-exact-task`, `tsc-exact-chdir` | The **whole** TSC function, not just its first line — see below. |
| `tsc-exact-deep-cwd` | The same, from a working directory as deep as the platform allows, to push the conversion past any small fixed-size buffer. |
| `fsr-loop`, `fsr-loop-dispatch`, `fsr-loop-concurrent` | Thousands of allocate/read/free cycles, interleaved with unrelated allocations. A mismatched ownership contract corrupts the heap rather than faulting on the spot. |

### Why `currentDirectoryPath` alone is not the whole story

The first pass of this reproducer probed only
`FileManager.default.currentDirectoryPath` and found nothing across eight
Swift-version / libc / build-system combinations. That is because on a platform
without the ObjC runtime — every Linux cell — TSC's accessor does three more
things after that first line:

```swift
let cwdStr = FileManager.default.currentDirectoryPath
guard !cwdStr.isEmpty else { return nil }
let fsr: UnsafePointer<Int8> = cwdStr.fileSystemRepresentation  // allocates
defer { fsr.deallocate() }                                      // frees, by hand
return try? AbsolutePath(validating: String(cString: fsr))      // reads through it
```

`fileSystemRepresentation` is manual memory management against an ownership
contract: swift-corelibs-foundation returns an *owned* pointer that the caller is
expected to free, which is why TSC deallocates it, while on Darwin the same-named
API is on `NSString` and returns an autoreleased pointer that must not be freed.
Swift 6.4 moved Linux Foundation onto the swift-foundation rewrite underneath
that API. A free of a pointer that is no longer owned corrupts the heap instead
of faulting immediately, which fits both the reported symptom (a bad pointer
dereference at a small bogus address) and the fact that it reproduces in a large,
long-lived tool but not in a short probe.

The `deleted-*` scenarios also call `getcwd` directly first, so the output shows
what the C library reported immediately before Foundation was asked the same
question. If `getcwd` fails and Foundation crashes rather than returning an empty
string, the bug is in Foundation's handling of that failure.

Each scenario runs in its own process, so a crash in one cannot hide the rest.

## Running it

```bash
swift build
scripts/run-probes.sh "$(swift build --show-bin-path)/curdir-probe"
```

The runner prints a table and exits 0 even when scenarios crash, because the
point is to collect a full set of results. Set `FAIL_ON_CRASH=1` to make a crash
fail the run.

## CI

`.github/workflows/ci.yml` runs the probes on `ubuntu-24.04` across eight cells:

- **Swift 6.3.3 and 6.4.0**, installed with swiftly.
- **glibc and musl**: the glibc cells build normally and link Foundation
  dynamically; the musl cells build through the static-linux Swift SDK and link it
  statically. Cross-compiling `x86_64-swift-linux-musl` on an x86_64 Linux host
  produces a binary that runs natively, so every cell runs what it builds.
- **native and swiftbuild**: the binary that crashed was produced by swiftbuild,
  which became the default in 6.4, while 6.3 used native. The two engines emit
  different link lines, so the same source can yield different binaries.

Each of the four build-system/flavour layouts puts the product somewhere
different — `debug`, `x86_64-swift-linux-musl/debug`, `out/Products/Debug` and
`out/Products/Debug-staticlinux-x86_64` — so the workflow asks SwiftPM for the
location with `--show-bin-path` and identical build flags rather than assuming
a path.

Each cell writes its result table to the job summary, so the eight cells can be
compared directly. A cell that fails to build records a row saying so, rather
than silently dropping out of the grid.

The musl SDK is downloaded with `curl` and installed from the local file:
`swift sdk install <url>` refuses a remote bundle unless it is given a
`--checksum`, and swift.org does not publish one next to the download, but the
same command accepts a local path without one.

Note when running the musl builds locally: `--swift-sdk x86_64-swift-linux-musl`
selects by triple, so it fails outright if more than one static-linux SDK is
installed —

    error: The query for `x86_64-swift-linux-musl` and host triple `...` matched
    multiple SDKs: swift-6.3.3-RELEASE_static-linux-0.1.0,
    swift-6.4.0-RELEASE_static-linux-0.1.0

A CI runner installs exactly one, so this only bites on a development machine
that has accumulated several.

## Reference

The crash was first seen in skiptools/skip-fuse CI while building a Fuse package
graph with the `swiftbuild` build system on Swift 6.4, where the `skipstone`
plugin binary segfaulted at `SkipstoneCommand.swift:92`.
