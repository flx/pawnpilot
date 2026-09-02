# DONE

An **index** of shipped items, one line each, newest first:

```
- [x] (slug) YYYY-MM-DD · **[tier · priority · area]** · `hash` … · what it did
```

…plus ` — ⚠ verification owed: <the exact check>` when a manual check is still
outstanding, and ` — closed, not built` for an item resolved without code.
**~500 characters, one physical line, ONE clause of what it did.** The long
record — decisions, deferrals, review ledger — lives in the commit message:
`git log --grep='(slug)'`. Only the newest 30 entries stay here; `/done`
rotates older ones to `records/done-archive-*.md`.

(Adopted 2026-09-01 from `../FlyWheelCADV3`; the July 2026 queue this replaced
had shipped nothing through it. Its items' dispositions are tabled in
`arch-reviews/2026-09-01-stability-performance.md`.)

- [x] (view-model-task-ownership-and-cancel) 2026-09-01 · **[hi · High · view-model/concurrency]** · `c5a31ca` · every asynchronous entry point of `AppViewModel` stores its task and a superseding gesture cancels the stale work (two cancel operations — superseded work vs the bot's move; generation + carried-FEN gates; owner-keyed tree flags; the one-shot engine terminates its child on cancel; a move during the bot's search is discarded silently); 14 tests — ⚠ verification owed: §5 sitting 1 (Variations → Analyze → select a node → board move → Analyze) by eye
- [x] (apply-move-then-animate) 2026-09-01 · **[hi · High · rules/state]** · `d960674` `f9e2d0a` · a move is applied to the model when it is accepted (validate, snapshot, apply, `lastMove` before the entry point returns); the 0.35 s animation is a visual tail that renders the pre-move frame carried on `AnimatedPiece`, every write snaps it first, tree selection sets the model and frame 0 in one step; 23 view-model tests — ⚠ verification owed: §5 `(sitting-ui-unchanged-after-each-landing)`, the by-eye pass named there
- [x] (persistent-engine-serialize-searches) 2026-09-01 · **[hi · High · engine/concurrency]** · `75a2fb5` · the persistent Stockfish actor runs one search at a time (FIFO tickets, one stored line iterator per child), turns caller cancellation into `stop` + drain with the child kept alive, and enforces `timeoutSeconds` over queue wait + handshake + search by killing only the child in use; 11 tests on the upgraded fake — ⚠ verification owed: the manual repro moved to `(view-model-task-ownership-and-cancel)`
- [x] (engine-pipe-write-after-death-sigpipe) 2026-09-01 · **[standard · High · engine/process]** · `f6950bd` · every Stockfish stdin write goes through a NOSIGPIPE, throwing `EngineStdinWriter`, a dead child surfaces as `StockfishError` (new `engineGone`) instead of killing the app, and the persistent engine restarts it on the next `analyze` — ⚠ verification owed: §5 `(sitting-sigpipe-timeout)`, optional (depth 30 + strict + Lines 10 → "Engine timed out" instead of a quit)
- [x] (fake-uci-engine-test-double) 2026-09-01 · **[standard · Medium · tests]** · `f6950bd` · `PawnPilotTests/FakeUCIEngine.swift` generates a parameterised `/bin/sh` UCI fake (delays, extra line after bestmove, exit on go / die once / exit before uci), launched through the engines' new `arguments:`; shipped inside the SIGPIPE item, `stop`-responsiveness follows with `(persistent-engine-serialize-searches)`
- [x] (detected-fen-mismatch) 2026-09-01 · **[trivial · Low · detection]** · — · the "Detected …" label that could disagree with the analysed board lives in `detectionStatusView`, which is never mounted, so the mismatch is unreachable; `DetectionOutput.fen` is removed under `(dead-detection-and-recents-purge)` — closed, not built
- [x] (detection-failed-unreported) 2026-09-01 · **[trivial · Low · detection]** · — · `DetectionStatus.failed` has no live consumer (same unmounted view); the enum's payload goes with `(dead-detection-and-recents-purge)` — closed, not built
