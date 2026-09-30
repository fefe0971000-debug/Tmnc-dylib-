# FEATURE_STATUS

Verified against source and the clean GitHub Actions build at [run 36652095671](https://github.com/fefe0971000-debug/Tmnc-dylib-/actions/runs/36652095671), commit `6409bccb65ab15d62a5527c9c1e8b21bbe332c5e`.

- [PASS] Legacy source located/restored from repository history and behavioral reference inspected
- [PASS] Legacy runtime collector restored as a streaming process-wide collector
- [PASS] Large-scale runtime class enumeration: complete `objc_getClassList` index has no small class cap; actual target count remains device-dependent
- [PASS] Legacy hierarchy collector restored with pointer cycle protection and high configurable safety bounds
- [PASS] Manual Runtime Classes action retained and backed by legacy index/detail collectors
- [PASS] Manual Loaded Images action retained and backed by the dyld collector
- [PASS] Manual View Controllers action retained and backed by the legacy controller collector
- [PASS] Manual Dump Visible Hierarchy action retained and backed by the legacy hierarchy collector
- [PASS] Prepare Full Capture creates a unique session directory and initial metadata immediately
- [PASS] Minimum 60-second non-blocking warm-up with status UI and no forced navigation
- [PASS] Sequential phase coordinator: metadata, images, class index, protocols, detail pass, controllers, windows, views, diagnostics, summary, ZIP
- [PASS] Progressive disk writes and per-phase logs; runtime classes/details are streamed in JSONL/text batches
- [PARTIAL] Partial-session preservation/recovery: files and `SESSION_STATE.json` survive cancellation/failure; automatic resume UI is not implemented
- [PASS] Independent legacy/window/controller-root/visible-controller view reports are generated
- [PASS] EXPORT ALL RUNTIME is an orchestrator over the same legacy collectors used by manual actions
- [PASS] `FINAL_LOG.txt` generated for complete and partial sessions
- [PASS] `FINAL_LOG.json` generated for complete and partial sessions
- [PASS] Streaming ZIP export without the former 2 MiB-per-file/16 MiB aggregate truncation
- [PASS] Native share-sheet path remains in the source
- [PASS] iOS arm64 compilation completed on macOS 14 / Xcode 15.4 / iPhoneOS SDK 17.5
- [PARTIAL] Physical-device injection, real Spotify runtime counts, screen navigation, share-sheet save, and crash/Jetsam behavior were not available in the sandbox
- [PARTIAL] No final runtime dump sample could be produced without an injected iOS target; supplied pre-repair evidence is preserved under `SAMPLE_OUTPUT/`

## Build evidence

- Artifact: `UniversalUIInspector.dylib`
- Architecture: Mach-O 64-bit arm64 dynamic library for iOS device
- Deployment target: iOS 13.0
- Clean build log: `BUILD_LOG.txt`
- Mach-O header: `MACHO_HEADER.txt`
- Dependencies: `LINKED_FRAMEWORKS.txt`
- SHA-256: `67b0bd956ff064d00481f2c34897750fa94fd8aea28b5ea6cd849440eedd2f3b`

The final binary was compiled from the implementation source. Documentation-only changes after the code build do not alter the binary; the final source commit is rebuilt by the same workflow before packaging.
