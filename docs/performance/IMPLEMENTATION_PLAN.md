# Files App — Full Performance Improvement Plan

> **Context:** RAM stable at <500MB — not the issue. System-wide slowdown is caused by **Disk I/O flooding** and **CPU exhaustion** from background services that accumulate or run unthrottled. Gets progressively worse over time.
>
> **Sources:** 3-agent full codebase audit (ShellViewModel, BaseShellPage, SidebarViewModel, Services, Git utils, Filesystem, XAML, DI)

---

## 🔴 CRITICAL — Implement first (direct cause of system-wide slowdown)

### Fix 1 — 1-second timer dispatching N×3 UI updates per item, per tab
**File:** `src/Files.App/Views/Shells/BaseShellPage.cs:197`  
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `UpdateDateDisplay()`  
**Resource:** CPU 🔥

Every second, for every recently-modified file, 3 individual `EnqueueOrInvokeAsync` calls fire. With `AsParallel().ForAll()` this floods the thread pool. N tabs = N timers × N files × 3 dispatches/second.

**Fix:**
- Change timer interval: `TimeSpan.FromSeconds(1)` → `TimeSpan.FromSeconds(30)`
- Batch all dispatcher enqueues into one call per update cycle
- Only dispatch when the formatted string would actually change

---

### Fix 2 — Git watcher recursively watching entire `.git/` tree
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:2395` — `WatchForGitChanges()`  
**Resource:** Disk I/O 🔥

`ReadDirectoryChangesW` called with `bWatchSubtree = true` on `.git/`. Every git object write, pack compaction, ref update — including from other terminal windows — wakes this watcher. Nearly continuous on a dev machine.

**Fix:**
- Change line 2395: `bWatchSubtree: true` → `false`
- Only the top-level `.git/` dir matters (HEAD, index, FETCH_HEAD)

---

### Fix 3 — Any file change → full folder re-scan with zero debounce
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:2223` — `DirectoryWatcher_Changed()`  
**Resource:** Disk I/O + CPU 🔥

Every FSW event immediately calls `RefreshItems(null)` — complete folder re-enumeration. In busy folders (Downloads, build output) this creates a continuous disk read loop. No batching at all (unlike the Win32 ReadDirectoryChangesW path which has proper queue + sampler).

**Fix:**
- Add 500ms debounce before calling `RefreshItems` in `DirectoryWatcher_Changed`
- Use the same `operationQueue` batching already in `ProcessOperationQueueAsync`

---

### Fix 4 — Sidebar subscribes `Section_PropertyChanged` N times, never removes it
**File:** `src/Files.App/ViewModels/UserControls/SidebarViewModel.cs:424`  
**Resource:** CPU 🔥

`AddElementToSectionAsync` calls `section.PropertyChanged += Section_PropertyChanged` for every element added with no prior unsubscribe. 10 pinned folders = 10 duplicate handlers. `Dispose()` never cleans these. Every sidebar expand/collapse fires N handlers, each writing to `UserSettingsService`. Accumulates indefinitely.

**Fix:**
```csharp
// In AddElementToSectionAsync:
section.PropertyChanged -= Section_PropertyChanged;
section.PropertyChanged += Section_PropertyChanged;

// In Dispose():
foreach (var section in sidebarItems.OfType<LocationItem>())
    section.PropertyChanged -= Section_PropertyChanged;
```

---

