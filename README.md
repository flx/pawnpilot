# PawnPilot

PawnPilot is a macOS chess app that detects a board position from an image and lets you analyze variations, inspect best lines, or play against Stockfish.

This README reflects the current `main` branch implementation.

## Current Status

- Platform: macOS app (`SwiftUI` + `AppKit` bridge), Apple Silicon.
- Minimum deployment target: macOS `13.5`.
- Engine: bundled Stockfish binary at `PawnPilot/Engine/stockfish-macos-m1-apple-silicon`.
- Offline app: no network dependency for detection or analysis.
- Current app version settings in project:
- `MARKETING_VERSION`: `1.2`
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`): `3`

## UI Overview

The app uses a two-column layout:

- Left column: chessboard, overlays, and score strip.
- Right column: AppKit-backed tab view with three modes:
- `Analyze Variations` (default on launch)
- `Analyze Best Lines`
- `Play Bot`
- Bottom section: output list (`Variations` / `Best Lines` / play-mode message).

Minimum window size is set to `1100 x 950` to avoid label wrapping in localized UI.

## Board Block (all tabs)

The `Board` group is split into two rows:

- Row A (state): `Next move` (White/Black), `Flip Board`, `Rotate` (icon).
- Row B (actions): `Open Image...`, `Reset`, `Undo`, `Redo`.

Also supported:

- Drag and drop image onto board.
- Legal-move highlighting.
- Last-move highlighting.
- Animated piece movement.
- Keyboard/menu shortcuts via app commands for open/reset/undo/redo/rotate/flip.

## Engine Parameters (all tabs)

- `Search Depth` slider: `4...30` (default `12`).
- `Strict depth` toggle: default `ON`.

`Strict depth` applies to:

- `Analyze Variations`
- `Analyze Best Lines`

It is not forced for bot-move generation.

## Mode Details

### Analyze Variations

- `Analysis Parameters`: `Alternatives/move` slider (`1...10`).
- Action button: `Analyze`.
- Output list behavior:
- Shows a selectable tree-style variation list with line numbering for current children.
- Number labels are right-aligned to a fixed width so single and double digits align.
- Selected path is rendered as a single row of move tokens.
- Earlier tokens in that path are clickable to jump back.
- Current last token is not clickable and not visually emphasized as clickable.
- Previously discovered alternatives are kept and shown in a gray, indented history list.
- Colored current alternatives are displayed as the most-indented entries.
- Clicking the selected row again deselects and returns to the root variation view.
- Board arrows in this mode show immediate next-ply branches from current base path.

Tree expansion notes:

- Expansion is lazy and happens one ply at a time.
- Distinct first moves are deduplicated.
- Retries up to 3 times with wider `MultiPV` if unique move count is below request.
- If fewer unique moves exist, status reports reduced count.
- Engine loop now exits cleanly on `bestmove` even when requested `MultiPV` cannot be fully populated, avoiding stalls.

### Analyze Best Lines

- `Analysis Parameters`:
- `Lines` slider (`1...10`)
- `Display plies` slider (`2...10`)
- Action buttons:
- `Analyze`
- `Play Selected Moves`
- Output list:
- Each line is prefixed with `a`, `b`, `c`, ...
- Format is `score` followed by UCI move sequence.
- Board arrows:
- Multi-line mode labels are `a1`, `a2`, ... / `b1`, `b2`, ...
- Selected single-line mode labels switch to `1`, `2`, `3`, ...

### Play Bot

- `Bot Parameters`:
- `Strength` (`1...5`)
- `Randomness` (`1...5`)
- `Keep playing` toggle
- Action button: `Play Bot Move`
- In play mode, analysis line output is hidden in the bottom section.

For analysis modes, engine strength is effectively maxed (`limitStrength = false`).
For bot play, configured strength/elo limiting is used.

## Scoring and Overlays

- Score strip under board shows `Score for white` or `Score for black` based on board bottom orientation.
- Variation-tree node scores are displayed from stored node perspective and adjusted for bottom side display.
- Threat map overlay rendering still exists internally (full-square red/blue overlays on white square base), but its UI toggle is currently removed from the visible interface.

## Help Popovers

Each group header has a question-mark icon:

- `Board`
- `Engine Parameters`
- `Analysis Parameters` (both analysis tabs)
- `Bot Parameters`

Hovering for ~0.5s opens a popover with concise control explanations.

## Localization

Project-localized languages currently configured:

- English (`en`)
- German (`de`)
- French (`fr`)
- Spanish (`es`)
- Italian (`it`)
- Chinese Simplified (`zh-Hans`)
- Japanese (`ja`)
- Korean (`ko`)
- Portuguese (Brazil) (`pt-BR`)

Localization files are in `PawnPilot/*.lproj/Localizable.strings`.

## Build and Run

Open in Xcode:

```bash
open /Users/felix/Documents/Programming/swift/PawnPilot/PawnPilot/PawnPilot.xcodeproj
```

Build from CLI:

```bash
xcodebuild -scheme PawnPilot -project /Users/felix/Documents/Programming/swift/PawnPilot/PawnPilot/PawnPilot.xcodeproj -configuration Debug build
```

To test a language in Xcode:

1. `Product > Scheme > Edit Scheme...`
2. Select `Run > Options`
3. Set `Application Language` and `Application Region`
4. Run

## Repository Layout

- App source: `PawnPilot/`
- View + UI composition: `PawnPilot/ContentView.swift`
- App state and behaviors: `PawnPilot/AppViewModel.swift`
- Engine wrappers: `PawnPilot/NextMoveModels/Engine/`
- Detection pipeline: `PawnPilot/FENDetector/`
- Project settings: `PawnPilot.xcodeproj/project.pbxproj`

## Known Gaps

- XCTest targets are mostly template scaffolding and do not yet cover current chess/engine workflows comprehensively.
- Recent images are kept in memory only (no persisted history).
- Threat-map feature is implemented but currently hidden from UI controls.
