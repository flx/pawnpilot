# Plan: (view-model-task-ownership-and-cancel)

Rev 5 · 2026-09-01 · tier **hi**. `adv-review-plan` rounds: Rev 1 (parked;
resolved by shipping `(apply-move-then-animate)` first), Rev 2 ("do not build
as scoped — fix 7"), Rev 3 ("do not build as scoped": one cancel point made a
human move cancel the bot's landing tail), Rev 4 ("do not build as scoped —
fix 5": the two-cancel split verified hole-free; three criteria green at
HEAD; cancel placement vs the entry guards unspecified; the bot-search guard
not mode-scoped). Rev 5 folds in every Rev 4 finding (D1–D16, tensions); see
Decisions, including the decision to implement after this revision without
a fifth plan round. Both adv reviewers on the code. No `/arch-review` —
reasons under Decisions.

Rev 1 + its review: `plans/parked/view-model-task-ownership-and-cancel.plan.rev1.md`.

Source: TODO.md §0; evidence `arch-reviews/2026-09-01-stability-performance.md` F5.
Builds on: item 1 (terminating a child then writing is safe), item 2
(cancelling the task that awaits `PersistentStockfishEngine.analyze` sends
`stop`, keeps the child, and throws `CancellationError` — EXCEPT that a
timeout or a child death during a cancelled search surfaces as `.timeout` /
`.engineGone`, `PersistentStockfishEngine.swift:310-333`, so a cancelled
caller must also test `Task.isCancelled`), item 4 (`f9e2d0a`: the model is
authoritative at the entry point; `snapAnimation`; `applyMoveNow → AppliedMove`;
`finishAnimation → .landed | .cutShort | .replaced`; `boardEpoch` bumped only
via `invalidateAnalysis(replacingBoard: true)`; `playSelectedLine` stops when
`analysisToken` changes; the injection seam; the tree hooks).

Item 4's reviews deferred three things here, all in scope: (a) `engineMove`
captures the epoch only after its `await`, so a Reset DURING the search
still lands the engine's move on the cleared board — closed by the
generation + FEN gate; (b) `playSelectedLine` has no re-entrancy guard —
closed by cancelling superseded work at its start; (c) `finishAnimation`'s
`try? await Task.sleep` falls through on cancellation — closed by a
`.cancelled` outcome on which every tail returns immediately.

## Premise (line numbers re-derived against `4159e8e`)

