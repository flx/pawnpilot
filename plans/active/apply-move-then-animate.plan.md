# Plan: (apply-move-then-animate)

Rev 3 · 2026-09-01 · tier **hi** (touches every move path in the view model
and the board view's contract; both adv reviewers on the code;
`adv-review-plan` ran twice — Rev 1 "build after fixing 4", Rev 2 "build
after fixing 3"; Rev 3 folds in every finding of both rounds. No third plan
round; reasons under Decisions. No `/arch-review`; reasons under Decisions.)

Source: TODO.md §0 (moved ahead of `(view-model-task-ownership-and-cancel)`
on 2026-09-01, `92d4040`); evidence `arch-reviews/2026-09-01-stability-performance.md` F4.
The cancel item's Rev 1 plan and its review findings are parked on disk at
`plans/parked/view-model-task-ownership-and-cancel.plan.rev1.md`.

## Premise re-derived against the tree (`92d4040`; every citation verified by both reviews)

`AppViewModel.swift`:
- `performAnimatedMove` (`:572-586`): validates (`:573`), `pushSnapshot()`
  (`:578`), sets `animatingPiece` (`:579`), sleeps 0.35 s (`:580`, `try?`),
  then `boardState.apply(move:)` (`:581`), `lastMove = move` (`:582`),
  `animatingPiece = nil` (`:583`), `updateUndoRedoState()`,
  `updateStatusForGameOver()`. Callers `engineMove` (`:398`),
  `playSelectedLine` (`:422`), `applyUserMove` (`:438`) — all from inside a
  `Task {}`, so nothing about the model changes before the entry point
  returns.
- `applyUserMove` (`:430-448`): validates (`:432`), `invalidateAnalysis()`
  (`:436`), `Task { await performAnimatedMove; engineLines = []; …; keepPlaying → engineMove() }`.
  Its caller (`ContentView.swift:318-322`) then sets `selectedSquare = nil`
  and calls `updateLegalMoves(for: nil)`.
- `undo`/`redo` (`:588-618`) pop/push snapshots and clear `animatingPiece`.
- Tree: `selectTreeNode` (`:297-346`) bumps `treeAnimationToken` (`:331`)
  and spawns the animators (`:890-958`), which mutate `boardState` after
  each sleep (`:933`, `:954`); `selectTreeNode(nil)` (`:298-308`) restores
  the snapshot without clearing `animatingPiece`; `:345` spawns
  `expandTreeForSelection`, which returns at `:757` for an already-expanded
  path. `animateTreeSelection` leaves the board alone when no move of the
  path resolves (`:920`).
- `invalidateAnalysis` (`:668-684`) bumps `treeAnimationToken` but does not
  clear `animatingPiece`. Callers: `detect` entry `:157`, `engineMove` `:368`,
  `applyUserMove` `:436`, `setSideToMove` `:460`, `resetBoard` `:470`,
  `rotatePosition` `:483`, `setPiece` `:534`, `undo` `:590`, `redo` `:606`.
  NOT callers: `analyze` (`:194-245`), `analyzeMoveTree` (`:247-295`),
  `selectTreeNode`, `playSelectedLine` (`:410-428`, which also never bumps
  the token). `detect`'s completion (`:171-183`) replaces the board later.
- `analyzeMoveTree` captures `treeRootState = boardState` (`:275`);
  `analyze` captures `boardState.fen` (`:230`); `gameOverScoreText`
  (`:686-688`), `pieceCode(at:)` (`:496-499`) and `updateLegalMoves`
  (`:450-456`) read `boardState`; `setPiece` (`:502-569`) compares the
  requested piece with the model (`:524-525`) before writing.
- Engines are `private let` concrete types (`:89-90`) built in `init()`
  (`:108-116`) — no injection seam.
- `interactionMode` defaults to `.analyzeMoveTree` (`:75`).

