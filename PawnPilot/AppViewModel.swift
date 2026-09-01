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
    private let engine: StockfishEngine
    private let treeEngine: PersistentStockfishEngine
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
    private var treeExpandingPaths: Set<String> = []
    private var treeExpansionTask: Task<Void, Never>?
    private var treeSelectionSnapshot: BoardSnapshot?

    init() {
        let bundle = AppBundle.main
        let engineURL = Self.findEngineURL(in: bundle)
        self.engine = StockfishEngine(engineURL: engineURL)
        self.treeEngine = PersistentStockfishEngine(engineURL: engineURL)
        if engineURL == nil {
            Self.reportMissingEngine(in: bundle)
        }
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
        Task {
            let output = await pipeline.process(cgImage: cgImage)
            guard token == self.detectionToken else { return }
            var state = BoardState(fromDetection: output)
            if output.suggestedFlipForFEN {
                state = state.rotated180()
            }
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
        interactionMode = .analyzeLines
        treeToken = UUID()
        isTreeAnalyzing = false
        treeNodes = []
        selectedTreeNodeID = nil
        treeSelectionSnapshot = nil
        treeExpansionTask?.cancel()
        treeExpansionTask = nil
        treeExpandedPaths.removeAll()
        treeExpandingPaths.removeAll()
        treeRootState = nil
        let token = UUID()
        analysisToken = token
        isAnalyzing = true
        statusMessage = String(localized: "Analyzing...")
        let options = analysisOptions(multiPV: max(multiPV, 1))
        Task {
            do {
                let lines = try await engine.analyze(fen: boardState.fen, options: options, requireFullDepth: strictDepth)
                guard token == analysisToken, interactionMode == .analyzeLines else { return }
                self.engineLines = lines
                self.statusMessage = lines.isEmpty
                    ? String(localized: "Engine returned no lines.")
                    : String(localized: "Analysis ready.")
            } catch {
                guard token == analysisToken, interactionMode == .analyzeLines else { return }
                self.engineLines = []
                self.statusMessage = error.localizedDescription
            }
            if token == analysisToken, interactionMode == .analyzeLines {
                self.isAnalyzing = false
            }
        }
    }

    func analyzeMoveTree() {
        if isTreeAnalyzing { return }
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
        interactionMode = .analyzeMoveTree
        analysisToken = UUID()
        isAnalyzing = false
        engineLines = []
        selectedEngineLineID = nil
        selectedTreeNodeID = nil
        treeSelectionSnapshot = nil
        treeExpandedPaths.removeAll()
        treeExpandingPaths.removeAll()
        treeExpansionTask?.cancel()
        treeRootState = boardState
        statusMessage = String(localized: "Analyzing move tree...")
        treeNodes = []
        let token = UUID()
        treeToken = token
        isTreeAnalyzing = true

        let branchCount = max(1, treeBranchCount)
        let pliesToExpand = 1

        treeExpansionTask = Task { [token] in
            await expandTreeChunk(
                from: treeRootState,
                basePath: [],
                basePlyIndex: -1,
                pliesToExpand: pliesToExpand,
                branchCount: branchCount,
                token: token
            )
        }
    }

    func selectTreeNode(_ id: TreeMoveNode.ID?) {
        if id == nil {
            treeAnimationToken = UUID()
            selectedTreeNodeID = nil
            if let snapshot = treeSelectionSnapshot {
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
        let shouldAnimateIncrementally: Bool
        if let previousPath {
            shouldAnimateIncrementally = newPath.count == previousPath.count + 1 && pathHasPrefix(newPath, previousPath)
        } else {
            shouldAnimateIncrementally = false
        }

        if treeSelectionSnapshot == nil {
            treeSelectionSnapshot = currentSnapshot()
        }

        let map = treeNodeMap()
        let animationToken = UUID()
        treeAnimationToken = animationToken
        Task {
            if shouldAnimateIncrementally, let previousPath {
                let succeeded = await animateTreeSelectionIncremental(
                    previousPath: previousPath,
                    newPath: newPath,
                    nodeMap: map,
                    token: animationToken
                )
                if succeeded { return }
            }
            await animateTreeSelection(path: newPath, rootState: rootState, nodeMap: map, token: animationToken)
        }
        selectedTreeNodeID = id
        Task { await expandTreeForSelection(id: id) }
    }

    func engineMove() {
        if isEngineThinking { return }
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
        invalidateAnalysis()
        interactionMode = .playAgainstComputer
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil
        isEngineThinking = true
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
        Task {
            defer { self.isEngineThinking = false }
            do {
                let lines = try await engine.analyze(fen: boardState.fen, options: options, requireFullDepth: false)
                guard
                    let line = selector.pickLine(from: lines, strength: randomnessStrength),
                    let uci = line.moves.first,
                    let move = boardState.move(fromUCI: uci)
                else {
                    self.statusMessage = String(localized: "Engine returned no move.")
                    return
                }
                await self.performAnimatedMove(move: move)
                self.statusMessage = String.localizedStringWithFormat(
                    NSLocalizedString("Engine played %@.", comment: "Status after engine move"),
                    uci
                )
                _ = self.updateStatusForGameOver()
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func playSelectedLine() {
        guard
            let selectedEngineLineID,
            let line = engineLines.first(where: { $0.id == selectedEngineLineID })
        else { return }

        interactionMode = .analyzeLines
        let movesToPlay = Array(line.moves.prefix(maxArrowsPerLine))
        Task {
            for uci in movesToPlay {
                guard interactionMode == .analyzeLines else { return }
                guard let move = boardState.move(fromUCI: uci) else { continue }
                await performAnimatedMove(move: move)
                engineLines = []
            }
            guard interactionMode == .analyzeLines else { return }
            analyze()
        }
    }

    func applyUserMove(from: BoardSquare, to: BoardSquare) {
        let move = ChessMove(from: from, to: to)
        guard moveValidator.isLegal(move: move, in: boardState) else {
            statusMessage = String(localized: "Illegal move.")
            return
        }
        invalidateAnalysis()
        Task {
            await performAnimatedMove(move: move)
            engineLines = []
            selectedEngineLineID = nil
            treeNodes = []
            selectedTreeNodeID = nil
            legalDestinations = []
            if keepPlaying, interactionMode == .playAgainstComputer, !isEngineThinking {
                engineMove()
            }
        }
    }

    func updateLegalMoves(for square: BoardSquare?) {
        guard let square else {
            legalDestinations = []
            return
        }
        legalDestinations = moveGenerator.legalDestinations(from: square, in: boardState)
    }

    func setSideToMove(_ color: PieceColor) {
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

    func pieceCode(at square: BoardSquare) -> String {
        guard let piece = boardState.piece(at: square) else { return "" }
        return Self.pieceCode(for: piece)
    }

    @discardableResult
    func setPiece(at square: BoardSquare, code rawCode: String) -> String? {
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

    // Already @MainActor-isolated, so direct mutation across the await is safe — no MainActor.run hops.
    private func performAnimatedMove(move: ChessMove) async {
        guard moveValidator.isLegal(move: move, in: boardState) else {
            statusMessage = String(localized: "Illegal move.")
            return
        }
        guard let piece = boardState.piece(at: move.from) else { return }
        pushSnapshot()
        animatingPiece = AnimatedPiece(id: UUID(), piece: piece, from: move.from, to: move.to)
        try? await Task.sleep(nanoseconds: UInt64(MoveAnimation.duration * 1_000_000_000))
        boardState.apply(move: move)
        lastMove = move
        animatingPiece = nil
        updateUndoRedoState()
        _ = updateStatusForGameOver()
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

    private func invalidateAnalysis() {
        analysisToken = UUID()
        treeToken = UUID()
        detectionToken = UUID()
        treeAnimationToken = UUID()
        // Bumping detectionToken abandons any in-flight detection (its completion guard now fails),
        // so don't leave the status stuck on "Detecting…". A new detect() re-sets it to .running.
        if case .running = detectionStatus { detectionStatus = .idle }
        isAnalyzing = false
        isTreeAnalyzing = false
        treeExpansionTask?.cancel()
        treeExpansionTask = nil
        treeExpandedPaths.removeAll()
        treeExpandingPaths.removeAll()
        treeRootState = nil
        treeSelectionSnapshot = nil
    }

    var gameOverScoreText: String? {
        gameOverMessage(for: boardState)
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

    private func expandTreeForSelection(id: TreeMoveNode.ID) async {
        guard interactionMode == .analyzeMoveTree else { return }
        guard !isTreeAnalyzing else { return }
        guard let rootState = treeRootState else { return }
        guard let selectedNode = treeNodes.first(where: { $0.id == id }) else { return }
        let baseNode = selectedNode
        let nodeMap = treeNodeMap()
        let baseKey = pathKey(baseNode.choicePath)
        guard !treeExpandedPaths.contains(baseKey), !treeExpandingPaths.contains(baseKey) else { return }

        let pliesToExpand = 1
        guard let baseStateResult = treeState(for: baseNode.choicePath, rootState: rootState, nodeMap: nodeMap) else { return }
        let baseState = baseStateResult.state

        treeExpandingPaths.insert(baseKey)
        await expandTreeChunk(
            from: baseState,
            basePath: baseNode.choicePath,
            basePlyIndex: baseNode.plyIndex,
            pliesToExpand: pliesToExpand,
            branchCount: max(1, treeBranchCount),
            token: treeToken
        )
    }

    private func expandTreeChunk(
        from state: BoardState?,
        basePath: [Int],
        basePlyIndex: Int,
        pliesToExpand: Int,
        branchCount: Int,
        token: UUID
    ) async {
        let baseKey = pathKey(basePath)
        defer { treeExpandingPaths.remove(baseKey) }
        guard token == treeToken, interactionMode == .analyzeMoveTree else { return }
        guard let state, pliesToExpand > 0 else {
            treeExpandedPaths.insert(baseKey)
            isTreeAnalyzing = false
            statusMessage = String(localized: "Tree analysis ready.")
            return
        }

        isTreeAnalyzing = true
        statusMessage = basePath.isEmpty
            ? String(localized: "Analyzing move tree...")
            : String(localized: "Expanding branch...")

        do {
            let maxAttempts = 3
            var attempt = 0
            var lines: [EngineLine] = []
            var uniqueFirstMoves = 0

            while attempt < maxAttempts {
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

            guard token == treeToken, interactionMode == .analyzeMoveTree else { return }
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
            guard token == treeToken, interactionMode == .analyzeMoveTree else { return }
            statusMessage = error.localizedDescription
        }

        if token == treeToken, interactionMode == .analyzeMoveTree {
            isTreeAnalyzing = false
        }
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

    private func animateTreeSelection(
        path: [Int],
        rootState: BoardState,
        nodeMap: [String: TreeMoveNode],
        token: UUID
    ) async {
        guard token == treeAnimationToken else { return }
        guard !path.isEmpty else {
            boardState = rootState
            lastMove = nil
            legalDestinations = []
            animatingPiece = nil
            return
        }

        var moves: [ChessMove] = []
        var state = rootState
        var currentPath: [Int] = []
        for index in path {
            currentPath.append(index)
            guard
                let node = nodeMap[pathKey(currentPath)],
                let move = state.move(fromUCI: node.uci)
            else {
                break
            }
            moves.append(move)
            state.apply(move: move)
        }

        guard !moves.isEmpty else { return }

        boardState = rootState
        lastMove = nil
        legalDestinations = []
        animatingPiece = nil

        for move in moves {
            guard token == treeAnimationToken else { return }
            guard let piece = boardState.piece(at: move.from) else { continue }
            animatingPiece = AnimatedPiece(id: UUID(), piece: piece, from: move.from, to: move.to)
            try? await Task.sleep(nanoseconds: UInt64(MoveAnimation.duration * 1_000_000_000))
            guard token == treeAnimationToken else { animatingPiece = nil; return }
            boardState.apply(move: move)
            lastMove = move
            animatingPiece = nil
        }
    }

    private func animateTreeSelectionIncremental(
        previousPath: [Int],
        newPath: [Int],
        nodeMap: [String: TreeMoveNode],
        token: UUID
    ) async -> Bool {
        guard token == treeAnimationToken else { return false }
        guard newPath.count == previousPath.count + 1, pathHasPrefix(newPath, previousPath) else { return false }
        guard let node = nodeMap[pathKey(newPath)], let move = boardState.move(fromUCI: node.uci) else { return false }
        guard let piece = boardState.piece(at: move.from) else { return false }

        legalDestinations = []
        animatingPiece = AnimatedPiece(id: UUID(), piece: piece, from: move.from, to: move.to)
        try? await Task.sleep(nanoseconds: UInt64(MoveAnimation.duration * 1_000_000_000))
        guard token == treeAnimationToken else { animatingPiece = nil; return true }
        boardState.apply(move: move)
        lastMove = move
        animatingPiece = nil
        return true
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

struct AnimatedPiece: Identifiable {
    let id: UUID
    let piece: Piece
    let from: BoardSquare
    let to: BoardSquare
}