`AppViewModel.swift`: `isEngineThinking` `:76`; `analysisToken` `:98`;
`treeExpansionTask` `:105`; `detect` `:189` (first statement
`invalidateAnalysis()` `:190`, `Task {` `:199`); `analyze` `:231` (cancels
`treeExpansionTask` `:256-257`, token `:262`, `Task {` `:266`, guards
`:269/:275/:279` — a `return` inside its `do` skips `isAnalyzing = false` at
`:279-281`); `analyzeMoveTree` `:285` (`analysisToken = UUID()` `:305`,
cancel `:313`, `treeExpansionTask = Task` `:324`); `selectTreeNode` `:336`
(unstored expansion tasks at `:372` and `:401`; frame advancer `:400`);
`engineMove` `:404` (`isEngineThinking = true` `:432`, `Task {` `:444`,
`defer { self.isEngineThinking = false }` `:445` — runs when the whole task
exits, AFTER the flight; `finishAnimation` at `:460`); `playSelectedLine`
`:472` (`analysisTokenAtStart` `:483`, `Task {` `:484`, guards
`:486/:493/:500`, `finishAnimation` `:490`, no re-entrancy guard);
`applyUserMove` `:505` (`invalidateAnalysis(replacingBoard: false)` `:512`,
tokens `:516`, `Task {` `:518`, `finishAnimation` `:519`, clears `:520-528`,
keep-playing chain `:534`; no bot guard); `finishAnimation` `:739`
(`try? await Task.sleep` `:740`); `invalidateAnalysis(replacingBoard:)`
`:831` (bumps `analysisToken`/`treeToken`/`detectionToken`, cancels
`treeExpansionTask` `:844-845`, resets `isAnalyzing`/`isTreeAnalyzing`,
NOT `isEngineThinking`; nine callers: `detect:190`, `engineMove:425`,
`applyUserMove:512`, `setSideToMove`, `resetBoard`, `rotatePosition`,
`setPiece`, `undo`, `redo`); `expandTreeForSelection` `:915`
(`guard !isTreeAnalyzing` `:917`, `guard !treeExpandingPaths.contains` `:923`,
insert `:929`); `expandTreeChunk` `:940` (`defer { treeExpandingPaths.remove }`
`:949`; `isTreeAnalyzing = true` before its first await; `maxAttempts = 3`
`:964`, loop `:969`; `treeExpandedPaths.insert` `:992` even when no nodes;
catch `:1003-1006`; flag cleared `:1008-1010` — all guarded by `treeToken` +
`interactionMode` only).
`StockfishEngine.swift`: `analyze` `:38`; `runEngine` `:50`; `defer` `:100`;
`TimeoutBox` `:108`; `for try await line in reader.bytes.lines` `:127`;
precedence `:163-175`. Main-actor-isolated by inference.
`ContentView.swift`: `isEngineThinking` read at `:475/:479` only; the board
callback calls `applyUserMove` unconditionally then deselects (`:319-321`);
the tab binding writes `interactionMode` directly (`:216-221`) — left alone
(see Decisions).
`FakeUCIEngine.swift`: the subshell checks the parent's liveness only before
its sleep (`:137`) and logs `<bestmove` unconditionally after the loop
(`:141`); with only `multipv 1` in its output, `expandTreeChunk`'s retry loop
issues THREE `go`s per expansion unless `treeBranchCount == 1`; `Script.depth`
applies only when `go` carries no depth (`:128-131`) — the view model always
sends `go depth max(1, searchDepth)`.

## Goal

Stale asynchronous WORK is cancelled, not just its result ignored. Two cancel
operations with distinct meanings: `cancelSupersededWork()` cancels the
analysis, the tree expansions, a replay and the previous move's tail;
`cancelBotMove()` cancels the bot's task. A human move cancels superseded
work but never the bot's landing tail (the bot can only be landing then —
a move during its SEARCH is refused). The one-shot engine cancels promptly
by terminating its child AND closing its read end. Results are applied only
for the generation that started them and the FEN they were computed for. A
cancelled task never writes a busy flag or a status. `isEngineThinking` and
the Play Bot spinner keep today's timing. No visible change otherwise.

## Acceptance criteria

`PawnPilotTests/AppViewModelTaskTests.swift` (`@MainActor`); engines from
`FakeUCIEngine` through the real classes; helper returns `(vm, engineLaunch,
treeLaunch, treeEngine)`; every wait is a `waitUntil` (≤ 5 s, 20 ms polls);
every cancel test asserts `statusMessage` never contains "CancellationError".
Every test sets `vm.searchDepth` (the view model sends `go depth searchDepth`
to BOTH engines) and, for tree tests, `vm.treeBranchCount = 1` (one `go` per
expansion). A search lasts `searchDepth × infoDelayMs`. One-shot fakes used
for "was terminated" checks use `searchDepth = 1` with a 1.5 s delay: the
fake's single info line is followed by its sleep and then the post-loop
liveness check, so a terminated parent never logs `<bestmove`, and the check
at 2.5 s has 0.9 s of margin.

- C1 Reset during the bot's search: one-shot `infoDelayMs: 1500`,
  `searchDepth = 1`, `.playAgainstComputer`; `engineMove()`; wait for `go`;
  `resetBoard()`. Immediately: `isEngineThinking == false`,
  `boardState == BoardState()`, `statusMessage == "Board cleared."`. At
  2.5 s: same board and status, engine log has no `<bestmove`.
- C2 Reset during a SELECTION expansion (the unowned task at `:372`/`:401`
  — HEAD already cancels the root expansion, so the root case is not a
  criterion): tree `infoDelayMs: 200`, `searchDepth = 10`, `treeBranchCount = 1`;
  seed with `markExpanded: false`; select A; wait for its `go`;
  `resetBoard()`. Within 1 s the tree log has `stop` (fails at HEAD: nothing
  holds that task); `isTreeAnalyzing == false`; `treeNodes` empty; tree pid
  unchanged.
