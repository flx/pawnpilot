import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "com.digitalhandstand.PawnPilot", category: "AppViewModel")

enum InteractionMode {
    case analyzeLines
    case playAgainstComputer
    case analyzeMoveTree
}

struct RecentImage: Identifiable {
    let id = UUID()
    let image: NSImage
    let label: String
}

struct TreeMoveNode: Identifiable {
    let id: UUID
    let parentID: UUID?
    let plyIndex: Int
    let choicePath: [Int]
    let uci: String
    let score: EngineScore
    let depth: Int
    let scorePerspective: PieceColor
    let isUserMove: Bool

    init(
        id: UUID = UUID(),
        parentID: UUID?,
        plyIndex: Int,
        choicePath: [Int],
        uci: String,
        score: EngineScore,
        depth: Int,
        scorePerspective: PieceColor,
        isUserMove: Bool
    ) {
        self.id = id
        self.parentID = parentID
        self.plyIndex = plyIndex
        self.choicePath = choicePath
        self.uci = uci
        self.score = score
        self.depth = depth
        self.scorePerspective = scorePerspective
        self.isUserMove = isUserMove
    }

    var label: String {
        choicePath.map { String($0 + 1) }.joined()
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var boardState = BoardState()
    @Published var detectionStatus: DetectionStatus = .idle
    @Published var engineLines: [EngineLine] = []
    @Published var statusMessage: String?
    @Published var isAnalyzing = false
    @Published var strength: Int = 5
    @Published var multiPV: Int = 5
    @Published var orientationWhiteAtBottom = true
    @Published var lastMove: ChessMove?
    @Published var legalDestinations: [BoardSquare] = []
    @Published var selectedEngineLineID: EngineLine.ID?
    @Published var maxArrowsPerLine: Int = 4
    @Published var randomnessStrength: Int = 1
    @Published var animatingPiece: AnimatedPiece?
    @Published var interactionMode: InteractionMode = .analyzeMoveTree
    @Published var isEngineThinking = false
    @Published var keepPlaying = false
    @Published var recents: [RecentImage] = []
    @Published var searchDepth: Int = 12
    @Published var strictDepth = true
    @Published var treeNodes: [TreeMoveNode] = []
    @Published var selectedTreeNodeID: TreeMoveNode.ID?
    @Published var treeBranchCount: Int = 5
    @Published var isTreeAnalyzing = false
    @Published var canUndo = false
    @Published var canRedo = false

    private let pipeline = DetectorPipeline()
    private let engine: any EngineAnalyzing
    private let treeEngine: any EngineAnalyzing
    private let selector = EngineMoveSelector()
    private let moveValidator = MoveValidator()
    private let moveGenerator = LegalMoveGenerator()
    private var undoStack: [BoardSnapshot] = []
    private var redoStack: [BoardSnapshot] = []
    private var droppedImageCounter = 0
    private let maxRecents = 3
    private var analysisToken = UUID()
    private var treeToken = UUID()
    private var detectionToken = UUID()
    private var treeAnimationToken = UUID()
    private var treeRootState: BoardState?
    private var treeExpandedPaths: Set<String> = []
    /// Path key -> the expansion that claimed it. Owner-keyed so a cancelled expansion can
    /// never drop the claim of the one that superseded it.
    private var treeExpandingPaths: [String: UUID] = [:]
    private var treeSelectionSnapshot: BoardSnapshot?

    // MARK: - Task ownership
    //
    // Every asynchronous entry point stores its task, so work a new gesture supersedes is
    // CANCELLED rather than left running with its result ignored. Two operations with distinct
    // meanings: `cancelSupersededWork()` (the analysis, both tree expansions, a replay and the
    // previous move's tail) and `cancelBotMove()` (the bot's search AND its landing tail). A
    // human move does the first and never the second — a move made during the bot's landing is
    // still reported as "Engine played …".
    private var detectionTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var engineMoveTask: Task<Void, Never>?
    private var playLineTask: Task<Void, Never>?
    private var userMoveTask: Task<Void, Never>?
    /// The ROOT expansion, started by `analyzeMoveTree`.
    private var treeExpansionTask: Task<Void, Never>?
    /// The SELECTION expansion, started by `selectTreeNode`, and the owner id it writes flags
    /// under. Separate from the root's handle: selecting another node cancels only this one.
    private var treeSelectionExpansionTask: Task<Void, Never>?
    private var treeSelectionExpansionOwner: UUID?
    /// Bumped by every cancel. A result is applied only for the generation that started it —
    /// and only for the FEN it was computed for.
    private var analysisGeneration = 0
    private var engineMoveGeneration = 0
    /// True only while the bot's SEARCH runs, never during its landing: that is the window in
    /// which a user move is refused (Play Bot mode only).
    private var isBotSearching = false
    /// Which expansion set `isTreeAnalyzing`. Only that expansion may clear it.
    private var treeFlagOwner: UUID?
    /// Bumped by every write that REPLACES the board (reset, rotate, edit, undo, redo, detection,
    /// a tree selection) — never by a move (`applyUserMove` and `engineMove` invalidate with
    /// `replacingBoard: false`). A move's tail compares it to tell "my flight was cut short" from
    /// "the board is no longer mine".
    private var boardEpoch = 0

    init() {
        let bundle = AppBundle.main
        let engineURL = Self.findEngineURL(in: bundle)
        self.engine = StockfishEngine(engineURL: engineURL)
        self.treeEngine = PersistentStockfishEngine(engineURL: engineURL)
        if engineURL == nil {
            Self.reportMissingEngine(in: bundle)
        }
    }

    /// Injection seam for tests: the same view model over engines the test controls
    /// (`FakeUCIEngine` through the real engine classes). Production uses `init()`.
    init(engine: any EngineAnalyzing, treeEngine: any EngineAnalyzing) {
        self.engine = engine
        self.treeEngine = treeEngine
    }

    // MARK: - The display clock
    //
    // Reads render the display clock; writes snap first (`snapAnimation`) and then act on the
    // model. While a piece is in flight the model is already past the move, so the board, the
    // last-move highlight, the arrows, the score label, the score strip's perspective colour and
    // the side-to-move picker's getter all read these two instead of `boardState`/`lastMove`.

    /// The position the board renders: the in-flight move's pre-move frame, else the model.
    var displayBoardState: BoardState {
        animatingPiece?.displayState ?? boardState
    }

    /// The last-move highlight the board renders. Note this cannot be written as
    /// `animatingPiece?.displayLastMove ?? lastMove`: optional chaining flattens, so a frame
    /// whose highlight is legitimately nil (frame 0 of a replay, or the first move of a game)
    /// would fall through to the model's move and light up squares the user cannot see yet.
    var displayLastMove: ChessMove? {
        guard let animatingPiece else { return lastMove }
        return animatingPiece.displayLastMove
    }

    func loadImage(from url: URL) {
        guard let nsImage = NSImage(contentsOf: url) else {
            statusMessage = String(localized: "Unable to load image.")
            return
        }
        loadImage(nsImage: nsImage, label: url.lastPathComponent)
    }

    func loadImage(nsImage: NSImage, label: String? = nil) {
        guard let cgImage = nsImage.cgImage else {
            statusMessage = String(localized: "Unable to load image.")
            return
        }
        let resolvedLabel = label ?? nextDroppedLabel()
        addRecent(image: nsImage, label: resolvedLabel)
        detect(cgImage: cgImage)
    }

    func loadRecent(_ recent: RecentImage) {
        addRecent(image: recent.image, label: recent.label)
        guard let cgImage = recent.image.cgImage else {
            statusMessage = String(localized: "Unable to load image.")
            return
        }
        detect(cgImage: cgImage)
    }

    func openImageFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = String(localized: "Choose a chessboard image")
        if panel.runModal() == .OK, let url = panel.url {
            loadImage(from: url)
        }
    }

