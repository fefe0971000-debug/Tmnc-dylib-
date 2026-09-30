SAMPLE OUTPUT / VERIFICATION BOUNDARY
=====================================

No injected iOS target or physical device was available in the sandbox, so a post-repair runtime dump could not be generated here. The three supplied files are preserved as pre-repair baseline evidence and are intentionally labeled by their original names:

- BOOT_DIAGNOSTICS.txt
- RUNTIME_STARTUP_REPORT.txt
- STARTUP_VIEW_TREE.txt

They document the regression that motivated the repair: a detected host window, approximately 1242 loaded images, and a 22-node startup tree stopped by depth 8. They are not claimed to be output from the final dylib.
