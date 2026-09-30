# LEGACY_VS_CURRENT_ANALYSIS

## Scope and evidence

This comparison was completed before implementation changes. Sources inspected:

- Behavioral reference: `LEGACY_REFERENCE/UniversalUIInspector_LEGACY.dylib` (Mach-O arm64, SHA-256 `df1e54fdbcb5d1835de3ff761ce699a8bef952b2970de3b7e2b8164c1a3e149f`).
- Current regression evidence: `CURRENT_FAILURE_EVIDENCE/STARTUP_VIEW_TREE.txt`, `RUNTIME_STARTUP_REPORT.txt`, and `BOOT_DIAGNOSTICS.txt`.
- Current branch: `universal-inspector-build`, commit `58fe665`.
- Historical source commits in `fefe0971000-debug/Tmnc-dylib-`: `95a9df0`, `5d1eeab`, `2917591`, `686fcd0`, `9d85af1`, `774e5c1`, `2d0dacc`, `fd99b71`, and `07f7b71`.

The reference binary exposes the legacy feature vocabulary and Objective-C implementation shape, including `FloatingInspector`, `UIInspectorCore`, `exportHierarchy`, `exportClasses`, `appendView:depth:to:`, `objc_getClassList`, `class_getSuperclass`, `subviews`, `rootViewController`, `presentedViewController`, and the legacy `RUNTIME_CLASSES.txt` output. It is used as behavioral evidence, not treated as source.

## 1. Current project files responsible for capture

The current branch captures from:

- `UniversalUIInspector/UniversalUIInspector.m` — overlay UI, host-window discovery, current manual methods, `SessionCapture`, bounded traversal, and the one-button phase chain.
- `UniversalUIInspector/LegacyCollectors.h/.m` — a later restoration that currently contains only a streaming class index and one visible hierarchy writer.
- `.github/workflows/build-universal-inspector.yml` — iOS arm64 compilation and artifact packaging.

The working tree also contains unrelated `Source/SatanabeCleanUI.mm`; it is not part of the UniversalUIInspector target and is not used for the final dylib.

## 2. Historical/legacy files responsible for manual capture

The historical manual implementation is concentrated in `UniversalUIInspector/UniversalUIInspector.m` from the runtime-inspector commits. The legacy manual methods are:

- `classes` — process-wide `objc_getClassList`, superclass, declared instance/class methods, properties, and ivars.
- `detailedRuntimeJSON` — process-wide structured class metadata including selectors, type encodings, IMPs, properties, ivars, and IMP image information.
- `images` — `_dyld_image_count`, image name, header/base, and slide.
- `controllers` — reachable root/presented controller reporting.
- `hierarchy` and `AppendViewTree` — visible UIKit hierarchy reporting.
- `showMenu` — manual actions for preparation, screen capture, hierarchy, controllers, runtime classes, loaded images, diagnostics, session export, and folder selection.

The restoration commit `07f7b71` added `LegacyCollectors.m` for a progressive complete class index and a configurable legacy visible hierarchy. Those collectors are the source of truth to reuse and extend; the new coordinator must call them rather than create a third scanner.

## 3. Legacy runtime-class enumeration path

The proven path is process-wide and starts with `objc_getClassList(NULL, 0)`, allocates exactly the returned class-list size, calls `objc_getClassList` again, then iterates every returned `Class`. For each class it uses `NSStringFromClass`, `class_getSuperclass`, and `class_getImageName`. The detailed manual path additionally uses `class_copyMethodList` on the class and metaclass, `method_getName`, `method_getTypeEncoding`, `method_getImplementation`, `dladdr`, `class_copyPropertyList`, `property_getName`, `property_getAttributes`, `class_copyIvarList`, `ivar_getName`, `ivar_getTypeEncoding`, and `ivar_getOffset`.

The restored class-index collector writes one JSON object per line and one text line per class, flushing periodically. This preserves the legacy enumeration behavior while avoiding a single giant `NSMutableString`.

## 4. Current runtime-class enumeration path

