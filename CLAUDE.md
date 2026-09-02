# PawnPilot — working notes for Claude

## Repository shape (read first)
The git root is THIS directory, `PawnPilot/PawnPilot/`, nested one level under a
same-named folder. Every command below runs from here. Sources: `PawnPilot/`
(app), `PawnPilotTests/` (unit), `PawnPilotUITests/` (Xcode template plus a
launch-time metric only). The Stockfish binary is
`PawnPilot/Engine/stockfish-macos-m1-apple-silicon` (git-lfs); the CoreML
classifier is `PawnPilot/Models/Piece13.mlpackage`.

## Development loop
Same process as `../FlyWheelCADV3` (adopted 2026-09-01). Work off `TODO.md`
(open) and `DONE.md` (shipped index). The four work surfaces:

| file | what it is |
|---|---|
| `TODO.md` | the queue. Open items only — a shipped item's entry is DELETED at `/done`, never struck-through-and-kept. |
| `DONE.md` | an **index**: one line per shipped item (slug, date, tier, commits, ONE clause, ~500 chars max). The long record is the commit message: `git log --grep='(slug)'`. |
| `plans/active/<slug>.plan.md` | plans for items in flight. `ls plans/active` = what is genuinely being worked. |
| `plans/shipped/` | plans for shipped items; `/done` moves them here. |

Evidence for anything filed in `TODO.md` lives in `arch-reviews/`.

**`/work` is the entry point** (`~/.claude/commands/work.md`): plan, implement,
review, fix, commit, `/done`, next — it ends when the queue is empty, not when
an item is. `/ship <slug>` is its single-item body; `/plan`, `/implement`,
`/done` are subroutines. **Autonomy policy is `~/.claude/AUTONOMY.md`** — read
it before running any workflow command: never stop to report progress,
reviewers advise they do not gate, do not invent prerequisites.

Per item, tiered by risk (the tier governs planning and review depth; it is
not a permission gate):
- **trivial**: implement; no plan file; review none, or `adv-review-behavior`
  if it touches control-flow/state.
- **standard**: `/plan <slug>` → `/implement <slug>` with ONE reviewer matched
  to the risk surface — `adv-review-edge` for engine/concurrency/detection/
  numeric work, `adv-review-behavior` for view-model state and spec conformance.
- **hi**: as standard, plus `/arch-review` on the plan if structural, and BOTH
  adv reviewers in parallel.

The universal net at every tier: **build + tests green, verified by the
orchestrator itself — never on a subagent's say-so — before review and again
before commit.**

Commit policy: commit autonomously on any non-`main` branch, one logical change
per commit, message = the record (what changed, why, what was decided, what was
deliberately not done). Landing to `main` follows AUTONOMY.md § Landing.

**No workflow guards are installed here** (FlyWheelCADV3's G1–G6 hooks are not
copied). The rules above are prose only — keep them anyway.

## Standing constraints
- **UI unchanged.** Felix, 2026-09-01: stability, crash-avoidance and speed
  work must not change the visible UI — layout, controls, copy, colours,
  animation timing and list rendering all stay as they are. Internal
  restructuring of view code is fine only where a filed item requires it and
  the result is pixel-equivalent. When an item's cleanest fix would alter the
  UI, ship the invisible half and file the UI half as a §5 sitting for Felix.
- **Never write to Stockfish's stdin after its stdout hit EOF.** Writing to a
  pipe whose child has exited kills the app with SIGPIPE (verified 2026-09-01,
  `arch-reviews/2026-09-01-stability-performance.md` F1).
- **Default actor isolation is MainActor** (`SWIFT_DEFAULT_ACTOR_ISOLATION`)
  and approachable concurrency is on. A `nonisolated async` function still
  runs on the CALLER's actor; only `@concurrent` (or `Task.detached` around
  nonisolated synchronous work) leaves the main thread. Every FENDetector type
  WAS main-actor-isolated — that is why detection used to freeze the UI; they
  are `nonisolated` since `(detection-off-main-actor)` (2026-09-02).
- **A FENDetector phase entry is SIGTRAP, not XCTFail, when called on main.**
  `process`, `detectBoard`, `normalize`, `estimateOrientation`,
  `extractSquares`, `ImageSanitizer.sanitize` and `PieceClassifier.classify`
  each open with a DEBUG `dispatchPrecondition(condition: .notOnQueue(.main))`.
  Those preconditions are sound only because `@concurrent DetectorPipeline.process`
  is their one caller and is guaranteed off the main actor: keep it the only
  production caller. A test that calls a phase directly must do so off the main
  actor (`Task.detached`) — a wrong call crashes the test host (exit 133), it
  does not fail an assertion.

## Build and test
```
xcodebuild -scheme PawnPilot -project PawnPilot.xcodeproj -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/pawnpilot-tests-dd \
  -only-testing:PawnPilotTests test
```
- DerivedData lives OUTSIDE the repo (CodeSign fails on file-provider-synced
  folders). `/private/tmp/pawnpilot-tests-dd` is the convention.
- `-only-testing:PawnPilotTests` on purpose: `PawnPilotUITests` is Xcode
  template code plus `XCTApplicationLaunchMetric`, which launches the app five
  times. Run it only when an item is about launch time.
- **Never run two xcodebuilds concurrently.** When dispatching reviewers or
  parallel agents, hold the build yourself and tell them not to build.
- Unit tests instantiate `AppViewModel`, which loads the CoreML model and
  locates the engine — a green run proves the bundle layout too.
- Baseline on 2026-09-01: build + the 35-method unit suite green on the
  primary checkout's working tree (which then carried an uncommitted ~900-line
  refactor: `MoveTreeLogic`, `PieceColor`, castling/en-passant sanitising, the
  piece editor, and the tests for them). After the same day's §0 items the
  suite is 94 methods (`c5a31ca`); the engine and view-model tests drive the
  real engine classes over `PawnPilotTests/FakeUCIEngine.swift`.

## Known pre-existing flakes
None catalogued yet. If a test fails, re-run it once before investigating, and
add what you learn here.

## Model tiering (capability/cost: Opus > Sonnet)
- Opus: every review role, plus hi-tier implementation.
- Sonnet: standard/trivial implementation, mechanical fixes.
