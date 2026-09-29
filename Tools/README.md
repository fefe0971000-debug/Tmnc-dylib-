# Universal IPA Analyzer

Run without modifying the IPA:

```bash
python3 ipa_analyzer.py MyApp.ipa --runtime-zip UniversalUIInspector-Runtime-Session.zip -o Analysis
python3 lookup_address.py Analysis selectorName
```

The analyzer extracts to a private output directory, inventories `Payload/*.app`, the main executable, embedded frameworks, dylibs and extensions, preserves originals byte-for-byte under `OriginalBinaries/`, computes SHA-256 hashes, parses accessible Mach-O headers/load commands/sections/dylibs/rpaths, inventories resources and strings, and emits chunked HEX/Base64 with reconstruction verification. It produces `ANALYSIS_INDEX.json`, `PerImage/`, `SCREEN_CLASS_METHOD_CORRELATION.*`, `Runtime/`, `MachO/DISASSEMBLY.txt`, `LIMITATIONS.txt`, and per-image reports.

The runtime ZIP is optional. When supplied, it is independently opened and CRC-tested using Python `zipfile`. Correlation is conservative: runtime IMPs are not treated as file offsets, and static address mapping is marked unavailable unless UUID, ASLR slide, unslid address and matching image data are present. No decryption, patching, signing, source recovery or publication of the IPA occurs.
