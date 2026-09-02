# Plan: (detection-off-main-actor)

Rev 5 · 2026-09-01 · tier **hi**. `adv-review-plan` rounds: Rev 1 ("build
after fixing 5"), Rev 2 ("do not build as scoped"), Rev 3 ("do not build as
scoped — 3 must-fix": the runtime flag is blind to async→sync hops, E8 was
vacuous, black squares classify as bishops), Rev 4 ("do not build as scoped
— 6 must-fix": a `makeFEN` precondition would trap from `BoardState.fen`,
the precondition is sound only where `process` is the unique caller, the
classifier seam must be `async`, sendability is unchecked here, E7 was
vacuous at 1.5 s, no warning criterion). Rev 5 folds in every Rev 4 finding
(1–12, T1–T3) and is NOT reviewed again — five rounds; the remaining
findings were text corrections with fixes the reviewer supplied. Both adv
reviewers on the code. No `/arch-review` — reasons under Decisions.

Source: TODO.md §0 (last item); evidence `arch-reviews/2026-09-01-stability-performance.md` F3 (first half).
Depends on `(view-model-task-ownership-and-cancel)` (in flight on this
branch: `detectionTask`, `cancelSupersededWork()`, `cancelBotMove()`,
`invalidateAnalysis(replacingBoard:)`). Line numbers for `AppViewModel.swift`
below are to be re-derived after that item commits.

## Premise re-derived against the tree (⚑ = probed by a review)

- App target: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable
  concurrency, Swift 5 mode ⇒ strict concurrency `minimal`. A
  main-actor-inferred SYNC declaration reached from a nonisolated context is
  a WARNING; from a nonisolated SYNC caller it is then called directly on the
  caller's thread, but from a nonisolated ASYNC caller the compiler inserts
  a HOP and the callee runs on the main actor (⚑). `-enable-actor-data-race-checks`
  traps only the first kind (⚑, Rev 3: `makeFEN` without `nonisolated`,
  called from `@concurrent process`, ran on main and exited 0 under the
  flag). Every phase `process` calls directly is of the second kind — the
  flag is blind to exactly this refactor's miss class. Nothing fails on new
  warnings (`SWIFT_TREAT_WARNINGS_AS_ERRORS` unset; the baseline has zero).
- Every declaration under `PawnPilot/FENDetector` is main-actor-inferred:
  the classes `DetectorPipeline` (`DetectorPipeline.swift:33`), `BoardDetector`
  (`BoardDetection.swift:32`), `BoardNormalizer` (`BoardNormalizer.swift:14`),
  `SquareExtractor` (`SquareExtractor.swift:14`), `PieceClassifier`
  (`PieceClassifier.swift:14`); the value types `OrientationEstimator`,
  `ImageSanitizer`, `FENBuilder`, `BoardGeometry`, `GridRefiner`,
  `DetectionOutput`, `DetectionWarning`, `LowConfidenceSquare`,
  `CastlingSuggestion`, `BoardDetectionResult`, `NormalizedBoard`,
  `SquareCrop`, `PieceClassificationResult`, `BoardOrientation`, `Board`,
  `Piece`; the nested/private `BoardQuadrilateral.boundingBox`
  (`BoardDetection.swift:11`), `private struct Run` (`:140-145`),
  `private struct DetectionConfig` (`:356`), `private extension CGImage { meanLuminance(in:) }`
  (`OrientationEstimator.swift:47-72`), `private struct GridContrastEvaluator`
  (`SquareExtractor.swift:116`), `private extension Array where Element == Double { average }`
  (`SquareExtractor.swift:216-221`). Marking all of these `nonisolated` with
  `process` `@concurrent` compiles with zero diagnostics (⚑); the three
  error enums need nothing (⚑).
- `DetectorPipeline.process` (`:57-131`): the edge scan (the expensive
  phase: ~2.2 s Debug / ~0.07 s Release on 2880×1800 ⚑), normalise,
  orientation, extract, sanitise 64 crops (`:94-97`), classify (64 serial
  `perform`s under `queue.sync`, sanitising again — idempotent by
  construction and by measurement ⚑), `classifier.isModelAvailable` read at
  `:108`/`:113`.
