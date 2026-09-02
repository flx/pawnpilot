# Plan: (view-model-task-ownership-and-cancel)

Rev 1 · 2026-09-01 · tier **hi** (every asynchronous path in `AppViewModel`
changes; the one-shot engine gains cancellation; wide blast radius inside the
view model. `adv-review-plan` on this plan; both adv reviewers on the code.
No `/arch-review`: no boundary changes — the engine protocol is unchanged and
the view model's public surface (its `@Published` state and methods) is
unchanged; what changes is which tasks are stored and what gates their results.)

Source: TODO.md §0; evidence `arch-reviews/2026-09-01-stability-performance.md` F5.
Builds on `(engine-pipe-write-after-death-sigpipe)` (`f6950bd`: terminating a
child and then writing is safe) and `(persistent-engine-serialize-searches)`
(this branch: cancelling the task that awaits `PersistentStockfishEngine.analyze`
sends `stop`, keeps the child, and throws `CancellationError`).

## Premise re-derived against the tree (`AppViewModel.swift`, unchanged by item 2)

- Unstored `Task {}`s: `detect` `:166`, `analyze` `:228`, `selectTreeNode` `:332`
  (animation) and `:345` (`expandTreeForSelection`), `engineMove` `:386`,
  `playSelectedLine` `:418`, `applyUserMove` `:437`. The only stored one is
  `treeExpansionTask` (`:105`, set at `:285`).
- `invalidateAnalysis` (`:668-684`) bumps four UUID tokens, resets
  `isAnalyzing`/`isTreeAnalyzing`, cancels `treeExpansionTask` — and does NOT
  reset `isEngineThinking` nor cancel anything else.
- `engineMove` (`:348-408`): `defer { self.isEngineThinking = false }` (`:387`)
  runs whenever the task ends — including after a NEWER `engineMove` set the
  flag again; the result is applied at `:398` with no token and no FEN check:
  `boardState.move(fromUCI:)` (`:393`) parses against whatever the board is
  NOW, and `performAnimatedMove` validates legality against it. Reset/Undo/
  new image during "Engine thinking…" plays the OLD position's move on the
  NEW board whenever it is legal there.
- `applyUserMove` (`:430-448`): no `isEngineThinking` guard.
- `playSelectedLine` (`:410-428`): replays `line.moves` with only an
  `interactionMode` guard per step; `move(fromUCI:)` returns nil for an
  unparseable move (`continue`), and `performAnimatedMove` rejects illegal
  ones, but a legal move on a diverged board is played.
- `analyze` (`:194-245`) gates on `token == analysisToken` (`:231`, `:237`, `:241`)
  — a UUID, not the position.
- `expandTreeChunk` (`:774-845`) gates on `treeToken` and `interactionMode`;
  the root position is `treeRootState` captured at `:275`.
- `StockfishEngine.runEngine` (`StockfishEngine.swift:42-180`): no
  `withTaskCancellationHandler`, no `Task.checkCancellation`; a superseded
  search runs to full depth on `activeProcessorCount/2` threads beside its
  replacement (`analysisOptions` `:736-747`, `engineMove` options `:376-385`).
- `AppViewModel.init` (`:108-116`) constructs both engines itself from the
  bundle; the stored properties are the concrete types (`:89-90`). No
  injection seam; the existing `AppViewModel` tests (`PawnPilotTests.swift:296-320`)
  build the real thing (CoreML + engine lookup).

## Goal

Stale asynchronous WORK is cancelled, not just its result ignored: every
engine-driven task is owned by the view model and cancelled by
`invalidateAnalysis`; the one-shot engine honours cancellation by terminating
its child; the persistent engine already stops. Every asynchronous result is
applied only if the board is still the position it was computed for (FEN
captured at start), and "Engine thinking…" can never end by playing a move on
a board that changed underneath it. No visible change: same status strings,
same controls, same timing.

## Acceptance criteria (tests in `PawnPilotTests/AppViewModelTaskTests.swift`, `@MainActor`, injected engines built from `FakeUCIEngine` through the REAL engine classes)

