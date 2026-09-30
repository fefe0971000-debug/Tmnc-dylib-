# Legacy vs current analysis

## Evidence inspected

The repository history contains the older manual collector in `b1c19a8`, `5de08dc`, `9d85af1`, `2917591`, and earlier commits. Its manual methods are `classes`, `detailedRuntimeJSON`, `images`, `hierarchy`, `controllers`, and `showMenu` actions. The legacy runtime path uses `objc_getClassList`, `class_getSuperclass`, `class_copyMethodList` for instance and metaclass methods, `class_copyPropertyList`, `class_copyIvarList`, and dyld image APIs. The legacy manual export writes `RUNTIME_CLASSES_DETAILED.txt`, `RUNTIME_CLASSES_DETAILED.json`, `LOADED_IMAGES.txt`, and hierarchy/controller reports.

The newer coordinator replaced the manual `classes` path with a bounded app-owned helper and replaced the direct hierarchy report with `SessionViewSnapshot`, which had depth 8 and a 1,200-view limit. The newer export was more automated but could therefore report only a small visible tree and a partial detail pass. The old `classes` implementation also built a large string and is not safe to run as one giant in-memory operation, so the restored legacy module preserves its enumeration APIs while streaming batches to disk.

## Restored modules

- `LegacyCollectors.h/.m`: streaming legacy-style runtime class index and visible hierarchy collector.
- Runtime enumeration remains process-wide and is not capped at 1,200 names.
- Hierarchy traversal uses pointer cycle protection and configurable high limits (`maxDepth=64`, `maxNodes=100000`) and records truncation.
- The existing manual methods and startup outputs remain in `UniversalUIInspector.m` for backward compatibility.
- The automated coordinator calls the restored legacy modules sequentially before session staging.

## Honesty and limits

The historical source available in this repository does not prove that every historical report's approximately 117,000 headers represented 117,000 distinct Objective-C classes; method/detail lines may contribute to that size. The new complete class index reports the actual `objc_getClassList` count and completion state. It does not claim Swift types that are not registered with Objective-C runtime, unseen screens, or original source code.