- `AppViewModel`: `private let pipeline = DetectorPipeline()` (an inline
  initialiser — the declaration must change to be injectable, and BOTH
  inits must assign it ⚑); `detect` → `invalidateAnalysis()` then
  `detectionTask = Task { … }` (cancel item); its completion is guarded by
  the token before `snapAnimation()`, the epoch bump and the board write;
  the completion clears `engineLines`/`treeNodes` by hand and writes its
  own status ("Detected position." / validation / game over).
  `invalidateAnalysis(replacingBoard:)` cancels `detectionTask` and bumps
  `detectionToken` on every call; `replacingBoard: true` additionally clears
  `treeExpandedPaths`, `treeRootState`, `treeSelectionSnapshot`.
  `analyze()`/`analyzeMoveTree()` call `cancelSupersededWork(); cancelBotMove()`
  and leave the detection alone; `engineMove()` calls
  `invalidateAnalysis(replacingBoard: false)` and therefore KILLS a running
  detection (⚑) — inconsistent with "a landing detection beats engine work".
  `analyze()`'s completion already gates on generation, cancellation, mode
  and FEN, so a stale analysis result cannot land on a detected board
  regardless (⚑).
- `DetectionStatus` (`DetectionService.swift:5-10`) is not `Equatable`
  (pattern-match in tests). `detectionStatusView` is never mounted; the only
  visible sign of a detection is `statusMessage`; `statusMessage == nil`
  renders "Ready." (`ContentView.swift:782`).
- SDK (⚑, MacOSX26.5): `CGImage`, `CIContext`, `CGContext`, `CGPoint`,
  `CGRect` are `Sendable`; `VNCoreMLModel`, `MLModel`, `VNImageRequestHandler`,
  `VNCoreMLRequest` are NOT (the last two are per-crop locals — fine).
  **Sendability is unchecked in this project** (⚑ round 4: Swift 5 mode
  without `SWIFT_STRICT_CONCURRENCY` ⇒ `minimal`; a `Sendable` struct holding
  a non-Sendable class and a bare class passed to `<T: Sendable>` both
  compile with zero diagnostics). Every `Sendable` annotation below is
  therefore documentation and forward-compatibility, not enforcement; the
  one real cross-thread claim is the `@unchecked Sendable` `VNCoreMLModel`
  holder, justified empirically (Tier 2).
  `@concurrent` on a `nonisolated final class` method compiles. Task-group
  children never inherit isolation (⚑). `pthread_main_np()` is 0 in a
  `@concurrent` body and in group children (⚑). A protocol declared in the
  app module is main-actor-inferred unless `nonisolated` (⚑). A nested type
  inherits its enclosing type's `nonisolated` (⚑ round 4), so `Run`,
  `DetectionConfig`, `CornerStats` are covered by their enclosing types.
- `FENBuilder.makeFEN` has a MAIN-ACTOR caller outside the pipeline:
  `BoardState.fen` (`BoardState.swift:49`), read from the view model and the
  tests on the main actor (⚑ round 4). It is a shared model helper, not a
  phase — it must be `nonisolated` but must NOT carry the executor
  precondition (a `dispatchPrecondition(.notOnQueue(.main))` entered from
  the main actor traps with SIGTRAP: ⚑ `probe7/p2 onmain` exits 133).