- C1 Reset during `engineMove`: slow fake (`infoDelayMs: 50`, `go depth 100`);
  `engineMove()`; wait until the fake's log contains `go`; `resetBoard()`.
  Within 3 s: `isEngineThinking == false`, the fake's log contains NO
  `bestmove` (the one-shot child was terminated, not left to finish),
  `boardState == BoardState()`, `lastMove == nil`, `canUndo == false`,
  `statusMessage == "Board cleared."`.
- C2 Cancellation reaches the persistent fake: `analyzeMoveTree()` with a
  slow fake; wait for `go`; `resetBoard()`. Within 1 s the fake's log contains
  `stop`; `isTreeAnalyzing == false`; `treeNodes` stays empty; the child pid
  is unchanged (the tree engine was not restarted).
- C3 A result for a different FEN is dropped: `analyze()` (Lines mode) with a
  fast fake; before the result lands, assign `boardState` directly (no
  invalidation, so nothing is cancelled) to a different position. Within 3 s
  `isAnalyzing == false`, `engineLines` is empty and `statusMessage` is not
  "Analysis ready.". Then `analyze()` again on the new board succeeds.
- C4 A user move during "Engine thinking…" is rejected: `engineMove()` with a
  slow fake; `applyUserMove(e2→e4)`; the board is unchanged and no snapshot
  was pushed (`canUndo == false`); the engine move then lands normally.
- C5 `playSelectedLine` stops when the board diverges: seed `engineLines` with
  one line `[e2e4, e7e5, g1f3]` and select it; `playSelectedLine()`; after the
  first move has been applied (poll `lastMove`), assign `boardState` directly
  to an unrelated position; within 3 s the replay has stopped: exactly one of
  the line's moves was applied, and the board is the unrelated position with
  no further move on it.
