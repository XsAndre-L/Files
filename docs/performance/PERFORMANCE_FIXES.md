# Performance Fixes — Files App

This document describes the root-cause performance issues identified and fixed in the Files app to address system-wide CPU and Disk I/O exhaustion.

> **Diagnosis:** RAM was stable at <500MB. The system-wide slowdown (other apps affected) was caused by Disk I/O flooding and CPU exhaustion from background services accumulating over time.

## Fixed Issues

### Fix 1 — Date display timer: 1s → 30s interval + batched dispatches
**File:** `src/Files.App/Views/Shells/BaseShellPage.cs`  
**Impact:** CPU 🔥  
The timer fired every second and dispatched 3 individual `EnqueueOrInvokeAsync` calls per recently-modified file using `AsParallel().ForAll()`. With N tabs open this was N × files × 3 thread-pool dispatches per second. Changed to 30-second interval.

### Fix 2 — Git watcher: bWatchSubtree true → false
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `WatchForGitChanges()`  
**Impact:** Disk I/O 🔥  
`ReadDirectoryChangesW` was called with `bWatchSubtree = true` on `.git/`, causing the kernel to deliver I/O events for every object write, pack compaction, ref update — nearly continuous on a dev machine. Changed to `false`.

### Fix 3 — File change → full re-scan: added 500ms debounce
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `DirectoryWatcher_Changed()`  
**Impact:** Disk I/O + CPU 🔥  
Every FSW event immediately triggered `RefreshItems(null)` — a full folder re-enumeration. In busy folders (Downloads, build output) this was continuous. Added 500ms CancellationToken debounce.

### Fix 4 — Sidebar: Section_PropertyChanged event accumulation
**File:** `src/Files.App/ViewModels/UserControls/SidebarViewModel.cs`  
**Impact:** CPU 🔥  
`AddElementToSectionAsync` subscribed `Section_PropertyChanged` once per element with no prior unsubscribe. `Dispose()` never cleaned these up. Added unsubscribe-before-subscribe guard and Dispose cleanup.

### Fix 5 — Git fetch: added 5-minute per-repo cooldown
**File:** `src/Files.App/Views/Shells/BaseShellPage.cs`  
**Impact:** Network + Disk I/O  
`FilesystemViewModel_DirectoryInfoUpdated` called `GitHelpers.FetchOrigin()` (live HTTP network request) on every folder load with no cooldown. Added per-repo `Dictionary<string, DateTimeOffset>` tracking last fetch time with 5-minute minimum interval.

### Fix 6 — Folder size calculator: fixed broken cancellation
**File:** `src/Files.App/Services/SizeProvider/CachedSizeProvider.cs`  
**Impact:** Disk I/O  
Recursive `Calculate()` only checked cancellationToken at the outermost level. Inner recursive calls could not be cancelled. Added token check at top of every recursive call, max depth of 10, and a SemaphoreSlim(1,1) to serialise concurrent walks.

### Fix 7 — FileSystemWatcher: disposal race on navigation
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `WatchForWin32FolderChanges()`  
**Impact:** Disk I/O  
Race condition caused old watchers to survive navigation, continuously calling `RefreshItems(null)`. Added explicit `watcher?.Dispose(); watcher = null;` before creating a new watcher.

### Fix 8 — Git watcher: duplicate IAsyncAction guard
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `WatchForGitChanges()`  
**Impact:** Thread pool + Disk I/O  
`WatchForGitChanges()` created a new `IAsyncAction` unconditionally on every navigation. Added `??=` guard to prevent duplicate git watcher threads.

### Fix 9 — Thumbnail semaphore: raised from (1,1) to (4,4)
**File:** `src/Files.App/ViewModels/ShellViewModel.cs`  
**Impact:** Disk I/O + Thread pool  
`SemaphoreSlim(1,1)` caused 500 items to queue 500 waiting thread pool tasks. Raised to `(4,4)` for better throughput.

## Verification

1. Open 3+ tabs, navigate rapidly for 5 minutes
2. **Task Manager → Performance → Disk** — should drop to near zero when idle
3. **Resource Monitor → CPU** — Files.App should stay <5% CPU when idle
4. Navigate to a git repo — no network spike on every navigation
5. Leave in background 10 min — near-zero CPU

## Related Files

- `sideloading/INSTALL.md` — How to build and install the dev build
- `src/Files.App/ViewModels/ShellViewModel.cs` — Core directory/watcher ViewModel
- `src/Files.App/Views/Shells/BaseShellPage.cs` — Shell page base with timer and git fetch
- `src/Files.App/Services/SizeProvider/CachedSizeProvider.cs` — Folder size calculation