- Unique-caller entries (⚑ round 4): `detectBoard` (`DetectorPipeline.swift:64`),
  `normalize` (`:75`), `estimateOrientation` (`:77`), `extractSquares`
  (`:92`), `ImageSanitizer.sanitize` (`:94`, once the classifier's own call
  at `PieceClassifier.swift:72` is removed), `classify` (`:98`) are called
  from `process` and nowhere else. Deep declarations reached through a
  NONISOLATED SYNC helper (`edgeBasedDetect`, `makeRuns`, `modeValue`,
  `isValidSquare`, `GridRefiner.refineGrid`, `GridContrastEvaluator`,
  `CGImage.meanLuminance`, `Board`'s subscript, `castlingSuggestion`, …) run
  on the caller's thread even when their `nonisolated` is forgotten — no
  hop, no trap, only a `#ActorIsolatedCall` warning (⚑ round 4). Their
  completeness oracle is the build log (E11).
  `Task.isCancelled` in a sync callee of `@concurrent` observes the owning
  task (⚑: a scan stopped at row 256). A child testing `Task.isCancelled`
  first, with all 64 enqueued and a cancel ~26 ms later, ran exactly
  `activeProcessorCount` times and `process` returned in ~60 ms (⚑).
- Fixtures (⚑, re-run by the orchestrator): a 768×768 image with a 128-px
  margin at 0.5 luminance around a 512-px board of 64-px squares in the
  app's greys (light 0.90, dark 0.65, a1 dark), no pieces, gives
  `edgeBasedDetect` = (128, 128, 511×511) on every run (in memory and after
  PNG), orientation `.standard` with no warning, `isValidSquare` passes,
  the `modeValue` tie-break cannot fire (every row/column yields one bin),
  and the real model classifies all 64 squares `empty`: placement
  `8/8/8/8/8/8/8/8`, 1 warning (low board confidence), 0 low-confidence
  squares, flip false, castling (false, false). (Black/white squares
  classify as 32 white bishops — rejected.) The tight 620×620 crop of
  `AnalyzeBestLines.png` takes the fallback path with pins reproduced by
  three independent runs; two of its pins (44 warnings, 43 low-confidence
  squares) are threshold crossings on raw logits and are recorded as the
  brittle ones. The app bundle ships `Piece13.mlmodelc`, byte-identical in
  weights to the probes' (⚑).
- Test count at HEAD of this branch (after the cancel item): 94 methods; 98
  after Tier 0 (⚑ Tier 0 implementer).

## Goal

Detection runs off the main actor: `process` is `@concurrent`, every
declaration it reaches is `nonisolated`, inputs/outputs are `Sendable`, the
64 classifications run concurrently on one `VNCoreMLModel`, crops are
sanitised once, a cancelled detection stops within the scan or between
phases and skips crops not yet started, and the view model publishes on
main. Every phase carries a DEBUG-only executor precondition, so a
forgotten `nonisolated` traps in the tests instead of silently hopping back
to main. Two fixtures — the edge-detector path with two truth claims, and
the fallback path — are pinned before and after. Interaction rules for the
new window: board edits beat a running detection; a landing detection beats
engine work started during it (the bot included).

## Fixtures (Tier 0)

- **F-edge (synthetic, drawn at test time):** 768×768 RGBA; margin 0.5
  grey; board 512 px of 64-px squares at (128, 128) in the app's greys (light
  0.90, dark 0.65, a1 dark); no pieces. Truth claims: `quadrilateral.boundingBox`
  == `CGRect(x: 128, y: 128, width: 511, height: 511)` ± 2 px (the detector's
  box spans pixel indices, hence size − 1); the `Board` is entirely empty;
  orientation `.standard` — `DetectionOutput` carries no orientation field, so
  it is pinned as "no rotation warning" plus `OrientationEstimator` re-run on
  `normalizedBoard.image` (⚑ a1-light negative control rejects);
  `suggestedFlipForFEN == false`. (Both claims probe-verified.)
- **F-real (file):** `PawnPilotTests/Fixtures/detection-bestlines-board-620.png`
  (252 KB, a regular blob). Pins: fallback quad (12.4, 12.4, 595.2×595.2);
  placement `rnbNkb1r/pppp1ppp/3ppn2/4pp2/4PP2/2N2N2/PPPP2PP/R1BQKB1R`; flip
  false; castling (true, true); and — recorded as threshold-brittle — 44
  warnings, 43 low-confidence squares.