- C6 A superseded `engineMove` never clears the newer one's flag: slow fake;
  `engineMove()`; wait for `go`; `resetBoard()`; `engineMove()` again;
  `isEngineThinking` is `true` until the SECOND search finishes (assert it is
  still true 200 ms after the first task's cancellation completed), then the
  second move lands.
- C7 One-shot engine cancellation, unit level (`EngineProcessTests`): cancel
  the task awaiting `StockfishEngine.analyze` against a slow fake; it throws
  `CancellationError` within 1 s and the child is gone (`kill(pid, 0)` fails
  after a bounded wait, or the fake's log has no `bestmove`).
- C8 The 53 existing tests still pass; the three existing `AppViewModel`
  tests still construct the view model with the no-argument initialiser.

## Design

### Tier 1 — an injection seam, no behaviour change

`AppViewModel`:
```swift
private let engine: any EngineAnalyzing
private let treeEngine: any EngineAnalyzing
init() { … as today … }                                   // production
init(engine: any EngineAnalyzing, treeEngine: any EngineAnalyzing) { … }   // tests
```
(`EngineAnalyzing` is `Sendable`; both concrete types conform; the calls pass
`requireFullDepth:` explicitly already.) Pays off alone (C8 unchanged).

### Tier 2 — the one-shot engine honours cancellation

`StockfishEngine.runEngine`: wrap the read loop in
`withTaskCancellationHandler(operation:onCancel:)`; `onCancel` terminates the
process (`process.terminate()` — the pattern the file's timeout task already
uses; safe after item 1 because nothing writes after EOF). After the loop, the
precedence becomes: `try Task.checkCancellation()` → `.timeout` → `.startFailed`
→ `.engineGone` → lines. The `defer` is unchanged (no write after EOF; `quit`
is a no-op once the writer is gone). Pays off alone (C7).

### Tier 3 — owned tasks and FEN gates in `AppViewModel`

Stored handles (all `Task<Void, Never>?`):
`detectionTask`, `analysisTask`, `engineMoveTask`, `playLineTask`,
`treeExpansionTask` (exists), `treeSelectionExpansionTask` (the orphan at
`:345`), `treeSelectionAnimationTask` (`:332`). `applyUserMove`'s task stays
unstored for now — it is the animation, which `(apply-move-then-animate)`
restructures next; storing it here would be churned immediately.

`invalidateAnalysis()` additionally: cancels `analysisTask`, `engineMoveTask`,
`playLineTask`, `treeSelectionExpansionTask`, `detectionTask`; sets
`isEngineThinking = false`. (`treeSelectionAnimationTask` is governed by
`treeAnimationToken`, which it already bumps; cancelling it too is harmless
and done.) Order inside each entry point stays: invalidate first, then set the
new state, then start the new task — so a cancelled task that resumes sees the
new generation and drops out.

Per-task generation instead of shared UUID tokens where a `defer` can clobber:
```swift
private var engineMoveGeneration = 0
func engineMove() {
    …
    engineMoveGeneration += 1
    let generation = engineMoveGeneration
    let fen = boardState.fen
    engineMoveTask = Task {
        defer { if generation == engineMoveGeneration { isEngineThinking = false } }
        do {
            let lines = try await engine.analyze(fen: fen, options: options, requireFullDepth: false)
            guard generation == engineMoveGeneration, !Task.isCancelled,
                  interactionMode == .playAgainstComputer, boardState.fen == fen else { return }
            … pick, move(fromUCI:), performAnimatedMove, status …
        } catch is CancellationError {
            return                                         // superseded: say nothing
        } catch {
            guard generation == engineMoveGeneration else { return }
            statusMessage = error.localizedDescription
        }
    }
}
```
The same shape for `analyze` (replace `analysisToken` with `analysisGeneration`
+ `fen`) and for `expandTreeChunk` (keep `treeToken`, add
`guard treeRootState?.fen == rootFenAtStart`, and **re-check
`token == treeToken` and `Task.isCancelled` between the retry attempts at
`:803-814`** — item 2's review found one stale expansion can otherwise occupy
the engine for up to three full searches), and `CancellationError` is
swallowed at every engine call site (the persistent engine now throws it;
without the filter the status bar would show an untranslated string).

Cancel promptness (from item 2's record): the persistent engine's cancel is
`stop` + drain; a child that ignores `stop` holds its slot until the clock and
the caller then gets `.timeout`. The view model must treat a cancelled task as
"done from the user's point of view" the moment it cancels (state reset
synchronously), never by awaiting the cancelled task.

`applyUserMove`: `guard !isEngineThinking else { return }` at the top (the
status already reads "Engine thinking…"; no new copy).

`playSelectedLine`: compute the expected pre-move FEN for each step by
applying the line's moves to a copy of the starting state; before each step
`guard !Task.isCancelled, interactionMode == .analyzeLines, boardState.fen == expectedFen else { return }`.

`detect`: store the task; keep `detectionToken` (the pipeline is not
cancellable until `(detection-off-main-actor)`; cancellation drops the result,
which the token already does).

### Tier 4 — tests (`PawnPilotTests/AppViewModelTaskTests.swift`)

`@MainActor final class AppViewModelTaskTests: XCTestCase`. Helper
`makeViewModel(oneShot: FakeUCIEngine.Script, tree: FakeUCIEngine.Script)` →
`AppViewModel(engine: StockfishEngine(engineURL: launch.executable, arguments:…, timeoutSeconds: 5), treeEngine: PersistentStockfishEngine(…))`
with both launches registered for `cleanUp()`. Polling helpers as in
`EngineSerializationTests` (`waitForLog`, `waitUntil { predicate }` with a
3 s deadline, 20 ms steps, `Task.sleep` so the main actor keeps turning).
Note `performAnimatedMove` sleeps 0.35 s; C1/C4/C6 bounds include it.

## Load-bearing assumptions

- The three existing `AppViewModel` tests keep using `init()`; adding a second
  initialiser does not change `ObservableObject` synthesis. Trivially true.
- `FakeUCIEngine` through `StockfishEngine` (one-shot): the one-shot sends
  `uci`, `setoption…`, `isready`, `position`, `go`, and terminates the child
  on cancel; the fake's main loop dies with SIGTERM and its subshell exits at
  the next liveness check. A3/A3b/A4 already run the fake through the one-shot.
- Directly assigning `boardState` from a test is a legitimate stand-in for a
  board change that bypasses `invalidateAnalysis` — it is exactly the F5 case
  "a result is accepted as long as nothing invalidated in between".

## Out of scope (explicit)

- Applying the move before the animation; cancelling/snapping animations —
  `(apply-move-then-animate)`.
- Moving detection off the main actor — `(detection-off-main-actor)`.
- Re-queuing a dropped selection expansion — `(tree-selection-expansion-dropped-while-busy)`.
- Consolidating the engines — `(engine-consolidate)`.

## Decisions taken

- 2026-09-01 · Generation counters per task instead of one shared UUID: a
  `defer` that resets a flag must know whether it still owns the flag; a
  shared token cannot say which task set it.
- 2026-09-01 · Results are gated on the FEN captured at start AND on the
  generation/cancellation: the FEN catches board changes that bypassed
  invalidation; the generation catches the same FEN after a supersession
  (e.g. Reset-to-the-same-position while a bot move is pending, where the
  user asked for a fresh start).
- 2026-09-01 · `CancellationError` is swallowed silently at every engine call
  site — a superseded task has nothing to tell the user; the newer task owns
  the status bar.
- 2026-09-01 · The one-shot engine cancels by terminating its child rather
  than `stop`+drain: the process is single-use, and termination is instant
  and safe after item 1. `stop` semantics belong to the persistent actor.
- 2026-09-01 · `applyUserMove`'s animation task is left unstored: it is the
  subject of the next item, which changes when the model mutates.

## Plan review round 1 (2026-09-01) — verdict "do not build as scoped"; fold into Rev 2 AFTER (apply-move-then-animate) ships

- D1 [Critical] The FEN/generation gate sits before `performAnimatedMove`'s 0.35 s sleep with no re-check after it; cancelling the task makes the stale apply land in ~0.1 s (probe). Resolved by reordering: `(apply-move-then-animate)` first. Rev 2 must add a criterion for "board changed during the animation".
- D2 [High] `treeSelectionExpansionTask`/`treeSelectionAnimationTask` overwritten without cancel: the first task keeps the engine slot while the stored handle points at a no-op. Rev 2: cancel-before-overwrite at every store site.
- D3 [High] C5 unobservable without item 4 (no suspension point between move 1's apply and move 2's guard). Rev 2: re-write C5 against the post-item-4 model.
- D4 [High] `analyze()`/`analyzeMoveTree()` never call `invalidateAnalysis`; they reset by hand and cancel only `treeExpansionTask`. Rev 2: one `cancelEngineWork()` called from every entry point (analyze, analyzeMoveTree, engineMove, playSelectedLine, selectTreeNode, invalidateAnalysis).
- D5 [High] C7 and C1's "no bestmove" clause pass without Tier 2 (AsyncBytes already throws CancellationError at the next line; the fake's 100×50 ms search never prints bestmove inside 3 s; the log marker is `<bestmove`). Rev 2: C7 with a 2 s output gap and a ~200 ms bound; C1 with depth×delay inside the deadline.
- D6 [Medium] `playSelectedLine` re-entrant (button not disabled during replay). Rev 2: cancel-before-overwrite + an `isReplaying` guard (no new copy).
- D7 [Medium] `applyUserMove`'s task launches `engineMove()` (keepPlaying) after a reset. Rev 2: store it too.
- D8 [Medium] `playSelectedLine`'s FEN guard `return`s past the terminal `analyze()`: Lines table blank forever. Rev 2: on divergence, stop replaying but still call `analyze()` on the current board (or restore `engineLines`) — decide and record.
- D9 [Medium] Test helper must return the launches and the concrete `PersistentStockfishEngine`; set `vm.searchDepth`; sequence C4's assertions.
- D10 [Low] `treeRootState` FEN guard is dead code — drop.
- D11 [Low] one-shot cancel: keep the `isRunning` guard; no SIGKILL escalation (document).
- D12 [Low] C6 anchor → "200 ms after the second engineMove() returns".
- T1 precedence: make the one-shot match the persistent engine (timeout beats cancellation). T2: update `(engine-consolidate)`'s entry (EngineAnalyzing becomes a used type). T3: record the silent drop in `applyUserMove` (or file a §5 note). T4: recast C3 as defence in depth. T5: skip of /arch-review is a boundary decision — record. T6: every VM test loads CoreML — acknowledge.
- G2: enumerate token sites to translate (`:213, :266, :299, :331, :669-672`). G3: `try Task.checkCancellation()` at the top of `StockfishEngine.analyze`.
- Facts: `StockfishEngine` is MainActor-isolated by inference from `EngineAnalyzing` (protocol inferred @MainActor); `onCancel { process.terminate() }` compiles and ends the loop by EOF in 1 ms.