### Fix 5 — Git diff opened per file item, unbounded parallelism, full commit graph walk per file
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:148, 1534`  
**File:** `src/Files.App/Utils/Git/GitHelpers.cs:639, 756`  
**Resource:** Disk I/O + CPU 🔥

Three compounding problems:
1. `EnabledGitProperties` setter fires N concurrent `Task.Run` tasks with no `SemaphoreSlim`
2. Each `LoadGitPropertiesAsync` opens `new Repository(repoPath)` — N times instead of once per directory
3. `GetLastCommitForFile()` iterates `repository.Commits` (entire commit graph) per file — O(commits) disk reads per file

**Fix:**
- Open `Repository` once per directory load, reuse for all items
- Add `SemaphoreSlim(4, 4)` limiting concurrent git property loads
- Replace `ForEach(async ...)` with `Parallel.ForEachAsync(..., new ParallelOptions { MaxDegreeOfParallelism = 4 })`
- Replace linear commits scan with `repository.Commits.QueryBy(path, new CommitFilter { FirstParentOnly = true }).FirstOrDefault()`
- Cache `IsRepositoryEx()` result with a 30-second TTL (currently re-walks ancestor dirs on every navigation)

---

### Fix 6 — Folder size calculator: recursive walk, broken cancellation, fire-and-forget
**File:** `src/Files.App/Services/SizeProvider/CachedSizeProvider.cs:23`  
**File:** `src/Files.App/Services/SizeProvider/DrivesSizeProvider.cs:37`  
**Resource:** Disk I/O 🔥

Four compounding problems:
1. Fully recursive `FindFirstFileExFromApp` walk, no depth limit
2. Cancellation **broken** — token only checked at outermost loop, inner recursive `Calculate()` calls can't be cancelled mid-subtree
3. Called as **fire-and-forget** — old calculations keep running after navigation
4. One `CachedSizeProvider` per drive, no shared concurrency cap — multiple tabs = multiple simultaneous recursive disk walks

**Fix:**
- Check `cancellationToken` at top of every `Calculate()` recursive call
- Replace fire-and-forget with a tracked `Task`, cancelled on navigation
- Add `SemaphoreSlim(1, 1)` per drive to serialise walks
- Add max recursion depth (e.g., 10)
- Cap `sizes` dictionary with LRU or count limit

---

## 🟠 HIGH — Implement next

### Fix 7 — Live `git fetch` (network call) on every folder navigation
**File:** `src/Files.App/Views/Shells/BaseShellPage.cs:248`  
**Resource:** Network + Disk I/O

`FilesystemViewModel_DirectoryInfoUpdated` fires multiple times per folder load and calls `GitHelpers.FetchOrigin()` — a real HTTP network request to GitHub — with no cooldown. Multiple git repo tabs = multiple concurrent fetches.

**Fix:**
- Add `Dictionary<string, DateTimeOffset> _lastFetchTime` per-repo, skip if under 5 minutes
- Or make git fetch fully opt-in only

---

### Fix 8 — `FileSystemWatcher` disposal race on rapid navigation
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:2203, 1759`  
**Resource:** Disk I/O

Race: if enumeration completes and calls `WatchForWin32FolderChanges()` after `CancelLoadAndClearFiles()` has run, `watcher` is overwritten without disposing the old one. Old watcher keeps firing `RefreshItems(null)` on an already-navigated-away folder.

**Fix:**
```csharp
// At top of WatchForWin32FolderChanges():
watcher?.Dispose();
watcher = null;
watcher = new FileSystemWatcher { ... };
```

---

### Fix 9 — Duplicate git watcher `IAsyncAction` created on every navigation
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:2257, 2374`  
**Resource:** Thread pool + Disk I/O

`ProcessOperationQueueAsync` is correctly guarded with `??=` but `WatchForGitChanges()` creates a new `IAsyncAction` **unconditionally** on every call. On rapid navigation, duplicate git watcher threads accumulate.

**Fix:**
- Add `gitWatcherAction ??=` guard matching the pattern used for `aProcessQueueAction`
- Add brief drain wait in `CloseWatcher()` before re-creating watchers

---

## 🟡 MEDIUM

### Fix 10 — 200ms poll loop per tab, runs even when nothing queued
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:2507`  
**Resource:** CPU

`ProcessOperationQueueAsync` wakes every 200ms on a `LongRunning` thread even with no changes. N tabs = N threads × 5 wakeups/second.

**Fix:**
- Replace `WaitAsync(200, token)` with `WaitAsync(token)` (no timeout)
- Signal queue drain via event signal instead of polling

---

### Fix 11 — `LibraryManager` FileSystemWatcher never disposed
**File:** `src/Files.App/Utils/Library/LibraryManager.cs:48, 442`  
**Resource:** Disk I/O

`Lazy<T>` singleton, `Dispose()` exists but never called. Kernel handle + IO completion port alive for app lifetime.

**Fix:**
- Call `LibraryManager.Default.Dispose()` on app suspend/close
- Post `OnLibraryChanged` work to dispatcher queue instead of inline COM calls on FSW event thread