`ContentView.swift` reads: board (`:303` `boardState`, `:306` `lastMove`,
`:307` `legalDestinations`, `:314` `animatingPiece`); side-to-move binding
(`:210-213`: get `boardState.sideToMove`, set `setSideToMove`); perspective
colour (`:338`) feeding the score strip's sign (`:1807-1812`, `:1842-1847`)
whose data is `displayedEngineLines` (`:177`), NOT cleared until the move's
task tail; score label (`:191` `gameOverScoreText`); piece editor seed
(`:790-798` → `pieceCode(at:)`) and apply (`:808-816` → `setPiece`);
`updateLegalMoves` on every `selectedSquare` change (`:329-331`);
`canUndo`/`canRedo` (`:509`, `:511`, and the ⌘Z/⇧⌘Z menu items in
`PawnPilotApp.swift:36-39`); the Variations "Analyze" button is enabled
during a selection replay (`:444`, `isTreeAnalyzing` false at `:757`).
`BoardGridView` (`:1243-1355`) reads only its parameters; `BoardWithCoords`
(`:1996-2110`) feeds one `boardState` to the grid and both arrow overlays.

## Goal

The model changes **before the entry point returns** — apply, snapshot,
`lastMove`, side to move — so every later validation, undo, engine call and
tree root sees the true position. The animation is a visual tail: while a
piece is in flight the view renders the pre-move frame carried on
`AnimatedPiece`; when it lands, the model. **Every view read is on the
display clock; every write snaps first** (rule below), so no read→write
pair ever straddles the two clocks and the length of the window (0.35 s per
move, one frame per ply for a tree replay) is never load-bearing.

## The rule (replaces Rev 2's clock table)

- **Reads → display clock.** `displayBoardState = animatingPiece?.displayState ?? boardState`;
  `displayLastMove = animatingPiece?.displayLastMove ?? lastMove`. The
  board, the last-move highlight, the arrows, the legal dots, the score
  label (`gameOverScoreText`), the score strip's perspective colour, the
  side-to-move picker's GETTER, and the piece editor's seed all read it.
  `canUndo`/`canRedo`/`statusMessage`/the busy flags are not board reads;
  they follow the writes that set them, as today.
- **Writes → snap, then model.** `snapAnimation()` = `treeAnimationToken = UUID()`;
  if `animatingPiece != nil`: `animatingPiece = nil`, and if that animation
  was a MOVE animation (not a tree replay) `_ = updateStatusForGameOver()`
  (the landing's one side effect, so a snapped mating move still reports
  mate — Rev 2 review D9). It is called, synchronously, at the top of every
  user-driven write that reads the board or replaces tree/board state:
  `invalidateAnalysis` (hence reset, rotate, setPiece, setSideToMove, undo,
  redo, detect entry, engineMove, applyUserMove), `analyze()`,
  `analyzeMoveTree()`, `playSelectedLine()`, `selectTreeNode` (both
  branches, before anything else), the `detect` completion, the piece
  editor's `beginEditing(at:)`, and `updateLegalMoves(for:)` when the square
  is non-nil (a square selection is the first half of a move; `nil` is the
  deselect that follows every move and must NOT snap).
  After the snap the display IS the model, so the write acts on what the
  user sees.

Consequences inside the window, all recorded for the §5 pass: interacting
with the board or its controls while a piece is in flight ends the flight
(the piece appears at its destination) and then acts; a board-replacing
action does the same (today the piece kept flying onto the new board and
the stale move then landed); the other side's immediate reply is accepted
(today "Illegal move."). When the user does not interact, every frame is
today's frame.

## Acceptance criteria (tests in `PawnPilotTests/MoveApplicationTests.swift`, `@MainActor async`; view model built with the injected fake engines — Tier 0)

- D1 Two rapid white moves: `applyUserMove(e2→e4)` then, without awaiting,
  `applyUserMove(d2→d4)`. Immediately after the FIRST call returns:
  `boardState.sideToMove == .black`, `boardState.piece(at: e4) == .whitePawn`,
  `canUndo == true`, `animatingPiece?.from == e2`. The second call sets
  `statusMessage == "Illegal move."` and changes nothing else. After 0.8 s
  only e2e4 is on the board and `animatingPiece == nil`.
