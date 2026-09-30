# FEATURE_STATUS

This revision is a **stability-first diagnostic build**. Compilation is verified, but runtime stability is intentionally not claimed until the exact device sequence in `RUNTIME_STABILITY_TEST_PLAN.md` passes.

## Stability architecture

- [PASS] Constructor reduced to one delayed main-queue initialization after host-app startup
- [PASS] Overlay startup no longer performs a UIKit hierarchy traversal
- [PASS] Session startup no longer captures a view/controller snapshot or screenshot automatically
- [PASS] Automatic application-active capture observation removed from SessionCapture startup
- [PASS] Passive startup test runs for 120 seconds with no polling, runtime enumeration, dump, hooks, screenshot, or object traversal
- [PASS] Lightweight warm-up is user-started and runs for 120 seconds
- [PASS] Lightweight polling collects only `objc_getClassList(NULL, 0)` and `_dyld_image_count()` every approximately 5 seconds
- [PASS] Heavy controls are locked until lightweight warm-up is stable
- [PASS] `EXPORT ALL RUNTIME` is disabled in this diagnostic build
- [PASS] Atomic `LAST_OPERATION.txt` breadcrumbs added before startup waits, warm-up samples, and collectors
- [PASS] Unique `CRASH_RECOVERY_STATE_*.json` files preserve prior crash evidence
- [PASS] `HEARTBEAT.txt` is updated approximately every 5 seconds during passive and lightweight tests
- [PASS] `MEMORY_LOG.txt` records safe process memory telemetry
- [PASS] Phase start/end/failure breadcrumbs and recovery-state updates added
- [PASS] Background final-log work uses main-thread-cached device metadata instead of UIKit reads

## Legacy collector preservation

- [PASS] Legacy source located/restored from repository history and behavioral reference inspected
- [PASS] Legacy runtime class index remains complete and streamed without the former small class cap
- [PASS] Legacy detailed runtime metadata remains a separate streamed collector
- [PASS] Legacy loaded-images/dyld collector remains available
- [PASS] Legacy protocol collector remains available
- [PASS] Legacy controller collector remains available
- [PASS] Legacy window and visible-hierarchy collectors remain available
- [PASS] Independent controller-root and visible-controller hierarchy collectors remain available
- [PASS] Manual collector functions remain in the source
- [PASS] Automatic coordinator remains in the source but is disabled in this diagnostic build
- [PASS] Runtime-generated `FINAL_LOG.txt` and `FINAL_LOG.json` remain implemented for later sessions

## Verification boundary

- [PASS] iOS arm64 source compilation can be performed by the supplied macOS workflow
- [NOT YET VERIFIED] Passive startup survival for 120+ seconds on a real target
- [NOT YET VERIFIED] Lightweight counter warm-up survival for 120+ seconds on a real target
- [NOT YET VERIFIED] Individual loaded-images, runtime-classes, controllers, and views device runs
- [NOT YET VERIFIED] Inspector-only / HomeCustomization-only / coexistence matrix
- [NOT YET VERIFIED] SpringBoard termination cause or crash log correlation

The sandbox has no injected iOS target, so no runtime-stability claim is made here. See `ROOT_CAUSE_ANALYSIS.md` and `RUNTIME_STABILITY_TEST_PLAN.md` for the exact next tests.
