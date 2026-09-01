# Architecture review 2026-09-01 — stability, crash-avoidance, performance

Requested by Felix on 2026-09-01: "an in-depth review of what should be / could
be changed so it avoids crashes and is stable and fast. I don't want to change
the UI." Findings only; every actionable finding is filed in `TODO.md` (slug
cited inline). This is the evidence file those entries point at.

**What was reviewed.** The PRIMARY checkout's working tree
(`/Users/felix/Documents/Programming/swift/PawnPilot/PawnPilot/`) as of
2026-09-01 — HEAD `9dca10e` (2026-02-08) PLUS its uncommitted ~900-line refactor
(`MoveTreeLogic.swift` staged; `AppViewModel`, `ContentView`, `BoardState`,
`MoveValidator`, tests and nine `Localizable.strings` modified). That is the
code Felix builds, so **all `File.swift:NN` references below are to that tree,
not to `9dca10e`**. Re-derive line numbers before planning against them. Every
Swift file was read in full (6,524 lines).

**Gate.** Run by the orchestrator, not a subagent: `xcodebuild … -only-testing:
PawnPilotTests test` with DerivedData at `~/.claude/jobs/2be18945/tmp/dd` —
**TEST SUCCEEDED** (35 test methods). No warnings were harvested; an
incremental build masks them.

**Verification.** After drafting, an independent read-only pass re-checked
every load-bearing claim (A–O in its brief) against the same tree: all
verified, one downgraded (F9 — the search early-exits), one upgraded from
estimated to reproduced (F2 — a second `FileHandle.bytes` iterator loses what
the first had buffered: iterator 1 consumed `l1` and broke, iterator 2 saw only
`l5, l6`). Its five additional findings are folded into F1, F2, F4, F5 and the
new F15 below, each marked "(verifier)".

**Three things were measured, not read:**
- `printf 'uci\nquit\n' | ./PawnPilot/Engine/stockfish-macos-m1-apple-silicon`
  → `id name Stockfish dev-20251221-c467fe5b`, `option name UCI_Elo type spin
  default 1320 min 1320 max 3190`.
- A 15-line Swift program that spawns `/bin/cat`, terminates it, waits, then
  calls `FileHandle.write(_:)` on its stdin — the exact shape of
  `StockfishEngine.runEngine`'s `defer` — **exited with status 141 (SIGPIPE)**.

## Phase 1 — the architecture as actually built

1. **One app target, one unit-test target, one UI-test target** (pbxproj,
   verified). No SPM packages: `FENDetector/` and `NextMoveModels/{Engine,
   Models,Rules,MoveTree,Detection}` are folders, and the compiler enforces no
   boundary between them. `AppBundle`'s `#if SWIFT_PACKAGE` branch and
   `Implementation_plan.md`'s NextMoveKit / FENDetectorKit targets are fossils
   of a package layout that does not exist.
2. **Layers as implemented**: `ContentView.swift` (2,192 lines, every view in
   one file) → `AppViewModel` (1,064 lines, `@MainActor ObservableObject`,
   26 `@Published`) → pure value-type domain (`BoardState`, `MoveValidator`,
   `LegalMoveGenerator`, `MoveTreeLogic`) → two engine wrappers + one
   detection pipeline. The domain layer is genuinely pure and testable; the
   view model is where all orchestration, all state and all resets live.
3. **Source of truth**: `AppViewModel.boardState`. Undo/redo are snapshot
   stacks. Analysis output (`engineLines`, `treeNodes`, selections,
   `legalDestinations`) is derived state that is **cleared by hand at 14
   sites** (`detect`, `analyze`, `analyzeMoveTree`, `engineMove`,
   `applyUserMove`, `setSideToMove`, `resetBoard`, `rotatePosition`,
   `setPiece`, `undo`, `redo` — `AppViewModel.swift:160-163, 178-183, 198-201,
   206-209, 251-254, 259-262, 352-356, 361-365, 370-373, 439-443, 462-466,
   472-477, 486-491, 544-549, 594-598, 610-614`).
4. **DI**: init-time construction inside `AppViewModel.init` (`:108-116`).
   `EngineAnalyzing` is conformed to by both engines and used as a type
   nowhere. Tests construct the real `AppViewModel`, which loads the CoreML
   model and locates the engine.