- D2 Undo during the animation: `applyUserMove(e2→e4)` then `undo()` in the
  same synchronous step. Immediately: `boardState == BoardState()`,
  `canUndo == false`, `canRedo == true`, `animatingPiece == nil`,
  `statusMessage == "Undid move."`. After 0.8 s: identical.
- D3 Reset during the animation with keep-playing armed:
  `interactionMode = .playAgainstComputer; keepPlaying = true`;
  `applyUserMove(e2→e4)` then `resetBoard()`. Immediately and after 0.8 s:
  `boardState == BoardState()`, `lastMove == nil`, `canUndo == false`,
  `animatingPiece == nil`, `statusMessage == "Board cleared."`,
  `isEngineThinking == false`, and the one-shot fake's log has no `go`.
- D4 Two-click tree (seeded tree, all paths expanded): select A (`[0]`)
  then B (`[0,1]`) in the same step. Immediately: `boardState == state(forPath: [0,1])`,
  `lastMove` is that path's last move, `selectedTreeNodeID == B`,
  `displayBoardState == state(forPath: [0])` (frame 0 of the incremental
  replay). After 1 s: `displayBoardState == boardState`, `animatingPiece == nil`.
- D4b Multi-frame replay: with B selected and settled, select D (`[1,0,0]`,
  depth 3, not incremental). Immediately: `boardState == state(forPath: [1,0,0])`,
  `displayBoardState == rootState`, `displayLastMove == nil`. At 0.5 s:
  `displayBoardState == state(forPath: [1])`, `displayLastMove == move(1)`.
  At 0.9 s: `state(forPath: [1,0])`, `displayLastMove == move([1,0])`. At
  1.3 s: `displayBoardState == boardState`, `animatingPiece == nil`. Then
  during a fresh replay of D, `selectTreeNode(nil)`: immediately the board
  is the pre-selection snapshot and `animatingPiece == nil`.
- D5 Frame lag: right after `applyUserMove(e2→e4)`: `displayBoardState == BoardState()`,
  `displayLastMove == nil`, `animatingPiece?.piece == .whitePawn`; after
  0.8 s `displayBoardState == boardState`, `displayLastMove == lastMove == e2e4`.
- D6 Castling and en passant frames: from a position where white can castle
  short, `applyUserMove(e1→g1)`: immediately `boardState.board[5,0] == .whiteRook`
  and `displayBoardState.board[7,0] == .whiteRook`; after 0.8 s both agree.
  En passant: the captured pawn is on the display board during the flight
  and gone from the model.
- D7 Tree root captures the true board: `applyUserMove(e2→e4)` then
  `analyzeMoveTree()` in the same step — `treeRootStateForTesting == boardState`
  (the applied board), and `animatingPiece == nil` (the snap). The fake
  answers; wait ≤ 3 s for `isTreeAnalyzing == false`.
- D8 Score label follows the display clock: fool's-mate position, apply
  `d8→h4`; immediately `gameOverScoreText == nil`; after 0.8 s it is the
  mate string and `statusMessage` is the mate string.
- D9 Selecting a square snaps: `applyUserMove(e2→e4)` then
  `updateLegalMoves(for: b8)` → `animatingPiece == nil`,
  `displayBoardState == boardState`, `legalDestinations == [a6, c6]`
  (black to move on the model). And `updateLegalMoves(for: nil)` right after
  a move does NOT snap (`animatingPiece != nil`, `legalDestinations == []`).
