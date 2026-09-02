# TODO

The single work queue. Format: `- [ ] (slug) **[tier · priority · area]** what, and where.`
Tier (`trivial|standard|hi`) governs plan and review depth per CLAUDE.md — it is
not priority. Sections are ordered; within §0 the order is decided — work it top
to bottom.

Evidence for everything filed here lives in `arch-reviews/` — this queue was
rebuilt on 2026-09-01 from `arch-reviews/2026-09-01-stability-performance.md`
(finding numbers `F1…F14` cited per item), which also carries the disposition of
every item from the July 2026 queue. Shipped records go to `DONE.md`. This file
holds only what is still to do.

**Line references** (`File.swift:NN`) are to the PRIMARY checkout's working tree
on 2026-09-01, which carried an uncommitted ~900-line refactor (`MoveTreeLogic`,
`PieceColor`, sanitised castling/en-passant, the piece editor, their tests) on
top of `9dca10e`. **Re-derive before planning** — `/plan` step 2 says so and it
applies doubly here.

**Standing constraint on every item: the visible UI does not change** (Felix,
2026-09-01; CLAUDE.md § Standing constraints). Layout, controls, copy, colours,
animation timing, list rendering stay pixel-equivalent. If an item's cleanest
fix would alter the UI, ship the invisible half and file the UI half in §5.

**§5 is a PARALLEL track, not a later one.** Its entries are manual sittings only
Felix can run on the built app; they must never queue behind agent work.

## Running `/work` with no arguments — read this first