5. **Concurrency** (the deep-dive theme; verified from pbxproj `:498-499,
   541-542` and grep): app-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
   with `SWIFT_APPROACHABLE_CONCURRENCY = YES`, Swift 5 language mode. Exactly
   ONE actor (`PersistentStockfishEngine`). `StockfishEngine` is a main-actor
   class stamped `@unchecked Sendable`. **No `nonisolated`, `@concurrent` or
   `Task.detached` exists in live code** (the only `Task.detached` is in the
   never-instantiated `DetectionService`), so every FENDetector type is
   main-actor-isolated. Tasks are spawned at seven sites in the view model;
   one (`treeExpansionTask`) is stored; cancellation reaches only that one.
6. **Process boundary**: a fresh Stockfish child per `analyze()`/`engineMove()`
   (`StockfishEngine`, 300 s timeout, `TimeoutBox` actor), plus one persistent
   child for the variation tree (`PersistentStockfishEngine`). UCI parsing,
   the `setoption` block and the `[safe:]` subscript are duplicated verbatim.
   All stdin writes go through the legacy non-throwing `FileHandle.write(_:)`;
   there is no SIGPIPE handling anywhere.
7. **Persistence**: none. No `UserDefaults`/`@AppStorage`; recents in memory.
8. **Failure architecture**: `StockfishError` (a proper `LocalizedError`) →
   `statusMessage`. Detection cannot fail from the user's point of view:
   warnings are `os.Logger`-only, `DetectionStatus.failed` is never produced,
   and the view that would render either status is never mounted (F7).

### Drift notes (what the system says about itself vs. what is enforced)

- `Implementation_plan.md` describes packages, "macOS 14+", and
  `Resources/Engine/arm64/stockfish`. Reality: one target, deployment target
  13.5, the engine copied into `Contents/MacOS` by a Copy Files phase and
  re-signed by the "Sign Stockfish" script phase (pbxproj `:285-305`). Treat
  the plan as history.
- `README.md` "Known Gaps: Recent images are kept in memory only (no persisted
  history)" reads as a missing feature. Actually the recents shelf is not in
  the UI at all — `recentsView` is defined and never referenced — so the three
  full-resolution `NSImage`s are retained for nothing (F7).
- `DetectionStatus` carries a `.failed(String)` case with a red-label branch in
  `detectionStatusView` (`ContentView.swift:653-655`) that cannot be reached:
  the case is never constructed and the view is never mounted.
- `BoardDetector`'s doc comment says "Wraps Vision rectangle detection"
  (`BoardDetection.swift:31`); the file imports no Vision and hand-rolls a
  luminance scan. `detectBoard` is `async throws` with zero suspension points.
  `luminanceMask`/`luminanceMaskQuad`/`luminanceRange` (`:266-353`) and
  `DetectionConfig` (`:356-363`) are private and never called.
- Two premises in the July TODO were wrong and are corrected in the
  disposition table at the end: availability IS checked against the app
  target's 13.5 at compile time, so the 26.2 test target hides nothing; and
  the view layer does not "reimplement" move application — it calls `apply`.

## Phase 2 — findings, most severe first

Severity is about user-visible consequence. "Verified" = read in source and,
where marked, reproduced; "estimated" = inferred, with what would settle it.

### F1 [High · verified + reproduced] — writing to a dead Stockfish kills the app with SIGPIPE

Evidence: `StockfishEngine.swift:91-96` — `defer { send("quit"); writer.
closeFile(); reader.readabilityHandler = nil; process.terminate() }`. The
timeout task (`:99-106`) calls `process.terminate()` from a detached sleep,
which ends the `for try await line in reader.bytes.lines` loop on EOF; the
function then throws `.timeout` (`:146-148`) and the `defer` writes `quit` into
a pipe whose only reader has exited. `send` (`:68-72`) uses `FileHandle.write(_
data:)`, the legacy API that neither throws nor suppresses SIGPIPE. The same
shape exists in `PersistentStockfishEngine.shutdownProcess` (`:166-171`) and,
worse, in `ensureProcess` (`:120-135`): `if process == nil { try startProcess() }`
never restarts a child that has exited, so after any engine death (crash, OOM
on `Hash`, sandbox kill, the F2 interleaving) the next `send("setoption …")`
(`:78`) writes to the dead pipe. `grep -rn SIGPIPE|NOSIGPIPE|write\(contentsOf`
over `PawnPilot/` returns nothing.