- D10 Editing a square snaps, so read and write agree: `applyUserMove(e2→e4)`
  then `beginEditing(at: e4)` returns `"wp"` and `animatingPiece == nil`;
  `setPiece(at: e4, code: "wp")` → "No piece change on e4." and the board
  is unchanged (Rev 2 review D2's create/delete cannot happen).
- D11 The picker: `applyUserMove(e2→e4)` then `setSideToMove(.black)` →
  `animatingPiece == nil`, `boardState.sideToMove == .black`, no snapshot
  pushed (the model already was black to move — same no-op as today, but
  the display now agrees).
- D12 Snapped mating move still reports mate: fool's-mate position, apply
  `d8→h4`, then `selectTreeNode(nil)` in the same step (no tree selected —
  it only snaps): `statusMessage` is the mate string immediately.
- D13 `playSelectedLine` after an illegal PV move still clears the lines:
  seed `engineLines` with one line whose first move is illegal and second
  legal; select it; `playSelectedLine()`; after 0.8 s `engineLines` was
  cleared (the terminal `analyze()` against the fake refills it — wait for
  `isAnalyzing == false`) and the legal move was applied.
- D14 Pure `MoveTreeLogic.frames(forPath:…)`: frame 0's `lastMoveBefore` is
  nil; frame k's `stateBefore` equals frame k−1's state after its move; a
  path whose third node is missing yields two frames and the two-ply state
  (prefix); an empty path yields no frames and the root.
- D15 The 53 existing tests still pass; `ContentView`'s diff is the two
  board call-site reads, the picker getter, the perspective colour, and the
  editor seed's method name — no layout, copy, colour or timing change;
  `MoveAnimation` untouched.

## Design

Ships as TWO commits: commit A = Tier 0 (the seam and hooks, no behaviour
change, gate green); commit B = Tiers 1–4 (one logical change: the model
becomes authoritative; the tiers below are reading order, not increments —
Tier 1 alone would be a no-op, Tier 2 without Tier 1 would show post-move
frames early).

### Tier 0 — engine injection seam (pulled forward from the parked cancel item's Tier 1)

```swift
private let engine: any EngineAnalyzing
private let treeEngine: any EngineAnalyzing
init() { … as today … }                                               // production
init(engine: any EngineAnalyzing, treeEngine: any EngineAnalyzing) { … }   // tests
```
(`any EngineAnalyzing` keeps the actor off-main — probe-verified in the Rev 2
review.) Two hooks (`// for tests`): `seedTreeForTesting(rootState:nodes:)`
(sets `interactionMode = .analyzeMoveTree`, `treeRootState`, `treeNodes`,
clears selection and snapshot, inserts every node's path key into
`treeExpandedPaths` so `expandTreeForSelection` returns at `:757` — verified
by the review to precede any engine call) and `var treeRootStateForTesting: BoardState?`.

### Tier 1 — `AnimatedPiece` carries the display frame; the view reads the display clock

```swift
struct AnimatedPiece: Identifiable {
    enum Kind { case move, treeReplay }
    let id: UUID
    let kind: Kind
    let piece: Piece
    let from: BoardSquare
    let to: BoardSquare
    let displayState: BoardState      // the position BEFORE this move
    let displayLastMove: ChessMove?   // the highlight to show while in flight
}
```
`AppViewModel`: `displayBoardState`, `displayLastMove` (computed);
`gameOverScoreText` and `updateLegalMoves` compute from `displayBoardState`
(the latter after its snap, when the two are equal); `pieceCode(at:)`
becomes `beginEditing(at:) -> String` = `snapAnimation()` then the model's
code. `ContentView`: `:303` → `displayBoardState`, `:306` → `displayLastMove`,
the picker getter (`:211`) → `displayBoardState.sideToMove`, the perspective
colour (`:338`) → `displayBoardState.sideToMove`, `:792` → `beginEditing(at:)`.
`BoardGridView`, both arrow overlays, `AnimatingPieceOverlay`, `MoveAnimation`
untouched.

### Tier 2 — the synchronous seam and the snap

```swift
/// Ends any animation NOW so the display equals the model. A move animation's
/// landing side effect (the game-over status) still happens.
private func snapAnimation() {
    treeAnimationToken = UUID()
    guard let current = animatingPiece else { return }
    animatingPiece = nil
    if current.kind == .move { _ = updateStatusForGameOver() }
}

/// Applies an accepted move to the model NOW and starts its animation.
/// Returns the animation id; nil means the move was refused and
/// `statusMessage` is "Illegal move.".
@discardableResult
private func applyMoveNow(_ move: ChessMove) -> UUID? {
    guard moveValidator.isLegal(move: move, in: boardState),
          let piece = boardState.piece(at: move.from) else {
        statusMessage = String(localized: "Illegal move.")
        return nil
    }
    let frame = boardState
    let frameLastMove = lastMove
    pushSnapshot()                       // pre-move model; updates canUndo/canRedo
    boardState.apply(move: move)
    lastMove = move
    let id = UUID()
    animatingPiece = AnimatedPiece(id: id, kind: .move, piece: piece, from: move.from, to: move.to,
                                   displayState: frame, displayLastMove: frameLastMove)
    return id
}

/// Waits out the animation started by `applyMoveNow`. False if something
/// snapped it — the snapper owns the board and the status.
private func finishAnimation(_ id: UUID) async -> Bool {
    try? await Task.sleep(nanoseconds: UInt64(MoveAnimation.duration * 1_000_000_000))
    guard animatingPiece?.id == id else { return false }
    animatingPiece = nil
    _ = updateStatusForGameOver()        // same moment as today
    return true
}
```

- `invalidateAnalysis` calls `snapAnimation()` (replacing its bare token bump).
- `analyze()` and `analyzeMoveTree()` call `snapAnimation()` where they
  currently bump/clear tree state (Rev 2 review D4). `playSelectedLine()`
  calls it first (D8). `detect`'s completion calls it next to the board
  replacement. `updateLegalMoves(for: square)` calls it when `square != nil`.
  `setSideToMove` reaches it through `invalidateAnalysis` — but its
  `guard boardState.sideToMove != color` runs FIRST today (`:459`); move the
  snap ahead of the guard so D11 holds (the guard then compares against the
  model the user now sees).
- `applyUserMove`: `guard isLegal` (early "Illegal move.", as today);
  `invalidateAnalysis()` (snaps); `guard let id = applyMoveNow(move) else { return }`;
  then `Task { let completed = await finishAnimation(id); engineLines = []; selectedEngineLineID = nil; treeNodes = []; selectedTreeNodeID = nil; legalDestinations = []; if completed, keepPlaying, interactionMode == .playAgainstComputer, !isEngineThinking { engineMove() } }`.
- `engineMove`'s task: `guard let id = applyMoveNow(move) else { return }`
  ("Illegal move." is set; today the status was then overwritten with
  "Engine played …" for a move that never happened — corrected, recorded);
  `guard await finishAnimation(id) else { return }`; then "Engine played %@."
  and `updateStatusForGameOver()` as today.
- `playSelectedLine`'s task, per move: `guard interactionMode == .analyzeLines`;
  `if let move = boardState.move(fromUCI: uci), let id = applyMoveNow(move) { guard await finishAnimation(id) else { return } }`;
  `engineLines = []` (unconditionally, as today — Rev 2 review D10). Then
  `analyze()` as today.
- `performAnimatedMove` is deleted.

### Tier 3 — tree selection: model and frame 0 in one synchronous step

`MoveTreeLogic` gains `TreeFrame { stateBefore, lastMoveBefore, move, piece }`
and `frames(forPath:rootState:nodeMap:) -> (frames: [TreeFrame], finalState: BoardState, finalLastMove: ChessMove?)`
with PREFIX semantics (stops at the first missing node, unparseable UCI or
empty `from`); frame 0's `lastMoveBefore` is nil.

`selectTreeNode(id)`:
1. `snapAnimation()` first (also bumps the token). Resolve `rootState`,
   `node`, `previousPath`, `newPath` as today; take `treeSelectionSnapshot`
   if nil.
2. `let replay = MoveTreeLogic.frames(forPath: newPath, …)`. If `newPath`
   is non-empty and `replay.frames` is empty, set `selectedTreeNodeID = id`,
   spawn the expansion task, and return without touching the board (today's
   `:920`, Rev 2 review D11).
3. Frames: incremental (`previousPath != nil`, `newPath == previousPath + [x]`,
   `boardState == replay.frames.last!.stateBefore`) → `[last]`; else all.
4. Same synchronous step: `boardState = replay.finalState`; `lastMove = replay.finalLastMove`;
   `legalDestinations = []`; `selectedTreeNodeID = id`;
   `animatingPiece = frames.first.map { AnimatedPiece(frame: $0, kind: .treeReplay) }`
   (nil when the path is empty — root selected — which is today's snap to
   the root).
5. `let token = treeAnimationToken; Task { await advanceTreeFrames(frames, token: token) }` —
   unstored, as today (the token is the ownership; Rev 2 review D13):
   `for index in frames.indices { sleep; guard token == treeAnimationToken else { return }; animatingPiece = index + 1 < frames.count ? AnimatedPiece(frame: frames[index + 1], kind: .treeReplay) : nil }`.
6. `Task { await expandTreeForSelection(id: id) }` as today.

`selectTreeNode(nil)`: `snapAnimation()` first, then as today.
`animateTreeSelection`, `animateTreeSelectionIncremental` deleted.

### Tier 4 — tests

`MoveApplicationTests.swift` (D1–D13; waits are `Task.sleep` on the main
actor — probe-verified to let the view model's tasks run — with 0.8 s / 1 s
against the 0.35 s animation, and D4b samples mid-frame at 0.5/0.9/1.3 s);
`MoveTreeLogic` frame tests (D14) next to the existing ones. Both fake
engines answer at once, so nothing else runs during the waits.

## Load-bearing assumptions

- Rendering the pre-move `BoardState` while animating reproduces today's
  board frames (Rev 1 and Rev 2 reviews: clean by construction).
- `@MainActor async` XCTest + `Task.sleep` lets the view model's main-actor
  tasks run (Rev 2 review probe: holds).
- `BoardState: Equatable` (`BoardState.swift:16`).
- The score strip's sign, computed from `perspectiveColor` and the
  displayed lines, is unchanged because both now come from the same
  (display) clock and the lines are cleared at the landing as today.

## Out of scope (explicit)

- Storing/cancelling the move and engine tasks — the parked cancel item
  (Tier 0 here is its Tier 1 pulled forward; its Rev 2 will build on the
  seam and on `snapAnimation`).
- Legality checking of tree PVs.
- A rendered-UI regression test (none exists in the repo); UI equivalence
  is the §5 `(sitting-ui-unchanged-after-each-landing)` pass, with the three
  recorded in-window differences named for it.

## Decisions taken

- 2026-09-01 · Rev 1 → Rev 2 (review round 1): the apply moved into a
  synchronous seam; engine injection pulled forward; tree model + frame 0
  in one step; prefix-replaying frames; callers' tails guarded.
- 2026-09-01 · Rev 2 → Rev 3 (review round 2, "build after fixing 3"): the
  per-read clock table is replaced by the rule "reads → display clock;
  writes → snap, then model". It closes the four read→write findings (score
  sign, piece editor create/delete, dots vs validation, picker) with one
  mechanism instead of four special cases, and makes the tree-replay window
  (one frame per ply, seconds) irrelevant because any interaction collapses
  it. Also folded: `analyze`/`analyzeMoveTree`/`playSelectedLine` snap;
  `applyMoveNow`'s contract is now exact (nil ⇒ "Illegal move." set);
  `engineMove` no longer overwrites "Illegal move." with "Engine played";
  D3 sets the mode; D4b drives the multi-frame path; a snapped mating move
  still reports mate; an illegal PV move still clears the lines; an
  unresolvable path leaves the board alone; the tree task is unstored; the
  parked plan is on disk; Tier 0 is its own commit.