**The queue is §0, top to bottom. When §0 is empty, STOP and report** — do not
fall through into §1–§4. §1 is decided but deliberately ordered AFTER §0 (its
rationale is in the review's "Change-cost decision"); §2–§4 are filed, not
scheduled. Refilling §0 is a priority decision and Felix's; if §0 is empty, say
so and name what §1 and §2 nominate — do not promote silently.

**Never eligible unless Felix says so:** all of **§5** (manual sittings), and
`(settings-persistence)` in §4 (a feature, not stability — filed so it is not
lost, not so it is built).

**Ordering rules inside §0 are all discharged** (2026-09-01: the SIGPIPE
item before the cancel item; the serialised actor before
`(engine-consolidate)`; and `(apply-move-then-animate)` before the cancel
item, which was reordered after the cancel item's plan review showed its
guarantee needed synchronous moves first). Work top to bottom.

## 0. Next up — work these first, in this order

*Filled 2026-09-01 from the review. Empty as of 2026-09-02: all five §0
items shipped (see `DONE.md`). The next `/work` run starts on §1.*

## 1. Architecture — decided, in this order (after §0)

*Decided direction, deliberately queued behind §0 — see the review's
"Change-cost decision". Do not promote without saying so.*

- [ ] (engine-consolidate) **[hi · Medium · engine]** One engine actor, one UCI
  parser, one `setoption` block, task cancellation as the cancel primitive
  (ticket-keyed inside the actor; there is deliberately no bare `stop()` —
  see `(persistent-engine-serialize-searches)`, `75a2fb5`). Today
  `StockfishEngine` (`:42-152`) spawns a fresh Stockfish, redoes the
  `uci`/`isready` handshake, reloads the NNUE network and starts with a cold
  128 MB hash on EVERY `analyze()` and EVERY bot move; `PersistentStockfishEngine`
  exists but serves only the tree; `parseInfo` (~50 lines), the option block
  and the `[safe:]` subscript are duplicated verbatim (review F14). Builds on
  `(persistent-engine-serialize-searches)`; retire `StockfishEngine` and
  `TimeoutBox`. `EngineAnalyzing` IS now a used type — `AppViewModel` stores
  both engines as `any EngineAnalyzing` and has an `init(engine:treeEngine:)`
  injection seam (`d960674`, 2026-09-01) that the view-model tests build the
  fakes through; keep the protocol (or its successor) as that seam. Acceptance: bot
  move latency at fixed depth measured before/after; all three modes on one
  process; the §4 fake covers timeout, EOF and `stop`.

- [ ] (viewmodel-mode-state) **[hi · Medium · view-model]** Model the three
  interaction modes as an enum with associated state. `AppViewModel` is 1,064
  lines / 26 `@Published`, and the same "clear engineLines /
  selectedEngineLineID / treeNodes / selectedTreeNodeID / legalDestinations"
  block is hand-written at 14 sites (`:160-163, 178-183, 198-201, 206-209,
  251-254, 259-262, 352-356, 361-365, 370-373, 439-443, 462-466, 472-477,
  486-491, 544-549, 594-598, 610-614`). Each entry point must remember to
  reset the other two modes; forgetting one is a silent bug. Queued after §0
  on purpose: every §0 item edits this file with a bounded diff, this one
  rewrites it. `/arch-review` on the plan.

## 2. Stability — filed, not scheduled

*Adjacency means nothing here.*

- [ ] (uci-square-parse-range-check) **[trivial · Medium · rules]** A malformed
  UCI square traps the process (review F6). `rankIndex(for:)`
  (`BoardState.swift:305-308`) returns `Int(String(char)) - 1` unchecked, so
  `"e0e4"` → rank −1 and `"e9e4"` → rank 8; `Board.subscript`
  (`FENDetector/Board.swift:48-50`) is `precondition`-guarded, so `piece(at:)`,
  `apply`, `ArrowsOverlay.arrowSegments` (`ContentView.swift:1424, 1438`) and
  `BoardSquare.label` (`:267-270`) all trap. A second parser copy,
  `enPassantSquare(from:)` (`MoveValidator.swift:353-359`), has the same gap.
  Only Stockfish's PV feeds this today, but stderr is merged into stdout
  (`StockfishEngine.swift:56`) and the parser accepts any line containing
  `pv` and `score`. Direction: one failable `BoardSquare.init?(uci:)` with
  range checks, used by both parsers and the tests' helper; the subscript
  stays trapping (invariant), strings can no longer reach it. Tests: `"e0e4"`,
  `"e9e4"`, `"i1a1"`, `"e2e"` → nil. `adv-review-behavior` not needed; pure.

- [ ] (detector-mode-tiebreak-nondeterministic) **[trivial · Low · detection]**
  Found 2026-09-01 by the `(detection-off-main-actor)` plan review, by
  probe: `BoardDetector.modeValue` (`BoardDetection.swift:227-238`) picks the
  most populated bin with `bins.max(by:)` over a `Dictionary`, whose
  iteration order is per-process random, so an exact tie between two bins
  returns a DIFFERENT band on different runs — reproduced: the same synthetic
  image gave `(0,128,…)`, `(64,128,…)`, `(128,128,…)` and `(0,0,…)` across
  eight launches. Direction: break ties deterministically (lowest bin key,
  or the bin with the smallest mean absolute deviation). Test: a values list
  with two equal-count bins returns the same answer on every call. No UI
  change.

- [ ] (dead-detection-and-recents-purge) **[standard · Medium · memory/dead-code]**
  Note (2026-09-02, after `(detection-off-main-actor)`): keep `DetectionStatus`
  itself — `AppViewModelDetectionTests` and the view model match on
  `.running`/`.idle`/`.succeeded`; drop only its dead cases/payload. The
  `nonisolated`/`Sendable` annotations on `GridRefiner`, `DetectionConfig` and
  `luminanceMask*` go with the code. `DetectionOutput.fen` is still read by
  `DetectionFixtureTests` (placement pin) — move that pin to `board` first.
  Deletion-only. `detectionStatusView` (`ContentView.swift:643-670`) and
  `recentsView` (`:672-708`) are defined and never mounted (grep); so
  `viewModel.recents` — up to three full-resolution `NSImage`s, ~59 MB each
  on a 5K display (`AppViewModel.swift:631-637`) — and `detectionStatus`,
  which pins the whole `DetectionOutput` (`normalizedBoard`, 64 `squareCrops`,
  the `fen` string) for the app's lifetime, buy nothing (review F7). Also
  dead: `DetectionService` (never instantiated), `EngineAnalyzing` as a type,
  `GridRefiner` + `SquareExtractor`'s `useGridRefinement` branch (constant
  `false` at `DetectorPipeline.swift:44`), `BoardDetector.luminanceMask*` and
  `DetectionConfig` (`BoardDetection.swift:266-363`), `DetectionStatus.failed`
  (never produced), `DetectionOutput.fen` (a second FEN producer the UI
  cannot show), the constant-confidence warning (`BoardDetection.swift:37, 40`
  vs threshold at `DetectorPipeline.swift:66` — fires on every detection), the
  "Wraps Vision rectangle detection" doc comment (`:31`). Product note: if a
  recents shelf is wanted later, git has it. Absorbs six July items (review
  disposition table). Standard with `adv-review-behavior` to confirm nothing
  visible changed; acceptance = build green, tests green, `git grep` finds
  none of the removed names, memory after three drops measured lower.