---

### Fix 12 — `Diff.Compare` calls bypass git semaphore, run on UI thread
**File:** `src/Files.App/Utils/Git/GitHelpers.cs:69`  
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:1532`  
**Resource:** CPU

`GetRepositoryHead()` uses `GitOperationSemaphore(1,1)` but `GetGitInformationForItem()` runs on UI thread inside `dispatcherQueue.EnqueueOrInvokeAsync`, bypassing the semaphore. Expensive `Diff.Compare` calls run unconstrained.

**Fix:**
- Move git computation off UI thread; only dispatch UI updates back via dispatcher
- Apply `GitOperationSemaphore` to `GetGitInformationForItem` calls

---

### Fix 13 — `loadThumbnailSemaphore(1,1)` spawns 500 waiting thread pool tasks
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:575, 1163`  
**Resource:** Disk I/O + Thread pool

500 `Task.Run` calls for 500 items, all queued against `SemaphoreSlim(1,1)` — 499 thread pool slots wasted on waiting tasks.

**Fix:**
- Raise to `SemaphoreSlim(4, 4)`
- Batch items into groups of 32 instead of 500 individual tasks

---

### Fix 14 — `NavigationToolbarViewModel.Dispose()` — verify all static event unhooks
**File:** `src/Files.App/ViewModels/UserControls/NavigationToolbarViewModel.cs`  
**Resource:** CPU

Constructor subscribes to 7+ static/singleton service events. Need to confirm all are removed in `Dispose()`.

**Fix:**
- Audit `Dispose()` and add any missing `-=` unsubscriptions

---

## Verification Plan

1. Open 3 tabs, navigate folders rapidly for 5 minutes
2. **Task Manager → Performance → Disk** — I/O should drop to near zero when idle
3. **Resource Monitor → CPU** — Files.App should stay <5% CPU when idle
4. Navigate to a git repo — confirm no network spike
5. Leave app in background 10 minutes — confirm near-zero CPU usage
6. Release build → install via `sideloading/INSTALL.md`

---

## Files to Edit (implementation order)

| Priority | File | Fixes |
|----------|------|-------|
| 1 | `src/Files.App/Views/Shells/BaseShellPage.cs` | Fix 1 (timer interval), Fix 7 (git fetch cooldown) |
| 1 | `src/Files.App/ViewModels/ShellViewModel.cs` | Fix 1 (batch dispatches), Fix 2 (git watcher subtree), Fix 3 (debounce), Fix 5 (repo reuse + semaphore), Fix 8 (FSW race), Fix 9 (git watcher guard), Fix 10 (poll loop), Fix 13 (thumbnail batch) |
| 1 | `src/Files.App/ViewModels/UserControls/SidebarViewModel.cs` | Fix 4 (event leak) |
| 1 | `src/Files.App/Services/SizeProvider/CachedSizeProvider.cs` | Fix 6 (cancellation + depth) |
| 1 | `src/Files.App/Services/SizeProvider/DrivesSizeProvider.cs` | Fix 6 (semaphore + fire-and-forget) |
| 2 | `src/Files.App/Utils/Git/GitHelpers.cs` | Fix 5 (commit query), Fix 12 (semaphore) |
| 2 | `src/Files.App/Utils/Library/LibraryManager.cs` | Fix 11 (dispose) |
| 3 | `src/Files.App/ViewModels/UserControls/NavigationToolbarViewModel.cs` | Fix 14 (dispose audit) |

> **Context:** RAM is stable at <500MB. The root cause of system-wide slowdown is **Disk I/O flooding** and **CPU exhaustion** from background services that accumulate or run unthrottled. These get progressively worse the longer the app runs.

---

## 🔴 CRITICAL — Fix immediately (biggest system-wide impact)

### Fix 1 — 1-second date-display timer dispatching N×3 UI updates per item
**File:** `src/Files.App/Views/Shells/BaseShellPage.cs:197`  
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `UpdateDateDisplay()`  
**Resource:** CPU 🔥

Every second, for every file modified within the last 7 days, the app fires 3 individual `EnqueueOrInvokeAsync` dispatcher calls (ItemDateAccessed, ItemDateCreated, ItemDateModified). With `AsParallel().ForAll()` this floods the thread pool. With multiple tabs open, N timers fire N sets of updates per second.

