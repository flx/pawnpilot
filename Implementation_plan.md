# Implementation Plan – NextMove Chess Tutor (Rebuild Blueprint)

This plan is structured so the app can be re-implemented from scratch with equivalent behavior. It reflects the current codebase (Apple Silicon, offline).

## Diagrams

### System Overview
```
[SwiftUI Views] <-> [AppViewModel] <-> [NextMoveKit]
                                   |-- BoardState / MoveValidator / LegalMoveGenerator
                                   |-- StockfishEngine (single-shot UCI)
                                   |-- PersistentStockfishEngine (tree analysis)
                                   |-- DetectorPipeline (FENDetectorKit)
                                   |-- Models: EngineLine, EngineScore, TreeMoveNode
```

### Runtime Flow
```
[Import Image] -> [Detection Pipeline] -> [BoardState + Orientation]
       |                    |                    |
       v                    v                    v
   [Recents]         [Board UI state]    [Status + warnings to console]
                                         |
                                         v
                            [Analyze Best Lines / Alternative Moves / Bot Move]
                                         |
                                         v
                          [Engine Lines or Tree Nodes] -> [Arrows Overlay + Lists]
```

### Tree Expansion Flow
```
[Analyze Alternative Moves]
    -> root state snapshot
    -> expand base path by 1 ply
    -> dedup first moves; if < requested, retry with higher MultiPV (3 attempts)
    -> render arrows for immediate children; list rows colored by branch
    -> on selection: animate from root (or incremental if selecting direct child)
    -> expand selected path lazily, one ply at a time
```

## 0) Targets and Resources
- Targets: NextMoveApp (SwiftUI), NextMoveKit (logic), vendored FENDetectorKit.
- Resources:
  - Engine: `Resources/Engine/arm64/stockfish` (and variants) bundled; locate executable recursively.
  - Pieces: SVG/PNG assets under `Resources/ChessPieces`.
- Platform: macOS 14+, Apple Silicon only. Offline; no networking.
- Engine timeouts: optional; default is no timeout (nil).

## 1) Core Models
- `BoardState`: pieces grid, activeColor ("w"/"b"), castling, enPassant, halfmoveClock, fullmoveNumber; FEN export; apply(move:) handles promotions (default queen), en-passant capture, castling rook move, clocks, and toggles activeColor.
- `ChessMove`, `BoardSquare`: UCI parsing uses activeColor for promotion piece color.
- `EngineScore`: `.cp(Int)` in centipawns; `.mate(Int)` where sign indicates side-to-mate.
- `EngineLine`: multipv, score, depth, nodes, nps, moves [UCI], id.
- `EngineOptions`: multiPV, movetimeMs?, depth, strength, limitStrength, elo, hash, threads.
- `TreeMoveNode`: id, parentID, plyIndex, choicePath, uci, score, depth, scorePerspective (side-to-move at creation), isUserMove.
- `RecentImage`: NSImage + label, capped at 3, in-memory.

## 2) Move Logic
- Move application:
  - Validate piece exists; resolve promotion (default queen).
  - En-passant capture removes pawn behind target.
  - Castling moves rook (king-side: h->f; queen-side: a->d).
  - Update castling rights on king/rook moves or rook capture on original square.
  - Set enPassant on double pawn advance; clear otherwise.
  - Reset halfmoveClock on pawn move/capture; increment otherwise.
  - Increment fullmoveNumber after black moves; toggle activeColor.
- Move validation:
  - Enforce side-to-move, blocking, captures, castling rules (rights, empty path, not through/into check), en-passant legality, and king safety after move.
- Legal move generation:
  - Produce candidate destinations per piece (including castling targets) and filter via validator.

## 3) Detection
- Use `DetectorPipeline` from FENDetectorKit.
- Input: CGImage from file or drop.
- Output: board, suggestedFlipForFEN, warnings, castling suggestion.
- Orientation:
  - If suggestedFlipForFEN, rotate board 180° and set UI orientation so white is at top (matches screenshot); otherwise white at bottom.
- Side-to-move defaults to white (toggle available in UI).
- Warnings: log to console only; no UI warning overlay.

## 4) Engine Integration
- StockfishEngine (single-shot):
  - Start process, send `uci`, wait `uciok`, apply options (Threads, Hash, MultiPV, UCI_LimitStrength/Elo), `isready`, then `position fen ...` and `go depth N` (or movetime if provided).
  - Parse `info` lines into EngineLine; collect latest per multipv; stop on `bestmove` or after reaching required depth if `requireFullDepth`.
  - Timeout optional; default nil (no timeout).
- PersistentStockfishEngine (tree):
  - Persistent process with one-time handshake (uci/ready) and reused for successive `go depth`.
  - Optional timeout (nil by default).
- Engine move selection (bot move):
  - Request MultiPV based on randomness; filter large eval drops; random pick among top-N; apply first move.