Reproduction: the 15-line program described above exits 141. The app has no
signal handler, so the same write in-process terminates it. A 300 s search
timeout — reachable with depth 30 + strict depth + MultiPV 10, which is why the
help text warns "Search depth 30 is very slow" — therefore ends in a crash
rather than the "Engine timed out" status the code intends. (Under the Xcode
debugger SIGPIPE shows up as a stop, which is probably why it has read as a
hang rather than a crash.)

(verifier) The same route fires when Stockfish dies at LAUNCH — an unsigned
or AMFI-killed binary, a sandbox denial: `process.run()` succeeds, the child
exits, the loop ends on EOF, the `defer` writes. So a broken engine install
crashes the app instead of surfacing `StockfishError.startFailed`.

Direction: one write helper per engine that uses the throwing
`write(contentsOf:)`, treats `EPIPE` as "engine gone", and never runs after the
reader saw EOF; `fcntl(fd, F_SETNOSIGPIPE, 1)` on the stdin write end right
after `Pipe()` creation (local, no global `signal()` side effect); track child
liveness with `terminationHandler` and let `ensureProcess` restart on
`isRunning == false`. Cost S. **Filed: `(engine-pipe-write-after-death-sigpipe)`.**

### F2 [High · verified] — the persistent engine actor is reentrant; two searches interleave on one pipe

Evidence: `AppViewModel.selectTreeNode` spawns `Task { await
expandTreeForSelection(id:) }` **unstored** (`:345`). `invalidateAnalysis`
(`:668-684`) sets `isTreeAnalyzing = false`, bumps `treeToken`, cancels only
`treeExpansionTask` — it cannot reach the selection task, which is suspended
inside `PersistentStockfishEngine.runSearch` at `for try await line in
reader.bytes.lines` (`:99`). Any invalidating action (a board move, Reset,
Undo, Rotate, side-to-move, piece edit, new image) followed by Analyze in the
Variations tab passes `analyzeMoveTree`'s `guard !isTreeAnalyzing` (`:248`)
and calls `treeEngine.analyze` again. Actors are reentrant at suspension
points, nothing in `analyze` (`:18-47`) records "a search is in flight", so the
second call sends `setoption`/`isready`/`position`/`go` (`:78-97`) while the
first search runs and opens a SECOND `reader.bytes.lines` iterator on the same
`FileHandle` (`readUntil` `:184-189`, then `:99`). Bytes are then split
arbitrarily between two parsers; whichever misses `bestmove` waits for the
300 s timeout — and Stockfish itself receives `setoption name Threads` /
`Hash` mid-search, which its UCI loop does not guard.

Consequence: the "Analyze" click appears to do nothing, then (5 minutes later)
"Engine timed out while searching." — or the engine dies and F1 fires on the
next write. Sequence to reproduce (§5 sitting): Variations → Analyze → select
a node → immediately make a board move → Analyze.

Related fragility, same file, **reproduced by the verifier**: each `readUntil`
and each `runSearch` creates a fresh `bytes` sequence (`:89, :99, :129, :133,
:185`); `FileHandle.AsyncBytes` reads in chunks, so any bytes buffered past the
line at which a loop `break`s are discarded (experiment: iterator 1 consumed
`l1` and broke; iterator 2 saw only `l5, l6`). It works today only because
Stockfish is silent between `bestmove` and the next command; under the
interleaving above the first search can lose its `bestmove` outright.

(verifier) Two more crash/teardown paths in the same actor: `runSearch`
captures `reader`/`writer` per search (`:55`), but a cancellation
(`treeExpansionTask?.cancel()` at `AppViewModel.swift:218, 274, 678`) fires
`onCancel: { Task { await shutdownProcess() } }` (`:115-117`), which CLOSES
those handles (`:171, :174`). If the old search then resumes with a buffered
line and reaches `send("stop")` (`:104` → `:64`), `FileHandle.write(_:)` on a
closed handle raises `NSFileHandleOperationException` — an uncaught ObjC
exception, i.e. a crash. And `analyze`'s `catch { shutdownProcess() }`
(`:43-46`) acts on whatever `process` is current, so a stale search failing
AFTER a new one has called `startProcess` (`:122`) tears the replacement down
mid-search.

