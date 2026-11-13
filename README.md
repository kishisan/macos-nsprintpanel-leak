# NSPrintPanel leaks the printer list (and every printer's parsed PPD) on each open

On macOS, every time the standard print panel is opened — e.g. **⌘P in Preview, then Cancel** — `PrintingUI` creates a `PMPrinterListController` that is never deallocated. It keeps every installed printer's parsed PPD data alive, so memory grows by tens of MB per open (depending on installed printers) and is only reclaimed when the app quits.

- Reported to Apple: **FB25555507** (Feedback Assistant)
- Found by a friend; root-cause analysis by Tomohiro Kishi ([@kishisan](https://github.com/kishisan))
- Confirmed on: macOS 26.7.1 (25G241), Apple silicon, one machine with 14 printer queues. All measurements below are from that machine. The Preview and `heap`/`leaks` numbers were measured once there; everything else can be re-run with the programs in this repo.

## Symptom

Preview, a 1‑page PDF, ⌘P → Cancel repeated via UI scripting (`phys_footprint` from `footprint -p Preview`):

| opens | Preview footprint |
|---|---|
| 0 | 358 MB |
| 10 | 701 MB |
| 20 | 1034 MB |
| 30 | 1367 MB |
| 40 | 1699 MB |
| 50 | 2034 MB |

≈ 33 MB per open, linear. Closing the document window does not release it.

The same happens in a ~30-line program that only calls `NSPrintPanel().runModal(with:)` and cancels it ([`repro/leak-repro.swift`](repro/leak-repro.swift)), so it is not specific to Preview.

## Root cause

1. Each time the panel loads, `PrintingUI` allocates a `PMPrinterListController` (`-initWithPrintInfo:`), which builds `_printerList` → `NSPrinterWrapper` → `PM_PPDWrapper` (incl. `_ppdConstraintsDict`) for **every** installed printer.
2. Inside that initializer it calls `-[NSNotificationCenter addObserverForName:object:queue:usingBlock:]` twice, for
   - `PMNearbyPrinterAddedNotification`
   - `PMNearbyPrinterRemovedNotification`

   with `object: nil`, `queue: nil`. Each block captures exactly one value, the controller itself ([`tools/observer-capture.m`](tools/observer-capture.m): 40-byte block = 32-byte header + one pointer). That this capture is strong follows from the proof below: removing just these two tokens is enough for `-dealloc` to run. The notification center keeps the blocks, so it keeps the controller.
3. The tokens returned by those calls are never removed. `-stopListeningForPMPrinterListChanged` only removes `NSPortDidBecomeInvalidNotification`, and `-dealloc` only calls `removeObserver:` with the controller and its printer wrappers, which does not cover block-based tokens ([`tools/teardown-trace.m`](tools/teardown-trace.m)). And `-dealloc` is never reached anyway, because of step 2.

Result: notification center → observer block → controller → all printers' PPD data, retained until the process exits.

Supporting evidence from Preview after 52 opens (`heap`, `leaks`):

- Exactly **52** live `PMPrinterListController`, and **728** `PM_PPDWrapper` (= 52 × 14 installed printers).
- `leaks` reports only ~1.5 MB as unreachable; the growth is *abandoned* memory that is still reachable. `leaks --traceTree` on one of the accumulated `NSMutableDictionary` objects:
  `NSNotificationCenter → CFXNotificationRegistrar → PMPrinterListController → _printerList → NSPrinterWrapper → _ppdWrapper (PM_PPDWrapper) → _ppdConstraintsDict → …`

### Proof: removing only those two observers stops the growth

[`repro/workaround-proof.m`](repro/workaround-proof.m) records the two tokens and removes them after the panel closes (standalone program, 14 printers installed):

| opens | as shipped | the two observers removed |
|---|---|---|
| 1 | 83 MB | 83 MB |
| 4 | 184 MB | 120 MB |
| 8 | 322 MB | 126 MB |
| `PMPrinterListController` deallocated | 0 of 8 | 7 of 8 |

Once the observers are removed, `-dealloc` runs and its existing teardown (`-stopListeningForPMPrinterListChanged`, `removeObserver:` for the printer wrappers) runs too. Growth drops from ~35 MB to ~1.5–2.5 MB per open.

The one controller that is not deallocated is always the first one created in the process. It stays alive even after its two tokens are removed. It is also the delegate passed to `+[PKPrinterBrowser browserWithDelegate:]`, which is called only once per process. I did not verify what retains it, but it is a single instance (bounded), not per-open.

Not analyzed: the residual growth of ~1.5–2.5 MB per open. It is not shown to be a leak; it may be caches. Separately, `leaks` on Preview also showed a small `PMRemotePDE` ⇄ `PMRemotePDEHost` retain cycle (~1 KB) left behind per open.

### Suggested minimal fix (in `PMPrinterListController`)

- In `-initWithPrintInfo:`, capture `self` **weakly** in the two observer blocks, and **store the returned tokens**.
- In `-stopListeningForPMPrinterListChanged` (already called from `-dealloc`), call `removeObserver:` on those two tokens.

Why both: in the traced flow `-stopListeningForPMPrinterListChanged` is reached only from `-dealloc`, so removing the tokens there alone is never reached while the blocks hold `self` strongly. Weak capture alone would let `-dealloc` run, but would leave two observers registered per open. Equivalently, the tokens can be removed when the panel is dismissed; that alone is what [`repro/workaround-proof.m`](repro/workaround-proof.m) does.

## Why the size depends on your printers

The leaked data scales with the PPDs of the installed printers. Same standalone repro, MB per open (average of opens 2–7):

| installed queues | MB / open |
|---|---|
| 14 (13 × Fuji Xerox DocuCentre‑V 7080 PostScript PPD: ~500 KB, 5,532 `*UIConstraints` each; 1 × AirPrint) | 34.4 |
| + 3 temporary queues with that same PPD | 41.8 (≈ +2.5 MB per queue) |
| + 3 temporary queues with the system `Generic.ppd` (4 `*UIConstraints`) | 35.6 (≈ +0.4 MB per queue) |

Machines with fewer, or simpler/driverless, printers leak less per open, but still leak.

## Reproduce

```sh
./build.sh
./bin/leak-repro 10                    # footprint grows on every open
./bin/workaround-proof 8               # as shipped
./bin/workaround-proof 8 --workaround  # the two observers removed -> flat
./bin/observer-capture                 # what the two observer blocks capture
./bin/teardown-trace                   # what stopListening / dealloc actually remove
```

Each program opens a real print panel and cancels it after ~1.5 s with `abortModal`, so no Accessibility permission is needed. The diagnostic programs swizzle private classes for analysis only; do not ship this.

## Workarounds for users

- Quit the app (Preview etc.) from time to time. Memory is only returned on quit.
- Remove printers you no longer use; the per-open growth is proportional to installed PPDs.

---

## 日本語の概要

macOS で標準の印刷パネルを開くたび（例: プレビューで ⌘P → キャンセル）、`PrintingUI` の `PMPrinterListController` が解放されずに残り、登録済みの全プリンタの PPD 解析結果を抱えたままメモリが増え続ける。

原因は、初期化のときに `PMNearbyPrinterAddedNotification` と `PMNearbyPrinterRemovedNotification` を、`self` を強参照するブロックで購読し、返されたトークンをどこでも解除していないこと。通知センターがブロックを持ち、ブロックがコントローラを持ち続けるので、`dealloc` に到達しない。

この 2 つの購読を外すだけで解放され、増加は 1 回あたり約 35MB から約 1.5〜2.5MB に減る。最小の修正は「ブロック内の `self` を weak にする」＋「トークンを保持して `-stopListeningForPMPrinterListChanged` で解除する」の 2 点（パネルを閉じるときにトークンを解除するだけでもよい）。Apple へは FB25555507 で報告した。
