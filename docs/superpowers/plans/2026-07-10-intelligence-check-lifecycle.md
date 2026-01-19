# Intelligence Check Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every degradation-check subprocess finishes within a bounded time and is terminated when the user cancels, closes Settings, or quits the app.

**Architecture:** Add a thread-safe subprocess lifetime controller that owns the active `Process`, records cancellation, waits with a per-sample deadline, and escalates from `terminate()` to `SIGKILL` when needed. Keep the check loop in its current view model, but route cancellation through the controller and connect Settings-window/app termination events to the view model.

**Tech Stack:** Swift 6, Foundation `Process`, AppKit window/application delegates, SwiftUI, Swift Testing.

---

### Task 1: Subprocess lifetime controller

**Files:**
- Create: `Sources/CodexUsage/CodexProcessLifetime.swift`
- Create: `Tests/CodexUsageTests/CodexProcessLifetimeTests.swift`
- Modify: `Package.swift`

- [x] **Step 1: Add failing lifecycle tests**

Add tests which launch `/bin/sleep`, verify explicit cancellation terminates it, and verify a short deadline throws `timedOut` while also terminating it.

- [x] **Step 2: Run the focused tests and verify failure**

Run: `swift test --filter CodexProcessLifetimeTests`

Expected: FAIL because `CodexProcessLifetimeController` and its wait API do not exist.

- [x] **Step 3: Implement the minimal controller**

Implement a lock-protected controller with these operations:

```swift
func reset()
func register(_ process: Process) -> Bool
func waitForExit(of process: Process, timeout: TimeInterval) throws
func cancelAndTerminate()
func clear(_ process: Process)
```

`waitForExit` must poll cancellation/deadline without blocking forever. Termination sends `Process.terminate()`, waits briefly, then sends `SIGKILL` if the process remains alive.

- [x] **Step 4: Run focused tests**

Run: `swift test --filter CodexProcessLifetimeTests`

Expected: PASS; neither spawned `sleep` process remains running.

### Task 2: Detection runner timeout and cancellation

**Files:**
- Modify: `Sources/CodexUsage/CodexIntelligenceCheck.swift:107-530`
- Modify: `Sources/CodexUsage/CodexIntelligenceCheck.swift:1604-1810`

- [x] **Step 1: Route the active subprocess through the controller**

Give the view model one controller, reset it before a new check, and pass it to every `runOne`. Replace unbounded `process.waitUntilExit()` with the controller's bounded wait.

- [x] **Step 2: Add real cancellation semantics**

Add `cancel()` to the view model. It cancels the parent Swift task and terminates the registered subprocess. A cancelled run must not be appended or recorded in history.

- [x] **Step 3: Stop the batch after a timeout**

Represent timeout/cancellation distinctly from ordinary command failures. Append a timeout row so the user sees the cause, then stop launching remaining samples.

- [x] **Step 4: Expose a Cancel button while running**

In `CodexIntelligenceCheckRows`, replace the disabled start action with an explicit `取消检测` action while a check is active.

### Task 3: Window and application lifecycle cleanup

**Files:**
- Modify: `Sources/CodexUsage/CodexUsageApp.swift:1-30`
- Modify: `Sources/CodexUsage/CodexUsageApp.swift:254-310`

- [x] **Step 1: Cancel when Settings closes**

Make `SettingsWindowPresenter` an `NSWindowDelegate`, assign it to the Settings window, and call the view model cancellation method from `windowWillClose`.

- [x] **Step 2: Cancel synchronously before application termination**

Install an `NSApplicationDelegate` through `@NSApplicationDelegateAdaptor` and terminate any active detection subprocess in `applicationWillTerminate`.

- [x] **Step 3: Verify the complete app**

Run: `swift test`

Expected: all lifecycle tests pass.

Run: `swift build`

Expected: the macOS executable compiles successfully.

Run: `git diff --check`

Expected: no whitespace errors.

### Self-review

- [x] Timeout, explicit cancel, Settings close, and app quit all reach the same subprocess termination path.
- [x] Cancellation cannot launch the next sequential sample.
- [x] A timed-out sample produces a visible result instead of an indefinite spinner.
- [x] Existing model/effort selection and history behavior remain unchanged.