- [ ] (tree-selection-expansion-dropped-while-busy) **[standard · Low · tree]**
  Selecting a node while the ROOT expansion is still running never expands
  it (review F8, narrowed 2026-09-01): `expandTreeForSelection` returns at
  its `guard !isTreeAnalyzing || treeFlagOwner == owner` when the flag belongs
  to `analyzeMoveTree`'s expansion, and nothing retries. The selection-during-
  selection half shipped in `(view-model-task-ownership-and-cancel)` (`c5a31ca`,
  test C7: selecting B during A's expansion cancels A and expands B, the flag
  handed over without a blank frame). Direction for the rest: remember the
  latest requested path and expand it when the root expansion finishes, or
  let a selection cancel the root expansion too (owner-keyed already).
  Acceptance: Analyze (tree) then select a node before "Tree analysis ready."
  → the node's children appear once the root expansion finishes.

- [ ] (tree-variation-user-move-loses-original) **[trivial · Low · tree/undo]**
  A user move made while a variation is shown discards the position the user
  had before clicking the tree (review F15, verifier). `selectTreeNode` keeps
  the pre-selection board only in `treeSelectionSnapshot` (`:325-327`) and
  never pushes an undo entry (`:297-346`); `applyUserMove` →
  `invalidateAnalysis` drops the snapshot (`:683`) and `performAnimatedMove`
  pushes the VARIATION state (`:578`), so Undo walks back to the variation,
  never to the original. Direction: on the first user move out of a
  variation, push the pre-selection snapshot first — undo semantics only, no
  visible change. If Felix prefers the current behaviour, close it and say so
  in a §5 note.

- [ ] (focus-stolen-by-key-handler) **[trivial · Low · view]**
  `KeyEventHandler.updateNSView` (`ContentView.swift:1862-1868`) calls
  `makeFirstResponder` whenever `isActive`, which is set at `:941, :948,
  :1092, :1099` and never cleared; after one list click every later re-render
  takes focus from the piece-editor `TextField` (`:823-826`) (review F11).
  Direction: claim first responder only on the false→true transition; clear
  `isActive` when the editor opens. Not a UI change — a focus fight removed.

- [ ] (bot-strength-elo-floor) **[trivial · Low · engine]** Found in passing:
  `elo(for:)` (`AppViewModel.swift:620-629`) returns 800/1100 for strengths
  1/2, but the bundled `Stockfish dev-20251221` reports (measured) `UCI_Elo
  min 1320`, and Stockfish drops an out-of-range spin value silently
  (estimated from its source — not observable over UCI; `value 800` prints
  nothing, an unknown name prints `No such option`), so strengths 1, 2 and 3
  (1400) are practically the same strength (review F13). Map 1…5 onto
  1320…≈2400 (record the curve in the commit); slider untouched.

## 3. Performance — filed, not scheduled

- [ ] (detection-downsample-before-edge-scan) **[standard · Medium · detection/perf]**
  Since `(detection-off-main-actor)` (2026-09-02) the scan runs off the main
  actor and tests `Task.isCancelled` every 64 rows/columns, so this is now
  purely wall-clock: `PawnPilotTests/SyntheticBoard.big2880()` (2880×1800,
  quad `CGRect(864, 324, 1151, 1151)`, empty board) is the fixture and
  `DetectionFixtureTests.testFBig_…` the before/after pin — 2.0 s Debug at
  HEAD. Keep the quad within ±2 px after scaling back.
  `BoardDetector.edgeBasedDetect` (`BoardDetection.swift:46-138`) scans every
  row AND every column of the full-resolution screenshot through a per-pixel
  closure with a `[Run]` allocation each (`:147-172`), and
  `bestAlternatingSegment` is O(runs²) per line in the worst case
  (`:190-211`); nothing downsamples first (review F3, second half).
  Direction: downsample to ~1024 px on the long side before the scan (its bins
  are ±6 px and `BoardNormalizer` re-samples to 1024² anyway), scale the quad
  back to source coordinates, and read pixels through ONE helper that first
  converts to a known 8-bit RGBA layout — the four readers
  (`BoardDetection.swift:47-56`, `ImageSanitizer.swift:37-46`,
  `OrientationEstimator.swift:49-56`, `GridRefiner.swift:7-12`) assume 8-bit
  RGB-first and silently mis-read 16-bit or grayscale inputs (in-bounds,
  verified — garbage, not a crash). Acceptance: detection result on the
  fixture unchanged; wall-clock on a 5120×2880 screenshot recorded before and
  after in the plan; a 16-bit PNG fixture detects. Independent of
  `(detection-off-main-actor)`; either order.