Direction: the actor owns ONE reader task for the child's lifetime that
converts stdout into an `AsyncStream<String>` of lines; `analyze` is an
explicit `idle | searching` state machine — a second call either awaits the
first or sends `stop`, drains to `bestmove`, then starts; expose `stop()` so
the view model can abort instead of ignore. Cost M. **Filed:
`(persistent-engine-serialize-searches)`.**

### F3 [High · verified] — board detection runs entirely on the main thread

Evidence: `DetectorPipeline`, `BoardDetector`, `BoardNormalizer`,
`SquareExtractor`, `PieceClassifier`, `ImageSanitizer`, `OrientationEstimator`
carry no isolation annotation (grep above), so under the project's default
isolation `DetectorPipeline.process(cgImage:)` (`DetectorPipeline.swift:57`) is
`@MainActor`. `AppViewModel.detect` awaits it from a `Task {}` (`:166-167`)
that inherits the main actor. `BoardDetector.detectBoard` is `async` with no
`await` inside (`BoardDetection.swift:35-43`). `PieceClassifier.classify` runs
64 `VNCoreMLRequest`s serially inside `queue.sync` (`PieceClassifier.swift:64-68`),
blocking the caller for the duration. Nothing downsamples: `edgeBasedDetect`
visits every row and every column of the full-resolution screenshot through a
per-pixel closure and allocates a `[Run]` per row/column
(`BoardDetection.swift:59-76, 147-172`); `bestAlternatingSegment` is O(runs²)
per row in the worst case (`:190-211`).

Consequence: on a Retina screenshot (5120×2880 = 14.7 M pixels, scanned twice)
plus a 1024² CIContext render plus 64 Vision requests, the UI is frozen for the
whole detection — the "Detecting board…" status set at `:165` may not even be
painted before the block starts. Duration not measured here (a §5 sitting
should time it on a real screenshot; estimate 1–3 s, longer on noisy photos).

Direction — two items, because one is a threading change and the other an
algorithmic one:
- Move the pipeline off the main actor: mark the FENDetector types
  `nonisolated`, make their outputs `Sendable` (`BoardQuadrilateral` already
  is), make `process` **`@concurrent`** — under approachable concurrency a
  plain `nonisolated async` function still runs on the caller's actor — drop
  the `DispatchQueue`, classify the 64 crops in a `TaskGroup` (Vision handlers
  are independent), and hop to main only to publish. While there, stop
  sanitising every crop twice (`DetectorPipeline.swift:94-95` and again in
  `PieceClassifier.swift:72`). Cost M. **Filed: `(detection-off-main-actor)`.**
- Bound the edge scan: downsample to ~1024 px on the long side before
  `edgeBasedDetect` (its bins are ±6 px and the normaliser re-samples to 1024²
  anyway), scale the quad back to source coordinates for `BoardNormalizer`,
  and read pixels through one helper that first converts to a known 8-bit RGBA
  layout — today four readers (`BoardDetection.swift:47-56`,
  `ImageSanitizer.swift:37-46`, `OrientationEstimator.swift:49-56`,
  `GridRefiner.swift:7-12`) assume 8-bit RGB-first and silently produce garbage
  for 16-bit or grayscale inputs (in-bounds, so no crash — verified the index
  arithmetic). Cost S–M. **Filed: `(detection-downsample-before-edge-scan)`.**

### F4 [High · verified] — moves are validated against a board that changes before they are applied

Evidence: `applyUserMove` (`AppViewModel.swift:430-448`) validates, then spawns
`Task { await performAnimatedMove(move:) }`. `performAnimatedMove`
(`:572-586`) validates again BEFORE `Task.sleep(0.35 s)` and mutates
`boardState` AFTER it with no re-check; `BoardState.apply` (`BoardState.swift:
89-153`) does not check side-to-move, it moves whatever sits on `from`.
Consequences reachable with two clicks inside 350 ms:
- Two white moves both validated against the pre-move board → both apply →
  white moves twice, black's turn is skipped.