## 5) View Model (AppViewModel)
- State: boardState, orientationWhiteAtBottom, detectionStatus, statusMessage, engineLines, selectedEngineLineID, animatingPiece, legalDestinations, lastMove, recents, undo/redo stacks, strength, randomness, searchDepth, multiPV (lines), maxArrowsPerLine (“Display plies”), interactionMode (best lines / alternative moves / play bot), isAnalyzing, isTreeAnalyzing, isEngineThinking, keepPlaying, treeBranchCount (“Alternatives/move”), treeNodes, selectedTreeNodeID, tree root state and activeColor snapshot, tree expansion bookkeeping.
- Behaviors:
  - loadImage/loadRecent -> detect() -> apply orientation, log warnings, reset lines/tree/history.
  - analyze (Best Lines) -> clear tree state and selections, run StockfishEngine with depth/multiPV; store lines; status “Analysis ready” or error.
  - analyzeMoveTree -> clear engine lines, reset selection, set root snapshot, expand 1 ply via PersistentStockfishEngine; dedup first moves; retry up to 3 times with higher MultiPV if unique count < requested; status shows reduced count when applicable.
  - selectTreeNode -> animate from root; if selecting direct child of current selection, animate only the new move; expand lazily one ply beyond current path.
  - tree arrows: only immediate children of current base path; labels are last digit of branch label; one ply per branch.
  - applyUserMove -> validate, animate, clear analyses; if keepPlaying in bot mode, queue bot move.
  - engineMove (Bot Move) -> run analyze with randomness, apply first move; spinner shown; disable button while thinking.
  - playSelectedLine -> animate up to maxArrowsPerLine from selected line; then re-run analyze.
  - Undo/Redo -> snapshot stacks; clear analyses.
  - resetBoard/rotatePosition/flipBoard/side-to-move toggle -> clear analyses and history; update orientation (flip toggles bottom color).
  - Re-running analyze in either analysis mode clears selections and resets tree/root state.
  - Scoring: all displays use bottom-side perspective; tree nodes keep scorePerspective captured at creation.

## 6) UI Composition
- Layout: fixed-width board column left; right panel controls; engine/alternative moves section below columns; scrollable lists; status bar at bottom; minimum window size ~960x700 to keep labels visible.
- Top margin preserved (traffic-light area empty).
- Group boxes:
  - Engine Parameters: strength slider, search depth slider (default 8), lines slider (MultiPV), “Display plies” slider (arrows per line).
  - Play Against Bot: randomness slider, “Bot Move” button with right-aligned spinner, “Keep playing” toggle (disabled outside bot mode).
  - Analyze Variations: “Alternatives/move” slider, “Analyze” button with spinner.
  - View Best Lines: lines slider, “Analyze” button with spinner.
  - Board: Open Image, Reset Board, Rotate Position, Flip Board toggle, Next move white/black toggle, Undo Move, Redo Move (arranged per current UI code rows).
- Engine section header: “Best Lines” or “Variations”.
- Lists:
  - Best Lines: shows score then moves inline (no numbering, no depth text). Selection gives dark border.
  - Variations list: move + score only; rows colored for children of current base path; selection border darker.
- Arrows:
  - Best Lines: labels 1a/1b/… when multiple lines shown; 1/2/3 when only selected line shown; circles present; overlap offset to reduce collision.
  - Variations: labels = last digit of branch label; no circles; one ply per branch at a time.
- Score strip under board: “Score for white/black: <value>” using bottom orientation; tree overrides show node score from bottom perspective.
- Drag/drop highlight does not resize board.

## 7) Interaction Modes
- View Best Lines: depth search, adjustable MultiPV and display plies; Play Selected Moves replays selected PV and re-analyzes.
- Analyze Variations: tree expansion with per-ply dedup and retry; lazy expansion on selection; incremental animation for direct child selections.
- Play Against Bot: lines hidden; Bot Move executes one move; Keep playing auto-replies after user move.
- Switching modes clears conflicting analysis state.

## 8) Error Handling
- Detection failures set status message; board unchanged.
- Missing/failed engine surfaces status; no analysis performed.
- Tree analysis with insufficient unique moves reports reduced count after retries.
- Timeouts: none by default; options accept timeout if needed.

## 9) Testing
- Automated (existing): BoardState apply (castling, en-passant, clocks), UCI promotion parsing, MoveValidator legality.
- Manual (see `manual_tests.md`): import/detect, orientation toggle/flip, score strip perspective, best-lines selection/labels/arrows, tree expansion (retry, labels, animation), bot move/randomness/keep-playing, undo/redo, board controls, drag/drop sizing, engine presence in bundle.

## 10) Rebuild Steps (High-Level)
1. Set up Swift package with targets NextMoveApp and NextMoveKit; include FENDetectorKit vendor.
2. Add resources: Stockfish arm64 binary under Engine/arm64; chess piece assets under Resources/ChessPieces; ensure bundle lookup enumerates recursively.
3. Implement models (EngineScore/Line/Options, TreeMoveNode, BoardState, MoveValidator, LegalMoveGenerator, EngineMoveSelector).
4. Implement StockfishEngine (single-shot) and PersistentStockfishEngine (persistent) with optional timeout (nil default).
5. Implement AppViewModel per behaviors above, including mode handling, retries for tree, score perspective, and incremental animation.
6. Build SwiftUI views: board rendering, overlays, controls, group boxes, lists, score strip, status bar; enforce fixed board column and anchored layout; ensure drag highlight doesn’t resize board.
7. Wire interactions: analyze buttons, bot move, keep playing, selection handling, play selected moves, undo/redo, orientation/flip/side-to-move toggles, recents shelf, drag/drop handlers.
8. Test: run `swift test`; validate manual checklist flows; verify Stockfish binary found in bundle and no timeouts at high depth.
