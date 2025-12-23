# Chess Tutor – Product and Technical Specification (MVP, as-built)

This document reflects the current codebase and is detailed enough to serve as the ground truth for a rebuild.

## Purpose
macOS SwiftUI app for Apple Silicon that detects a chessboard from a screenshot (offline), converts it to FEN, visualizes engine analysis directly on the board, and supports lightweight play/analysis modes without persistence.

## Platforms and Constraints
- Apple Silicon only; Intel not supported.
- Offline processing; no networking.
- Bundled Stockfish binary (arm64) found under `Resources/Engine/arm64/...`.
- No clipboard import; recents are in-memory only (last 3 items).

## Current Capabilities
- Detection: drag/drop or file picker, auto-rotate board per detection suggestion, console-only warnings.
- Board: coordinates, legal move highlighting, last-move highlight, animated moves, undo/redo, rotate 180°, flip toggle, side-to-move toggle, reset board, load recent images.
- Engine: multi-PV analysis (depth-based), adjustable strength, search depth, lines count, arrows/plies display, score strip from bottom-side perspective, optional play-against-bot with randomness, optional “keep playing” auto-reply.
- Modes:
  - View Best Lines: classic multi-PV list + arrows; selectable line highlights only its arrows; play selected moves replays the selected PV subset.
  - Analyze Variations: move-tree exploration with per-branch expansion, deduped first moves, retry to fetch more unique moves, and per-branch arrows.
  - Play Against Bot: user moves with legal validation; bot replies via Stockfish; lines hidden in this mode.
- Engine timeouts: disabled by default (no forced timeout).

## User Flows
1. Import
   - Open via file picker or drag/drop.
   - Added to Recents (up to 3, in-memory).
   - Detection runs immediately; warnings logged to console.
2. Board Setup
   - If detector suggests flip, board state is rotated 180° and UI shows white at top (orientation reflects screenshot).
   - Side to move defaults to white; user can toggle.
   - Flip toggle sets board to look like “playing as black” when enabled.
3. View Best Lines
   - User sets strength, search depth, lines (MultiPV), and “Display plies” (arrows per line).
   - Press Analyze to run depth search (no movetime toggle).
   - List shows score (relative to bottom side) followed by moves; numbering and depth labels are omitted.
   - Selecting a line shows only its arrows (labeled 1a/1b/… when multiple lines, 1/2/3 when isolated).
   - Play Selected Moves replays up to the display-plies limit, then re-analyzes.
4. Analyze Variations
   - Slider “Alternatives/move” controls branch count.
   - Press Analyze to build a tree: per depth-step expansion of distinct first moves. If fewer than requested unique first moves are returned, engine retries up to 3 times with higher MultiPV before giving up and noting reduced count.
   - Tree list shows move + score only (no labels/depth text); rows are colored by branch at the current base depth.
   - Arrows show only the next ply per branch; labels show the last digit of the branch label.
   - Selecting a node animates from root; selecting a direct child of the current selection animates incrementally with just the new move.
   - Scores are displayed from the perspective of the color at the bottom; tree scores use the stored perspective at node creation (do not flip per ply).
   - Re-running Analyze in this mode clears selection and resets to the root position.
5. Play Against Bot
   - “Bot Move” triggers Stockfish move selection; randomness slider controls pick among top lines.
   - “Keep playing” auto-invokes bot move after user moves (disabled in other modes).
   - No engine lines shown; analysis state is cleared when entering this mode.
6. Board Controls
   - “Open Image…”, “Reset Board”, “Rotate Position”, “Flip Board”, “Next move white/black” toggle, “Undo Move”, “Redo Move”.
   - Board drop highlight does not resize the board.
7. Status and Scores
   - Score strip reads “Score for white/black” based on bottom orientation and uses bottom-side perspective.
   - Status bar shows detection/analysis messages; warnings are not shown in UI.

## Data and Models
- `BoardState`: pieces, activeColor, castling, enPassant, halfmoveClock, fullmoveNumber. Provides FEN and move application (promotions default to queen if omitted).
- `ChessMove` / `BoardSquare`: UCI parsing honors activeColor for promotions.
- `EngineScore`: cp or mate.
- `EngineLine`: multipv, score, depth, nodes, nps, moves, id.
- `EngineOptions`: multiPV, movetimeMs (unused in current UI), depth, strength, limitStrength, elo, hash, threads.
- `TreeMoveNode`: id, parentID, plyIndex, choicePath, uci, score, depth, scorePerspective, isUserMove.
- Recents: `[RecentImage]` with NSImage + label, capped at 3, in-memory only.