- `undo()` (`:588-602`) during the sleep pops the pre-move snapshot and
  restores it; the sleeping task then applies the move anyway, with its undo
  entry already consumed (`canUndo` false, move on the board).
- Tree selection: `animateTreeSelectionIncremental` (`:939-958`) applies
  `node.uci` to whatever `boardState` currently holds. If the previous
  animation was interrupted mid-path by a new click (token bump at `:331`),
  the board is at an intermediate position and the single new move lands on
  top of it — e.g. white's `g1f3` applied before black's `e7e5` — a position
  that is not the tree's, from which every later `move(fromUCI:)` and
  `apply` compound the error. (verifier) Easiest trigger: hold Down-arrow in
  the Variations list — `handleMove` (`ContentView.swift:1106-1126`) calls
  `onSelect` per key repeat.
- (verifier) `resetBoard` (`:469-480`), `rotatePosition` (`:482-494`) and
  `detect` (`:156-192`) replace `boardState` and wipe history during the
  sleep; the pending `apply` then lands the stale move on the NEW board —
  `apply` checks only that SOME piece sits on `from` (`BoardState.swift:90`),
  and after a rotation that is a different piece.
- (verifier) `analyzeMoveTree` (`:265-279`) and `analyze` (`:212-230`) capture
  `boardState` as the tree root / the FEN without bumping
  `treeAnimationToken`; the Analyze button is enabled during a per-ply
  animation because re-selecting an expanded node returns early at `:757`
  with `isTreeAnalyzing == false`. The pending `apply` lands after the root
  was captured, so tree root ≠ displayed board.

Direction: change the model synchronously at the moment a move is accepted
(apply, push snapshot, set `lastMove`); the animation becomes purely visual —
`animatingPiece` describes a piece in flight and `BoardGridView` already hides
the piece at both ends while one is animating (`ContentView.swift:1287`), so
the piece appears at its destination when `animatingPiece` clears, exactly as
today. Tree selection computes its target with `MoveTreeLogic.state(forPath:)`
and sets it authoritatively; an interrupted animation snaps to the target
instead of leaving a hybrid. Same 0.35 s, same hidden-square rule — no visible
change. Cost M. **Filed: `(apply-move-then-animate)`.**

### F5 [High · verified] — only one of seven Tasks can be cancelled; stale results are ignored but stale WORK is not

Evidence: unstored `Task`s at `:228` (`analyze`), `:386` (`engineMove`),
`:418` (`playSelectedLine`), `:437` (`applyUserMove`), `:332` and `:345`
(`selectTreeNode`); `invalidateAnalysis` cancels `treeExpansionTask` only.
`StockfishEngine.runEngine` has no `withTaskCancellationHandler` and no
`Task.checkCancellation`; a superseded search runs to full depth on
`activeProcessorCount/2` threads with a 128 MB hash while the replacement
spawns beside it. Three concrete consequences beyond wasted cores:
- `engineMove` (`:386-407`) applies `line.moves.first` after its `await` with
  no token check (compare `analyze`'s `guard token == analysisToken` at
  `:231`), and `invalidateAnalysis` never resets `isEngineThinking` — so
  Reset, Undo or a new image during "Engine thinking…" plays the move for the
  OLD position on the NEW one whenever it happens to be legal there.
  (verifier) `applyUserMove` (`:430-436`) has no `isEngineThinking` guard
  either, so a user move during "Engine thinking…" is the same failure.
- `playSelectedLine` (`:410-428`) replays a PV onto whatever the board becomes
  during the replay.
- The engine token is a fresh `UUID`, not a board identity: a result is
  accepted as long as nothing invalidated in between, even though nothing
  proves it belongs to the current position.

Direction: per-purpose stored task handles (or one `activeTasks` set) that
`invalidateAnalysis` cancels; engine wrappers honour cancellation (`stop` +
drain, or terminate — safely, after F1); gate every asynchronous result on the
FEN captured at start rather than a bare UUID. Order matters with F1: a cancel
path that terminates the child and then writes is exactly the SIGPIPE path.
Cost M. **Filed: `(view-model-task-ownership-and-cancel)`.**