The current coordinator calls `LegacyWriteRuntimeClassIndex`, but then also runs the newer `WriteDetailedRuntimeReport` and `WriteAppOwnedRuntimeJSON`. The latter two are deliberately bounded to app-owned classes, `1200` classes, `12000` methods, and `8 MiB`; they are not equivalent to the legacy manual collector. The manual `classes` method still builds a potentially massive in-memory string and the manual `detailedRuntimeJSON` builds an in-memory array containing every class.

Therefore the current implementation only partially restored the legacy path: the complete name index is present, but detailed/manual output and orchestration still rely on weaker bounded or memory-heavy paths.

## 5. Legacy hierarchy path

The reference behavior and historical manual path recursively start at a reachable host/root view and use `subviews`, recording class, pointer, frame, bounds, alpha/hidden and color information. The restored `LegacyWriteVisibleHierarchy` writes progressively to disk and uses a visited-pointer set. The legacy behavior is preferred for `VIEW_TREE_LEGACY.txt`.

## 6. Current hierarchy path

The startup/current path is `AppendViewTree` in `UniversalUIInspector.m`. It stops at `kMaxStartupDepth = 8` or `kMaxStartupNodes = 2000`. `SessionViewSnapshot` independently stops at depth `8` and a caller-provided limit of `1200`; controller snapshots stop at depth `16` and `500` controllers. The one-button export previously wrote only one legacy view report plus a bounded session snapshot and `CURRENT_VIEW_HIERARCHY.txt`; it did not generate independent window-root, controller-root, and visible-controller trees.

The supplied evidence shows the resulting startup tree contains only 22 nodes and explicitly reports `depth limit: 8`. This is an incomplete diagnostic, not a full capture.

## 7. Legacy loaded-image path

The historical/manual `images` method uses `_dyld_image_count`, `_dyld_get_image_name`, `_dyld_get_image_header`, and `_dyld_get_image_vmaddr_slide` for every loaded image. This is the path that produced the working image report and is consistent with the supplied report showing approximately 1242 images. It must remain intact; the repaired implementation keeps it as `LegacyWriteLoadedImages` and preserves `LOADED_IMAGES.txt` plus JSONL output.

## 8. Current loaded-image path

The current one-button phase calls `self.images` and writes only `LOADED_IMAGES.txt`. That path is functional and should not be replaced with a different image scanner. The repair moves the same dyld enumeration into the legacy collector module so both the manual action and automatic phase share one collector, and adds structured records without removing the text format.

## 9. Legacy controller enumeration path

The historical manual controller path starts from the host window's `rootViewController`, follows `presentedViewController`, and reports class, presented controller, and child count. The session path also follows `childViewControllers`, presented controllers, and standard navigation/tab relationships. The repaired collector keeps those reachable UIKit relationships and separately writes controller records, a relationship tree, and controller-to-view mappings.

## 10. Current controller enumeration path

The current `controllers` method only walks a root-to-presented chain. `SessionControllerSnapshot` is bounded to 500 controllers and depth 16 and omits several independent roots/relationships from the automatic export. The current one-button flow does not write `CONTROLLERS.txt`, `CONTROLLER_TREE.txt`, or `CONTROLLER_VIEW_MAP.txt` from the proven manual path. The repair restores these outputs through `LegacyWriteControllers` and calls it as its own sequential phase.

## 11. Artificial limits introduced by the current rewrite

The following limits or truncations were found:

- `kMaxStartupDepth = 8`.
- `kMaxStartupNodes = 2000`.
- `SessionViewSnapshot` depth `8` and per-capture view limit `1200`.
- Session controller snapshot depth `16` and limit `500`.
- `WriteDetailedRuntimeReport`: `maxClasses=1200`, `maxMethods=12000`, `maxBytes=8 MiB`.
- `WriteAppOwnedRuntimeJSON`: `maxClasses=1200`, `maxMethods=12000`, `maxBytes=8 MiB`.
- `ClassMatches`: `50` matching classes.
- `CountObservedClass`: depth `8` and `500` observed instances.
- ZIP staging previously truncated individual files at `2 MiB` and the aggregate at `16 MiB`, which could discard the large class index.
- The earlier phase UI collapsed many heavy collectors into a single “views/controllers” phase and omitted protocol, window, independent hierarchy, diagnostics, and final-log phases.
- `NSMutableString`/`NSMutableArray` detailed reports retained large runtime output in memory instead of streaming.

