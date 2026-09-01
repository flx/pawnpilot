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

- [x] (detected-fen-mismatch) 2026-09-01 · **[trivial · Low · detection]** · — · the "Detected …" label that could disagree with the analysed board lives in `detectionStatusView`, which is never mounted, so the mismatch is unreachable; `DetectionOutput.fen` is removed under `(dead-detection-and-recents-purge)` — closed, not built
- [x] (detection-failed-unreported) 2026-09-01 · **[trivial · Low · detection]** · — · `DetectionStatus.failed` has no live consumer (same unmounted view); the enum's payload goes with `(dead-detection-and-recents-purge)` — closed, not built