**Fix:**
- Change timer interval from `1 second` → `30 seconds`
- Batch all dispatcher enqueues into a single call per update cycle
- Only dispatch when the formatted string would actually change (not on every tick)

---

### Fix 2 — Git watcher recursively watching entire `.git/` tree
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `WatchForGitChanges()` ~line 2395  
**Resource:** Disk I/O 🔥

`ReadDirectoryChangesW` is called with `bWatchSubtree = true` on the entire `.git/` directory. This wakes the watcher on every git operation system-wide — object writes, pack file compaction, ref updates — flooding the kernel I/O queue.

**Fix:**
- Change `bWatchSubtree = true` → `false`
- Only the top-level `.git/` directory needs watching for HEAD/ref pointer changes

---

### Fix 3 — File system change → full folder re-enumeration with no debounce
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `DirectoryWatcher_Changed()` ~line 2223  
**Resource:** Disk I/O + CPU 🔥

Every file created/deleted/renamed triggers a **complete re-enumeration** of the entire folder (`RefreshItems(null)`). In busy folders (Downloads, compiler output, package managers) this means the disk is being read continuously. There is zero debouncing or batching on this path.

**Fix:**
- Add a 500ms debounce before calling `RefreshItems` from `DirectoryWatcher_Changed`
- Use the same `operationQueue` batching pattern already used in the Win32 ReadDirectoryChangesW path

---

### Fix 4 — `SidebarViewModel` subscribes `Section_PropertyChanged` once per element, never unsubscribes
**File:** `src/Files.App/ViewModels/UserControls/SidebarViewModel.cs:424`  
**Resource:** CPU 🔥

`AddElementToSectionAsync` calls `section.PropertyChanged += Section_PropertyChanged` every time an element is added — without a guard or prior removal. With 10 pinned folders, the handler is subscribed 10 times on the same section. `Dispose()` never removes these. Every sidebar section expand/collapse fires N duplicate handlers, each writing to `UserSettingsService`. Accumulates indefinitely.

**Fix:**
```csharp
// In AddElementToSectionAsync — unsubscribe before subscribing:
section.PropertyChanged -= Section_PropertyChanged;
section.PropertyChanged += Section_PropertyChanged;

// In Dispose():
foreach (var section in sidebarItems.OfType<LocationItem>())
    section.PropertyChanged -= Section_PropertyChanged;
```

---

## 🟠 HIGH — Fix next (significant sustained impact)

### Fix 5 — `git fetch` (live network request) on every navigation to a git folder
**File:** `src/Files.App/Views/Shells/BaseShellPage.cs:248`  
**Resource:** CPU + Network I/O

`FilesystemViewModel_DirectoryInfoUpdated` fires after every folder load AND after every file-system watcher event. Each time it calls `GitHelpers.FetchOrigin()` — a **synchronous network call to GitHub** — if the folder is inside a git repo. No cooldown exists.

**Fix:**
- Add a `Dictionary<string, DateTimeOffset>` tracking last-fetch time per repo path
- Skip fetch if last fetch was less than **5 minutes** ago

---

### Fix 6 — Opens `new Repository()` for every file in a git folder (N disk reads per nav)
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `LoadGitPropertiesAsync()` ~line 1534  
**Resource:** Disk I/O

In a folder with N git-tracked files, `new Repository(repoPath)` is opened N times. Each open reads `.git/config`, `.git/HEAD`, pack index files. Even with OS page cache, this is N independent syscall sequences plus N `Diff.Compare<TreeChanges>()` calls.

**Fix:**
- Open `Repository` once per directory load, pass it into each item's git property resolution
- Close/dispose after all items are processed

---