### F6 [Medium · verified] — a malformed UCI square traps the process

Evidence: `rankIndex(for:)` (`BoardState.swift:305-308`) returns
`Int(String(char)) - 1` unchecked: `"e0e4"` → rank −1, `"e9e4"` → rank 8.
`Board.subscript` (`FENDetector/Board.swift:48-50`) is `precondition`-guarded,
so `piece(at:)` (`:185-187`), `apply` (`:90`), `ArrowsOverlay.arrowSegments`
(`ContentView.swift:1424, 1438`) and `BoardSquare.label` (`:267-270`) all trap
on such a square. A second copy of the parser, `enPassantSquare(from:)`
(`MoveValidator.swift:353-359`), has the same gap. Today the only producer of
UCI text is Stockfish's PV, which is well-formed — but stderr is merged into
stdout (`StockfishEngine.swift:56`), and the parser accepts any line that
contains both `pv` and `score cp|mate N`, so the guard is "Stockfish never
prints an odd line", which is not an invariant the app owns.

Direction: one failable `BoardSquare.init?(uci:)` with range checks, used by
both parsers and the tests' helper; keep the subscript trapping (it is an
invariant), make it unreachable from strings. Cost S. **Filed:
`(uci-square-parse-range-check)`.**

### F7 [Medium · verified] — dead views keep three screenshots and the detection output alive