- [ ] (game-over-recomputed-per-render) **[trivial · Low · view-model/perf]**
  `ContentView.scoreOverrideText` (`:190-192`) reads
  `viewModel.gameOverScoreText` (`AppViewModel.swift:686-688`), which runs a
  legal-move search (`hasAnyLegalMove` + `isInCheck`) on EVERY body
  evaluation, including every slider tick (`ContentView.swift:539-583` write
  `@Published` values) (review F9). Cheap in ordinary positions — the search
  early-exits at the first legal move (`MoveValidator.swift:302-304`) — and a
  full 64-square scan only near mate/stalemate; still per-render work that
  depends only on `boardState`. Direction: compute once per `boardState`
  change (a `didSet`-fed stored value). Acceptance: a counter probe shows one
  search per board change during a slider drag.

- [ ] (tab-panels-rerender-on-every-update) **[standard · Low · view/perf]**
  `AppKitTabView.updateItems` (`ContentView.swift:1698-1719`) sets
  `hosting.rootView` on all three `NSHostingView`s every `updateNSView`, and
  `tabItems` (`:223-241`) rebuilds three `AnyView`s per body; only one tab is
  visible (review F10). Direction: update the selected tab's root view and
  defer the others until selected, or `EquatableView` the panels. Layout must
  stay identical — `adv-review-behavior`, plus the §5 by-eye pass.

- [ ] (classifier-model-load-at-launch) **[trivial · Low · launch/perf]**
  `AppViewModel.init` (`:108-116`) builds `DetectorPipeline()`, whose defaults
  load the CoreML model (`PieceClassifier.swift:25-49`) and create a
  `CIContext`, and runs `findEngineURL` with a recursive enumerator fallback
  (`:967-1005`), all synchronously on launch (review F12). Direction: a
  detached load at init that the first `detect` awaits. Acceptance:
  `XCTApplicationLaunchMetric` (already in `PawnPilotUITests`) before/after.

## 4. Structure, tests, infrastructure — filed, not scheduled

- [ ] (rules-perft-tests) **[standard · Medium · tests]** Perft-style tests
  for `MoveValidator` / `LegalMoveGenerator` — the 359-line rules engine still
  has zero direct coverage (tests touch `BoardState`, `MoveTreeLogic`,
  `EngineMoveSelector`, `AppViewModel.setPiece`). Both are pure structs over a
  value type, so this is cheap. Caveat (re-derived 2026-09-01):
  `candidateMoves` (`MoveValidator.swift:311-350`) enumerates destinations,
  not promotion variants, so perft must either count auto-queen promotion as
  one move (and say so) or extend the generator first. Start position 20 /
  400 / 8,902 / 197,281 and Kiwipete 48 / 2,039 / 97,862 are the reference
  counts. Prerequisite in spirit for `(move-semantics-dedupe)`.

- [ ] (move-semantics-dedupe) **[standard · Medium · rules]** Two real
  implementations of move application — `BoardState.apply`
  (`BoardState.swift:89-153`) and `MoveValidator.kingInCheckAfterMove`
  (`MoveValidator.swift:134-177`) — plus a third statement of piece geometry
  in `LegalMoveGenerator.candidateMoves` (`:311-350`). Divergence is silent.
  (July's "replayed a third time inside view body" was wrong: the view calls
  `apply`.) Land `(rules-perft-tests)` first so the dedupe is checked.

- [ ] (typed-board-state) **[standard · Low · rules]** Keep FEN strings at the
  serialisation boundary only — `BoardState.activeColor/castling/enPassant`
  are still `String`s (`sideToMove` at `BoardState.swift:180-183` is the
  pattern); rules code does `state.castling.contains(right)`
  (`MoveValidator.swift:99`); castling rights are derived at four sites
  (`BoardState.swift:63-73, 208-239, 334-343`, `DetectorPipeline.swift:161-185`);
  three private square parsers exist. A castling `OptionSet` + optional
  `BoardSquare` makes the states `sanitizedCastling`/`sanitizedEnPassant`
  repair unrepresentable. Natural follow-on to `(uci-square-parse-range-check)`.

- [ ] (observability-consolidate) **[standard · Low · logging]** One
  diagnostics channel, one user-facing channel — today: one `os.Logger`
  (`AppViewModel.swift:7`), four `print`s behind flags
  (`SquareExtractor.swift:72-76, 90`, `PieceClassifier.swift:62`), unlocalised
  `DetectionWarning` strings logged and never shown, ~40 localised
  `statusMessage` sites. `StockfishError` is a proper `LocalizedError`;
  `BoardDetectionError` is a bare enum interpolated into a warning.