    func detect(cgImage: CGImage) {
        invalidateAnalysis()
        let token = UUID()
        detectionToken = token
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil
        detectionStatus = .running
        statusMessage = String(localized: "Detecting board...")
        // Assigned AFTER `invalidateAnalysis()` above, which cancels the PREVIOUS detection.
        detectionTask = Task {
            let output = await pipeline.process(cgImage: cgImage)
            guard token == self.detectionToken else { return }
            var state = BoardState(fromDetection: output)
            if output.suggestedFlipForFEN {
                state = state.rotated180()
            }
            // The board is being replaced: end any flight first, so a move started during the
            // detection cannot land on the detected position.
            self.snapAnimation()
            self.boardEpoch += 1
            self.boardState = state
            // Orient the UI to match the screenshot (white at top when flip is suggested).
            self.orientationWhiteAtBottom = !output.suggestedFlipForFEN
            self.detectionStatus = .succeeded(output)
            self.logWarnings(output.warnings)
            self.engineLines = []
            self.selectedEngineLineID = nil
            self.treeNodes = []
            self.selectedTreeNodeID = nil
            self.lastMove = nil
            self.legalDestinations = []
            self.resetHistory()
            if let validationMessage = self.analysisValidationMessage(for: state) {
                self.statusMessage = validationMessage
            } else {
                self.statusMessage = String(localized: "Detected position.")
                _ = self.updateStatusForGameOver()
            }
        }
    }