Evidence: `detectionStatusView` (`ContentView.swift:643-670`) and `recentsView`
(`:672-708`) are defined and referenced from no `body` (grep: their only
mentions are their own definitions and `recentsView`'s internals).
`viewModel.recents` is read only inside `recentsView`; `addRecent`
(`AppViewModel.swift:631-637`) retains up to three full-size `NSImage`s. On a
5K display a decoded screenshot is ~59 MB, so the shelf nobody can see costs
up to ~180 MB. `detectionStatus` is read only by the dead view, so
`DetectionOutput` — with `normalizedBoard` (1024²×4 B), 64 `squareCrops`, and
the `fen` string that the July TODO worried contradicts the board — is
retained for the app's lifetime for nothing. `DetectionService` is never
instantiated; `EngineAnalyzing` is never used as a type; `GridRefiner` and the
`useGridRefinement` branch of `SquareExtractor` are behind a constant `false`
(`DetectorPipeline.swift:44`); `BoardDetector.luminanceMask*` and
`DetectionConfig` are unreferenced; every detection emits a "confidence is
low" warning because confidence is the constant 0.2 or 0.05
(`BoardDetection.swift:37, 40`; threshold 0.4 at `DetectorPipeline.swift:66`).

Direction: one deletion-only item. It closes three July items outright
(`detected-fen-mismatch`, `detection-failed-unreported`,
`detection-output-retains-images`) and absorbs three more (`dead-code-purge`,
`board-detector-docs`, `detection-confidence-constant`). Product note for
Felix: if a recents shelf is wanted later, git has it; keeping it retained
but invisible is the worst of both. Cost S. **Filed:
`(dead-detection-and-recents-purge)`.**

### F8 [Low · verified] — a selection made while a branch is expanding is never expanded

Evidence: `expandTreeForSelection` (`:749-772`) returns at `guard
!isTreeAnalyzing` (`:751`); nothing records the request, nothing retries when
the running expansion completes. The user sees the selected node with no
children until they click away and back. Direction: remember the latest
requested path and expand it when the current expansion finishes (or abort
the current one via F2's `stop()`). Cost S. **Filed:
`(tree-selection-expansion-dropped-while-busy)`.**

### F9 [Low · verified, downgraded] — a legal-move search on every render

Evidence: `ContentView.scoreOverrideText` (`:190-192`) reads
`viewModel.gameOverScoreText` (`AppViewModel.swift:686-688`), which runs
`LegalMoveGenerator.hasAnyLegalMove` plus `isInCheck` on EVERY `ContentView`
body evaluation, including every slider tick (the sliders write `@Published`
values at `ContentView.swift:539-583`). (verifier) `hasAnyLegalMove` returns
at the FIRST legal move (`MoveValidator.swift:302-304`), so in an ordinary
position this is a handful of `isLegal` calls, not a full generation; the full
64-square scan happens only near mate or stalemate. Still per-render work that
depends only on `boardState`. Direction: compute once per `boardState` change
(a `didSet`-fed stored value). Cost S. **Filed:
`(game-over-recomputed-per-render)`.**

### F10 [Low · verified] — all three tab panels re-render on every update

Evidence: `AppKitTabView.updateItems` (`ContentView.swift:1698-1719`) assigns
`hosting.rootView = item.view` for all three `NSHostingView`s on every
`updateNSView`, and `tabItems` (`:223-241`) rebuilds three `AnyView`s per body.
Only the selected tab is visible. Direction: update the selected tab's root
view, defer the others until selected (or wrap panels in `EquatableView`);
layout must stay identical. Cost S. **Filed:
`(tab-panels-rerender-on-every-update)`.**

### F11 [Low · verified] — the list key handler re-steals first responder

Evidence: `KeyEventHandler.updateNSView` (`:1862-1868`) calls
`window.makeFirstResponder(nsView)` whenever `isActive` is true; `isActive`
is set true on any row tap (`:941, :948, :1092, :1099`) and never set false.
After one click in a list, any later re-render — a status change, a slider —
takes focus back from the piece-editor `TextField` (`:823-826`), which the
editor focuses through `isPieceEditorFocused`. Direction: claim first responder
only on the false→true transition and clear `isActive` when the editor opens.
Cost S. **Filed: `(focus-stolen-by-key-handler)`.**

### F12 [Low · verified] — launch does the CoreML load, CIContext creation and engine lookup synchronously

Evidence: `PawnPilotApp` holds `@StateObject var viewModel = AppViewModel()`;
`AppViewModel.init` (`:108-116`) builds `DetectorPipeline()` whose default
arguments call `PieceClassifier.loadDefaultModel()` (`PieceClassifier.swift:
25-49`, `MLModel(contentsOf:)`) and `BoardNormalizer()` (`CIContext()`), and
runs `findEngineURL` with a recursive resource enumerator fallback (`:967-1005`).
`ContentView` additionally builds an `NSTabView` and measures six localised
strings in static initialisers (`:73-92`). Direction: load the classifier and
context lazily off-main at init (a detached task the first `detect` awaits).
Measure with the existing `XCTApplicationLaunchMetric` before and after. Cost
S. **Filed: `(classifier-model-load-at-launch)`.**

### F13 [Low · found in passing, measured] — bot strengths 1 and 2 are the same strength

Evidence: `elo(for:)` (`AppViewModel.swift:620-629`) maps strength 1…5 to
800/1100/1400/1700/2000; the bundled engine reports `UCI_Elo … min 1320`.
Stockfish's `Option::operator=` drops an out-of-range spin value silently
(**estimated from Stockfish source, not observable over UCI** — the verifier
sent `value 800` and `value 5000` and got no message either way, whereas an
unknown option name does print `No such option`), so 800 and 1100 leave
`UCI_Elo` at its default 1320 and strength 3 (1400) is nearly identical. Not
a stability item, but it is a wrong mapping in a shipped control and the fix
is one function with the slider untouched. Cost S. **Filed:
`(bot-strength-elo-floor)`.**

### F14 [Medium · verified] — a fresh Stockfish per analysis and per bot move

Evidence: `StockfishEngine.runEngine` (`:42-152`) spawns a process, performs
the `uci`/`isready` handshake and sets `Hash 128` on every call; Stockfish's
NNUE network (the bulk of the 114 MB binary) is loaded on each spawn and the
hash table starts cold. The persistent engine exists but serves only the tree.
Direction is the July item `(engine-consolidate)`: after F1, F2 and F5, one
engine actor for all three modes, one UCI parser, one `setoption` block, and
`stop()` as the cancel primitive. Cost M. **Kept as `(engine-consolidate)`,
re-tiered hi, promoted to §1.**

### F15 [Low · verifier] — a user move from a shown variation makes the original position unrecoverable

Evidence: `selectTreeNode` replaces the board with the variation and keeps the
pre-selection position only in `treeSelectionSnapshot` (`:325-327`), which it
never pushes onto the undo stack (`:297-346`). `applyUserMove` from that
position calls `invalidateAnalysis`, which drops the snapshot (`:683`), and
`performAnimatedMove` pushes the VARIATION state as the undo entry (`:578`).
Undo then walks back to the variation, never to the position the user had
before clicking the tree. Direction: on the first user move out of a
variation, push the pre-selection snapshot first (undo semantics only — no
visible change), or keep the behaviour and say so in the help text (that
would be a UI change → §5). Cost S. **Filed:
`(tree-variation-user-move-loses-original)`.**

### Structural (kept from July, verified 2026-09-01, still true)

- `(viewmodel-mode-state)`: the 14-site reset census above. Every §0 item
  edits `AppViewModel`; decision below on ordering.
- `(typed-board-state)`: `activeColor`/`castling`/`enPassant` are still
  `String`s; `sideToMove` (`BoardState.swift:180-183`) is the pattern the rest
  should follow; `state.castling.contains(right)` at `MoveValidator.swift:99`;
  castling rights derived at `BoardState.swift:63-73, 208-239`,
  `DetectorPipeline.swift:161-185`, `BoardState.swift:334-343`.
- `(move-semantics-dedupe)`: two real implementations of move application —
  `BoardState.apply` (`:89-153`) and `MoveValidator.kingInCheckAfterMove`
  (`:134-177`) — plus a third statement of piece geometry in
  `LegalMoveGenerator.candidateMoves` (`:311-350`). The view layer calls
  `apply`; it does not reimplement it (July premise corrected).
- `(observability-consolidate)`: one `os.Logger` (`AppViewModel.swift:7`),
  four `print`s behind flags (`SquareExtractor.swift:72-76, 90`,
  `PieceClassifier.swift:62`), unlocalised `DetectionWarning`s logged only,
  ~40 localised `statusMessage` sites.
- `(rules-perft-tests)`: `MoveValidator`/`LegalMoveGenerator` still have zero
  direct coverage. Caveat for the plan: `candidateMoves` enumerates
  destinations, not promotion variants, so perft must either count auto-queen
  promotion as one move or extend the generator first.

### Change-cost decision recorded here

Every High item edits `AppViewModel`, and `(viewmodel-mode-state)` would
rewrite the same file. Ordering chosen: **§0 first, the mode-enum refactor
after.** Reason: each §0 item is bounded, has a reproducible failure and a
testable acceptance check; the refactor is wide and its value is
maintainability, not a fixed crash. Doing the refactor first would put five
crash fixes behind an unbounded diff. Felix can overturn this by moving
`(viewmodel-mode-state)` into §0.

## Disposition of the July 2026 TODO.md

| July slug | 2026-09-01 disposition |
|---|---|
| `(engine-cancel)` | verified; widened and re-filed as `(view-model-task-ownership-and-cancel)` |
| `(detected-fen-mismatch)` | **closed, not built** — the label lives in a view that is never mounted; `DetectionOutput.fen` goes with `(dead-detection-and-recents-purge)` |
| `(detection-failed-unreported)` | **closed, not built** — `.failed` has no live consumer; folded into the purge |
| `(detection-output-retains-images)` | folded into `(dead-detection-and-recents-purge)` |
| `(dead-code-purge)` | verified; renamed/widened into `(dead-detection-and-recents-purge)` |
| `(board-detector-docs)` | folded into the purge (the dead branches go, the comment with them) |
| `(detection-confidence-constant)` | folded into the purge (drop the mechanism) |
| `(double-sanitize)` | verified; folded into `(detection-off-main-actor)` |
| `(deployment-target-mismatch)` | premise corrected; re-filed as `(deployment-target-alignment)`, trivial · Low |
| `(engine-consolidate)` | verified; re-tiered hi; §1 |
| `(viewmodel-mode-state)` | verified; §3 |
| `(typed-board-state)` | verified; §3 |
| `(move-semantics-dedupe)` | premise corrected ("third copy" is a call, not a copy); §3 |
| `(observability-consolidate)` | verified; §3 |
| `(rules-perft-tests)` | verified; §4 with the promotion caveat |
| `(settings-persistence)` | not a stability item; kept in §4 as a feature |