- 2026-09-01 · No third plan round: two rounds moved the design from
  "apply then animate" to "apply, display a frame, snap on interaction",
  and the residual risk is now in the implementation (13 criteria cover the
  seam, the snap sites and the frames), which is what the two code
  reviewers see. Alternative: another ~15-minute round. Rejected as
  diminishing returns.
- 2026-09-01 · The other side's immediate reply is accepted inside the
  window (today rejected because the model still said it was the mover's
  turn); interacting mid-flight ends the flight. Both recorded for §5.
- 2026-09-01 · No `/arch-review`: the boundary is the two display
  accessors plus one rule, written above; `(viewmodel-mode-state)` inherits
  the rule. The Rev 2 review's tension (a table of reads was the wrong
  artefact) is accepted — the rule is the artefact it asked for.
- 2026-09-01 · `updateStatusForGameOver` runs at the landing (as today) or
  at the snap of a move animation; the callers' own status writes are
  guarded by `finishAnimation`'s result.
- 2026-09-01 · **Code review (both reviewers: ship after fixing 2–3),
  accepted and fixed.** The plan's `finishAnimation` Bool conflated "my
  flight was cut short" with "my move never happened": a square click, an
  edit or the picker snaps the animation while the move IS on the model,
  so the keep-playing reply was cancelled, "Engine played …" was suppressed
  and a PV replay stopped on any click inside the window. Fix:
  `applyMoveNow` returns an `AppliedMove` (animation id, the FEN it
  produced, `boardEpoch`); `finishAnimation` returns `.landed | .cutShort |
  .replaced`, where `.replaced` means `boardEpoch` advanced — it is bumped
  only by board-REPLACING writes (`invalidateAnalysis`'s callers, both
  `selectTreeNode` branches, the detect completion), never by a move.
  Tails: the engine status needs `!= .replaced`; the keep-playing reply
  needs that AND `boardState.fen == fenAfter` (a further move's own tail
  chains its own reply); the replay loop stops on `.replaced` or a changed
  FEN and otherwise continues. `applyUserMove`'s post-flight clears are
  gated on the analysis/tree tokens captured at the move, so an analysis or
  tree started inside the window survives the tail (the pre-existing
  wipe-at-0.35 s that D7's own scenario suffered). `setPiece` and
  `engineMove` snap before their first board read (the plan claimed both
  were covered; `setPiece`'s comparison ran before `invalidateAnalysis`).
  `ContentView` passes a literal `nil` to `updateLegalMoves` after a move.
  D13 now samples inside the flight (it was vacuous after the terminal
  `analyze()` refilled the lines); E1–E5 and D10b added. The fake gained a
  configurable `bestmove` so keep-playing gets a legal black reply.
- 2026-09-01 · **Re-review of the fix delta (adv-review-edge: ship after
  fixing 1), accepted and fixed:** a `playSelectedLine` replay continued
  underneath an `analyze()` started mid-replay (a benign snap that leaves
  board and mode alone), so with a slow search the arrows for a position
  plies back could land on a later board with "Analysis ready." — the loop
  and its terminal `analyze()` now stop when the analysis token changes.
  A user move must not bump `boardEpoch` (it did, through
  `invalidateAnalysis`), or a reply made inside the engine's flight left the
  status on "Engine thinking…" — `invalidateAnalysis(replacingBoard: false)`
  for the two move callers. E4 asserts its flight is live before snapping
  (it had silently stopped discriminating past 0.35 s); E6 pins the epoch
  for the keep-playing reply (Reset then the same move yields the identical
  FEN — only the epoch prevents two replies); E7 pins the analysis-token
  stop — and its first run caught that the loop's own post-flight
  `engineLines = []` wiped the mid-replay analysis before the next
  iteration's guard ran; the token is now checked right after the flight
  too. Deferred to the cancel item: `engineMove` captures the epoch after
  its await, so a Reset DURING the search still lands the engine's move on
  the cleared board (F5's case, unchanged by this item); `playSelectedLine`
  has no re-entrancy guard; `finishAnimation`'s `try? await Task.sleep`
  must check cancellation once tasks are cancellable.
- 2026-09-01 · **Recorded, not changed:** an edit composed on the piece
  editor BEFORE a move and applied within the window acts on the post-move
  board (the snap makes that the board the user sees at the instant of the
  write). Before this change the stale model made the same edit a no-op by
  accident inside the window, while outside the window it always applied to
  the current board — the two cases are now consistent. Making a move while
  the editor card is open is the precondition. The reviewers' other notes
  (an unparseable PV move now retires the lines too; the sub-frame at t≈0
  that the old asynchronous apply may have drawn) are glitch-removing.
