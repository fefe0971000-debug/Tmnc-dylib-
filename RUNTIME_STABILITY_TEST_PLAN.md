# Runtime Stability Test Plan

## Purpose

This is a **stability-first diagnostic build**. It must not be described as fixed from compilation alone. The target process must remain alive through each phase before the next phase is enabled.

The diagnostic build uses the following architecture:

1. Minimal constructor schedules one delayed main-thread initialization.
2. Overlay creation occurs only after the host app has had time to construct its foreground scene.
3. Passive startup runs for 120 seconds with no runtime polling, object traversal, hooks, dump, screenshot, or automatic capture.
4. User-started lightweight warm-up polls only `objc_getClassList(NULL, 0)` and `_dyld_image_count()` every approximately 5 seconds for 120 seconds.
5. Only after the 120-second minimum and 6 consecutive stable post-minimum checks are complete are individual manual legacy collectors exposed.
6. `EXPORT ALL RUNTIME` remains disabled in this diagnostic build.

## Build identity

Record the exact dylib SHA-256, source commit, iOS deployment target, device model, iOS version, target app version, and loaded dylibs before every test. Preserve the following files after every run:

- `LAST_OPERATION.txt`
- `HEARTBEAT.txt`
- `MEMORY_LOG.txt`
- `WARMUP_SAMPLES.txt`
- all `CRASH_RECOVERY_STATE_*.json` files
- `BOOT_DIAGNOSTICS.txt`
- `RUNTIME_STARTUP_REPORT.txt`
- `STARTUP_VIEW_TREE.txt`

Do not delete the previous report directory before installing a new build.

## Build 1 — Passive startup test

**Configuration:** Inspector dylib only. HomeCustomization disabled. Automatic full capture disabled.

1. Inject the dylib and launch the target app.
2. Confirm the app reaches its normal first screen.
3. Confirm the inspector overlay button appears after the delayed initialization.
4. Do not open the inspector menu.
5. Do not tap a collector or capture action.
6. Observe the target for at least 120 seconds.
7. Record whether the process remains alive, whether the target remains interactive, and whether SpringBoard appears.
8. Check that `LAST_OPERATION.txt` remains `PASSIVE_WAIT` and that `STARTUP_VIEW_TREE.txt` explicitly reports no hierarchy traversal.

**Pass condition:** process remains alive and interactive for 120+ seconds. No runtime counters or dump files should be created by startup itself.

**Failure interpretation:** if this fails, inspect `LAST_OPERATION.txt`, the last `HEARTBEAT.txt`, and crash logs. Do not enable any collector.

## Build 2 — Lightweight counters only

1. Complete Build 1 successfully.
2. Open the inspector panel and tap `START LIGHTWEIGHT WARM-UP`.
3. Let it run for at least 120 seconds.
4. Verify each sample contains only timestamp, elapsed time, class count, and image count.
5. Verify no UIKit hierarchy, controller, view, layer, accessibility, method, property, ivar, IMP, Mach-O, or instance data appears in `WARMUP_SAMPLES.txt`.
6. Review `MEMORY_LOG.txt` for monotonic growth.

**Allowed operations per sample:**

- `objc_getClassList(NULL, 0)`
- `_dyld_image_count()`
- safe process memory telemetry
- tiny atomic breadcrumb/heartbeat writes

**Pass condition:** `LIGHTWEIGHT_WARMUP_STABLE=YES`, the process remains alive, and memory does not continuously grow.

## Builds 3–6 — Individual legacy collectors

Run each only after Build 2 passes. Start each collector from a fresh target launch and keep the other collectors disabled.

### Build 3 — Loaded Images

Tap `RUN LEGACY LOADED IMAGES`. Verify `LEGACY_IMAGES_BEGIN`, collector output, `LEGACY_IMAGES_END`, and process survival.

### Build 4 — Legacy Runtime Classes

Tap `RUN LEGACY RUNTIME CLASSES`. Verify the complete class index is streamed progressively and no small artificial cap is present. Verify process survival through the expected target class count.

### Build 5 — Controllers

Tap `RUN LEGACY CONTROLLERS`. This is a main-thread UIKit operation. Verify controller output, pointer-cycle protection, and process survival.

### Build 6 — Views

Tap `RUN LEGACY VIEWS`. This is a main-thread UIKit operation. Verify the legacy visible hierarchy output, independent controller-root output when manually requested, and process survival.

For every collector, record:

- elapsed time
- peak and post-cleanup memory
- `LAST_OPERATION.txt`
- heartbeat freshness
- whether the target remained interactive
- whether SpringBoard appeared
- whether any exception or crash log was generated

## Build 7 — Sequential coordinator

Do not enable this in the diagnostic build. Enable only after Builds 3–6 have passed on the target device in separate runs. The coordinator must run one legacy collector at a time, flush each phase to disk, clean temporary state, and preserve the partial session on failure.

## UIKit threading audit

- Overlay creation and all UIKit hierarchy/controller/window operations must run on the main thread.
- Background queues may only serialize plain immutable structures or stream already-opened files.
- Runtime-only collectors may run off-main only when they do not access UIKit objects.
- No background queue may call `UIApplication`, `UIScene`, `UIWindow`, `UIView`, `UIViewController`, `CALayer` attached to UIKit, navigation controllers, tab controllers, `UIDevice`, `UIScreen`, or UIKit metadata reads.

## Constructor and hook audit

The constructor may only schedule delayed initialization. There must be no `+load`, global swizzling, lifecycle hook installation, automatic observers, dump, hierarchy walk, screenshot, ZIP, large allocation, or network activity on the constructor path.

## Coexistence matrix

Run the passive and lightweight tests in three configurations:

| Test | Inspector | HomeCustomization | Required result |
|---|---:|---:|---|
| A | enabled | disabled | survives passive + lightweight phases |
| B | disabled | enabled | HomeCustomization baseline remains unchanged |
| C | enabled | enabled | survives passive + lightweight phases; no overlay/window conflict |

If A passes and C fails, compare duplicate Objective-C class names, exported symbols, associated-object keys, global hooks, notification observers, window levels, and lifecycle timing.

## Crash triage rule

Compilation success is not a stability result. A process termination at any point fails the current build. Do not slow the dump and call it fixed. Use the last atomic breadcrumb and heartbeat to identify the exact operation, revert to the preceding stable build, and re-enable only the next isolated test.