    func analyze() {
        if isAnalyzing { return }
        snapAnimation()
        if let validationMessage = analysisValidationMessage(for: boardState) {
            statusMessage = validationMessage
            engineLines = []
            selectedEngineLineID = nil
            treeNodes = []
            selectedTreeNodeID = nil
            return
        }
        if let gameOver = gameOverMessage(for: boardState) {
            statusMessage = gameOver
            engineLines = []
            selectedEngineLineID = nil
            treeNodes = []
            selectedTreeNodeID = nil
            return
        }
        // AFTER the guards above, so a second click on a busy control still cancels nothing:
        // this search supersedes the previous analysis, the tree expansions and a replay, and
        // its status takes the bar from the bot (whose move would land on a board being read).
        cancelSupersededWork()
        cancelBotMove()
        interactionMode = .analyzeLines
        treeToken = UUID()
        isTreeAnalyzing = false
        treeNodes = []
        selectedTreeNodeID = nil
        treeSelectionSnapshot = nil
        treeExpandedPaths.removeAll()
        treeExpandingPaths.removeAll()
        treeRootState = nil
        let token = UUID()
        analysisToken = token
        let generation = analysisGeneration
        // Carried, not recomputed: the result is applied only to the position it was computed
        // for, so a board replaced without an invalidation cannot be labelled with these lines.
        let fen = boardState.fen
        isAnalyzing = true
        statusMessage = String(localized: "Analyzing...")
        let options = analysisOptions(multiPV: max(multiPV, 1))
        analysisTask = Task {
            // Releases the flag on EVERY exit, including the guards below — a mode change
            // during the search used to leave it stuck at true.
            defer {
                if generation == analysisGeneration { isAnalyzing = false }
            }
            do {
                let lines = try await engine.analyze(fen: fen, options: options, requireFullDepth: strictDepth)
                guard
                    generation == analysisGeneration,
                    !Task.isCancelled,
                    interactionMode == .analyzeLines,
                    boardState.fen == fen
                else { return }
                self.engineLines = lines
                self.statusMessage = lines.isEmpty
                    ? String(localized: "Engine returned no lines.")
                    : String(localized: "Analysis ready.")
            } catch {
                // A cancelled search can surface as CancellationError, .timeout or .engineGone:
                // test the task, not the error.
                if Task.isCancelled { return }
                guard generation == analysisGeneration, interactionMode == .analyzeLines else { return }
                self.engineLines = []
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func analyzeMoveTree() {
        if isTreeAnalyzing { return }
        snapAnimation()
        if let validationMessage = analysisValidationMessage(for: boardState) {
            statusMessage = validationMessage
            engineLines = []
            selectedEngineLineID = nil
            treeNodes = []
            selectedTreeNodeID = nil
            return
        }
        if let gameOver = gameOverMessage(for: boardState) {
            statusMessage = gameOver
            engineLines = []
            selectedEngineLineID = nil
            treeNodes = []
            selectedTreeNodeID = nil
            return
        }
        // AFTER the guards above: this analysis supersedes the previous one, both expansions
        // and a replay, and takes the board and the status bar from the bot.
        cancelSupersededWork()
        cancelBotMove()
        interactionMode = .analyzeMoveTree
        analysisToken = UUID()
        isAnalyzing = false
        engineLines = []
        selectedEngineLineID = nil
        selectedTreeNodeID = nil
        treeSelectionSnapshot = nil
        treeExpandedPaths.removeAll()
        treeExpandingPaths.removeAll()
        treeRootState = boardState
        statusMessage = String(localized: "Analyzing move tree...")
        treeNodes = []
        let token = UUID()
        treeToken = token
        // The owner is set SYNCHRONOUSLY with the flag it owns, so "isTreeAnalyzing implies an
        // owner" already holds when the task body runs — including when the body's first guard
        // fails and its `defer` is the only thing that can release the flag.
        let owner = UUID()
        isTreeAnalyzing = true
        treeFlagOwner = owner

        let branchCount = max(1, treeBranchCount)
        let pliesToExpand = 1

        treeExpansionTask = Task { [token, owner] in
            await expandTreeChunk(
                from: treeRootState,
                basePath: [],
                basePlyIndex: -1,
                pliesToExpand: pliesToExpand,
                branchCount: branchCount,
                token: token,
                owner: owner
            )
        }
    }

    func selectTreeNode(_ id: TreeMoveNode.ID?) {
        // A selection replaces the board: end any flight first (this also bumps the animation
        // token, so a replay in flight stops at its next checkpoint).
        snapAnimation()
        if id == nil {
            selectedTreeNodeID = nil
            if let snapshot = treeSelectionSnapshot {
                boardEpoch += 1
                boardState = snapshot.state
                lastMove = snapshot.lastMove
                legalDestinations = []
            }
            treeSelectionSnapshot = nil
            return
        }

        guard let id else { return }
        guard let rootState = treeRootState else { return }
        guard let node = treeNodes.first(where: { $0.id == id }) else { return }

        let previousPath = selectedTreeNodeID.flatMap { currentID in
            treeNodes.first(where: { $0.id == currentID })?.choicePath
        }
        let newPath = node.choicePath

        if treeSelectionSnapshot == nil {
            treeSelectionSnapshot = currentSnapshot()
        }

        let map = treeNodeMap()
        let replay = MoveTreeLogic.frames(forPath: newPath, rootState: rootState, nodeMap: map)

        // Nothing along the path resolves yet: leave the board where it is and let the expansion
        // fill the tree in, as the old animator did when no move of the path parsed.
        if !newPath.isEmpty, replay.frames.isEmpty {
            selectedTreeNodeID = id
            startSelectionExpansion(for: id)
            return
        }

        // One step deeper from the selection the board is already showing: replay only that ply.
        let frames: [MoveTreeLogic.TreeFrame]
        if let previousPath,
           newPath.count == previousPath.count + 1,
           pathHasPrefix(newPath, previousPath),
           let lastFrame = replay.frames.last,
           boardState == lastFrame.stateBefore {
            frames = [lastFrame]
        } else {
            frames = replay.frames
        }

        // The model reaches the selected position in this synchronous step; the replay is the
        // visual tail, starting at frame 0.
        boardEpoch += 1
        boardState = replay.finalState
        lastMove = replay.finalLastMove
        legalDestinations = []
        selectedTreeNodeID = id
        animatingPiece = frames.first.map { AnimatedPiece(frame: $0, kind: .treeReplay) }

        // Unstored on purpose: the token is the ownership. Any snap bumps it and this task
        // returns at its next checkpoint without touching the board.
        let token = treeAnimationToken
        Task { await advanceTreeFrames(frames, token: token) }
        startSelectionExpansion(for: id)
    }

    /// Starts the expansion of a newly selected node, cancelling only its PREDECESSOR selection
    /// expansion — never the root's, and never the analysis or the bot (a tree selection does
    /// not go through `invalidateAnalysis`).
    ///
    /// Owner-keyed: a predecessor that returned at `expandTreeForSelection`'s `!isTreeAnalyzing`
    /// guard never set the flag, so `treeFlagOwner` is not its owner and the root expansion's
    /// flag is left alone.
    ///
    /// A predecessor that DID hold the flag hands it over: `treeFlagOwner` becomes the new
    /// expansion's owner and `isTreeAnalyzing` stays true across the switch. Clearing it here
    /// would blank the spinner (and re-enable the button) for the frame between this call and
    /// the successor's task body, which is a visible change; the successor releases it through
    /// `expandTreeForSelection`'s `defer` on every path that does not reach `expandTreeChunk`.
    private func startSelectionExpansion(for id: TreeMoveNode.ID) {
        let owner = UUID()
        if let previous = treeSelectionExpansionTask, let previousOwner = treeSelectionExpansionOwner {
            previous.cancel()
            if treeFlagOwner == previousOwner {
                treeFlagOwner = owner        // transferred, not cleared: `isTreeAnalyzing` stays true
            }
            treeExpandingPaths = treeExpandingPaths.filter { $0.value != previousOwner }
        }
        treeSelectionExpansionOwner = owner
        treeSelectionExpansionTask = Task { await expandTreeForSelection(id: id, owner: owner) }
    }

    func engineMove() {
        if isEngineThinking { return }
        // A control was used: end any flight before the validation reads below.
        snapAnimation()
        if let validationMessage = analysisValidationMessage(for: boardState) {
            statusMessage = validationMessage
            engineLines = []
            selectedEngineLineID = nil
            treeNodes = []
            selectedTreeNodeID = nil
            legalDestinations = []
            return
        }
        if let gameOver = gameOverMessage(for: boardState) {
            statusMessage = gameOver
            engineLines = []
            selectedEngineLineID = nil
            treeNodes = []
            selectedTreeNodeID = nil
            legalDestinations = []
            return
        }
        invalidateAnalysis(replacingBoard: false)
        interactionMode = .playAgainstComputer
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil
        engineMoveGeneration += 1
        let generation = engineMoveGeneration
        // Carried, not recomputed: a Reset DURING the search must not let this move land on the
        // cleared board, and the generation alone cannot see a board replaced without a cancel.
        let fen = boardState.fen
        isEngineThinking = true
        isBotSearching = true
        statusMessage = String(localized: "Engine thinking...")
        let options = EngineOptions(
            multiPV: max(randomnessStrength, multiPV, 1),
            movetimeMs: nil,
            depth: max(1, searchDepth),
            strength: strength,
            limitStrength: true,
            elo: elo(for: strength),
            hash: 64,
            threads: max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        )
        engineMoveTask = Task {
            // Same timing as before — the whole task, flight included — but only for the bot
            // this task IS: a superseded search must never clear the newer one's flag.
            defer {
                if generation == engineMoveGeneration {
                    isEngineThinking = false
                    isBotSearching = false
                }
            }
            do {
                let lines = try await engine.analyze(fen: fen, options: options, requireFullDepth: false)
                guard
                    generation == engineMoveGeneration,
                    !Task.isCancelled,
                    interactionMode == .playAgainstComputer,
                    boardState.fen == fen
                else { return }
                // The search is over: from here the bot is landing, and a user move is accepted.
                isBotSearching = false
                guard
                    let line = selector.pickLine(from: lines, strength: randomnessStrength),
                    let uci = line.moves.first,
                    let move = boardState.move(fromUCI: uci)
                else {
                    self.statusMessage = String(localized: "Engine returned no move.")
                    return
                }
                // A refusal ("Illegal move.") owns the status. The move is on the model from here;
                // only a board-replacing write (reset, undo, …) takes the status away from it — a
                // square click that merely cuts the flight short does not.
                guard let applied = self.applyMoveNow(move) else { return }
                let outcome = await self.finishAnimation(applied)
                guard outcome == .landed || outcome == .cutShort else { return }
                self.statusMessage = String.localizedStringWithFormat(
                    NSLocalizedString("Engine played %@.", comment: "Status after engine move"),
                    uci
                )
                _ = self.updateStatusForGameOver()
            } catch {
                if Task.isCancelled { return }
                guard generation == engineMoveGeneration else { return }
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func playSelectedLine() {
        snapAnimation()
        guard
            let selectedEngineLineID,
            let line = engineLines.first(where: { $0.id == selectedEngineLineID })
        else { return }

        // AFTER the "nothing selected" guard above: a replay supersedes the analysis, the tree
        // expansions and any previous replay (the re-entrancy guard this used to lack), and
        // takes the board and the status bar from the bot.
        cancelSupersededWork()
        cancelBotMove()
        interactionMode = .analyzeLines
        let movesToPlay = Array(line.moves.prefix(maxArrowsPerLine))
        // An `analyze()` started mid-replay is a benign snap (it leaves board and mode alone) but
        // it owns the lines from then on: the replay must not run on underneath its search.
        let analysisTokenAtStart = analysisToken
        playLineTask = Task {
            for uci in movesToPlay {
                guard !Task.isCancelled else { return }
                guard interactionMode == .analyzeLines, analysisToken == analysisTokenAtStart else { return }
                if let move = boardState.move(fromUCI: uci), let applied = applyMoveNow(move) {
                    // A replaced board belongs to whoever replaced it; a cancelled replay belongs
                    // to whoever cancelled it; a user move made inside the window belongs to that
                    // move's own tail. Either way stop replaying here.
                    let outcome = await finishAnimation(applied)
                    guard outcome == .landed || outcome == .cutShort else { return }
                    guard boardState.fen == applied.fenAfter else { return }
                    // An analysis started during this flight owns the lines: do not retire them.
                    guard analysisToken == analysisTokenAtStart else { return }
                }
                // Retire the lines after every PV move, refused or not (before this change an
                // unparseable UCI skipped the clear; that only ever happened on malformed engine
                // output).
                engineLines = []
            }
            guard !Task.isCancelled else { return }
            guard interactionMode == .analyzeLines, analysisToken == analysisTokenAtStart else { return }
            analyze()
        }
    }

    func applyUserMove(from: BoardSquare, to: BoardSquare) {
        let move = ChessMove(from: from, to: to)
        // The bot owns the board while it is SEARCHING, so a move made in that window is
        // DISCARDED: not applied, no undo snapshot, no status. Silent by design (plan
        // Decisions) — the user may move either colour here, so the move can perfectly well be
        // legal, and before this item such a move WAS applied, to a board the bot was about to
        // move on. The board deselects the piece as it does for any refused move. Scoped to
        // Play Bot: a search left running in another tab must not deaden the board there — its
        // result is dropped by the mode gate in `engineMove`'s task instead.
        guard !(isBotSearching && interactionMode == .playAgainstComputer) else { return }
        // Refuse before the snap: a click the position rejects must not end the flight.
        guard moveValidator.isLegal(move: move, in: boardState) else {
            statusMessage = String(localized: "Illegal move.")
            return
        }
        // Cancels superseded work (including the PREVIOUS move's tail) but never the bot's
        // landing tail: a move made while the reply flies still lets it report what it played.
        invalidateAnalysis(replacingBoard: false)
        guard let applied = applyMoveNow(move) else { return }
        // Captured after the invalidation: if either changes before the flight ends, an analysis
        // or a tree started inside the window and its results must not be wiped by this tail.
        let analysisTokenAtMove = analysisToken
        let treeTokenAtMove = treeToken
        userMoveTask = Task {
            let outcome = await finishAnimation(applied)
            // Cancelled: whoever cancelled owns the board and the status. No clears, no chain.
            if outcome == .cancelled { return }
            if analysisToken == analysisTokenAtMove {
                engineLines = []
                selectedEngineLineID = nil
            }
            if treeToken == treeTokenAtMove {
                treeNodes = []
                selectedTreeNodeID = nil
            }
            legalDestinations = []
            // Chain the reply only while the board still holds the position this move produced:
            // not after a reset/undo/… (`.replaced`), and not after a further move, whose own tail
            // chains its own reply. A flight merely cut short by a click still chains.
            if outcome == .landed || outcome == .cutShort,
               boardState.fen == applied.fenAfter,
               keepPlaying, interactionMode == .playAgainstComputer, !isEngineThinking {
                engineMove()
            }
        }
    }

    func updateLegalMoves(for square: BoardSquare?) {
        // `nil` is the deselect that follows every move — it must not end the flight.
        guard let square else {
            legalDestinations = []
            return
        }
        // Selecting a square is the first half of a move, so it snaps; the dots are then
        // generated from the position the user is looking at.
        snapAnimation()
        legalDestinations = moveGenerator.legalDestinations(from: square, in: displayBoardState)
    }

    func setSideToMove(_ color: PieceColor) {
        // Ahead of the guard: the picker shows the display clock, so the comparison has to be
        // against the position the user sees — which the snap makes the model.
        snapAnimation()
        guard boardState.sideToMove != color else { return }
        invalidateAnalysis()
        boardState.sideToMove = color
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil
        legalDestinations = []
    }

    func resetBoard() {
        invalidateAnalysis()
        boardState = BoardState()
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil
        lastMove = nil
        legalDestinations = []
        resetHistory()
        statusMessage = String(localized: "Board cleared.")
    }

    func rotatePosition() {
        invalidateAnalysis()
        boardState = boardState.rotated180()
        orientationWhiteAtBottom.toggle()
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil
        lastMove = nil
        legalDestinations = []
        resetHistory()
        statusMessage = String(localized: "Position rotated 180°.")
    }

    /// Seeds the piece editor. Snaps first so the code it returns and the `setPiece` that
    /// follows describe the same square of the same position.
    func beginEditing(at square: BoardSquare) -> String {
        snapAnimation()
        guard let piece = boardState.piece(at: square) else { return "" }
        return Self.pieceCode(for: piece)
    }

    @discardableResult
    func setPiece(at square: BoardSquare, code rawCode: String) -> String? {
        // A write: end any flight first (a tree replay's frames especially), so the board the user
        // sees while this edit lands is the model it edits. The comparison below reads the model.
        snapAnimation()
        let normalizedCode = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let replacement: Piece?
        if normalizedCode.isEmpty || normalizedCode == "--" || normalizedCode == "empty" {
            replacement = nil
        } else if let parsedPiece = Self.piece(forCode: normalizedCode) {
            replacement = parsedPiece
        } else {
            let errorMessage = String.localizedStringWithFormat(
                NSLocalizedString(
                    "Unknown piece code \"%@\". Use codes like wk, bn, or empty.",
                    comment: "Validation error for invalid piece code input"
                ),
                rawCode
            )
            statusMessage = errorMessage
            return errorMessage
        }

        let currentPiece = boardState.board[square.file, square.rank]
        guard currentPiece != replacement else {
            statusMessage = String.localizedStringWithFormat(
                NSLocalizedString("No piece change on %@.", comment: "Status when edited square keeps same piece"),
                square.label
            )
            return nil
        }

        pushSnapshot()
        invalidateAnalysis()

        var nextState = boardState
        nextState.board[square.file, square.rank] = replacement
        // A manual edit can move/remove a king or rook, or invalidate a stored en-passant target;
        // reconcile the metadata so the stored state stays consistent (not just the emitted FEN).
        nextState.castling = BoardState.sanitizedCastling(nextState.castling, board: nextState.board)
        nextState.enPassant = BoardState.sanitizedEnPassant(nextState.enPassant, board: nextState.board, activeColor: nextState.activeColor)
        boardState = nextState

        lastMove = nil
        legalDestinations = []
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil

        if let validationMessage = analysisValidationMessage(for: nextState) {
            statusMessage = validationMessage
        } else if let gameOverMessage = gameOverMessage(for: nextState) {
            statusMessage = gameOverMessage
        } else if let replacement {
            statusMessage = String.localizedStringWithFormat(
                NSLocalizedString("Set %@ to %@.", comment: "Status after setting a piece on a square"),
                square.label,
                Self.pieceCode(for: replacement)
            )
        } else {
            statusMessage = String.localizedStringWithFormat(
                NSLocalizedString("Cleared %@.", comment: "Status after clearing a square"),
                square.label
            )
        }

        return nil
    }

    /// Ends any animation NOW so the display equals the model. A move animation's landing side
    /// effect (the game-over status) still happens, so a mating move that gets snapped is still
    /// reported as mate. Every write that reads the board or replaces board/tree state calls this
    /// first, which is what keeps the length of the animation window from being load-bearing.
    private func snapAnimation() {
        treeAnimationToken = UUID()
        guard let current = animatingPiece else { return }
        animatingPiece = nil
        if current.kind == .move { _ = updateStatusForGameOver() }
    }

    /// What `applyMoveNow` hands its caller: enough to tell, after the flight, whether the move is
    /// still what the board holds.
    private struct AppliedMove {
        let animationID: UUID
        /// The position the move produced.
        let fenAfter: String
        /// `boardEpoch` at the apply: a later replacement of the board bumps it.
        let epoch: Int
    }

    /// How a move's flight ended. A snap is NOT "the move never happened" — the move is on the
    /// model from `applyMoveNow` on; only `.replaced` means somebody else owns the board now.
    private enum FlightOutcome {
        /// The animation ran to its end.
        case landed
        /// A benign write (a square click, an edit, the picker) ended the flight early; the move
        /// is still on the board.
        case cutShort
        /// A board-replacing write (reset, rotate, edit, undo, redo, detection, a tree selection)
        /// happened since the apply; whoever did it owns the board and the status.
        case replaced
        /// This tail's own task was cancelled: whoever cancelled it owns the board and the
        /// status, so the tail returns without writing anything at all.
        case cancelled
    }

    /// Applies an accepted move to the model NOW and starts its animation. Returns nil when the
    /// move was refused, in which case `statusMessage` is "Illegal move.".
    // Already @MainActor-isolated, so the caller's tail runs on the same actor — no MainActor.run hops.
    @discardableResult
    private func applyMoveNow(_ move: ChessMove) -> AppliedMove? {
        guard moveValidator.isLegal(move: move, in: boardState),
              let piece = boardState.piece(at: move.from) else {
            statusMessage = String(localized: "Illegal move.")
            return nil
        }
        // Carried, not recomputed: this exact position is what the board renders while the piece
        // is in flight.
        let frame = boardState
        let frameLastMove = lastMove
        pushSnapshot()                       // pre-move model; updates canUndo/canRedo
        boardState.apply(move: move)
        lastMove = move
        let id = UUID()
        animatingPiece = AnimatedPiece(
            id: id,
            kind: .move,
            piece: piece,
            from: move.from,
            to: move.to,
            displayState: frame,
            displayLastMove: frameLastMove
        )
        return AppliedMove(animationID: id, fenAfter: boardState.fen, epoch: boardEpoch)
    }

    /// Waits out the animation started by `applyMoveNow` and reports how it ended.
    ///
    /// Cancellation is checked FIRST: `Task.sleep` returns immediately when the task is
    /// cancelled, and a cancelled tail must write nothing — not the game-over status, not a
    /// chained reply.
    private func finishAnimation(_ applied: AppliedMove) async -> FlightOutcome {
        try? await Task.sleep(nanoseconds: UInt64(MoveAnimation.duration * 1_000_000_000))
        if Task.isCancelled {
            // Every canceller snaps before it cancels; should one ever not, the board must not
            // stay frozen on this move's pre-move frame.
            if animatingPiece?.id == applied.animationID { animatingPiece = nil }
            return .cancelled
        }
        if boardEpoch != applied.epoch { return .replaced }
        guard animatingPiece?.id == applied.animationID else { return .cutShort }
        animatingPiece = nil
        _ = updateStatusForGameOver()        // same moment as before: the landing
        return .landed
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        invalidateAnalysis()
        redoStack.append(currentSnapshot())
        boardState = snapshot.state
        lastMove = snapshot.lastMove
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil
        legalDestinations = []
        animatingPiece = nil
        statusMessage = String(localized: "Undid move.")
        updateUndoRedoState()
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        invalidateAnalysis()
        undoStack.append(currentSnapshot())
        boardState = snapshot.state
        lastMove = snapshot.lastMove
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil
        legalDestinations = []
        animatingPiece = nil
        statusMessage = String(localized: "Redid move.")
        updateUndoRedoState()
    }

    private func elo(for strength: Int) -> Int {
        // Simple mapping for limited strength play; can be tuned later.
        switch strength {
        case 1: return 800
        case 2: return 1100
        case 3: return 1400
        case 4: return 1700
        default: return 2000
        }
    }

    private func addRecent(image: NSImage, label: String) {
        recents.removeAll { $0.label == label }
        recents.insert(RecentImage(image: image, label: label), at: 0)
        while recents.count > maxRecents {
            recents.removeLast()
        }
    }

    private func nextDroppedLabel() -> String {
        droppedImageCounter += 1
        return String.localizedStringWithFormat(
            NSLocalizedString("Dropped %d", comment: "Label for dropped images"),
            droppedImageCounter
        )
    }

    private func currentSnapshot() -> BoardSnapshot {
        BoardSnapshot(state: boardState, lastMove: lastMove)
    }

    private func pushSnapshot() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
        updateUndoRedoState()
    }

    private func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoRedoState()
    }

    private func updateUndoRedoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Cancels the work a new gesture supersedes: the analysis, the tree expansions (root and
    /// selection), a replay, and the previous move's tail. Never the bot's task (that is
    /// `cancelBotMove`) and never detection (that is `invalidateAnalysis`).
    ///
    /// Invariant: a cancelled task never writes a busy flag or a status — every engine-call
    /// catch tests `Task.isCancelled` first (a cancelled persistent-engine search can surface
    /// as `.timeout`/`.engineGone`), and the tree flag is owner-keyed.
    ///
    /// Precondition: callers snap the flight first (`snapAnimation()`), so a cancelled move
    /// tail has nothing left to clean up. `finishAnimation` covers the caller that does not.
    ///
    /// Note: the stored handles are cleared only by the cancel operations, never on normal
    /// completion — a non-nil handle means "started and not cancelled since", NOT "running".
    private func cancelSupersededWork() {
        for task in [analysisTask, treeExpansionTask, treeSelectionExpansionTask, playLineTask, userMoveTask] {
            task?.cancel()
        }
        analysisTask = nil
        treeExpansionTask = nil
        treeSelectionExpansionTask = nil
        treeSelectionExpansionOwner = nil
        playLineTask = nil
        userMoveTask = nil
        analysisGeneration += 1
        analysisToken = UUID()
        treeToken = UUID()
        isAnalyzing = false
        isTreeAnalyzing = false
        treeFlagOwner = nil
        treeExpandingPaths.removeAll()
    }

    /// Cancels the bot's task, in its search phase or its landing tail. Only board-replacing
    /// writes and the search-starting entry points call this — never a human move, which must
    /// leave the bot's landing tail alone so it still reports the move it played.
    private func cancelBotMove() {
        let hadBotTask = engineMoveTask != nil
        engineMoveTask?.cancel()
        engineMoveTask = nil
        engineMoveGeneration += 1
        isEngineThinking = false
        isBotSearching = false
        // "Engine thinking..." belongs to the task just cancelled: with the spinner gone it would
        // sit in the bar forever (the side-to-move picker cancels the bot and writes no status of
        // its own). nil renders "Ready.". Only the callers that write NOTHING see this —
        // `setSideToMove` and `playSelectedLine`; reset, rotate, undo, redo, setPiece, detect,
        // analyze and analyzeMoveTree all write their own status right after this returns and
        // overwrite it.
        if hadBotTask, statusMessage == String(localized: "Engine thinking...") {
            statusMessage = nil
        }
    }

    /// - Parameter replacingBoard: false for the two callers that are about to MOVE rather than
    ///   replace the board (`applyUserMove`, `engineMove`); a move must not read as a
    ///   replacement to a flight it cuts short, and must not cancel the bot's landing tail.
    private func invalidateAnalysis(replacingBoard: Bool = true) {
        // FIRST, so `cancelSupersededWork`'s documented precondition actually holds: the flight
        // is already over when the tails it cancels are cancelled, and there is nothing left for
        // them to clean up. Also bumps `treeAnimationToken`, so a replay in flight stops at its
        // next checkpoint.
        snapAnimation()
        cancelSupersededWork()
        if replacingBoard { cancelBotMove() }
        detectionToken = UUID()
        // Bumping detectionToken already abandons an in-flight detection (its completion guard
        // fails); cancelling the task stops it from running on past the board it was for.
        detectionTask?.cancel()
        detectionTask = nil
        // Every caller of this replaces (or is about to replace) the board — except a move.
        if replacingBoard { boardEpoch += 1 }
        // Don't leave the status stuck on "Detecting…"; a new detect() re-sets it to .running.
        if case .running = detectionStatus { detectionStatus = .idle }
        treeExpandedPaths.removeAll()
        treeRootState = nil
        treeSelectionSnapshot = nil
    }

    var gameOverScoreText: String? {
        gameOverMessage(for: displayBoardState)
    }

    private func gameOverMessage(for state: BoardState) -> String? {
        guard !moveGenerator.hasAnyLegalMove(in: state) else { return nil }
        if moveValidator.isInCheck(state: state) {
            return state.activeColor == "w"
                ? String(localized: "White is check mate")
                : String(localized: "Black is check mate")
        } else {
            return String(localized: "Draw through Stalemate")
        }
    }

    @discardableResult
    private func updateStatusForGameOver() -> Bool {
        if let message = gameOverMessage(for: boardState) {
            statusMessage = message
            return true
        }
        return false
    }

    private func analysisValidationMessage(for state: BoardState) -> String? {
        let whiteKingCount = pieceCount(.whiteKing, in: state.board)
        let blackKingCount = pieceCount(.blackKing, in: state.board)
        guard whiteKingCount == 1, blackKingCount == 1 else {
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Invalid board for analysis: expected 1 white king and 1 black king, found %d and %d. Please correct the detected pieces and try again.",
                    comment: "Validation message when detected board has wrong king counts"
                ),
                whiteKingCount,
                blackKingCount
            )
        }
        return nil
    }

    private func pieceCount(_ target: Piece, in board: Board) -> Int {
        var count = 0
        for rank in 0..<8 {
            for file in 0..<8 where board[file, rank] == target {
                count += 1
            }
        }
        return count
    }

    private func analysisOptions(multiPV: Int, hash: Int = 128) -> EngineOptions {
        // Analysis runs at full engine strength; `strength`/`elo` are left at their defaults
        // because `limitStrength: false` makes them inert here (only Play Bot limits strength).
        EngineOptions(
            multiPV: max(multiPV, 1),
            movetimeMs: nil,
            depth: max(1, searchDepth),
            limitStrength: false,
            hash: hash,
            threads: max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        )
    }

    /// - Parameter owner: the id every flag this expansion writes is keyed by, so a cancelled
    ///   expansion can never clear the flag or the claim of the one that superseded it.
    private func expandTreeForSelection(id: TreeMoveNode.ID, owner: UUID) async {
        // A flag INHERITED from the predecessor this expansion cancelled (see
        // `startSelectionExpansion`) must be released on every early return below. Once
        // `expandTreeChunk` has run, its own owner-keyed `defer` has already released it and
        // this is a no-op.
        defer {
            if treeFlagOwner == owner {
                isTreeAnalyzing = false
                treeFlagOwner = nil
            }
        }
        guard interactionMode == .analyzeMoveTree else { return }
        // A ROOT expansion still blocks a selection (its owner is not this one); the successor
        // that inherited the flag from the selection it replaced proceeds.
        guard !isTreeAnalyzing || treeFlagOwner == owner else { return }
        guard let rootState = treeRootState else { return }
        guard let selectedNode = treeNodes.first(where: { $0.id == id }) else { return }
        let baseNode = selectedNode
        let nodeMap = treeNodeMap()
        let baseKey = pathKey(baseNode.choicePath)
        guard !treeExpandedPaths.contains(baseKey), treeExpandingPaths[baseKey] == nil else { return }

        let pliesToExpand = 1
        guard let baseStateResult = treeState(for: baseNode.choicePath, rootState: rootState, nodeMap: nodeMap) else { return }
        let baseState = baseStateResult.state

        treeExpandingPaths[baseKey] = owner
        await expandTreeChunk(
            from: baseState,
            basePath: baseNode.choicePath,
            basePlyIndex: baseNode.plyIndex,
            pliesToExpand: pliesToExpand,
            branchCount: max(1, treeBranchCount),
            token: treeToken,
            owner: owner
        )
    }

    /// - Parameter owner: the id this expansion writes `isTreeAnalyzing` and its expanding-path
    ///   claim under. Every flag write and every release is keyed by it, so a cancelled
    ///   expansion cannot clear the flag of the expansion that replaced it.
    private func expandTreeChunk(
        from state: BoardState?,
        basePath: [Int],
        basePlyIndex: Int,
        pliesToExpand: Int,
        branchCount: Int,
        token: UUID,
        owner: UUID
    ) async {
        let baseKey = pathKey(basePath)
        // The one release path for both flags, taken on every exit — a mode change or a token
        // bump mid-search used to leave `isTreeAnalyzing` stuck at true.
        defer {
            if treeExpandingPaths[baseKey] == owner { treeExpandingPaths[baseKey] = nil }
            if treeFlagOwner == owner {
                isTreeAnalyzing = false
                treeFlagOwner = nil
            }
        }
        guard token == treeToken, !Task.isCancelled, interactionMode == .analyzeMoveTree else { return }
        guard let state, pliesToExpand > 0 else {
            treeExpandedPaths.insert(baseKey)
            if treeFlagOwner == owner {
                isTreeAnalyzing = false
                treeFlagOwner = nil
            }
            statusMessage = String(localized: "Tree analysis ready.")
            return
        }

        isTreeAnalyzing = true
        treeFlagOwner = owner
        treeExpandingPaths[baseKey] = owner
        statusMessage = basePath.isEmpty
            ? String(localized: "Analyzing move tree...")
            : String(localized: "Expanding branch...")

        do {
            let maxAttempts = 3
            var attempt = 0
            var lines: [EngineLine] = []
            var uniqueFirstMoves = 0

            while attempt < maxAttempts {
                // Between attempts too: a retry must not re-ask the engine for a tree nobody
                // is waiting for any more.
                guard token == treeToken, !Task.isCancelled else { return }
                let requestedPV = max(branchCount * (attempt + 2), branchCount + 1)
                let options = analysisOptions(multiPV: requestedPV)
                lines = try await treeEngine.analyze(
                    fen: state.fen,
                    options: options,
                    requireFullDepth: strictDepth
                )
                uniqueFirstMoves = countUniqueFirstMoves(in: lines)
                if uniqueFirstMoves >= branchCount { break }
                attempt += 1
            }

            guard token == treeToken, !Task.isCancelled, interactionMode == .analyzeMoveTree else { return }
            let newNodes = buildTreeChunkNodes(
                lines: lines,
                basePath: basePath,
                basePlyIndex: basePlyIndex,
                pliesToExpand: pliesToExpand,
                branchCount: branchCount,
                scorePerspective: state.sideToMove
            )
            mergeTreeNodes(newNodes)
            treeExpandedPaths.insert(baseKey)
            if newNodes.isEmpty {
                statusMessage = String(localized: "Engine returned no lines.")
            } else if uniqueFirstMoves < branchCount {
                statusMessage = String.localizedStringWithFormat(
                    NSLocalizedString("Only %d unique moves found.", comment: "Tree analysis returned fewer unique moves than requested"),
                    uniqueFirstMoves
                )
            } else {
                statusMessage = String(localized: "Tree analysis ready.")
            }
        } catch {
            // A cancelled search can surface as CancellationError, .timeout or .engineGone:
            // test the task, not the error — and write no status for it.
            if Task.isCancelled { return }
            guard token == treeToken, interactionMode == .analyzeMoveTree else { return }
            statusMessage = error.localizedDescription
        }
        // The flag is released by the `defer` above, owner-keyed, on this path too.
    }

    private func buildTreeChunkNodes(
        lines: [EngineLine],
        basePath: [Int],
        basePlyIndex: Int,
        pliesToExpand: Int,
        branchCount: Int,
        scorePerspective: PieceColor
    ) -> [TreeMoveNode] {
        guard pliesToExpand > 0 else { return [] }
        return MoveTreeLogic.buildChunkNodes(
            lines: lines,
            basePath: basePath,
            basePlyIndex: basePlyIndex,
            branchCount: branchCount,
            scorePerspective: scorePerspective,
            existing: treeNodeMap()
        )
    }

    private func mergeTreeNodes(_ newNodes: [TreeMoveNode]) {
        guard !newNodes.isEmpty else { return }
        var map = treeNodeMap()
        for node in newNodes {
            let key = pathKey(node.choicePath)
            if map[key] == nil {
                map[key] = node
            }
        }
        treeNodes = map.values.sorted { compareChoicePath($0.choicePath, $1.choicePath) }
    }

    private func treeNodeMap() -> [String: TreeMoveNode] {
        MoveTreeLogic.nodeMap(from: treeNodes)
    }

    private func treeState(
        for path: [Int],
        rootState: BoardState,
        nodeMap: [String: TreeMoveNode]
    ) -> (state: BoardState, lastMove: ChessMove?)? {
        MoveTreeLogic.state(forPath: path, rootState: rootState, nodeMap: nodeMap)
    }

    /// The visual tail of a tree selection: the model is already at the selected position, so this
    /// only walks the display frames. `token` is the ownership — a snap bumps it and the loop
    /// returns before touching `animatingPiece`.
    private func advanceTreeFrames(_ frames: [MoveTreeLogic.TreeFrame], token: UUID) async {
        for index in frames.indices {
            try? await Task.sleep(nanoseconds: UInt64(MoveAnimation.duration * 1_000_000_000))
            guard token == treeAnimationToken else { return }
            animatingPiece = index + 1 < frames.count
                ? AnimatedPiece(frame: frames[index + 1], kind: .treeReplay)
                : nil
        }
    }

    private func logWarnings(_ warnings: [DetectionWarning]) {
        guard !warnings.isEmpty else { return }
        for warning in warnings {
            log.warning("Detection warning: \(warning.message, privacy: .public)")
        }
    }

    static func findEngineURL(in bundle: Bundle) -> URL? {
        let candidates = ["stockfish-macos-m1-apple-silicon", "stockfish"]
        let fm = FileManager.default

        // Prefer executables embedded in Contents/MacOS (Copy Files: Executables).
        if let exeDir = bundle.executableURL?.deletingLastPathComponent() {
            for name in candidates {
                let candidate = exeDir.appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        // Fallbacks for older layouts (Resources or nested folders).
        for name in candidates {
            if let url = bundle.url(forResource: name, withExtension: nil) {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Engine/arm64") {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Engine/arm64/stockfish") {
                return url
            }
        }

        guard let resourceURL = bundle.resourceURL else { return nil }
        guard let enumerator = fm.enumerator(at: resourceURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            guard candidates.contains(fileURL.lastPathComponent) else { continue }
            if fm.isExecutableFile(atPath: fileURL.path) {
                return fileURL
            }
        }
        return nil
    }

    private static func piece(forCode code: String) -> Piece? {
        switch code {
        case "wk": return .whiteKing
        case "wq": return .whiteQueen
        case "wr": return .whiteRook
        case "wb": return .whiteBishop
        case "wn": return .whiteKnight
        case "wp": return .whitePawn
        case "bk": return .blackKing
        case "bq": return .blackQueen
        case "br": return .blackRook
        case "bb": return .blackBishop
        case "bn": return .blackKnight
        case "bp": return .blackPawn
        default: return nil
        }
    }

    private static func pieceCode(for piece: Piece) -> String {
        switch piece {
        case .whiteKing: return "wk"
        case .whiteQueen: return "wq"
        case .whiteRook: return "wr"
        case .whiteBishop: return "wb"
        case .whiteKnight: return "wn"
        case .whitePawn: return "wp"
        case .blackKing: return "bk"
        case .blackQueen: return "bq"
        case .blackRook: return "br"
        case .blackBishop: return "bb"
        case .blackKnight: return "bn"
        case .blackPawn: return "bp"
        }
    }

    // for tests: install a tree without running the engine.
    // - Parameter markExpanded: with the default, every node's path is marked expanded, so
    //   selecting a node never reaches `treeEngine.analyze`. Pass `false` to test the selection
    //   expansion itself.
    func seedTreeForTesting(rootState: BoardState, nodes: [TreeMoveNode], markExpanded: Bool = true) {
        interactionMode = .analyzeMoveTree
        treeRootState = rootState
        treeNodes = nodes
        selectedTreeNodeID = nil
        treeSelectionSnapshot = nil
        treeExpandingPaths.removeAll()
        treeExpandedPaths = markExpanded ? Set(nodes.map { pathKey($0.choicePath) }) : []
    }

    // for tests
    var treeRootStateForTesting: BoardState? { treeRootState }

    private static func reportMissingEngine(in bundle: Bundle) {
        let exeDir = bundle.executableURL?.deletingLastPathComponent().path ?? "n/a"
        log.error("Stockfish engine not found. Checked executable dir: \(exeDir, privacy: .public)")
    }

    private struct BoardSnapshot {
        let state: BoardState
        let lastMove: ChessMove?
    }
}

// Thin forwarders to the pure logic in `MoveTreeLogic`, kept so the call sites above read cleanly.
private func compareChoicePath(_ lhs: [Int], _ rhs: [Int]) -> Bool { MoveTreeLogic.compareChoicePath(lhs, rhs) }
private func pathHasPrefix(_ path: [Int], _ prefix: [Int]) -> Bool { MoveTreeLogic.pathHasPrefix(path, prefix) }
private func pathKey(_ path: [Int]) -> String { MoveTreeLogic.pathKey(path) }
private func countUniqueFirstMoves(in lines: [EngineLine]) -> Int { MoveTreeLogic.countUniqueFirstMoves(in: lines) }

/// A piece in flight, carrying the frame the board renders while it flies: the position the
/// move was made from and the highlight that belonged to it. The model is already past this
/// frame (`applyMoveNow` applies before it animates), so the display clock lives here.
struct AnimatedPiece: Identifiable {
    /// A move animation's landing has one side effect (the game-over status); a tree replay's
    /// has none. `snapAnimation` needs to tell them apart.
    enum Kind {
        case move
        case treeReplay
    }

    let id: UUID
    let kind: Kind
    let piece: Piece
    let from: BoardSquare
    let to: BoardSquare
    /// The position BEFORE this move.
    let displayState: BoardState
    /// The last-move highlight to show while this move is in flight.
    let displayLastMove: ChessMove?
}

extension AnimatedPiece {
    /// The in-flight piece for one ply of a tree replay.
    init(frame: MoveTreeLogic.TreeFrame, kind: Kind) {
        self.init(
            id: UUID(),
            kind: kind,
            piece: frame.piece,
            from: frame.move.from,
            to: frame.move.to,
            displayState: frame.stateBefore,
            displayLastMove: frame.lastMoveBefore
        )
    }
}