- [ ] (deployment-target-alignment) **[trivial · Low · build]** Premise
  corrected 2026-09-01: availability IS checked at compile time against the
  app target's `MACOSX_DEPLOYMENT_TARGET = 13.5` (pbxproj `:492, :533`), so
  the project-level and test-target `26.2` (`:401, :459, :557`) hide no API
  use. What it does do: any new target inherits 26.2, and the test bundle
  cannot run on a <26.2 machine. Set the project-level default to 13.5.

- [ ] (build-test-script) **[trivial · Low · infra]** `scripts/test.sh` that
  runs the CLAUDE.md gate command (DerivedData outside the repo,
  `-only-testing:PawnPilotTests`) and, with `--ui`, the UI target too; the
  one command `/work`'s gate calls. No stamp/guard hooks unless Felix asks.

- [ ] (settings-persistence) **[standard · Low · feature]** **Not eligible
  for `/work` unless Felix says so** — a feature, filed so it is not lost. No
  `UserDefaults`/`@AppStorage` anywhere, so `searchDepth`, `strength`,
  `multiPV`, `treeBranchCount`, `randomnessStrength`, `maxArrowsPerLine`,
  `strictDepth`, `keepPlaying` reset on quit. Extract a settings value type
  so persistence is one seam rather than eight. No UI change.

## 5. Manual sittings — Felix only, parallel track

*Only Felix can run these, on the built app. They never queue behind agent
work. Each is a few minutes.*

- [ ] (sitting-baseline-repros) Before any §0 item lands, confirm the four
  reproductions on the installed app so the fixes have a before: (1) Variations
  → Analyze → select a node → make a board move → Analyze: stalls, then
  "Engine timed out" after ~5 min (F2); (2) Play Bot Move at depth 30, then
  Reset while "Engine thinking…": the move lands on the reset board (F5);
  (3) drop a full-screen Retina screenshot: the spinner/status is not painted
  until detection finishes, and note the wall-clock (F3); (4) make a move and
  click a second move within the 0.35 s animation: white moves twice (F4) —
  or, easier, expand a variation and hold Down-arrow in the list: the board
  ends on a position that is not the tree's.
  Record what you saw in the corresponding `plans/active/*.plan.md` or here.
- [ ] (sitting-ui-unchanged-after-each-landing) After each §0 item lands: a
  by-eye pass over move animation, tree arrows, best-line arrows, list
  selection, the piece editor and slider drag smoothness — nothing visible
  changed. This is the manual half of every item's acceptance.
  For `(apply-move-then-animate)` (`f9e2d0a`, 2026-09-01) specifically: with
  no interaction, every frame of a user move, an engine move, a "Play
  Selected Moves" replay and a tree click (incremental and full replay) must
  look as before — castling rook still home during the king's flight,
  en-passant victim still visible, arrows and the score strip unchanged
  until the landing. The three recorded in-window differences, all needing
  interaction inside 0.35 s: clicking a square / editing / the picker /
  Analyze ends the flight (the piece appears at its destination) before
  acting; a board-replacing action (Reset, Undo, …) does the same instead of
  letting the piece fly onto the new board; the other side's immediate reply
  is accepted (before: "Illegal move.").
- [ ] (sitting-detection-spinner-paints) After `(detection-off-main-actor)`
  (2026-09-02): drop a full-screen Retina screenshot. "Detecting board…"
  and the spinner must now PAINT during the detection and the window must
  stay responsive (F3's freeze is gone); the detected position must be the
  one the old build produced for the same image. Note the wall-clock next
  to the F3 baseline you recorded.
- [ ] (sitting-detection-stale-status-after-cancel) A UI decision, not a
  bug fix: make a board move (or Reset) WHILE a detection runs. The
  detection stops, but the bar keeps reading "Detecting board…" until the
  next status write — exactly as before the item (kept under "UI
  unchanged"). Decide whether it should read "Ready." or the move's status
  instead; the one-line change is `statusMessage = nil` where
  `invalidateAnalysis` moves `detectionStatus` from `.running` to `.idle`.
- [ ] (sitting-sigpipe-timeout) Optional confirmation of F1 on the installed
  app (outside the debugger — under Xcode it shows as a stop, not a crash):
  depth 30, strict depth on, Lines 10, Analyze, wait for the 300 s timeout.
  Expected today: the app quits. Skip if the reproduction program's exit 141
  is evidence enough.
