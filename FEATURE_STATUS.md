# Feature status

- [PASS] Legacy runtime enumeration restored as streaming `LegacyCollectors.m`
- [PARTIAL] 100k+ scale supported by streaming/process-visible enumeration; actual count depends on target process
- [PASS] Legacy hierarchy collector restored with cycle protection and high configurable limits
- [PASS] Manual Runtime Classes
- [PASS] Manual Loaded Images
- [PASS] Manual View Controllers
- [PASS] Manual Dump Visible Hierarchy
- [PASS] Prepare Full Capture with 60-second non-blocking warm-up
- [PASS] Sequential capture coordinator
- [PASS] Progressive file writes for legacy index/hierarchy
- [PARTIAL] Partial-session recovery: files survive phase failures; automatic resume UI is not implemented
- [PASS] Export All Runtime orchestration
- [PASS] FINAL_LOG.txt
- [PASS] FINAL_LOG.json
- [PASS] ZIP export and independent ZIP bounds validation
- [PASS] Share sheet path in source/build verification
- [PASS] arm64 compilation

Device-only verification still required: Spotify injection, two distinct manual screens, native share sheet, Files save, background/foreground, and crash/Jetsam behavior.