- **F-big (synthetic, drawn at test time):** the F-edge design at
  2880×1800: a 1152-px board of 144-px squares centred (`isValidSquare` at
  the `edgeBasedDetect` call site is passed `minSideFraction: 0.6`, so it
  needs ≥ 0.6 × 1800 = 1080 px; the parameter's declared default is 0.7),
  margins 324 px vertically and 864 px
  horizontally at 0.5 grey (both ≥ 1.7 × the square, so neither can join
  the band) — the wall-clock and main-actor-liveness input, sized like a
  Retina capture. Its quad — `CGRect(x: 864, y: 324, width: 1151, height: 1151)`
  ± 2 px, ⚑ round 4: exact on three in-memory trials and after a PNG round
  trip, FEN `8/8/8/8/8/8/8/8`, flip false, 1 warning, 0 low-confidence
  squares, orientation `.standard`, 2.3–2.8 s wall clock at `-Onone` — and
  its empty board are asserted like F-edge's.
  (Also the natural fixture for `(detection-downsample-before-edge-scan)`,
  which needs an input above 1024 px — Rev 3 review G2.)

## Acceptance criteria

- E1 (Tier 0, BEFORE the change): `DetectionFixtureTests` (`@MainActor`)
  asserts F-edge's and F-big's quad ± 2 px, empty board and orientation;
  F-real's pins; prints `[detection] <fixture>: N ms` for all three — the
  F-big number is the "before" wall-clock for a Retina-sized input.
- E2 After the change: E1 unchanged (the pins), F-big's "after" number
  recorded. E2 is also the coverage of the real `PieceClassifier` on the
  concurrent path (F-real: 64 real crops through the task group).
- E3 Off-main, discriminating: a probe `PieceClassifying` records
  `pthread_main_np()` in its single `classify` call → 0, driven from a
  `@MainActor` test through `process`.
- E4 Fan-out order and overlap (mechanism test): `classifyConcurrently(count: 64)`
  with a lock-guarded in-flight counter around a 5 ms `Thread.sleep`
  returns index-ordered results and peak overlap ≥ 2 when
  `activeProcessorCount >= 2` (else `XCTSkip`).
- E5 Cancellation stops the run: (a) during the SCAN: `process(F-big)` in a
  `Task`, cancel after 100 ms; `process` returns within 1 s and the probe
  classifier was never called; (b) during the fan-out: probe blocking 50 ms
  per crop through `classifyConcurrently`; cancel when the first crop is
  observed; `process` returns within 1.5 s with fewer than 64 crops run.
- E6 The main actor stays live: injected pipeline with F-big (edge scan
  ~2 s Debug) and a probe classifier whose ONE `classify` call
  `Thread.sleep`s 1 s then delegates to the real classifier. Immediately
  after `detect(cgImage:)`: `statusMessage == String(localized: "Detecting board...")`
  and `if case .running = detectionStatus`; a `Task.sleep(100 ms)` on the
  main actor completes within 400 ms (fails at HEAD, where the scan alone
  blocks main for ~2 s); the run finishes (`waitUntil` ≤ 15 s) with
  `case .succeeded`, the probe called once, and `boardState` equal to
  F-big's empty board with both kings... — F-big has no kings, so
  `analysisValidationMessage` fires: the completion's status is the
  validation message; assert THAT (the board is published regardless).
- E7 A board edit during a detection wins and stops the work: as E6;
  while `.running` (during the scan), `applyUserMove(e2→e4)`. Immediately:
  `if case .idle = detectionStatus`, `statusMessage == String(localized: "Detecting board...")`
  (the string the current code leaves there — a pre-existing quirk, kept
  under "UI unchanged" and filed as a §5 sitting), the move on the model.
  After 4 s (past F-big's 2.3–2.8 s `-Onone` scan, so the clause is not
  vacuous): the probe's call count is still 0 and the board still holds the
  move. This proves the between-phase checkpoint at the view-model level;
  the IN-SCAN abort is E5(a)'s job (it fails without the in-scan checks,
  E7 does not).
- E8 A landing detection beats engine work started during it — including
  the bot: (a) `.analyzeLines`, one-shot fake `infoDelayMs: 5000`,
  `searchDepth = 1`; `detect(F-real)` with the 1 s probe; while `.running`,
  `analyze()`; after `case .succeeded`: `boardState` is F-real's board,
  `engineLines` empty, `isAnalyzing == false`; then wait until 5.3 s past
  the fake's `go` and assert the log has no `<bestmove` (the completion
  cancelled the search — fails without it, where the search runs to its
  end). The test records the landing time (`go` → `.succeeded`) in its
  output and FAILS if it exceeds 2.5 s (half the fake's delay: the budget
  the oracle needs, ⚑ round 4 — F-real lands in ≈1.25 s optimised, more
  at `-Onone`; the first gate run pins the Debug number in Decisions).
  (b) `.playAgainstComputer`, same fake; while `.running`, `engineMove()`:
  the detection is NOT dropped (`engineMove` no longer supersedes it) —
  after `case .succeeded` the board is F-real's, `isEngineThinking == false`,
  and, past 5.3 s, no `<bestmove` (fails at the cancel item's HEAD, where
  `engineMove` kills the detection and the bot plays on the old board).
