# Root Cause Analysis — Startup Termination Risk

## Conclusion

The reported timing—successful launch, visible inspector button, brief usability, then the entire target process terminating before a long dump completes—is consistent with unsafe work in the startup/automatic-capture path rather than dump duration.

The strongest source-level trigger was the startup call chain:

```text
constructor
  -> repeated main-queue startup attempts at 0.5/1/2/4 seconds
  -> InspectorCore start
  -> writeStartupReports
  -> LegacyWriteVisibleHierarchy
  -> recursive UIKit view traversal
```

The startup report was not a lightweight diagnostic. It recursively visited the host window’s UIKit hierarchy, read view/layer properties, tracked object pointers, and wrote a full tree immediately after overlay creation while the host application could still be constructing its initial hierarchy.

A second unsafe startup path existed when capture preparation began:

```text
prepareFullCapture
  -> createSession
  -> SessionCapture start
  -> immediate SessionCapture capture
  -> recursive view/controller snapshots
  -> screenshot rendering with drawViewHierarchyInRect:
```

`SessionCapture` also installed a process-level application-active observer and could trigger a delayed capture after application activation. That made automatic startup behavior more invasive than the required passive warm-up.

This is a **plausible source-level root cause**, not a claim of completed device proof. The supplied observation must still be verified against the diagnostic build using `RUNTIME_STABILITY_TEST_PLAN.md`.

## Unsafe behavior found

### 1. Full UIKit hierarchy traversal during startup

`start` called `writeStartupReports`, and `writeStartupReports` called `LegacyWriteVisibleHierarchy` before the target had been allowed to settle. This violated the intended warm-up boundary and could dereference a changing UIKit graph during app construction.

### 2. Immediate snapshot and screenshot on session start

`SessionCapture start:` immediately called `capture:`. The capture recursively walked views and controllers and rendered a screenshot. This could happen as part of session preparation rather than after a deliberate user capture.

### 3. Automatic application lifecycle observation

`SessionCapture start:` registered for `UIApplicationDidBecomeActiveNotification` and scheduled a later capture from `sceneChanged:`. That was unnecessary for a passive stability test and made background lifecycle timing part of the crash surface.

### 4. Startup retry fan-out

The constructor scheduled four initialization attempts at 0.5, 1, 2, and 4 seconds. Although `started` prevented most duplicate overlays, this still created unnecessary startup scheduling and repeated host-scene inspection while the application was initializing.

### 5. Background final-log UIKit reads

The ZIP phase ran on a utility queue and called `writeFinalLogs`, which read `UIDevice` metadata. The final-log implementation now uses values cached on the main thread when the session is created, removing that UIKit access from the worker path.

## Exact changes made

1. Added a compile-time diagnostic stability mode: `kDiagnosticStabilityBuild = YES`.
2. Reduced the constructor to one delayed main-queue initialization after 10 seconds.
3. Removed startup hierarchy traversal. `STARTUP_VIEW_TREE.txt` now records that no hierarchy traversal occurred during passive startup.
4. Removed automatic session-start snapshots and screenshot capture.
5. Removed automatic application-active observation from `SessionCapture` startup.
6. Added a 120-second passive startup test. It performs no runtime polling, enumeration, object traversal, screenshot, dump, hook, or automatic capture.
7. Added a user-started 120-second lightweight warm-up. Every approximately 5 seconds it collects only:
   - `objc_getClassList(NULL, 0)`
   - `_dyld_image_count()`
   - safe memory telemetry
   - tiny atomic breadcrumb/heartbeat files
8. Heavy collector controls remain locked until lightweight warm-up is stable.
9. Disabled `EXPORT ALL RUNTIME` in this diagnostic build. The legacy collectors remain available individually after stability is proven.
10. Added atomic `LAST_OPERATION.txt` markers before passive waits, counter samples, and each manual/automatic collector phase.
11. Added unique `CRASH_RECOVERY_STATE_*.json` breadcrumbs so a new launch does not immediately overwrite prior recovery evidence.
12. Added `HEARTBEAT.txt` updates approximately every 5 seconds during passive and lightweight phases.
13. Added `MEMORY_LOG.txt` process-footprint samples around lightweight warm-up and collector phases.
14. Added phase start/end/failure breadcrumbs and recovery state updates around coordinator phases.
15. Cached device/app metadata on the main thread before background ZIP/final-log work.
16. Added the exact device test sequence and coexistence matrix in `RUNTIME_STABILITY_TEST_PLAN.md`.

## What was intentionally not changed

The proven legacy collectors remain the source of truth. No new dumper architecture was introduced, and no attempt was made to compensate for startup risk by merely slowing the existing full export. The automatic coordinator remains available in the source for later re-enablement only after isolated device tests pass; it is disabled in this diagnostic build.

## Verification boundary

The sandbox can compile the iOS arm64 dylib but cannot inject it into the target app or observe SpringBoard termination. Therefore this change must not be described as runtime-fixed until Builds 1–6 in the stability plan pass on-device.
