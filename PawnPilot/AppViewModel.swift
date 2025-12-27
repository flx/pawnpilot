import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
//import NextMoveKit
//import FENDetectorKit

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
    let scorePerspective: String
    let isUserMove: Bool

    init(
        id: UUID = UUID(),
        parentID: UUID?,
        plyIndex: Int,
        choicePath: [Int],
        uci: String,
        score: EngineScore,
        depth: Int,
        scorePerspective: String,
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
    @Published var boardState = BoardState() {
        didSet { recomputeThreatMap() }
    }
    @Published var detectionStatus: DetectionStatus = .idle
    @Published var engineLines: [EngineLine] = []
    @Published var statusMessage: String?
    @Published var isAnalyzing = false
    @Published var strength: Int = 5
    @Published var multiPV: Int = 4
    @Published var orientationWhiteAtBottom = true
    @Published var lastMove: ChessMove?
    @Published var legalDestinations: [BoardSquare] = []
    @Published var selectedEngineLineID: EngineLine.ID?
    @Published var maxArrowsPerLine: Int = 4
    @Published var randomnessStrength: Int = 1
    @Published var animatingPiece: AnimatedPiece?
    @Published var interactionMode: InteractionMode = .playAgainstComputer
    @Published var isEngineThinking = false
    @Published var keepPlaying = false
    @Published var recents: [RecentImage] = []
    @Published var searchDepth: Int = 8
    @Published var treeNodes: [TreeMoveNode] = []
    @Published var selectedTreeNodeID: TreeMoveNode.ID?
    @Published var treeBranchCount: Int = 3
    @Published var isTreeAnalyzing = false
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var showThreatOverlay = false
    @Published var threatMapWhite: [BoardSquare: Int] = [:]
    @Published var threatMapBlack: [BoardSquare: Int] = [:]

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
    private var treeRootState: BoardState?
    var treeRootActiveColor: String?
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
        recomputeThreatMap()
    }

    func loadImage(from url: URL) {
        guard let nsImage = NSImage(contentsOf: url) else {
            statusMessage = "Unable to load image."
            return
        }
        loadImage(nsImage: nsImage, label: url.lastPathComponent)
    }

    func loadImage(nsImage: NSImage, label: String? = nil) {
        guard let cgImage = nsImage.cgImage else {
            statusMessage = "Unable to load image."
            return
        }
        let resolvedLabel = label ?? nextDroppedLabel()
        addRecent(image: nsImage, label: resolvedLabel)
        detect(cgImage: cgImage)
    }

    func loadRecent(_ recent: RecentImage) {
        addRecent(image: recent.image, label: recent.label)
        guard let cgImage = recent.image.cgImage else {
            statusMessage = "Unable to load image."
            return
        }
        detect(cgImage: cgImage)
    }

    func openImageFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose a chessboard image"
        if panel.runModal() == .OK, let url = panel.url {
            loadImage(from: url)
        }
    }

    func detect(cgImage: CGImage) {
        invalidateAnalysis()
        engineLines = []
        selectedEngineLineID = nil
        treeNodes = []
        selectedTreeNodeID = nil
        detectionStatus = .running
        statusMessage = "Detecting board..."
        Task {
            let output = await pipeline.process(cgImage: cgImage)
            var state = BoardState(fromDetection: output)
            if output.suggestedFlipForFEN {
                state = state.rotated180()
            }
            self.boardState = state
            // Orient the UI to match the screenshot (white at top when flip is suggested).
            self.orientationWhiteAtBottom = !output.suggestedFlipForFEN
            self.detectionStatus = .succeeded(output)
            self.statusMessage = "Detected position."
            self.logWarnings(output.warnings)
            self.engineLines = []
            self.selectedEngineLineID = nil
            self.treeNodes = []
            self.selectedTreeNodeID = nil
            self.lastMove = nil
            self.legalDestinations = []
            self.resetHistory()
            _ = self.updateStatusForGameOver()
        }
    }

    func analyze() {
        if isAnalyzing { return }
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
        treeRootActiveColor = nil
        treeSelectionSnapshot = nil
        let token = UUID()
        analysisToken = token
        isAnalyzing = true
        statusMessage = "Analyzing..."
        let options = analysisOptions(multiPV: max(multiPV, 1))
        Task {
            do {
                let lines = try await engine.analyze(fen: boardState.fen, options: options, requireFullDepth: true)
                guard token == analysisToken, interactionMode == .analyzeLines else { return }
                self.engineLines = lines
                self.statusMessage = lines.isEmpty ? "Engine returned no lines." : "Analysis ready."
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
        treeRootActiveColor = boardState.activeColor
        statusMessage = "Analyzing move tree..."
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
        Task {
            if shouldAnimateIncrementally, let previousPath {
                let succeeded = await animateTreeSelectionIncremental(
                    previousPath: previousPath,
                    newPath: newPath,
                    nodeMap: map
                )
                if succeeded { return }
            }
            await animateTreeSelection(path: newPath, rootState: rootState, nodeMap: map)
        }
        selectedTreeNodeID = id
        Task { await expandTreeForSelection(id: id) }
    }

    func engineMove() {
        if isEngineThinking { return }
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
        statusMessage = "Engine thinking..."
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
                    self.statusMessage = "Engine returned no move."
                    return
                }
                await self.performAnimatedMove(move: move)
                self.statusMessage = "Engine played \(uci)."
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
                guard let move = boardState.move(fromUCI: uci) else { continue }
                await performAnimatedMove(move: move)
                await MainActor.run { engineLines = [] }
            }
            analyze()
        }
    }

    func applyUserMove(from: BoardSquare, to: BoardSquare) {
        let move = ChessMove(from: from, to: to)
        guard moveValidator.isLegal(move: move, in: boardState) else {
            statusMessage = "Illegal move."
            return
        }
        invalidateAnalysis()
        Task {
            await performAnimatedMove(move: move)
            await MainActor.run {
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
    }

    func updateLegalMoves(for square: BoardSquare?) {
        guard let square else {
            legalDestinations = []
            return
        }
        legalDestinations = moveGenerator.legalDestinations(from: square, in: boardState)
    }

    func setSideToMove(_ color: String) {
        let normalized = color == "b" ? "b" : "w"
        guard boardState.activeColor != normalized else { return }
        invalidateAnalysis()
        boardState.activeColor = normalized
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
        statusMessage = "Board cleared."
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
        statusMessage = "Position rotated 180°."
    }

    private func performAnimatedMove(move: ChessMove) async {
        guard moveValidator.isLegal(move: move, in: boardState) else {
            await MainActor.run { statusMessage = "Illegal move." }
            return
        }
        guard let piece = boardState.piece(at: move.from) else { return }
        pushSnapshot()
        await MainActor.run {
            animatingPiece = AnimatedPiece(id: UUID(), piece: piece, from: move.from, to: move.to)
        }
        try? await Task.sleep(nanoseconds: UInt64(MoveAnimation.duration * 1_000_000_000))
        await MainActor.run {
            boardState.apply(move: move)
            lastMove = move
            animatingPiece = nil
        }
        updateUndoRedoState()
        await MainActor.run { _ = updateStatusForGameOver() }
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
        statusMessage = "Undid move."
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
        statusMessage = "Redid move."
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
        return "Dropped \(droppedImageCounter)"
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
        isAnalyzing = false
        isTreeAnalyzing = false
        treeExpansionTask?.cancel()
        treeExpansionTask = nil
        treeExpandedPaths.removeAll()
        treeExpandingPaths.removeAll()
        treeRootState = nil
        treeSelectionSnapshot = nil
        treeRootActiveColor = nil
    }

    var gameOverScoreText: String? {
        gameOverMessage(for: boardState)
    }

    private func gameOverMessage(for state: BoardState) -> String? {
        guard !moveGenerator.hasAnyLegalMove(in: state) else { return nil }
        if moveValidator.isInCheck(state: state) {
            return state.activeColor == "w" ? "White is check mate" : "Black is check mate"
        } else {
            return "Draw through Stalemate"
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

    private func recomputeThreatMap() {
        let (white, black) = threatCounts(for: boardState)
        threatMapWhite = white
        threatMapBlack = black
    }

    private func threatCounts(for state: BoardState) -> (white: [BoardSquare: Int], black: [BoardSquare: Int]) {
        var white: [BoardSquare: Int] = [:]
        var black: [BoardSquare: Int] = [:]

        for rank in 0..<8 {
            for file in 0..<8 {
                let square = BoardSquare(file: file, rank: rank)
                guard let piece = state.board[file, rank] else { continue }
                let attacks = attackedSquares(for: piece, at: square, board: state.board)
                if piece.isWhite {
                    for target in attacks {
                        white[target, default: 0] += 1
                    }
                } else {
                    for target in attacks {
                        black[target, default: 0] += 1
                    }
                }
            }
        }
        return (white, black)
    }

    private func attackedSquares(for piece: Piece, at square: BoardSquare, board: Board) -> [BoardSquare] {
        func inBounds(_ file: Int, _ rank: Int) -> Bool {
            (0..<8).contains(file) && (0..<8).contains(rank)
        }

        var results: [BoardSquare] = []
        let f = square.file
        let r = square.rank

        switch piece {
        case .whitePawn:
            let targets = [(f - 1, r + 1), (f + 1, r + 1)]
            for (tf, tr) in targets where inBounds(tf, tr) {
                results.append(BoardSquare(file: tf, rank: tr))
            }
        case .blackPawn:
            let targets = [(f - 1, r - 1), (f + 1, r - 1)]
            for (tf, tr) in targets where inBounds(tf, tr) {
                results.append(BoardSquare(file: tf, rank: tr))
            }
        case .whiteKnight, .blackKnight:
            let offsets = [(1,2),(2,1),(-1,2),(-2,1),(1,-2),(2,-1),(-1,-2),(-2,-1)]
            for (dx, dy) in offsets {
                let tf = f + dx
                let tr = r + dy
                if inBounds(tf, tr) {
                    results.append(BoardSquare(file: tf, rank: tr))
                }
            }
        case .whiteBishop, .blackBishop:
            results.append(contentsOf: slidingAttacks(from: square, directions: [(1,1), (-1,1), (1,-1), (-1,-1)], board: board))
        case .whiteRook, .blackRook:
            results.append(contentsOf: slidingAttacks(from: square, directions: [(1,0), (-1,0), (0,1), (0,-1)], board: board))
        case .whiteQueen, .blackQueen:
            results.append(contentsOf: slidingAttacks(from: square, directions: [(1,0), (-1,0), (0,1), (0,-1), (1,1), (-1,1), (1,-1), (-1,-1)], board: board))
        case .whiteKing, .blackKing:
            for dx in -1...1 {
                for dy in -1...1 where !(dx == 0 && dy == 0) {
                    let tf = f + dx
                    let tr = r + dy
                    if inBounds(tf, tr) {
                        results.append(BoardSquare(file: tf, rank: tr))
                    }
                }
            }
        }

        return results
    }

    private func slidingAttacks(from square: BoardSquare, directions: [(Int, Int)], board: Board) -> [BoardSquare] {
        var results: [BoardSquare] = []
        for (dx, dy) in directions {
            var file = square.file + dx
            var rank = square.rank + dy
            while (0..<8).contains(file) && (0..<8).contains(rank) {
                let target = BoardSquare(file: file, rank: rank)
                results.append(target)
                if board[file, rank] != nil {
                    break
                }
                file += dx
                rank += dy
            }
        }
        return results
    }

    private func analysisOptions(multiPV: Int, hash: Int = 128) -> EngineOptions {
        EngineOptions(
            multiPV: max(multiPV, 1),
            movetimeMs: nil,
            depth: max(1, searchDepth),
            strength: strength,
            limitStrength: strength < 5,
            elo: elo(for: strength),
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
            statusMessage = "Tree analysis ready."
            return
        }

        isTreeAnalyzing = true
        statusMessage = basePath.isEmpty ? "Analyzing move tree..." : "Expanding branch..."

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
                    requireFullDepth: false
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
                scorePerspective: state.activeColor
            )
            mergeTreeNodes(newNodes)
            treeExpandedPaths.insert(baseKey)
            if newNodes.isEmpty {
                statusMessage = "Engine returned no lines."
            } else if uniqueFirstMoves < branchCount {
                statusMessage = "Only \(uniqueFirstMoves) unique moves found."
            } else {
                statusMessage = "Tree analysis ready."
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
        scorePerspective: String
    ) -> [TreeMoveNode] {
        guard pliesToExpand > 0 else { return [] }
        var nodeMap = treeNodeMap()
        var newNodes: [TreeMoveNode] = []
        let parentID = basePath.isEmpty ? nil : nodeMap[pathKey(basePath)]?.id
        var seenFirstMoves: Set<String> = []

        for (index, line) in lines.enumerated() {
            guard let firstMove = line.moves.first else { continue }
            guard seenFirstMoves.insert(firstMove).inserted else { continue }
            let firstPath = basePath + [index]
            let firstKey = pathKey(firstPath)
            if nodeMap[firstKey] == nil {
                let node = TreeMoveNode(
                    parentID: parentID,
                    plyIndex: basePlyIndex + 1,
                    choicePath: firstPath,
                    uci: firstMove,
                    score: line.score,
                    depth: line.depth,
                    scorePerspective: scorePerspective,
                    isUserMove: (basePlyIndex + 1).isMultiple(of: 2)
                )
                nodeMap[firstKey] = node
                newNodes.append(node)
            }
            if seenFirstMoves.count >= branchCount { break }
        }

        return newNodes
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
        var map: [String: TreeMoveNode] = [:]
        for node in treeNodes {
            map[pathKey(node.choicePath)] = node
        }
        return map
    }

    private func treeState(
        for path: [Int],
        rootState: BoardState,
        nodeMap: [String: TreeMoveNode]
    ) -> (state: BoardState, lastMove: ChessMove?)? {
        var state = rootState
        var lastMove: ChessMove?
        var currentPath: [Int] = []
        for index in path {
            currentPath.append(index)
            guard
                let node = nodeMap[pathKey(currentPath)],
                let move = state.move(fromUCI: node.uci)
            else {
                return nil
            }
            state.apply(move: move)
            lastMove = move
        }
        return (state, lastMove)
    }

    private func animateTreeSelection(
        path: [Int],
        rootState: BoardState,
        nodeMap: [String: TreeMoveNode]
    ) async {
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
            guard let piece = boardState.piece(at: move.from) else { continue }
            animatingPiece = AnimatedPiece(id: UUID(), piece: piece, from: move.from, to: move.to)
            try? await Task.sleep(nanoseconds: UInt64(MoveAnimation.duration * 1_000_000_000))
            boardState.apply(move: move)
            lastMove = move
            animatingPiece = nil
        }
    }

    private func animateTreeSelectionIncremental(
        previousPath: [Int],
        newPath: [Int],
        nodeMap: [String: TreeMoveNode]
    ) async -> Bool {
        guard newPath.count == previousPath.count + 1, pathHasPrefix(newPath, previousPath) else { return false }
        guard let node = nodeMap[pathKey(newPath)], let move = boardState.move(fromUCI: node.uci) else { return false }
        guard let piece = boardState.piece(at: move.from) else { return false }

        legalDestinations = []
        animatingPiece = AnimatedPiece(id: UUID(), piece: piece, from: move.from, to: move.to)
        try? await Task.sleep(nanoseconds: UInt64(MoveAnimation.duration * 1_000_000_000))
        boardState.apply(move: move)
        lastMove = move
        animatingPiece = nil
        return true
    }

    private func logWarnings(_ warnings: [DetectionWarning]) {
        guard !warnings.isEmpty else { return }
        for warning in warnings {
            print("Detection warning: \(warning.message)")
        }
    }

    private static func findEngineURL(in bundle: Bundle) -> URL? {
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

    private static func reportMissingEngine(in bundle: Bundle) {
        let exeDir = bundle.executableURL?.deletingLastPathComponent().path ?? "n/a"
        print("Stockfish engine not found. Checked executable dir: \(exeDir)")
    }

    private struct BoardSnapshot {
        let state: BoardState
        let lastMove: ChessMove?
    }
}

private func compareChoicePath(_ lhs: [Int], _ rhs: [Int]) -> Bool {
    for (l, r) in zip(lhs, rhs) {
        if l != r { return l < r }
    }
    return lhs.count < rhs.count
}

private func pathHasPrefix(_ path: [Int], _ prefix: [Int]) -> Bool {
    guard path.count >= prefix.count else { return false }
    return Array(path.prefix(prefix.count)) == prefix
}

private func pathKey(_ path: [Int]) -> String {
    path.map(String.init).joined(separator: ".")
}

private func countUniqueFirstMoves(in lines: [EngineLine]) -> Int {
    var seen: Set<String> = []
    for line in lines {
        if let mv = line.moves.first {
            seen.insert(mv)
        }
    }
    return seen.count
}

struct AnimatedPiece: Identifiable {
    let id: UUID
    let piece: Piece
    let from: BoardSquare
    let to: BoardSquare
}
