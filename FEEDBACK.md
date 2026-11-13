# Feedback Assistant submission (as filed: FB25555507, 2026-11-13)

- Platform: macOS / Area: Printing / Type: Incorrect/Unexpected Behavior
- Attach: zip of `repro/`, `tools/`, `build.sh`, `README.md`; Mac System Information Report (required for printing issues); sysdiagnose (attached automatically by the app)

## Title

PrintingUI: PMPrinterListController (with all printers' parsed PPDs) leaks on every print panel open – block observers retain self – macOS 26.7.1

## Description

Every time the standard print panel is opened and dismissed, PrintingUI's PMPrinterListController is never deallocated. It keeps _printerList → NSPrinterWrapper → PM_PPDWrapper (incl. _ppdConstraintsDict) for every installed printer, so the app's memory grows by tens of MB per open and is only reclaimed on quit.

Root cause: in -[PMPrinterListController initWithPrintInfo:], PrintingUI calls -[NSNotificationCenter addObserverForName:object:queue:usingBlock:] for PMNearbyPrinterAddedNotification and PMNearbyPrinterRemovedNotification (object nil, queue nil). Each block captures exactly one value, the controller; that the capture is strong follows from the proof below (removing just these two tokens is enough for -dealloc to run). The returned tokens are never removed: -stopListeningForPMPrinterListChanged only removes NSPortDidBecomeInvalidNotification, and -dealloc only calls removeObserver: with the controller and its NSPrinterWrappers, which does not cover block tokens. Since the center retains the blocks, -dealloc is never reached.

Proof: removing only those two tokens after the panel closes lets -dealloc run (with its existing teardown) and reduces growth from ~35 MB to ~1.5–2.5 MB per open (attached workaround-proof.m). The one controller that is not deallocated is always the first one in the process; it is also the delegate passed to the once-per-process +[PKPrinterBrowser browserWithDelegate:]. I did not verify what retains it, but it is a single instance (bounded), not per-open.

Suggested minimal fix: capture self weakly in those two blocks, keep the returned tokens, and remove them in -stopListeningForPMPrinterListChanged (already called from -dealloc). In the traced flow stopListening is reached only from -dealloc, so token removal there alone is never reached while the blocks hold self strongly; weak capture alone would leave two observers registered per open. Equivalently, the tokens can be removed when the panel is dismissed (which is what workaround-proof.m does).

## Steps to reproduce

1. Have several printers installed (test machine: 13 queues with the Fuji Xerox DocuCentre-V 7080 PostScript PPD, ~500 KB / 5,532 *UIConstraints each, plus 1 AirPrint queue).
2. Open any 1-page PDF in Preview.
3. Press ⌘P, then Cancel. Repeat 50 times.
4. Check Preview's memory (Activity Monitor, or `footprint -p Preview`).

Standalone repro (no Preview): `./build.sh && ./bin/leak-repro 10`. It only calls NSPrintPanel().runModal(with:) and dismisses it with abortModal.

## Actual results

- Preview: 358 MB → 2034 MB after 50 open/cancel cycles (~33 MB per cycle, linear). Closing the document window does not release it.
- After 52 cycles: 52 live PMPrinterListController and 728 PM_PPDWrapper (= 52 × 14 printers).
- `leaks` reports only ~1.5 MB unreachable. The growth is abandoned memory reachable via NSNotificationCenter → CFXNotificationRegistrar → PMPrinterListController.
- Standalone repro (same 14 queues): 5 MB → 395 MB after 10 cycles (~45 MB one-time framework load on the first open, then ~34 MB per cycle).
- Growth per open scales with the installed PPDs: +3 queues with the PPD above add ~2.5 MB each per open; +3 queues with the system Generic.ppd add ~0.4 MB each.

## Expected results

The printer list controller and its PPD data are released after the panel is dismissed; repeated open/cancel does not grow the process.

## Additional notes

- All numbers are from one machine (macOS 26.7.1 25G241, Apple silicon, 14 queues). The Preview and heap/leaks numbers were measured once; the rest can be re-run with the attached programs.
- Not analyzed: the residual ~1.5–2.5 MB per open after the fix (not shown to be a leak; may be caches). leaks on Preview also showed a small PMRemotePDE ⇄ PMRemotePDEHost retain cycle (~1 KB) left per open.
- Public write-up with the same repro: <GitHub URL>