- C3 Stale-FEN result dropped AND the flag released: one-shot
  `infoDelayMs: 200`, `searchDepth = 2`, `.analyzeLines`; `analyze()`;
  assign `boardState` directly (no invalidation); wait for `isAnalyzing == false`
  (the `defer` releases it even though the result is dropped — fails at
  HEAD, where the early `return` skips the clear); `engineLines` empty;
  `statusMessage != "Analysis ready."`.
- C4 A human move is refused during the bot's SEARCH and accepted during
  its landing, and the bot's status survives: one-shot `infoDelayMs: 200`,
  `searchDepth = 3`, `bestmove: "e2e4"`, `.playAgainstComputer`;
  `engineMove()`; `applyUserMove(e7→e5)` at once → board unchanged,
  `canUndo == false`, `statusMessage == "Engine thinking..."`. Wait until
  `piece(at: e4) == .whitePawn && animatingPiece != nil`; `applyUserMove(e7→e5)`
  → accepted (e5 on the model). Then wait for `isEngineThinking == false`;
  `statusMessage == "Engine played e2e4."`.
- C5 A superseded `engineMove` is terminated and never clears the newer
  one's flag: one-shot `infoDelayMs: 1500`, `searchDepth = 1`; `engineMove()`;
  wait for `go`; `resetBoard()`; `engineMove()` at once — the engine log
  must show a SECOND `go` within 1 s (fails at HEAD, where `isEngineThinking`
  is still true after Reset and the second call returns at `:405`); at
  700 ms `isEngineThinking == true`; wait for the second move to land and
  the flag to clear; at 2.5 s after the first `go` the log has exactly one
  `<bestmove` (the second search's) — the first was terminated.
- C6 One-shot cancellation, unit level (`EngineProcessTests`): fake
  `infoDelayMs: 1500`, `EngineOptions(depth: 1)`; cancel the awaiting task
  100 ms after the log shows `go`; `CancellationError` within 500 ms; at
  2.5 s the log has no `<bestmove` (the fake would log it at ~1.6 s if
  alive — 0.9 s of margin, and the deadline errs toward a false FAIL under
  load, never a false pass).
- C7 Selecting B while A's selection expansion runs cancels A and expands
  B: tree `infoDelayMs: 100`, `searchDepth = 10`, `treeBranchCount = 1`;
  seed with `markExpanded: false`; select A = `[0]`; wait for `go`; select
  B = `[0, 1]` (a seeded node with NO seeded child, so the only node its
  expansion can add is `[0, 1, 0]`, which is not in the seed). Then the log
  shows `stop` and a second `go`; within 5 s `isTreeAnalyzing == false` and
  `treeNodes` contains a node with `choicePath == [0, 1, 0]` (fails at HEAD:
  B's expansion returns at `:917`). (This is the selection-vs-selection half
  of §2's `(tree-selection-expansion-dropped-while-busy)`; at `/done` that
  entry's acceptance line is rewritten to the root-vs-selection case, which
  stays filed — see Decisions.)
- C8 `analyzeMoveTree()` cancels bot work: the C1 fake; `engineMove()`; wait
  for `go`; `analyzeMoveTree()` → immediately `isEngineThinking == false`;
  at 2.5 s no `<bestmove`.
- C9 A cancelled bot tail writes nothing: one-shot `infoDelayMs: 0`,
  tree `infoDelayMs: 300`, `searchDepth = 2`, `treeBranchCount = 1`,
  `.playAgainstComputer`; `engineMove()`; wait until `animatingPiece != nil`
  (the reply is landing); `analyzeMoveTree()` (snaps the flight, cancels
  the bot task; its tree search takes 0.6 s). At 0.5 s — after the bot's
  tail would have fired at apply + 0.35 s — `statusMessage == "Analyzing move tree..."`
  (fails at HEAD, where the tail writes "Engine played e2e4."); then wait
  for `isTreeAnalyzing == false`.
- C10 A mode change during a search never leaves a busy flag stuck (the
  `defer`s): (a) one-shot `infoDelayMs: 300`, `searchDepth = 2`,
  `.analyzeLines`; `analyze()`; set `interactionMode = .analyzeMoveTree`
  directly (the tab binding's write); wait ≤ 3 s for `isAnalyzing == false`
  (fails at HEAD: both guards at `:269/:279` fail on the mode and the flag
  sticks); (b) tree `infoDelayMs: 300`, `searchDepth = 2`, `treeBranchCount = 1`;
  `analyzeMoveTree()`; set `interactionMode = .analyzeLines`; wait ≤ 3 s for
  `isTreeAnalyzing == false` (fails at HEAD at `:982/:1008`). (The double
  "Play Selected Moves" case is dropped: HEAD and the design end in the same
  board and the same single terminal `go`; the re-entrancy guard's value is
  not observable — recorded.)
- C11 The F2/F5 repro end-to-end (§5 sitting 1, automated): tree
  `infoDelayMs: 100`, `searchDepth = 5`, `treeBranchCount = 1`;
  `analyzeMoveTree()`; wait for `isTreeAnalyzing == false`; select the
  first node (`e2e4`, the fake's only line); wait for that expansion's `go`
  (the 2nd); `applyUserMove(e7→e5)` (legal: black to move after 1.e4);
  `analyzeMoveTree()`. Within 5 s: `isTreeAnalyzing == false`,
  `treeRootStateForTesting == boardState` (the position after e7e5),
  `treeNodes` non-empty, the tree log shows `stop` after the 2nd `go` and
  before the 3rd, pid unchanged.
- C12 The 80 existing tests still pass — ONE commit for the whole item
  (Tier 1 alone is observable only through C6; the item is one logical
  change, Rev 4 review G16) — (the fake's liveness fix is checked
  against `EngineSerializationTests.testB1/testB3` and `EngineProcessTests`);
  `ContentView` untouched.

## Design

### Tier 1 — the one-shot engine honours cancellation (`StockfishEngine.swift`)

- `analyze`: `try Task.checkCancellation()` first.
- `runEngine`: after `run()`, wrap the process in
  `private final class ProcessBox: @unchecked Sendable { let process: Process }`
  (Rev 3 review D12: a liveness check needs the object) and capture
  `let reader = stdoutPipe.fileHandleForReading` (`FileHandle` is Sendable).
  The read loop runs inside `withTaskCancellationHandler` with
  `onCancel: { if box.process.isRunning { box.process.terminate() }; try? reader.close() }`.
  Closing the read end ends the blocked `bytes.lines` promptly even while a
  grandchild holds the write end.
- Mechanism (probed, Rev 4 review): closing the read end makes
  `for try await line in reader.bytes.lines` END NORMALLY, promptly — the
  cancelled search therefore leaves the loop through the `!sawBestmove`
  path, not through a throw. Keep HEAD's order: `writer.markGone()` right
  after the loop when no `bestmove` was seen (`:163-166`, BEFORE the
  ladder — never write to a child whose stdout hit EOF), then the ordered
  precedence: `.timeout` if the box fired → `try Task.checkCancellation()`
  → `.startFailed` → `.engineGone` → lines. A `catch is CancellationError`
  around the loop is kept as belt-and-braces for the case where a line
  arrives after cancellation (the iterator then throws), treated as "loop
  ended". The `defer` does `try? reader.close()` (idempotent, probed).

### Tier 2 — ownership (`AppViewModel.swift`)

Stored handles: `detectionTask`, `analysisTask`, `engineMoveTask`,
`playLineTask`, `userMoveTask`, `treeExpansionTask` (root), and
`treeSelectionExpansionTask` with `treeSelectionExpansionOwner: UUID?`.
Generations: `analysisGeneration`, `engineMoveGeneration` (Int; `analysisToken`
stays and is bumped with `analysisGeneration`). New flags: `isBotSearching`
(private; true only while the bot's search runs), `treeFlagOwner: UUID?`
(which expansion set `isTreeAnalyzing`). `treeExpandingPaths` becomes
`[String: UUID]` (path key → owner).

```swift
/// Cancels the work a new gesture supersedes: the analysis, the tree expansions
/// (root and selection), a replay, and the previous move's tail. Never the bot's
/// task (see cancelBotMove) and never detection (see invalidateAnalysis).
/// Invariant: a cancelled task never writes a busy flag or a status — every
/// engine-call catch tests `Task.isCancelled` first (a cancelled persistent-engine
/// search can surface as .timeout/.engineGone), and the tree flag is owner-keyed.
private func cancelSupersededWork() {
    for task in [analysisTask, treeExpansionTask, treeSelectionExpansionTask, playLineTask, userMoveTask] { task?.cancel() }
    analysisTask = nil; treeExpansionTask = nil; treeSelectionExpansionTask = nil; treeSelectionExpansionOwner = nil
    playLineTask = nil; userMoveTask = nil
    analysisGeneration += 1; analysisToken = UUID(); treeToken = UUID()
    isAnalyzing = false; isTreeAnalyzing = false; treeFlagOwner = nil; treeExpandingPaths.removeAll()
}

/// Cancels the bot's task (search or landing). Only board-replacing writes and
/// the search-starting entry points call this — never a human move.
private func cancelBotMove() {
    engineMoveTask?.cancel(); engineMoveTask = nil
    engineMoveGeneration += 1
    isEngineThinking = false; isBotSearching = false
}
```

Callers (placement rule, Rev 4 review D4: every cancel call sits AFTER the
entry point's existing re-entrancy guard and early returns — `if isAnalyzing { return }`,
`if isTreeAnalyzing { return }`, `if isEngineThinking { return }`, the
"nothing selected" return, the validation/game-over returns — so a second
click on a busy or disabled control stays a no-op exactly as today, and a
refused call cancels nothing):
- `invalidateAnalysis(replacingBoard:)`: `cancelSupersededWork()`; if
  `replacingBoard` also `cancelBotMove()`. Detection: `detectionTask?.cancel()`
  next to the existing `detectionToken` bump and status reset, in both cases
  (today's token bump is unconditional). So a human move (`replacingBoard: false`)
  cancels superseded work and a stale detection, and leaves the bot's
  landing tail alone (Rev 3 review D1); it snaps the flight as today, so
  the bot's tail sees `.cutShort` and still reports "Engine played …".
- `analyze()`, `analyzeMoveTree()`, `playSelectedLine()`: `cancelSupersededWork()`
  then `cancelBotMove()` (a search the user starts supersedes the bot's
  search AND its landing tail — the new status owns the bar; C9).
- `engineMove()`: as today via `invalidateAnalysis(replacingBoard: false)`
  (its `if isEngineThinking { return }` guard prevents a second bot task).
- `selectTreeNode` (both expansion sites): cancels only its predecessor
  selection expansion, owner-keyed (Rev 3 review D3):
  ```swift
  if let previous = treeSelectionExpansionTask, let owner = treeSelectionExpansionOwner {
      previous.cancel()
      if treeFlagOwner == owner { isTreeAnalyzing = false; treeFlagOwner = nil }
      treeExpandingPaths = treeExpandingPaths.filter { $0.value != owner }
  }
  let owner = UUID()
  treeSelectionExpansionOwner = owner
  treeSelectionExpansionTask = Task { await expandTreeForSelection(id: id, owner: owner) }
  ```
  A predecessor that returned at `:917` (root expansion running) never set
  the flag, so `treeFlagOwner != owner` and the root's flag is untouched.
- `detect()`: `invalidateAnalysis()` FIRST (as today), then
  `detectionTask = Task { … }` (Rev 3 review G3).
- The tab binding is left alone (Rev 3 review D10): cancelling on a tab
  switch would destroy a tree analysis the user only peeked away from;
  today the result lands when they return. Recorded; `(viewmodel-mode-state)`
  owns mode-aware ownership.

Per entry point:
- `analyze()`: `analysisTask = Task { defer { if generation == analysisGeneration { isAnalyzing = false } }; do { let lines = try await …; guard generation == analysisGeneration, !Task.isCancelled, interactionMode == .analyzeLines, boardState.fen == fen else { return }; … } catch { if Task.isCancelled { return }; guard generation == analysisGeneration else { return }; … } }`
  (the `defer` releases the flag on every exit — Rev 3 review D4).
- `engineMove()`: `engineMoveGeneration += 1; let generation = …; let fen = boardState.fen; isEngineThinking = true; isBotSearching = true`;
  `engineMoveTask = Task { defer { if generation == engineMoveGeneration { isEngineThinking = false; isBotSearching = false } }; do { let lines = try await engine.analyze(…); guard generation == engineMoveGeneration, !Task.isCancelled, interactionMode == .playAgainstComputer, boardState.fen == fen else { return }; isBotSearching = false; … applyMoveNow …; let outcome = await finishAnimation(applied); guard outcome == .landed || outcome == .cutShort else { return }; status + updateStatusForGameOver as today } catch { if Task.isCancelled { return }; guard generation == engineMoveGeneration else { return }; statusMessage = error.localizedDescription } }`.
- `applyUserMove`: `guard !(isBotSearching && interactionMode == .playAgainstComputer) else { return }`
  first (silent; the board deselects the piece as for any refused move —
  recorded). Mode-scoped (Rev 4 review D5): a bot search left running in
  the background after a tab switch must not deaden the board in the other
  modes; its result is dropped there by the mode gate. Tail
  → `userMoveTask`; `let outcome = await finishAnimation(applied); if outcome == .cancelled { return }` (Rev 3 review D8: no
  clears, no chain); the keep-playing chain requires
  `(outcome == .landed || outcome == .cutShort) && boardState.fen == applied.fenAfter && !isEngineThinking`.
- `playSelectedLine()`: `cancelSupersededWork(); cancelBotMove()` first; no
  precomputed FEN chain; per step `guard !Task.isCancelled`, item 4's guards,
  and `outcome == .landed || outcome == .cutShort` to continue; `playLineTask = Task { … }`.
- `finishAnimation`: after the sleep, `if Task.isCancelled { if animatingPiece?.id == applied.animationID { animatingPiece = nil }; return .cancelled }`
  FIRST — every canceller snaps before cancelling, but a cancelled tail
  must never leave the board frozen on the pre-move frame if one does not
  (Rev 4 review D7; the precondition is also written into
  `cancelSupersededWork`'s doc comment: "call `snapAnimation()` first").
- `expandTreeForSelection(id:owner:)` / `expandTreeChunk(…, owner:)`:
  `expandTreeChunk` sets `isTreeAnalyzing = true; treeFlagOwner = owner;
  treeExpandingPaths[baseKey] = owner` and ends with
  `defer { if treeExpandingPaths[baseKey] == owner { treeExpandingPaths[baseKey] = nil }; if treeFlagOwner == owner { isTreeAnalyzing = false; treeFlagOwner = nil } }`
  (owner-keyed on both — Rev 3 review D2/D9); between retry attempts
  `guard token == treeToken, !Task.isCancelled else { return }`; its catch
  `if Task.isCancelled { return }` before the status write. The root
  expansion started by `analyzeMoveTree` gets its own owner id, and
  `analyzeMoveTree` sets `treeFlagOwner` SYNCHRONOUSLY next to its
  `isTreeAnalyzing = true` (`:319`) so the invariant "`isTreeAnalyzing` ⇒ an
  owner" holds before the task body runs (Rev 4 review D11); the
  `state == nil` exit (`:951-956`) becomes owner-keyed like every other flag
  write (D10).
- `expandTreeForSelection`'s `guard !isTreeAnalyzing` at `:917` stays (the
  root-vs-selection case is §2's item).

### Tier 3 — the fake and the tests

`FakeUCIEngine`: in the search subshell, AFTER the `while` loop and BEFORE
`printf '<bestmove'`, add `if ! kill -0 "$MAIN" 2>/dev/null; then exit 0; fi`
(Rev 3 review D13: this exact placement is the one that matters; the
in-loop check stays). `seedTreeForTesting(rootState:nodes:markExpanded: Bool = true)`.
`AppViewModelTaskTests.swift` (C1–C5, C7–C11), C6 in `EngineProcessTests.swift`.

## Load-bearing assumptions

- Closing the one-shot's read `FileHandle` from `onCancel` ends a blocked
  `bytes.lines` promptly (probed on the same API in item 2); a second
  `close()` is harmless (probed, Rev 3 review).
- The tree flag's owner discipline: exactly one expansion holds
  `isTreeAnalyzing` at a time. Root and selection expansions never run
  together (the selection returns at `:917` while the root runs; the root
  is started only by `analyzeMoveTree`, which cancels everything first).
- Both move tails sleep exactly `MoveAnimation.duration`, so the human's
  tail always resolves after the bot's; the keep-playing chain's
  `!isEngineThinking` relies on that (Rev 3 review T2, recorded).

## Out of scope (explicit)

- Cancelling the tree frame advancer (token-owned; item 4).
- Making detection itself cancellable — `(detection-off-main-actor)`
  (cancelling the task drops the result through the token; that item adds
  the between-phase checks and the stale-status clearing).
- Mode-aware ownership and the tab binding — `(viewmodel-mode-state)`.
- The root-vs-selection half of `(tree-selection-expansion-dropped-while-busy)`
  (nothing retries a selection made during the root expansion).

## Decisions taken

- 2026-09-01 · Rev 4 → Rev 5 (review round 4, "do not build as scoped —
  fix 5"; the two-cancel split itself was verified hole-free): C2 re-targeted
  to the unowned SELECTION expansion (the root case is HEAD behaviour, D1);
  C5 asserts the second `go` and the terminated first search through the
  log (D2); the double-click criterion dropped as unobservable (D3); every
  cancel call sits AFTER the entry point's existing guards (D4); the
  bot-search refusal is scoped to `.playAgainstComputer` so a background
  search never deadens the board in other modes (D5); C7 names a node the
  seed does not contain (D6); a `.cancelled` tail clears its own animation
  if the canceller did not snap (D7); `selectTreeNode` replacing the board
  without cancelling the bot/analysis is out of scope and the Goal says
  "through `invalidateAnalysis`" (D8); C10 now pins the stuck-flag
  mode-change case the `defer`s exist for (D9); the `state == nil` exit is
  owner-keyed and the root owner is set synchronously (D10, D11); Tier 1's
  text names the real mechanism (the loop ends normally on close) and keeps
  `markGone()` before the ladder (D12); C6 uses depth 1 with a 0.9 s margin
  (D13); `:426` (D14); §2's entry gets its acceptance rewritten at `/done`
  (G15); one commit (G16). Tensions recorded: cancelling the bot from
  `analyze`/`analyzeMoveTree`/`playSelectedLine` stops the Play Bot spinner
  instantly instead of at the search's end — intended, visible only in a
  tab the user just left; silent refusal is confined to Play Bot mode.
- 2026-09-01 · **Implement after Rev 5 without a fifth plan round.** Four
  rounds moved the design from "one cancel point" to the verified split;
  round 4 found no hole in the mechanism and its remaining findings were
  in the acceptance net and two guard details, all folded in above. The
  hi-tier code review (both reviewers, on real code) is the next net.
  Alternative: a fifth ~20-minute round. Rejected as diminishing returns on
  a plan whose mechanism has been probed clean.
- 2026-09-01 · Rev 3 → Rev 4 (review round 3): ONE cancel point was wrong —
  a human move must supersede searches but never the bot's landing tail, so
  `cancelSupersededWork()` and `cancelBotMove()` are separate, and
  `invalidateAnalysis(replacingBoard: false)` calls only the former (D1);
  `treeToken` is bumped with the rest and every engine-call catch tests
  `Task.isCancelled` first, because the persistent engine can surface a
  cancelled search as `.timeout`/`.engineGone` (D2); the tree flag and the
  expanding-paths set are owner-keyed so a no-op predecessor cannot clear
  the root expansion's flag and a cancelled task cannot remove a newer
  expansion's key (D3, D9); `analyze()` releases its flag in a `defer`
  (D4); C11 uses the real board move and the tree tests set
  `treeBranchCount = 1` so the retry loop issues one `go` per expansion
  (D5); criteria that were green at HEAD were re-anchored or dropped —
  C3 now fails at HEAD on the flag, C5 samples after the cancelled task's
  exit, C6 checks `<bestmove` at 3.5 s, C9 samples inside the window with
  a slow tree search, the old replay-stop criterion is dropped (D6); C7
  asserts on `treeNodes` and closes only the selection-vs-selection half of
  §2's item (D7); a `.cancelled` tail returns immediately (D8);
  `setInteractionMode` is dropped — cancelling on a tab switch would destroy
  work the user returns to (D10); a cancel leaves the status bar to the
  canceller, as today (D11); `onCancel` uses a Sendable `ProcessBox` so it
  can check liveness (D12); the fake's liveness check goes after the loop,
  before the marker (D13); `FakeUCIEngine` line numbers corrected (D14);
  `detect` assigns its task after `invalidateAnalysis` (G3); a refused move
  deselects silently, as any refused move does (G4).
- 2026-09-01 · Generations per task; results gated on generation AND FEN;
  `CancellationError` swallowed at every engine call site.
- 2026-09-01 · A user move during the bot's SEARCH is refused silently;
  during the reply's flight it is accepted (item 4's semantics).
- 2026-09-01 · No `/arch-review`: the published surface is unchanged, the
  new types are private, and the structural question Rev 3 raised (a
  nine-caller private method with two meanings) is resolved by the split —
  the split IS the structural decision, recorded here.
- 2026-09-01 · Implementation (Rev 5) staged; the orchestrator restored the
  `interactionMode == .analyzeLines` gate on `analyze()`'s error path (the
  implementer had dropped it — a failing analysis on a tab the user left
  would have written its error into the status bar; UI unchanged). Gates
  20–22 on that tree: 92/92 green three times in a row (80 → 92 methods).
  Both adv reviewers dispatched on the frozen diff.
- 2026-09-01 · Code review: adv-review-behavior "merge after fixing 4",
  adv-review-edge "merge after fixing 1". Applied: `cancelBotMove` clears
  the bot's own "Engine thinking..." so a silent canceller (`setSideToMove`)
  renders "Ready." instead of a stale busy string (+C13); C7 pins the
  successor's "Tree analysis ready."; C10b waits for `go` before flipping
  the mode; C3b pins the bot's FEN gate; C9 polls the status from 0.4 s to
  1.0 s with an 800 ms tree search; `startSelectionExpansion` TRANSFERS the
  flag to the successor (no one-frame blank); `invalidateAnalysis` snaps
  before it cancels; `markGone()` also on the bestmove-then-cancelled path;
  comments corrected (refusal delta; the fake's post-loop check is live only
  for the persistent engine's `kill(pid)`, `terminate()` signals the group).
  Accepted, not fixed: no escape hatch while a hung child holds
  `isBotSearching` (300 s timeout; the spinner is the cue); `onCancel` on
  the cancelling thread (pre-existing pattern); unguarded
  `UInt64(timeoutSeconds * 1e9)` (pre-existing). Verified by the edge
  reviewer's probes: `Task.cancel()` alone leaves `bytes.lines` blocked,
  closing the read end ends it in 1 ms (C6 is discriminating); an
  unstructured `Task {}` created inside a cancelled task starts uncancelled.
  Correction to C3's text: at HEAD it fails on `engineLines.isEmpty` (the
  lines land), not on the flag.
- 2026-09-01 · Accepted visible delta: a LEGAL move made during the bot's
  search in Play Bot is discarded (HEAD applied it, pushed an undo snapshot
  and could chain a reply on the board the bot was about to move on).
- 2026-09-01 · Gate 23 on the review-fixed tree: 94/94 green (C3b, C13
  added), zero app-target warnings. Committed on that run; gate 24 (repeat,
  flake data) recorded at `/done`.
- 2026-09-01 · Gate 24 (repeat on the committed tree): 94/94 green. Five
  green gate runs on this item in total (20–22 on the pre-review tree,
  23–24 on the fixed one), no flake observed. Shipped as `c5a31ca`.