## Engine Behavior
- UCI handshake per run (single-shot) and persistent engine (for tree) share option application: Threads, Hash, MultiPV, UCI_LimitStrength/elo.
- Search is depth-driven; movetime selection UI removed.
- MultiPV: View Best Lines uses user MultiPV; tree uses Alternatives/move with retry widening MultiPV if unique moves are insufficient.
- Timeouts: constructors accept optional timeout; current app passes nil (no timeout).
- Engine move selection: uses MultiPV enlarged when randomness > 1; selector filters large eval drops before random pick.

## Tree Analysis Details
- Branch expansion: one ply at a time from base path; dedup on first move per branch.
- Retry strategy: up to 3 attempts increasing MultiPV (branchCount*(attempt+2)), stop early if enough unique first moves.
- Overlay: shows only immediate child ply arrows; labels are the last digit of branch path.
- Tree list: shows moves and scores only; rows colored for children of the current base path.
- Selection animation: full replay from root for non-adjacent selection; incremental single-move animation when selecting a direct child of the current selection.
- Scores: always from bottom-side perspective using node.scorePerspective captured when node was created.

## UI Layout (Current)
- Two-column layout: fixed-width board column on the left; right panel for controls. Board/top-left anchored; engine sections below two columns; scrollable engine/tree list.
- Top of window (traffic lights area) kept empty (content starts below).
- Window sizing: minimum width 960px and minimum height 700px to keep labels visible; otherwise resizable.
- Group boxes:
  - Engine Parameters: strength slider, search depth slider (default 8), lines slider (MultiPV), “Display plies” slider for arrows per line.
  - Play Against Bot: randomness slider, “Bot Move” button with small spinner on the right, “Keep playing” toggle.
  - Analyze Variations: “Alternatives/move” slider, “Analyze” button with spinner.
  - View Best Lines: lines slider (same setting), “Analyze” button with spinner, “Play Selected Moves” button in engine section header.
  - Board: Open Image, Reset Board, Rotate Position, Flip Board toggle, Next move white/black toggle, Undo Move, Redo Move (arranged in rows per UI code).
- Engine section header text switches between “Best Lines” and “Variations”. Engine list shows score then move text inline, no numbering, no depth. Tree list shows move + score.
- Arrows:
  - Best Lines: labels 1a/1b/… when multiple lines visible, or 1/2/3 when only selected line displayed; circles present.
- Variations: labels are last digit of branch label; no circles or numbering stubs; one ply per branch at a time.
  - Offset handling keeps overlapping arrows separated; board size fixed when drag highlight appears.
- Score strip under board: “Score for white/black: <value>” using bottom orientation perspective (cp sign flips based on bottom side vs engine reporting side-to-move).

## Error Handling and Reset Behavior
- Detection failures surface as status messages; board remains unchanged.
- Missing engine shows a user-facing error and prevents analysis.
- Re-running Analyze in either mode clears previous selections and resets tree/root state (tree) or selected engine line (best lines).

## Non-Goals (still out-of-scope)
- Intel support.
- Persistence (recents, sessions, configs).
- SAN display or FEN editor UI.
- Clipboard paste import.
- Additional analysis modes (Top Moves vs Best Line toggle), copy actions, metadata controls, overlays for low confidence, recents shelf persistence.

## Testing
- Automated: BoardState move application (castling, en-passant, promotions), MoveValidator legality (castling through check, EP), UCI promotion parsing.
- Manual (see `manual_tests.md`): import/detect, orientation, analysis modes, tree expansion and selection, score strip perspective, bot move/keep-playing, undo/redo, board controls, drag/drop without resizing board, stockfish presence in bundle.

## Glossary
- Active color: side to move, “w” or “b”.
- Bottom-side perspective: scores displayed from the color currently at the bottom of the UI.
- MultiPV: Stockfish option returning multiple principal variations.
- PV: principal variation; best line from current node.
- UCI: Universal Chess Interface; protocol used with Stockfish.
- Alternatives/move: requested number of distinct first moves per ply in tree mode.