The repaired design removes the low traversal caps from full collectors, uses pointer-identity cycle protection, and makes any remaining high safety bounds explicit in state/log output. Large runtime output is JSONL/text streamed in batches.

## 12. Why the current build reaches only approximately 22 startup view nodes

The supplied `STARTUP_VIEW_TREE.txt` contains 22 nodes and the supplied `BOOT_DIAGNOSTICS.txt` says `Startup tree nodes: 22 depth limit: 8`. The current startup walker reaches outer containers, then terminates when `depth > 8`; it also has a node cap. The session walker repeats the same shallow depth policy. Consequently, the current result is caused by the rewrite's traversal limits and single-root strategy, not by failure to find the host window: the host window and approximately 1242 loaded images are detected successfully.

## 13. Exact legacy functions/modules to restore or reuse

The repair reuses and extends these legacy collectors:

- `LegacyWriteRuntimeClassIndex` — complete process-wide class index, JSONL + text + summary.
- `LegacyWriteRuntimeDetails` — legacy declared methods/properties/ivars/selectors/encodings/IMP enrichment, streamed JSONL and text with per-class progress.
- `LegacyWriteProtocols` — `objc_copyProtocolList` and protocol metadata.
- `LegacyWriteLoadedImages` — dyld image text + JSONL.
- `LegacyWriteControllers` — manual reachable controller enumeration, relationship tree, and controller-view map.
- `LegacyWriteWindowHierarchy` — all relevant scene/window roots and recursive window trees.
- `LegacyWriteVisibleHierarchy` — legacy visible hierarchy output with cycle protection and high configurable safety bounds.
- `LegacyWriteControllerViewHierarchy` — independent controller.view traversal.

The existing `classes`, `detailedRuntimeJSON`, `images`, `controllers`, and `hierarchy` manual entry points remain available and delegate to these same collectors/output formats.

## 14. Current UI/session/export components that can remain

The following current components remain and are strengthened rather than discarded:

- `InspectorWindow`, `InspectorRootController`, and the floating inspector button.
- Foreground `UIWindowScene`/host-window discovery and startup evidence.
- `SessionCapture` and manual `CAPTURE CURRENT SCREEN` snapshots.
- `PREPARE FULL CAPTURE` with a non-blocking minimum 60-second warm-up.
- `STOP CAPTURE`, `EXPORT SESSION`, `CHOOSE EXPORT FOLDER`, and native share-sheet handling.
- Selected-class search/export and read-only diagnostics.
- The small ZIP writer, with the old aggregate truncation removed from full runtime export.

The automatic coordinator is layered over these components and uses one serial background operation per heavy phase.

## 15. Behavior that cannot be reconstructed from available source

The binary does not contain original source, and no device/runtime session is available in this sandbox. Therefore the following cannot be proven here:

- Exact historical UI layout/presentation details beyond the symbols and strings in the reference binary.
- Runtime counts for the user's Spotify target or any other injected app without executing the final dylib in that process.
- Swift-only metadata not registered with the Objective-C runtime.
- Unseen app screens that the user did not navigate to during warm-up/snapshots.
- A guaranteed safe read for every optional UIKit property on arbitrary custom subclasses.
- Native share-sheet success and crash/Jetsam behavior on a physical device.

These limitations are recorded honestly in `FEATURE_STATUS.md`, per-session logs, and `FINAL_LOG` status/sanity warnings.

## Conclusion

The correct fix is **proven legacy collectors plus a safe sequential automation layer**. The repaired implementation does not introduce an independent generic dumper. It keeps the working manual controls, removes the regression-causing shallow limits from full capture, writes each phase immediately, preserves partial sessions, and marks suspiciously small results instead of claiming success.