### Fix 7 — Git properties loaded for ALL items simultaneously with no concurrency limit
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:148`  
**Resource:** CPU + Disk I/O

`EnabledGitProperties` setter calls `ForEach(async item => await LoadGitPropertiesAsync(gitItem))` — all items in parallel, no `SemaphoreSlim`. Spawns N concurrent `Task.Run` tasks each reading from disk.

**Fix:**
- Add `SemaphoreSlim(2)` around `LoadGitPropertiesAsync` calls in the setter

---

### Fix 8 — `CachedSizeProvider.UpdateAsync`: unbounded recursive disk walk, no concurrency cap
**File:** `src/Files.App/Services/SizeProvider/CachedSizeProvider.cs:23`  
**Resource:** Disk I/O

Recursive `FindFirstFileExFromApp` walk with no `SemaphoreSlim`. Multiple items in the same folder can trigger concurrent walks on the same disk. `Task.Yield()` inside doesn't throttle I/O — it just floods the task scheduler.

**Fix:**
- Add `SemaphoreSlim(1, 1)` in `DrivesSizeProvider.UpdateAsync` to serialise disk walks
- Remove `Task.Yield()` micro-tasks inside the walk loop

---

## 🟡 MEDIUM — Fix after the above

### Fix 9 — 200ms poll loop per tab, runs even when idle
**File:** `src/Files.App/ViewModels/ShellViewModel.cs` — `ProcessOperationQueueAsync()` ~line 2507  
**Resource:** CPU

The background loop wakes every 200ms on a `LongRunning` thread even with no queued events. With N tabs open = N threads waking 5× per second.

**Fix:**
- Replace `WaitAsync(200, token)` with `WaitAsync(token)` (no timeout)
- Handle queue draining separately via an event signal, not a poll

---

### Fix 10 — `watcherCTS.Token.Register()` × 3 — watcher overlap risk on rapid navigation
**File:** `src/Files.App/ViewModels/ShellViewModel.cs:2183, 2340, 2430`  
**Resource:** Disk I/O

Three `Register()` callbacks are placed in watcher-start methods. On rapid navigation, there is a window where old and new watchers briefly run simultaneously. Needs verification that `CloseWatcher()` fully disposes the old CTS before the new one starts.

**Fix:**
- Ensure `CloseWatcher()` is `await`ed completely before `WatchForWin32FolderChanges` is called
- Add a lock or sequential guard on watcher replacement

---

### Fix 11 — `NavigationToolbarViewModel.Dispose()` — verify all event unhooks
**File:** `src/Files.App/ViewModels/UserControls/NavigationToolbarViewModel.cs`  
**Resource:** CPU (static service event retention)

Constructor subscribes to: `UserSettingsService.OnSettingChangedEvent`, `UpdateService.PropertyChanged`, multiple `Commands.*.PropertyChanged`, `AppearanceSettingsService.PropertyChanged`, `OngoingTasksViewModel.PropertyChanged`. Need to verify Dispose() removes all of these.

**Fix:**
- Audit `Dispose()` and add any missing `-=` unsubscriptions

---

## Verification Plan

### After each fix group:
1. Run the app, open 3+ tabs, navigate folders rapidly for 5 minutes
2. Open **Task Manager → Performance → Disk** — verify I/O drops significantly
3. Open **Resource Monitor → CPU** — verify Files.App CPU stays low when idle
4. Navigate away and back to a git repo — verify no network spike

### Automated:
- Build in Release mode and confirm no regressions
- Confirm `Add-AppxPackage` installs cleanly using `sideloading/INSTALL.md`

---

## Files to Edit (in order)

| Priority | File | Fix # |
|----------|------|--------|
| 1 | `src/Files.App/Views/Shells/BaseShellPage.cs` | Fix 1 (timer interval) |
| 1 | `src/Files.App/ViewModels/ShellViewModel.cs` | Fix 1 (batch dispatches), Fix 2 (git watcher subtree), Fix 3 (debounce), Fix 6 (repo reuse), Fix 7 (semaphore), Fix 8 (size provider), Fix 9 (poll loop), Fix 10 (watcher overlap) |
| 1 | `src/Files.App/ViewModels/UserControls/SidebarViewModel.cs` | Fix 4 (event leak) |
| 2 | `src/Files.App/Views/Shells/BaseShellPage.cs` | Fix 5 (git fetch cooldown) |
| 2 | `src/Files.App/Services/SizeProvider/CachedSizeProvider.cs` | Fix 8 (concurrency cap) |
| 3 | `src/Files.App/ViewModels/UserControls/NavigationToolbarViewModel.cs` | Fix 11 (dispose audit) |