- E9 The executor preconditions are the isolation oracle for the HOP miss
  class. Rule: a precondition goes ONLY on an entry whose unique caller is
  `process` (a `dispatchPrecondition(.notOnQueue(.main))` entered from the
  main actor traps — ⚑ round 4). The list, each with its callers checked:
  `process` itself, `detectBoard`, `normalize`, `estimateOrientation`,
  `extractSquares`, `ImageSanitizer.sanitize` (after Tier 2 removes the
  classifier's own call), `classify`. NOT `makeFEN` (`BoardState.fen` calls
  it from main), NOT anything reachable from the view model or the tests
  directly. Each begins with `Self.assertOffMain()` =
  `#if DEBUG dispatchPrecondition(condition: .notOnQueue(.main)) #endif`
  (DEBUG is active in the gate's Debug configuration, ⚑). A forgotten
  `nonisolated` on any listed entry hops it back to main and TRAPS in every
  Debug test that runs the pipeline (E1/E2/E5/E6/E7/E8): ⚑ round 4
  `probe7/p2 hop` exits 133; `conc`/`group`/`detached` never fire falsely.
- E10 The existing 92 tests (plus the cancel item's) still pass;
  `DetectionService` compiles; the only visible change is that "Detecting
  board..." now paints during a detection (§5 sitting). Deliberately kept:
  a cancelled detection leaves "Detecting board..." in the bar (E7).
- E11 Zero new concurrency warnings in the APP target's build log: the
  orchestrator greps the gate log for `warning:` lines under `PawnPilot/`
  (not the test target, whose main-actor-initializer warnings pre-date this
  item) and compares against the baseline (zero). This is the completeness
  oracle for the deep declarations E9 cannot see (⚑ round 4: a main-actor
  sync callee reached through a nonisolated SYNC helper runs on the pool
  with only a `#ActorIsolatedCall` warning; `SWIFT_TREAT_WARNINGS_AS_ERRORS`
  is unset).

## Design — THREE commits (Rev 3 review G3)

A = Tier 0 (fixtures + E1 on the current pipeline).
B = Tiers 1–2 (isolation, sendability, preconditions, cancellation points,
the concurrent classifier) + E2–E5, E9, E11. Buildable and green on its
own (⚑ round 4: the view model's `pipeline.process` call site compiles
unchanged once `process` is `@concurrent nonisolated`); its claim is
"compiles, zero new warnings, pins unchanged, off-main proven at the
pipeline level (E3)". By FILE it touches `FENDetector/` only; by blast
radius `Board`, `Piece`, `FENBuilder`, `BoardGeometry`, `DetectionOutput`
becoming `nonisolated` reaches `MoveTreeLogic`, `MoveValidator`,
`BoardState`, `ContentView`, `PawnPilotApp` and three test files — which
is why the gate, not the file list, is B's proof.
C = Tier 3 (view model: injection, completion cleanup, the interaction
rules) + E6–E8. The USER-VISIBLE liveness claim (E6) belongs to C.

### Tier 0 — fixtures and the "before" pins

`SyntheticBoard.render(size:boardOrigin:squareSize:marginGrey:lightGrey:darkGrey:)`
with `edge768()`/`big2880()` (CoreGraphics, no assets; the probes' exact
parameters);
`PawnPilotTests/Fixtures/detection-bestlines-board-620.png` located via
`Bundle(for:)` with `subdirectory: "Fixtures"` falling back to none;
`DetectionFixtureTests` (E1).

### Tier 1 — isolation, sendability, preconditions, cancellation (`FENDetector/*`)

- Every declaration in the premise list becomes `nonisolated` — the TYPE
  `BoardQuadrilateral`, not only its `boundingBox` (its synthesised
  `==`/`hash`/`Codable` members would otherwise stay main-actor — round 4
  finding 11); `FENBuilder` and `makeFEN` included (shared with
  `BoardState.fen`, no precondition).
- The seam is pinned NOW, before the classifier is rewritten (round 4
  finding 4):
  ```swift
  nonisolated public protocol PieceClassifying: Sendable {
      var isModelAvailable: Bool { get }
      func classify(crops: [SquareCrop]) async -> [PieceClassificationResult]
  }
  ```
  `DetectorPipeline.process` awaits it (`let results = await classifier.classify(crops:)`);
  the fan-out `classifyConcurrently` is a separate, internal, `static`
  function on `PieceClassifier` so E4/E5(b) reach it directly, while the
  E3/E6/E8 probes implement ONE `classify` call.
- `Sendable` on the value types, `DetectorPipeline`, `BoardDetector`,
  `SquareExtractor`, `BoardNormalizer` — documentation only in this project
  (premise); `@unchecked Sendable` on `PieceClassifier` with the model in
  `private struct ClassifierModel: @unchecked Sendable { let vision: VNCoreMLModel }`,
  the one claim that matters, justified by the probe under Decisions.
- `private static func assertOffMain() { #if DEBUG dispatchPrecondition(condition: .notOnQueue(.main)) #endif }`
  called first thing in each E9 entry and nowhere else.
- `BoardDetector.detectBoard` loses `async`; `edgeBasedDetect` checks
  `Task.isCancelled` every 64 rows and every 64 columns and returns nil.
- `DetectorPipeline.process` becomes `@concurrent nonisolated`;
  `static let cancelledOutput` = empty `Board`, its FEN, `quadrilateral nil`,
  no crops, one warning "Detection cancelled."; returned after the scan,
  after normalisation, before classification, and AFTER classification if
  any fan-out slot is nil (never a bogus board — Rev 3 review D7).

### Tier 2 — `PieceClassifier`: concurrent, single-sanitise, injectable

`static func classifyConcurrently<T: Sendable>(count:work:) async -> [T?]`
with `withTaskGroup`; each child tests `Task.isCancelled` FIRST and returns
nil. `classifySquare` static, no sanitise. `classify(crops:)` becomes
`async` and awaits the fan-out. **This deletes an invariant**: today every
`VNImageRequestHandler.perform` on the one `VNCoreMLModel` is serialised
under `queue.sync` (`PieceClassifier.swift:64`); after Tier 2 up to
`activeProcessorCount` performs run concurrently on it, and (premise) the
compiler checks none of it. `DetectorPipeline.init(… classifier: any PieceClassifying = …)`.

### Tier 3 — `AppViewModel`

- `private let pipeline: DetectorPipeline` assigned in BOTH inits;
  `init(engine:treeEngine:pipeline: DetectorPipeline = DetectorPipeline())`.
- `invalidateAnalysis(replacingBoard:supersedesDetection: Bool = true)`:
  `engineMove` passes `supersedesDetection: false` (Rev 3 review D4);
  every other caller keeps the default. It does NOT touch `statusMessage`
  (round 4 finding 9: nil-ing it would render "Ready." — a second visible
  change; the stale "Detecting board..." is pre-existing and filed as a §5
  sitting instead).
- The detection completion, after its token guard and `snapAnimation()`
  (in that order — Rev 3 review G4), performs the board-replacing cleanup
  minus the detection parts: `cancelSupersededWork(); cancelBotMove();
  treeExpandedPaths.removeAll(); treeRootState = nil; treeSelectionSnapshot = nil`
  (Rev 3 review D5), then bumps the epoch and replaces the board as today.

### Tier 4 — tests

`DetectionFixtureTests` (E1/E2), `DetectionConcurrencyTests` (E3–E5),
`AppViewModelDetectionTests` (E6–E8, `@MainActor`, own `waitUntil`). Probe
sleeps are `Thread.sleep`; status strings via `String(localized:)`;
status matched with `if case`.

## Load-bearing assumptions

- `dispatchPrecondition(condition: .notOnQueue(.main))` holds on the
  cooperative pool's threads (they are not the main queue) and fails when
  a function is entered on the main actor's executor — the main actor runs
  on the main queue. If a future executor change breaks that, the
  precondition fails loudly in tests, not silently.
- The cancel item ships first; Tier 3 is written against its final
  `invalidateAnalysis`/`cancelSupersededWork`/`cancelBotMove`.
- F-big renders identically across the test bundle and the probe (same
  CoreGraphics parameters).

## Out of scope (explicit)

- Downsampling — `(detection-downsample-before-edge-scan)`; F-big is its
  fixture (above 1024 px).
- The dead detection code — `(dead-detection-and-recents-purge)` (keeps
  `DetectionStatus`; deletes some `nonisolated` annotations this item adds).
- The tie-break — `(detector-mode-tiebreak-nondeterministic)`.
- Bounding the fan-out's use of the cooperative pool (Rev 3 review T2:
  ~20 ms of pool saturation per detection; recorded).

## Decisions taken

- 2026-09-01 · Rev 4 → Rev 5 (review round 4, "do not build as scoped — 6
  must-fix"), all twelve findings folded: `makeFEN` dropped from the
  precondition list and the unique-caller rule stated with callers
  enumerated (1, 2); E11 added as the warning-based completeness oracle and
  the premise corrected — the precondition catches the hop class only (3);
  the classifier seam pinned as an `async` protocol with the fan-out a
  separate static (4); sendability recorded as unchecked/documentation and
  `CGContext` corrected to `Sendable` (5); E7 re-timed to 4 s and its
  in-scan claim handed to E5(a) (6); E8's fake delay raised to 5 s with a
  landing-time budget of 2.5 s the test enforces (7); commit B's claim
  narrowed and its blast radius recorded, the liveness claim moved to C
  (8); `statusMessage = nil` dropped, the stale "Detecting board..."
  filed as a §5 sitting (9); both quads stated as `CGRect` (10);
  `BoardQuadrilateral` the type (11); the deleted `queue.sync`
  serialisation recorded (12). Tensions accepted knowingly: T1 — E2
  re-pins F-real's 44 warnings / 43 low-confidence squares after the
  serial→concurrent switch; if the first run flips them the pin becomes
  a range and the flip is recorded, not hidden. T2 — blast radius (above).
  T3 — Release has no isolation net; the Debug gate is the net. NO fifth
  review round: five plan rounds, the last findings were text corrections
  with supplied fixes; the code reviewers see the result.
- 2026-09-01 · Concurrent `VNCoreMLModel` use, the one real thread-safety
  claim: `probe6/concprobe` ran 64 real classifications with peak 10 in
  flight and zero label differences against the serial run; Apple documents
  `VNCoreMLModel`/`MLModel` prediction as thread-safe. Recorded as the
  justification for `@unchecked Sendable`.
- 2026-09-01 · Rev 3 → Rev 4 (review round 3, "do not build as scoped — 3
  must-fix"): the runtime flag is replaced by DEBUG-only executor
  preconditions at every phase entry — the only oracle that catches an
  async caller hopping a forgotten main-actor callee back onto main (D1,
  T1 — no module-wide instrumentation, no build-setting change); E8 now
  asserts the engine child was terminated (no `<bestmove`), the only
  observable the completion's cancel adds (D2); F-edge uses the app's
  greys, which the model classifies as empty — two truth claims — and a
  Retina-sized F-big carries the wall-clock and liveness criteria (D3,
  G1, G2, D10); `engineMove` no longer supersedes a detection, so the
  bot is under the same rule as the analysis (D4); the completion performs
  the board-replacing cleanup (D5); E7 cancels during the scan and asserts
  the classifier never ran (D6); a cancel after classification returns
  `cancelledOutput`, never a bogus board (D7); the SDK bullet corrected
  (D8); the pipeline property declaration and both inits (D9); counts and
  the "inside `process`" precondition (D10); cancels after `snapAnimation()`
  (G4); three commits (G3); the logit-threshold pins recorded as brittle
  (T3); pool saturation recorded (T2).
- 2026-09-01 · Interaction rules for the new window: board edits beat a
  running detection (the token rule); a landing detection beats engine
  work started during it, the bot included.
- 2026-09-01 · Size of the win, recorded: the Release freeze on a
  2880×1800 capture is ~0.1 s (larger on 5K and noisy inputs, O(runs²)
  per line); the item stays as Felix's §0 priority and its F-big fixture
  unblocks the downsampling item.
- 2026-09-01 · No `/arch-review`: the API changes are inside one module
  with one production caller each.
- 2026-09-01 · Tier 0 gated (gate 25: 98/98 green, +4 tests). "Before"
  numbers from the result bundle's per-test durations (Debug, main thread,
  model load included; the `[detection]` prints are not captured by
  xcodebuild's log): F-big 3.0 s, F-edge 0.6 s, F-real 0.54 s /
  0.52 s. The pipeline froze the main actor for the whole of each.
  Tier 0 pins reproduced 24/24 by the implementer against the app bundle's
  own `Piece13.mlmodelc` and shown non-vacuous (+12 px shift, black/white
  squares, a1-light each reject). No pbxproj edit needed (the test folder is
  a synchronized group without exceptions).
