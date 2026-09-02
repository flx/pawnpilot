import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

private enum PieceImages {
    private static var cache: [Piece: NSImage] = [:]

    static func image(for piece: Piece) -> NSImage? {
        if let cached = cache[piece] { return cached }
        let name = filename(for: piece)
        guard let img = AppBundle.main.image(forResource: NSImage.Name(name)) else {
            return nil
        }
        cache[piece] = img
        return img
    }

    private static func filename(for piece: Piece) -> String {
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
}

private func treeBaseColor(_ index: Int) -> Color {
    let palette: [Color] = [
        Color.green,
        Color.blue,
        Color.orange,
        Color.purple,
        Color.red,
        Color.cyan,
        Color.mint,
        Color.pink,
        Color.yellow,
        Color.indigo,
        Color.brown
    ]
    if index < palette.count {
        return palette[index]
    }
    let hue = Double(index % 12) / 12.0
    return Color(hue: hue, saturation: 0.65, brightness: 0.8)
}

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    private enum RightPanelTab: Hashable {
        case analyzeVariations
        case analyzeBestLines
        case playBot
    }
    @State private var selectedSquare: BoardSquare?
    @State private var dropHighlight = false
    @State private var pieceEditorSquare: BoardSquare?
    @State private var pieceEditorCode = ""
    @State private var pieceEditorError: String?
    @FocusState private var isPieceEditorFocused: Bool
    private let boardColumnWidth: CGFloat = 492
    private let pieceEditorCardWidth: CGFloat = 192
    private static let tabViewTopInset: CGFloat = {
        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        tabView.tabViewType = .topTabsBezelBorder
        tabView.tabViewBorderType = .line
        return max(0, tabView.bounds.maxY - tabView.contentRect.maxY - 3)
    }()
    private static let sliderLabelWidth: CGFloat = {
        let labels = [
            String(localized: "Search Depth"),
            String(localized: "Alternatives/move"),
            String(localized: "Display plies"),
            String(localized: "Lines"),
            String(localized: "Strength"),
            String(localized: "Randomness")
        ]
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widths = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let maxWidth = widths.max() ?? 110
        return ceil(maxWidth + 8)
    }()
    private var rightPanelHeight: CGFloat {
        BoardWithCoords.boardTopInset + BoardWithCoords.boardSize
    }
    private static let boardHelpItems: [HelpItem] = [
        HelpItem(
            id: "next-move",
            title: "Next move",
            body: "Indicates which side has the next move - you can change who has the next move, in particular after board detection from screenshot."
        ),
        HelpItem(
            id: "flip-board",
            title: "Flip Board",
            body: "Changes the viewing orientation only."
        ),
        HelpItem(
            id: "rotate",
            title: "Rotate",
            body: "Rotates the board without moving the pieces. If a1 was bottom left before it will be top right afterwards. This helps to correct boards when board detection did not accurately guess which side was black or white. Affects which direction white or black pawns move."
        ),
        HelpItem(
            id: "open-image",
            title: "Open Image…",
            body: "Import a screenshot and run board detection. You can alternatively drag the screenshot on the chessboard."
        ),
        HelpItem(
            id: "reset",
            title: "Reset",
            body: "Return the board to starting position."
        ),
        HelpItem(
            id: "undo-redo",
            title: "Undo / Redo",
            body: "Step backward or forward through move history."
        )
    ]
    private static let engineHelpItems: [HelpItem] = [
        HelpItem(
            id: "search-depth",
            title: "Search Depth",
            body: "Controls how deep the engine searches. Higher is slower but more accurate. Search depth 30 is very slow."
        ),
        HelpItem(
            id: "strict-depth",
            title: "Strict depth",
            body: "When on, waits for all lines to reach the target depth before returning. Slower but more accurate."
        )
    ]
    private static let analysisVariationsHelpItems: [HelpItem] = [
        HelpItem(
            id: "alternatives",
            title: "Alternatives/move",
            body: "Number of distinct move variations shown."
        )
    ]
    private static let analysisLinesHelpItems: [HelpItem] = [
        HelpItem(
            id: "lines",
            title: "Lines",
            body: "How many best lines to request from the engine."
        ),
        HelpItem(
            id: "display-plies",
            title: "Display plies",
            body: "How many arrows to draw for each line."
        )
    ]
    private static let botHelpItems: [HelpItem] = [
        HelpItem(
            id: "strength",
            title: "Strength",
            body: "Limits engine strength for bot play. Higher is stronger."
        ),
        HelpItem(
            id: "randomness",
            title: "Randomness",
            body: "Introduces strength randomness for the bot move. 1 - no randomness, 5 - high randomness."
        ),
        HelpItem(
            id: "keep-playing",
            title: "Keep playing",
            body: "Auto-respond with a bot move after you play."
        )
    ]
    private var displayedEngineLines: [EngineLine] {
        viewModel.interactionMode == .analyzeLines ? viewModel.engineLines : []
    }
    private var displayedTreePaths: [TreeArrowPath] {
        guard viewModel.interactionMode == .analyzeMoveTree else { return [] }
        return treeOverlayPaths(nodes: viewModel.treeNodes, selectedID: viewModel.selectedTreeNodeID)
    }
    private var treeMaxPlies: Int {
        1
    }
    private var treeScoreText: String? {
        guard viewModel.interactionMode == .analyzeMoveTree else { return nil }
        return treeScoreDisplay(nodes: viewModel.treeNodes, selectedID: viewModel.selectedTreeNodeID)
    }
    private var scoreOverrideText: String? {
        viewModel.gameOverScoreText ?? treeScoreText
    }
    private var currentTreeBasePath: [Int] {
        guard
            viewModel.interactionMode == .analyzeMoveTree,
            let selectedID = viewModel.selectedTreeNodeID,
            let selected = viewModel.treeNodes.first(where: { $0.id == selectedID })
        else {
            return []
        }
        return selected.choicePath
    }

    init(viewModel: AppViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    /// Single source of truth lives in the view model; these bindings project it for the controls.
    private var nextMoveBinding: Binding<PieceColor> {
        Binding(
            get: { viewModel.displayBoardState.sideToMove },
            set: { viewModel.setSideToMove($0) }
        )
    }

    private var selectedTabBinding: Binding<RightPanelTab> {
        Binding(
            get: { Self.tab(for: viewModel.interactionMode) },
            set: { viewModel.interactionMode = Self.mode(for: $0) }
        )
    }

    private var tabItems: [AppKitTabItem<RightPanelTab>] {
        [
            AppKitTabItem(
                title: String(localized: "Analyze Variations"),
                tag: .analyzeVariations,
                view: AnyView(analyzeVariationsPanel)
            ),
            AppKitTabItem(
                title: String(localized: "Analyze Best Lines"),
                tag: .analyzeBestLines,
                view: AnyView(analyzeBestLinesPanel)
            ),
            AppKitTabItem(
                title: String(localized: "Play Bot"),
                tag: .playBot,
                view: AnyView(playBotPanel)
            )
        ]
    }

    private static func tab(for mode: InteractionMode) -> RightPanelTab {
        switch mode {
        case .analyzeMoveTree:
            return .analyzeVariations
        case .analyzeLines:
            return .analyzeBestLines
        case .playAgainstComputer:
            return .playBot
        }
    }

    private static func mode(for tab: RightPanelTab) -> InteractionMode {
        switch tab {
        case .analyzeVariations:
            return .analyzeMoveTree
        case .analyzeBestLines:
            return .analyzeLines
        case .playBot:
            return .playAgainstComputer
        }
    }

    private func treeLineColor(_ index: Int) -> Color {
        treeBaseColor(index).opacity(0.65)
    }
    private var flipBoardBinding: Binding<Bool> {
        Binding(
            get: { !viewModel.orientationWhiteAtBottom },
            set: { viewModel.orientationWhiteAtBottom = !$0 }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            statusBar
        }
        .padding(.horizontal)
        .padding(.bottom)
        .frame(minWidth: 1100, maxWidth: .infinity, minHeight: 950, maxHeight: .infinity, alignment: .topLeading)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                boardColumn
                    .frame(width: boardColumnWidth, alignment: .topLeading)
                rightPanel
                    .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
            }
            engineSection
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var boardColumn: some View {
        VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    BoardWithCoords(
                        boardState: viewModel.displayBoardState,
                        orientationWhiteAtBottom: viewModel.orientationWhiteAtBottom,
                        selected: $selectedSquare,
                        lastMove: viewModel.displayLastMove,
                        legalTargets: viewModel.legalDestinations,
                        engineLines: displayedEngineLines,
                        selectedEngineLineID: viewModel.selectedEngineLineID,
                        treePaths: displayedTreePaths,
                        treeMaxPlies: treeMaxPlies,
                        maxSegments: viewModel.maxArrowsPerLine,
                        dropHighlight: dropHighlight,
                        animatingPiece: viewModel.animatingPiece,
                        onEditSquare: { square in
                            beginPieceEdit(at: square)
                        }
                    ) { from, to in
                        viewModel.applyUserMove(from: from, to: to)
                        selectedSquare = nil
                        viewModel.updateLegalMoves(for: nil)
                    }
                    if let square = pieceEditorSquare {
                        pieceEditorCard(square: square)
                            .position(pieceEditorPosition(for: square))
                            .zIndex(20)
                    }
                }
                .onChange(of: selectedSquare) { newSelection in
                    viewModel.updateLegalMoves(for: newSelection)
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $dropHighlight) { providers in
                    handleDrop(providers: providers)
                }
                scoreStrip(
                    lines: displayedEngineLines,
                    bottomColor: viewModel.orientationWhiteAtBottom ? .white : .black,
                    perspectiveColor: viewModel.displayBoardState.sideToMove,
                    overrideScore: scoreOverrideText
                )
        }
    }

    private var rightPanel: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: max(0, BoardWithCoords.boardTopInset - Self.tabViewTopInset))
            AppKitTabView(
                selection: selectedTabBinding,
                items: tabItems,
                borderType: .line,
                tabType: .topTabsBezelBorder
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: rightPanelHeight, maxHeight: rightPanelHeight, alignment: .topLeading)
    }

    private var analyzeVariationsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            boardBox
            engineParametersBox
            analysisVariationsBox
            analyzeVariationsAction
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var analyzeBestLinesPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            boardBox
            engineParametersBox
            analysisLinesBox
            analyzeLinesAction
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var playBotPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            boardBox
            engineParametersBox
            botParametersBox
            botMoveAction
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var engineParametersBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                analysisControls
            }
            .padding(10)
        } label: {
            groupBoxHeader("Engine Parameters", items: Self.engineHelpItems)
        }
    }

    private var analysisVariationsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                treeBranchControl
            }
            .padding(10)
        } label: {
            groupBoxHeader("Analysis Parameters", items: Self.analysisVariationsHelpItems)
        }
    }

    private var analysisLinesBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                linesControl
                arrowCountControl
            }
            .padding(10)
        } label: {
            groupBoxHeader("Analysis Parameters", items: Self.analysisLinesHelpItems)
        }
    }

    private var botParametersBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                strengthControl
                randomnessControl
                Toggle("Keep playing", isOn: $viewModel.keepPlaying)
                    .toggleStyle(.switch)
                    .disabled(viewModel.interactionMode != .playAgainstComputer)
            }
            .padding(10)
        } label: {
            groupBoxHeader("Bot Parameters", items: Self.botHelpItems)
        }
    }

    private var analyzeVariationsAction: some View {
        HStack(spacing: 8) {
            Button("Analyze", action: viewModel.analyzeMoveTree)
                .controlSize(.large)
                .disabled(viewModel.isTreeAnalyzing)
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .opacity(viewModel.isTreeAnalyzing ? 1 : 0)
            Spacer()
        }
    }

    private var analyzeLinesAction: some View {
        HStack(spacing: 8) {
            Button("Analyze", action: viewModel.analyze)
                .controlSize(.large)
                .disabled(viewModel.isAnalyzing)
            Button("Play Selected Moves") {
                viewModel.playSelectedLine()
            }
            .controlSize(.large)
            .disabled(viewModel.selectedEngineLineID == nil || viewModel.isAnalyzing)
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .opacity(viewModel.isAnalyzing ? 1 : 0)
            Spacer()
        }
    }

    private var botMoveAction: some View {
        HStack(spacing: 8) {
            Button("Play Bot Move", action: viewModel.engineMove)
                .controlSize(.large)
                .disabled(viewModel.isEngineThinking)
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .opacity(viewModel.isEngineThinking ? 1 : 0)
            Spacer()
        }
    }

    private func groupBoxHeader(_ title: LocalizedStringKey, items: [HelpItem]) -> some View {
        HStack(spacing: 6) {
            Text(title)
            HoverHelpIcon(items: items)
        }
    }

    private var boardBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    nextMoveControl
                    Toggle("Flip Board", isOn: flipBoardBinding.animation(.easeInOut(duration: 0.15)))
                        .toggleStyle(.switch)
                    Button(action: viewModel.rotatePosition) {
                        Label("Rotate", systemImage: "rotate.right")
                            .labelStyle(.iconOnly)
                    }
                    .help(String(localized: "Rotate Position"))
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("Open Image…", action: viewModel.openImageFromPanel)
                    Button("Reset", action: viewModel.resetBoard)
                    Button("Undo", action: viewModel.undo)
                        .disabled(!viewModel.canUndo)
                    Button("Redo", action: viewModel.redo)
                        .disabled(!viewModel.canRedo)
                    Spacer()
                }
            }
            .padding(10)
        } label: {
            groupBoxHeader("Board", items: Self.boardHelpItems)
        }
    }

    private var nextMoveControl: some View {
        HStack(spacing: 6) {
            Text("Next move")
                .fixedSize()
                .lineLimit(1)
            Picker("Next move", selection: nextMoveBinding) {
                Text("White").tag(PieceColor.white)
                Text("Black").tag(PieceColor.black)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
        }
        .frame(minWidth: 230, alignment: .leading)
        .layoutPriority(1)
    }

    private var strengthControl: some View {
        labeledSlider(title: "Strength", value: Binding(
            get: { Double(viewModel.strength) },
            set: { viewModel.strength = Int($0.rounded()) }
        ), range: 1...5, display: "\(viewModel.strength)")
    }

    private var randomnessControl: some View {
        labeledSlider(title: "Randomness", value: Binding(
            get: { Double(viewModel.randomnessStrength) },
            set: { viewModel.randomnessStrength = Int($0.rounded()) }
        ), range: 1...5, display: "\(viewModel.randomnessStrength)")
    }

    private var linesControl: some View {
        labeledSlider(title: "Lines", value: Binding(
            get: { Double(viewModel.multiPV) },
            set: { viewModel.multiPV = Int($0.rounded()) }
        ), range: 1...10, display: "\(viewModel.multiPV)")
    }

    private var analysisControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledSlider(title: "Search Depth", value: Binding(
                get: { Double(viewModel.searchDepth) },
                set: { viewModel.searchDepth = Int($0.rounded()) }
            ), range: 4...30, display: "\(viewModel.searchDepth)")
            Toggle("Strict depth", isOn: $viewModel.strictDepth)
                .toggleStyle(.switch)
        }
    }

    private var treeBranchControl: some View {
        labeledSlider(title: "Alternatives/move", value: Binding(
            get: { Double(viewModel.treeBranchCount) },
            set: { viewModel.treeBranchCount = Int($0.rounded()) }
        ), range: 1...10, display: "\(viewModel.treeBranchCount)")
    }

    private var arrowCountControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            labeledSlider(title: "Display plies", value: Binding(
                get: { Double(viewModel.maxArrowsPerLine) },
                set: { viewModel.maxArrowsPerLine = Int($0.rounded()) }
            ), range: 2...10, display: "\(viewModel.maxArrowsPerLine)")
        }
    }

    private func labeledSlider(title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        HStack {
            Text(title)
                .frame(width: Self.sliderLabelWidth, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text(display)
                .font(.system(.body, design: .monospaced))
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func treeScoreDisplay(nodes: [TreeMoveNode], selectedID: TreeMoveNode.ID?) -> String? {
        guard !nodes.isEmpty else { return nil }
        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let targetNode = treeScoreNode(nodes: nodes, selectedID: selectedID)
        guard let targetNode, let resolvedNode = nodeMap[targetNode.id] else { return nil }
        let bottomColor: PieceColor = viewModel.orientationWhiteAtBottom ? .white : .black
        return scoreTextForBottomPerspective(
            score: resolvedNode.score,
            bottomColor: bottomColor,
            perspectiveColor: resolvedNode.scorePerspective
        )
    }

    private func treeScoreNode(nodes: [TreeMoveNode], selectedID: TreeMoveNode.ID?) -> TreeMoveNode? {
        if let selectedID, let selected = nodes.first(where: { $0.id == selectedID }) {
            return selected
        }
        let zeroPath = nodes.filter { $0.choicePath.allSatisfy { $0 == 0 } }
        if let deepestZero = zeroPath.max(by: { $0.plyIndex < $1.plyIndex }) {
            return deepestZero
        }
        return nodes.first
    }
    private func treeOverlayPaths(nodes: [TreeMoveNode], selectedID: TreeMoveNode.ID?) -> [TreeArrowPath] {
        guard !nodes.isEmpty else { return [] }
        let basePath: [Int]
        if let selectedID, let selected = nodes.first(where: { $0.id == selectedID }) {
            basePath = selected.choicePath
        } else {
            basePath = []
        }

        let baseDepth = basePath.count
        let children = nodes.filter { pathHasPrefix($0.choicePath, basePath) && $0.choicePath.count == baseDepth + 1 }

        return children.compactMap { child in
            guard let branchIndex = child.choicePath.last else { return nil }
            return TreeArrowPath(nodes: [child], lineIndex: branchIndex)
        }
    }

    private func pathHasPrefix(_ path: [Int], _ prefix: [Int]) -> Bool {
        guard path.count >= prefix.count else { return false }
        return Array(path.prefix(prefix.count)) == prefix
    }

    private var detectionStatusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Detection")
                .font(.caption)
                .foregroundColor(.secondary)
        switch viewModel.detectionStatus {
        case .idle:
            Text("Idle").foregroundColor(.secondary)
        case .running:
            Label("Detecting…", systemImage: "hourglass")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
        case .succeeded(let output):
            Label {
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString("Detected %@", comment: "Detection output status"),
                        output.fen
                    )
                )
                .lineLimit(2)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
        }
    }
    }

    private var recentsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recents")
                .font(.caption)
                .foregroundColor(.secondary)
            if viewModel.recents.isEmpty {
                Text("No recent images.")
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.recents) { item in
                            Button {
                                viewModel.loadRecent(item)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: item.image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipped()
                                        .cornerRadius(6)
                                    Text(item.label)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .frame(width: 80)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 110)
            }
        }
    }

    private var engineSectionTitle: LocalizedStringKey {
        viewModel.interactionMode == .analyzeMoveTree ? "Variations" : "Best Lines"
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(engineSectionTitle)
                    .font(.headline)
                Spacer()
            }
            Group {
                if viewModel.interactionMode == .playAgainstComputer {
                    Text("Play mode active - analysis lines hidden.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if viewModel.interactionMode == .analyzeMoveTree {
                    if viewModel.treeNodes.isEmpty {
                        Text("No analysis output yet.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                TreeNodesView(
                                    nodes: viewModel.treeNodes,
                                    selectedID: viewModel.selectedTreeNodeID,
                                    basePath: currentTreeBasePath,
                                    bottomColor: viewModel.orientationWhiteAtBottom ? .white : .black,
                                    lineColor: treeLineColor,
                                    onSelect: { viewModel.selectTreeNode($0) }
                                )
                                .padding(.vertical, 4)
                            }
                            .onChange(of: viewModel.selectedTreeNodeID) { newValue in
                                guard let newValue else { return }
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    proxy.scrollTo(newValue, anchor: .center)
                                }
                            }
                        }
                    }
                } else if displayedEngineLines.isEmpty {
                    Text("No analysis output yet.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            EngineLinesView(
                                lines: displayedEngineLines,
                                selectedID: viewModel.selectedEngineLineID,
                                onSelect: { viewModel.selectedEngineLineID = $0 }
                            )
                            .padding(.vertical, 4)
                        }
                        .onChange(of: viewModel.selectedEngineLineID) { newValue in
                            guard let newValue else { return }
                            withAnimation(.easeInOut(duration: 0.12)) {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusBar: some View {
        HStack {
            Text(viewModel.statusMessage ?? String(localized: "Ready."))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginPieceEdit(at square: BoardSquare) {
        pieceEditorSquare = square
        pieceEditorCode = viewModel.beginEditing(at: square)
        pieceEditorError = nil
        selectedSquare = nil
        viewModel.updateLegalMoves(for: nil)
        DispatchQueue.main.async {
            isPieceEditorFocused = true
        }
    }

    private func closePieceEditor() {
        pieceEditorSquare = nil
        pieceEditorCode = ""
        pieceEditorError = nil
        isPieceEditorFocused = false
    }

    private func applyPieceEditor() {
        guard let square = pieceEditorSquare else { return }
        if let error = viewModel.setPiece(at: square, code: pieceEditorCode) {
            pieceEditorError = error
            isPieceEditorFocused = true
        } else {
            closePieceEditor()
        }
    }

    private func pieceEditorCard(square: BoardSquare) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String.localizedStringWithFormat(NSLocalizedString("Edit %@", comment: "Piece editor title"), square.label))
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(String(localized: "wk, bn, empty"), text: $pieceEditorCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($isPieceEditorFocused)
                .onSubmit(applyPieceEditor)
            if let pieceEditorError {
                Text(pieceEditorError)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Apply", action: applyPieceEditor)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel, action: closePieceEditor)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(8)
        .frame(width: pieceEditorCardWidth)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)
    }

    private func pieceEditorPosition(for square: BoardSquare) -> CGPoint {
        let files = viewModel.orientationWhiteAtBottom ? Array(0...7) : Array((0...7).reversed())
        let ranks = viewModel.orientationWhiteAtBottom ? Array((0...7).reversed()) : Array(0...7)
        guard
            let col = files.firstIndex(of: square.file),
            let rowFromTop = ranks.firstIndex(of: square.rank)
        else {
            return CGPoint(x: boardColumnWidth * 0.5, y: boardColumnWidth * 0.5)
        }

        let boardOriginX = BoardWithCoords.boardLeadingInset
        let boardOriginY = BoardWithCoords.boardTopInset
        let x = boardOriginX + (CGFloat(col) + 0.5) * BoardWithCoords.squareSize
        let y = boardOriginY + (CGFloat(rowFromTop) + 0.5) * BoardWithCoords.squareSize

        // Keep the floating card fully inside the board column. Heights approximate the card with
        // and without the error row; the exact value only affects edge clamping.
        let halfWidth = pieceEditorCardWidth / 2
        let halfHeight: CGFloat = pieceEditorError == nil ? 48 : 60
        let margin: CGFloat = 4
        let clampedX = min(max(x, halfWidth + margin), boardColumnWidth - halfWidth - margin)
        let clampedY = min(max(y, halfHeight + margin), boardColumnWidth - halfHeight - margin)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                _ = provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                    guard
                        let data,
                        let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    Task { @MainActor in
                        viewModel.loadImage(from: url)
                    }
                }
                return true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    Task { @MainActor in
                        viewModel.loadImage(nsImage: image)
                    }
                }
                return true
            }
        }
        return false
    }
}

struct EngineLinesView: View {
    let lines: [EngineLine]
    let selectedID: EngineLine.ID?
    let onSelect: (EngineLine.ID?) -> Void
    @State private var isActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(letter(for: index))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 14, alignment: .leading)
                    Text(scoreText(line.score))
                    Text(line.moves.joined(separator: " "))
                        .font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor(for: treeBaseColor(index), isSelected: line.id == selectedID))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selectionBorder(lineColor: treeBaseColor(index), isSelected: line.id == selectedID), lineWidth: 2)
                )
                .onTapGesture {
                    if selectedID == line.id {
                        onSelect(nil)
                    } else {
                        onSelect(line.id)
                    }
                    isActive = true
                }
                .id(line.id)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isActive = true
        }
        .background(
            KeyEventHandler(isActive: $isActive, onMove: handleMove)
        )
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        guard !lines.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in
            lines.firstIndex(where: { $0.id == id })
        }
        switch direction {
        case .down:
            let nextIndex = min((currentIndex ?? -1) + 1, lines.count - 1)
            onSelect(lines[nextIndex].id)
        case .up:
            if let currentIndex {
                let nextIndex = max(currentIndex - 1, 0)
                onSelect(lines[nextIndex].id)
            } else {
                onSelect(lines[lines.count - 1].id)
            }
        default:
            break
        }
    }

    private func selectionBorder(lineColor: Color, isSelected: Bool) -> Color {
        isSelected ? lineColor.opacity(0.8) : Color.clear
    }

    private func backgroundColor(for lineColor: Color, isSelected: Bool) -> Color {
        let baseOpacity: Double = isSelected ? 0.28 : 0.16
        return lineColor.opacity(baseOpacity)
    }
}

struct TreeNodesView: View {
    let nodes: [TreeMoveNode]
    let selectedID: TreeMoveNode.ID?
    let basePath: [Int]
    let bottomColor: PieceColor
    let lineColor: (Int) -> Color
    let onSelect: (TreeMoveNode.ID?) -> Void
    @State private var isActive = false
    private let moveIndent: CGFloat = 32

    private struct DisplayNode: Identifiable {
        let id: TreeMoveNode.ID
        let node: TreeMoveNode
        let movesText: String
        let indent: CGFloat
        let isDeemphasized: Bool
        let pathNodes: [TreeMoveNode]?
    }

    private var displayNodes: [DisplayNode] {
        guard let selectedID, let selected = nodes.first(where: { $0.id == selectedID }) else {
            return nodes
                .filter { $0.choicePath.count == 1 }
                .map { node in
                    DisplayNode(
                        id: node.id,
                        node: node,
                        movesText: node.uci,
                        indent: 0,
                        isDeemphasized: false,
                        pathNodes: nil
                    )
                }
        }

        let nodeMap = nodeMapByID()
        let baseDepth = basePath.count
        let basePathNodes = pathNodes(for: selected, nodeMap: nodeMap)
        let baseMoves = basePathNodes.map(\.uci).joined(separator: " ")
        var rows: [DisplayNode] = [
            DisplayNode(
                id: selected.id,
                node: selected,
                movesText: baseMoves,
                indent: 0,
                isDeemphasized: false,
                pathNodes: basePathNodes
            )
        ]

        let childNodes = nodes.filter { node in
            pathHasPrefix(node.choicePath, basePath) && node.choicePath.count == baseDepth + 1
        }
        let childIndent = moveIndent * CGFloat(max(1, baseDepth))
        rows.append(contentsOf: childNodes.map { node in
            DisplayNode(
                id: node.id,
                node: node,
                movesText: node.uci,
                indent: childIndent,
                isDeemphasized: false,
                pathNodes: nil
            )
        })

        rows.append(contentsOf: alternativeDisplayNodes(for: basePath))

        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(displayNodes) { display in
                let lineNumber = lineNumberLabel(for: display.node)
                HStack(spacing: 8) {
                    Text(lineNumber ?? "")
                        .font(.system(.body, design: .monospaced).monospacedDigit())
                        .frame(width: 20, alignment: .trailing)
                        .lineLimit(1)
                        .opacity(lineNumber == nil ? 0 : 1)
                    Text(scoreTextForBottomPerspective(score: display.node.score, bottomColor: bottomColor, perspectiveColor: display.node.scorePerspective))
                    if let pathNodes = display.pathNodes, !pathNodes.isEmpty {
                        movePathTokens(pathNodes)
                    } else {
                        Text(display.movesText)
                            .font(.system(.body, design: .monospaced))
                    }
                    Spacer()
                }
                .foregroundColor(display.isDeemphasized ? .secondary : .primary)
                .padding(8)
                .padding(.leading, display.indent)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor(for: display.node, isSelected: display.node.id == selectedID, isDeemphasized: display.isDeemphasized))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelectedBorder(node: display.node), lineWidth: 2)
                )
                .onTapGesture {
                    if selectedID == display.node.id {
                        onSelect(nil)
                    } else {
                        onSelect(display.node.id)
                    }
                    isActive = true
                }
                .id(display.node.id)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isActive = true
        }
        .background(
            KeyEventHandler(isActive: $isActive, onMove: handleMove)
        )
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        let currentNodes = displayNodes
        guard !currentNodes.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in
            currentNodes.firstIndex(where: { $0.id == id })
        }
        switch direction {
        case .down:
            let nextIndex = min((currentIndex ?? -1) + 1, currentNodes.count - 1)
            onSelect(currentNodes[nextIndex].id)
        case .up:
            if let currentIndex {
                let nextIndex = max(currentIndex - 1, 0)
                onSelect(currentNodes[nextIndex].id)
            } else {
                onSelect(currentNodes[currentNodes.count - 1].id)
            }
        default:
            break
        }
    }

    private func isSelectedBorder(node: TreeMoveNode) -> Color {
        node.id == selectedID ? Color.black.opacity(0.6) : Color.clear
    }

    private func backgroundColor(for node: TreeMoveNode, isSelected: Bool, isDeemphasized: Bool) -> Color {
        let depth = node.choicePath.count
        let baseDepth = basePath.count
        let isChild = depth == baseDepth + 1 && pathHasPrefix(node.choicePath, basePath)
        let baseOpacity: Double = isSelected ? 0.45 : 0.25
        if isChild, let childIndex = node.choicePath.last {
            let opacity = isDeemphasized ? baseOpacity * 0.6 : baseOpacity
            return lineColor(childIndex).opacity(opacity)
        }
        let grayOpacity = isSelected ? 0.30 : 0.12
        return Color.gray.opacity(isDeemphasized ? grayOpacity * 0.6 : grayOpacity)
    }

    private func pathHasPrefix(_ path: [Int], _ prefix: [Int]) -> Bool {
        guard path.count >= prefix.count else { return false }
        return Array(path.prefix(prefix.count)) == prefix
    }

    private func lineNumberLabel(for node: TreeMoveNode) -> String? {
        let depth = node.choicePath.count
        let baseDepth = basePath.count
        guard depth == baseDepth + 1, pathHasPrefix(node.choicePath, basePath) else { return nil }
        guard let last = node.choicePath.last else { return nil }
        return String(last + 1)
    }

    private func alternativeDisplayNodes(for selectedPath: [Int]) -> [DisplayNode] {
        guard !selectedPath.isEmpty else { return [] }
        var rows: [DisplayNode] = []
        for depth in stride(from: selectedPath.count, through: 1, by: -1) {
            let prefix = Array(selectedPath.prefix(depth - 1))
            let selectedIndex = selectedPath[depth - 1]
            let siblings = nodes.filter { node in
                node.choicePath.count == depth
                    && pathHasPrefix(node.choicePath, prefix)
                    && node.choicePath.last != selectedIndex
            }
            let indent = moveIndent * CGFloat(max(0, depth - 1))
            rows.append(contentsOf: siblings.map { node in
                DisplayNode(
                    id: node.id,
                    node: node,
                    movesText: node.uci,
                    indent: indent,
                    isDeemphasized: true,
                    pathNodes: nil
                )
            })
        }
        return rows
    }

    private func nodeMapByID() -> [TreeMoveNode.ID: TreeMoveNode] {
        var map: [TreeMoveNode.ID: TreeMoveNode] = [:]
        for node in nodes {
            map[node.id] = node
        }
        return map
    }

    private func pathNodes(for node: TreeMoveNode, nodeMap: [TreeMoveNode.ID: TreeMoveNode]) -> [TreeMoveNode] {
        var nodes: [TreeMoveNode] = []
        var current: TreeMoveNode? = node
        while let entry = current {
            nodes.append(entry)
            if let parentID = entry.parentID {
                current = nodeMap[parentID]
            } else {
                current = nil
            }
        }
        return nodes.reversed()
    }

    private func movePathTokens(_ pathNodes: [TreeMoveNode]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(pathNodes.enumerated()), id: \.element.id) { index, node in
                let isCurrent = index == pathNodes.count - 1
                if isCurrent {
                    Text(node.uci)
                        .font(.system(.body, design: .monospaced))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(tokenFill(isCurrent: true))
                        )
                } else {
                    Button {
                        onSelect(node.id)
                    } label: {
                        Text(node.uci)
                            .font(.system(.body, design: .monospaced))
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(tokenFill(isCurrent: false))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tokenFill(isCurrent: Bool) -> Color {
        isCurrent ? Color.clear : Color.black.opacity(0.18)
    }
}

struct BoardGridView: View {
    let boardState: BoardState
    let orientationWhiteAtBottom: Bool
    @Binding var selected: BoardSquare?
    let lastMove: ChessMove?
    let legalTargets: [BoardSquare]
    let animatingPiece: AnimatedPiece?
    let onMove: (BoardSquare, BoardSquare) -> Void

    private var ranks: [Int] {
        orientationWhiteAtBottom ? Array((0...7).reversed()) : Array(0...7)
    }

    private var files: [Int] {
        orientationWhiteAtBottom ? Array(0...7) : Array((0...7).reversed())
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(ranks, id: \.self) { rank in
                HStack(spacing: 0) {
                    ForEach(files, id: \.self) { file in
                        squareView(file: file, rank: rank)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private func squareView(file: Int, rank: Int) -> some View {
        let square = BoardSquare(file: file, rank: rank)
        let isLight = (file + rank).isMultiple(of: 2)
        let piece = boardState.piece(at: square)
        let isSelected = selected == square
        let isLastMove = lastMove?.from == square || lastMove?.to == square
//        let lightColor = Color(.sRGB, red: 0.90, green: 0.70, blue: 0.70, opacity: 1.0)  // muted red
//        let darkColor = Color(.sRGB, red: 0.65, green: 0.78, blue: 0.95, opacity: 1.0) // muted blue
        let lightColor = Color(.sRGB, red: 0.65, green: 0.65, blue: 0.65, opacity: 1.0) // dark gray
        let darkColor = Color(.sRGB, red: 0.90, green: 0.90, blue: 0.90, opacity: 1.0)  // light gray
        let isLegalTarget = legalTargets.contains(square)
        let isHiddenByAnimation = animatingPiece?.from == square || animatingPiece?.to == square
        let baseColor = isLight ? lightColor : darkColor

        return Rectangle()
            .fill(baseColor)
            .overlay(
                Rectangle()
                    .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .overlay(
                ZStack {
                    if isSelected {
                        Color.accentColor.opacity(0.25)
                    }
                    if isLastMove {
                        Color.yellow.opacity(0.25)
                    }
                    if let piece {
                        if !isHiddenByAnimation {
                            if let img = PieceImages.image(for: piece) {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(6)
                            } else {
                                Text(symbol(for: piece))
                                    .font(.system(size: 22, weight: .semibold, design: .default))
                                    .foregroundColor(piece.isWhite ? .primary : .black)
                            }
                        }
                    }
                    if isLegalTarget {
                        Circle()
                            .fill(Color.black.opacity(0.35))
                            .frame(width: 14, height: 14)
                    }
                }
            )
            .frame(width: 56, height: 56)
            .onTapGesture {
                handleTap(square: square)
            }
    }

    private func handleTap(square: BoardSquare) {
        if let origin = selected {
            onMove(origin, square)
        } else {
            selected = square
        }
    }

    private func symbol(for piece: Piece) -> String {
        switch piece {
        case .whitePawn: return "P"
        case .whiteKnight: return "N"
        case .whiteBishop: return "B"
        case .whiteRook: return "R"
        case .whiteQueen: return "Q"
        case .whiteKing: return "K"
        case .blackPawn: return "p"
        case .blackKnight: return "n"
        case .blackBishop: return "b"
        case .blackRook: return "r"
        case .blackQueen: return "q"
        case .blackKing: return "k"
        }
    }

}

struct ArrowsOverlay: View {
    let boardState: BoardState
    let orientationWhiteAtBottom: Bool
    let engineLines: [EngineLine]
    let selectedEngineLineID: EngineLine.ID?
    let maxSegments: Int

    var body: some View {
        GeometryReader { geo in
            let squareSize = min(geo.size.width, geo.size.height) / 8.0
            let files = orientationWhiteAtBottom ? Array(0...7) : Array((0...7).reversed())
            let ranks = orientationWhiteAtBottom ? Array((0...7).reversed()) : Array(0...7)

            let activeLines: [(Int, EngineLine)] = {
                let indexed = Array(engineLines.enumerated())
                if let sel = selectedEngineLineID, let match = indexed.first(where: { $0.element.id == sel }) {
                    return [match]
                }
                return indexed
            }()
            let singleLineMode = selectedEngineLineID != nil

            let renderSegments: [RenderSegment] = activeLines.flatMap { (originalIdx, line) in
                let segments = arrowSegments(for: line, lineIndex: originalIdx, singleLineMode: singleLineMode)
                return segments.enumerated().map { idx, segment in
                    RenderSegment(
                        key: SegmentKey(lineIndex: originalIdx, segmentIndex: idx),
                        lineIndex: originalIdx,
                        segmentIndex: idx,
                        segment: segment
                    )
                }
            }
            let overlapPositions = BoardArrowGeometry.overlapPositions(for: renderSegments)

            ForEach(renderSegments) { render in
                let segment = render.segment
                let fromPoint = BoardArrowGeometry.center(for: segment.from, files: files, ranks: ranks, square: squareSize)
                let toPoint = BoardArrowGeometry.center(for: segment.to, files: files, ranks: ranks, square: squareSize)
                let offset = BoardArrowGeometry.offset(for: render, from: fromPoint, to: toPoint, overlapPositions: overlapPositions)
                let startPoint = CGPoint(x: fromPoint.x + offset.x, y: fromPoint.y + offset.y)
                let endPoint = CGPoint(x: toPoint.x + offset.x, y: toPoint.y + offset.y)
                ArrowShape(start: startPoint, end: endPoint)
                    .stroke(BoardArrowGeometry.color(for: render.lineIndex).opacity(segment.opacity), style: StrokeStyle(lineWidth: segment.lineWidth, lineCap: .round))
                    .overlay(
                        Group {
                            if !segment.label.isEmpty {
                                Text(segment.label)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Circle().fill(BoardArrowGeometry.color(for: render.lineIndex)))
                                    .position(BoardArrowGeometry.midpoint(from: startPoint, to: endPoint))
                            }
                        }
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private func arrowSegments(for line: EngineLine, lineIndex: Int, singleLineMode: Bool) -> [ArrowSegment] {
        var tempState = boardState
        var segments: [ArrowSegment] = []
        let moves = Array(line.moves.prefix(maxSegments))
        for (idx, uci) in moves.enumerated() {
            guard let move = tempState.move(fromUCI: uci) else { break }
            let label: String
            if singleLineMode {
                label = "\(idx + 1)"
            } else {
                label = "\(letter(for: lineIndex))\(idx + 1)"
            }
            segments.append(ArrowSegment(
                from: move.from,
                to: move.to,
                label: label,
                lineWidth: idx == 0 ? 4 : 3,
                opacity: idx == 0 ? 1.0 : 0.8
            ))
            tempState.apply(move: move)
        }
        return segments
    }
}

struct TreeArrowPath: Identifiable {
    let id = UUID()
    let moves: [String]
    let labels: [String]
    let lineIndex: Int

    init(nodes: [TreeMoveNode], lineIndex: Int) {
        self.moves = nodes.map { $0.uci }
        self.labels = nodes.map { node in
            if let last = node.choicePath.last {
                return String(last + 1)
            }
            return node.label
        }
        self.lineIndex = lineIndex
    }
}

struct TreeArrowsOverlay: View {
    let boardState: BoardState
    let orientationWhiteAtBottom: Bool
    let paths: [TreeArrowPath]
    let maxPlies: Int

    var body: some View {
        GeometryReader { geo in
            let squareSize = min(geo.size.width, geo.size.height) / 8.0
            let files = orientationWhiteAtBottom ? Array(0...7) : Array((0...7).reversed())
            let ranks = orientationWhiteAtBottom ? Array((0...7).reversed()) : Array(0...7)

            let renderSegments: [RenderSegment] = paths.flatMap { path in
                let segments = arrowSegments(for: path)
                return segments.enumerated().map { idx, segment in
                    RenderSegment(
                        key: SegmentKey(lineIndex: path.lineIndex, segmentIndex: idx),
                        lineIndex: path.lineIndex,
                        segmentIndex: idx,
                        segment: segment
                    )
                }
            }
            let overlapPositions = BoardArrowGeometry.overlapPositions(for: renderSegments)

            ForEach(renderSegments) { render in
                let segment = render.segment
                let fromPoint = BoardArrowGeometry.center(for: segment.from, files: files, ranks: ranks, square: squareSize)
                let toPoint = BoardArrowGeometry.center(for: segment.to, files: files, ranks: ranks, square: squareSize)
                let offset = BoardArrowGeometry.offset(for: render, from: fromPoint, to: toPoint, overlapPositions: overlapPositions)
                let startPoint = CGPoint(x: fromPoint.x + offset.x, y: fromPoint.y + offset.y)
                let endPoint = CGPoint(x: toPoint.x + offset.x, y: toPoint.y + offset.y)
                ArrowShape(start: startPoint, end: endPoint)
                    .stroke(BoardArrowGeometry.color(for: render.lineIndex).opacity(segment.opacity), style: StrokeStyle(lineWidth: segment.lineWidth, lineCap: .round))
                    .overlay(
                        Text(segment.label)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(BoardArrowGeometry.color(for: render.lineIndex)))
                            .position(BoardArrowGeometry.midpoint(from: startPoint, to: endPoint))
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private func arrowSegments(for path: TreeArrowPath) -> [ArrowSegment] {
        var tempState = boardState
        var segments: [ArrowSegment] = []
        let moves = Array(path.moves.prefix(maxPlies))
        for (idx, uci) in moves.enumerated() {
            guard let move = tempState.move(fromUCI: uci) else { break }
            let label = (idx == moves.count - 1) ? (path.labels.last ?? "") : ""
            segments.append(ArrowSegment(
                from: move.from,
                to: move.to,
                label: label,
                lineWidth: idx == 0 ? 4 : 3,
                opacity: idx == 0 ? 1.0 : 0.8
            ))
            tempState.apply(move: move)
        }
        return segments
    }
}

/// Shared geometry for the engine-line and tree arrow overlays. Both overlays map board squares
/// to view coordinates and fan out parallel arrows identically; this keeps that math in one place.
private enum BoardArrowGeometry {
    static func center(for square: BoardSquare, files: [Int], ranks: [Int], square squareSize: CGFloat) -> CGPoint {
        guard let col = files.firstIndex(of: square.file), let row = ranks.firstIndex(of: square.rank) else {
            return .zero
        }
        let x = (CGFloat(col) + 0.5) * squareSize
        let y = (CGFloat(row) + 0.5) * squareSize
        return CGPoint(x: x, y: y)
    }

    static func midpoint(from: CGPoint, to: CGPoint) -> CGPoint {
        CGPoint(x: (from.x + to.x) * 0.5, y: (from.y + to.y) * 0.5)
    }

    static func overlapPositions(for segments: [RenderSegment]) -> [SegmentKey: OverlapPosition] {
        var positions: [SegmentKey: OverlapPosition] = [:]
        var groups: [OverlapKey: [RenderSegment]] = [:]

        for render in segments {
            if let key = overlapKey(for: render.segment) {
                groups[key, default: []].append(render)
            } else {
                positions[render.key] = OverlapPosition(index: 0, count: 1)
            }
        }

        for (_, group) in groups {
            let sorted = group.sorted {
                if $0.lineIndex != $1.lineIndex { return $0.lineIndex < $1.lineIndex }
                return $0.segmentIndex < $1.segmentIndex
            }
            let count = sorted.count
            for (idx, render) in sorted.enumerated() {
                positions[render.key] = OverlapPosition(index: idx, count: count)
            }
        }

        return positions
    }

    static func overlapKey(for segment: ArrowSegment) -> OverlapKey? {
        let dx = segment.to.file - segment.from.file
        let dy = segment.to.rank - segment.from.rank
        guard dx != 0 || dy != 0 else { return nil }
        let dirX = dx == 0 ? 0 : dx / abs(dx)
        let dirY = dy == 0 ? 0 : dy / abs(dy)
        return OverlapKey(from: segment.from, dirX: dirX, dirY: dirY)
    }

    static func offset(
        for render: RenderSegment,
        from: CGPoint,
        to: CGPoint,
        overlapPositions: [SegmentKey: OverlapPosition]
    ) -> CGPoint {
        guard let position = overlapPositions[render.key], position.count > 1 else {
            return .zero
        }
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return .zero }
        let offsetIndex = CGFloat(position.index) - CGFloat(position.count - 1) / 2.0
        let baseSpacing: CGFloat = 12.0
        let divisor = CGFloat(max(position.count, 2))
        let spacing = baseSpacing * 2.0 / divisor
        let unitX = -dy / length
        let unitY = dx / length
        return CGPoint(x: unitX * spacing * offsetIndex, y: unitY * spacing * offsetIndex)
    }

    static func color(for index: Int) -> Color {
        treeBaseColor(index).opacity(0.8)
    }
}

private struct SegmentKey: Hashable {
    let lineIndex: Int
    let segmentIndex: Int
}

private struct RenderSegment: Identifiable {
    let key: SegmentKey
    let lineIndex: Int
    let segmentIndex: Int
    let segment: ArrowSegment

    var id: SegmentKey { key }
}

private struct OverlapKey: Hashable {
    let from: BoardSquare
    let dirX: Int
    let dirY: Int
}

private struct OverlapPosition {
    let index: Int
    let count: Int
}

private func letter(for idx: Int) -> String {
    let scalarValue = Int(UnicodeScalar("a").value) + idx
    if let scalar = UnicodeScalar(scalarValue), idx < 26 {
        return String(Character(scalar))
    }
    return "z"
}

private func scoreText(_ score: EngineScore) -> String {
    switch score {
    case .cp(let v):
        let val = Double(v) / 100.0
        return String(format: "%+.2f", val)
    case .mate(let m):
        return "M\(m)"
    }
}

private struct HelpItem: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let body: LocalizedStringKey
}

private struct AppKitTabItem<Selection: Hashable> {
    let title: String
    let tag: Selection
    let view: AnyView
}

private struct AppKitTabView<Selection: Hashable>: NSViewRepresentable {
    @Binding var selection: Selection
    let items: [AppKitTabItem<Selection>]
    let borderType: NSTabView.TabViewBorderType
    let tabType: NSTabView.TabType

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTabView {
        let tabView = NSTabView()
        tabView.delegate = context.coordinator
        tabView.tabViewBorderType = borderType
        tabView.tabViewType = tabType
        applyItems(to: tabView)
        selectCurrent(in: tabView)
        return tabView
    }

    func updateNSView(_ nsView: NSTabView, context: Context) {
        nsView.tabViewBorderType = borderType
        nsView.tabViewType = tabType
        updateItems(in: nsView)
        selectCurrent(in: nsView)
    }

    private func applyItems(to tabView: NSTabView) {
        for item in items {
            let tabItem = NSTabViewItem(identifier: item.tag)
            tabItem.label = item.title
            tabItem.view = hostingView(for: item.view)
            tabView.addTabViewItem(tabItem)
        }
    }

    private func updateItems(in tabView: NSTabView) {
        let existingTags = tabView.tabViewItems.compactMap { $0.identifier as? Selection }
        let desiredTags = items.map(\.tag)
        if existingTags != desiredTags {
            let existingItems = tabView.tabViewItems
            for item in existingItems {
                tabView.removeTabViewItem(item)
            }
            applyItems(to: tabView)
            return
        }

        for (index, item) in items.enumerated() {
            let tabItem = tabView.tabViewItems[index]
            tabItem.label = item.title
            if let hosting = tabItem.view as? NSHostingView<AnyView> {
                hosting.rootView = item.view
            } else {
                tabItem.view = hostingView(for: item.view)
            }
        }
    }

    private func selectCurrent(in tabView: NSTabView) {
        guard let match = tabView.tabViewItems.first(where: { ($0.identifier as? Selection) == selection }) else {
            return
        }
        if tabView.selectedTabViewItem !== match {
            tabView.selectTabViewItem(match)
        }
    }

    private func hostingView(for view: AnyView) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }

    final class Coordinator: NSObject, NSTabViewDelegate {
        private var parent: AppKitTabView

        init(_ parent: AppKitTabView) {
            self.parent = parent
        }

        func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            guard let tag = tabViewItem?.identifier as? Selection else { return }
            if parent.selection != tag {
                parent.selection = tag
            }
        }
    }
}

private struct HoverHelpIcon: View {
    let items: [HelpItem]
    @State private var isPresented = false
    @State private var hoverTask: DispatchWorkItem?

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    let task = DispatchWorkItem { isPresented = true }
                    hoverTask = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
                } else {
                    isPresented = false
                }
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                HelpPopoverContent(items: items)
            }
            .onDisappear {
                hoverTask?.cancel()
                isPresented = false
            }
    }
}

private struct HelpPopoverContent: View {
    let items: [HelpItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(item.body)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }
}

private func bestScoreText(lines: [EngineLine]) -> String {
    guard let first = lines.first else { return "--" }
    return scoreText(first.score)
}

private func scoreStrip(lines: [EngineLine], bottomColor: PieceColor, perspectiveColor: PieceColor, overrideScore: String? = nil) -> some View {
    let displayScore = overrideScore ?? sideScoreText(
        lines: lines,
        bottomColor: bottomColor,
        perspectiveColor: perspectiveColor
    )
    let label = bottomColor == .white
        ? String(localized: "Score for white")
        : String(localized: "Score for black")
    return HStack {
        Spacer()
        Text("\(label): \(displayScore)")
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.secondary.opacity(0.1))
            )
        Spacer()
    }
}

private func sideScoreText(lines: [EngineLine], bottomColor: PieceColor, perspectiveColor: PieceColor) -> String {
    guard let first = lines.first else { return "--" }
    return scoreTextForBottomPerspective(
        score: first.score,
        bottomColor: bottomColor,
        perspectiveColor: perspectiveColor
    )
}

private func scoreTextForBottomPerspective(score: EngineScore, bottomColor: PieceColor, perspectiveColor: PieceColor) -> String {
    let adjusted = adjustedScoreForBottom(score: score, bottomColor: bottomColor, perspectiveColor: perspectiveColor)
    return scoreText(adjusted)
}

private func adjustedScoreForBottom(score: EngineScore, bottomColor: PieceColor, perspectiveColor: PieceColor) -> EngineScore {
    let sameSide = bottomColor == perspectiveColor
    switch score {
    case .cp(let v):
        return .cp(sameSide ? v : -v)
    case .mate(let m):
        return .mate(sameSide ? m : -m)
    }
}

private struct KeyEventHandler: NSViewRepresentable {
    @Binding var isActive: Bool
    let onMove: (MoveCommandDirection) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onMove = onMove
        guard isActive, let window = nsView.window else { return }
        if window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {
        var onMove: ((MoveCommandDirection) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126:
                onMove?(.up)
            case 125:
                onMove?(.down)
            default:
                super.keyDown(with: event)
            }
        }
    }
}

struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 14
        let arrowAngle: CGFloat = .pi / 7

        let p1 = CGPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )
        path.move(to: end)
        path.addLine(to: p1)
        path.move(to: end)
        path.addLine(to: p2)
        return path
    }
}

struct ArrowSegment {
    let from: BoardSquare
    let to: BoardSquare
    let label: String
    let lineWidth: CGFloat
    let opacity: Double
}

struct AnimatingPieceOverlay: View {
    let orientationWhiteAtBottom: Bool
    let animatingPiece: AnimatedPiece?
    @State private var progress: CGFloat = 0
    @State private var currentID: UUID?

    var body: some View {
        GeometryReader { geo in
            if let anim = animatingPiece {
                let squareSize = min(geo.size.width, geo.size.height) / 8.0
                let files = orientationWhiteAtBottom ? Array(0...7) : Array((0...7).reversed())
                let ranks = orientationWhiteAtBottom ? Array((0...7).reversed()) : Array(0...7)
                let from = BoardArrowGeometry.center(for: anim.from, files: files, ranks: ranks, square: squareSize)
                let to = BoardArrowGeometry.center(for: anim.to, files: files, ranks: ranks, square: squareSize)
                let pos = CGPoint(
                    x: from.x + (to.x - from.x) * progress,
                    y: from.y + (to.y - from.y) * progress
                )

                Group {
                    if let img = PieceImages.image(for: anim.piece) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: squareSize * 0.8, height: squareSize * 0.8)
                            .position(pos)
                    } else {
                        Text(symbol(for: anim.piece))
                            .font(.system(size: 22, weight: .semibold, design: .default))
                            .position(pos)
                    }
                }
                .onChange(of: anim.id) { newID in
                    currentID = newID
                    progress = 0
                    withAnimation(MoveAnimation.animation) {
                        progress = 1
                    }
                }
                .onAppear {
                    if currentID != anim.id {
                        currentID = anim.id
                        progress = 0
                        withAnimation(MoveAnimation.animation) {
                            progress = 1
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func symbol(for piece: Piece) -> String {
        switch piece {
        case .whitePawn: return "P"
        case .whiteKnight: return "N"
        case .whiteBishop: return "B"
        case .whiteRook: return "R"
        case .whiteQueen: return "Q"
        case .whiteKing: return "K"
        case .blackPawn: return "p"
        case .blackKnight: return "n"
        case .blackBishop: return "b"
        case .blackRook: return "r"
        case .blackQueen: return "q"
        case .blackKing: return "k"
        }
    }
}

struct BoardWithCoords: View {
    static let squareSize: CGFloat = 56
    static let boardSize: CGFloat = squareSize * 8
    static let coordLabelHeight: CGFloat = 18
    static let coordLabelSpacing: CGFloat = 4
    static let boardTopInset: CGFloat = coordLabelHeight + coordLabelSpacing
    /// Width of the rank-number gutter on each side of the grid.
    static let rankLabelWidth: CGFloat = 18
    /// X offset of the grid's left edge within `BoardWithCoords` (rank gutter + its trailing spacing).
    static let boardLeadingInset: CGFloat = rankLabelWidth + coordLabelSpacing
    let boardState: BoardState
    let orientationWhiteAtBottom: Bool
    @Binding var selected: BoardSquare?
    let lastMove: ChessMove?
    let legalTargets: [BoardSquare]
    let engineLines: [EngineLine]
    let selectedEngineLineID: EngineLine.ID?
    let treePaths: [TreeArrowPath]
    let treeMaxPlies: Int
    let maxSegments: Int
    let dropHighlight: Bool
    let animatingPiece: AnimatedPiece?
    let onEditSquare: (BoardSquare) -> Void
    let onMove: (BoardSquare, BoardSquare) -> Void

    private var fileLabels: [String] {
        let labels = ["a","b","c","d","e","f","g","h"]
        return orientationWhiteAtBottom ? labels : labels.reversed()
    }

    private var rankLabels: [String] {
        let labels = ["1","2","3","4","5","6","7","8"]
        return orientationWhiteAtBottom ? labels : labels.reversed()
    }

    var body: some View {
        VStack(spacing: Self.coordLabelSpacing) {
            HStack(spacing: 0) {
                Spacer().frame(width: Self.rankLabelWidth)
                ForEach(fileLabels, id: \.self) { file in
                    Text(file)
                        .font(.caption)
                        .frame(width: 56, height: Self.coordLabelHeight)
                }
                Spacer().frame(width: Self.rankLabelWidth)
            }
            HStack(spacing: 4) {
                VStack(spacing: 0) {
                    ForEach(rankLabels.reversed(), id: \.self) { rank in
                        Text(rank)
                            .font(.caption)
                            .frame(width: Self.rankLabelWidth, height: 56)
                    }
                }
                ZStack {
                    BoardGridView(
                        boardState: boardState,
                        orientationWhiteAtBottom: orientationWhiteAtBottom,
                        selected: $selected,
                        lastMove: lastMove,
                        legalTargets: legalTargets,
                        animatingPiece: animatingPiece,
                        onMove: onMove
                    )
                    .frame(width: Self.boardSize, height: Self.boardSize)
                    SecondaryClickBoardOverlay(
                        orientationWhiteAtBottom: orientationWhiteAtBottom,
                        squareSize: Self.squareSize,
                        onSelectSquare: onEditSquare
                    )
                    .frame(width: Self.boardSize, height: Self.boardSize)
                    AnimatingPieceOverlay(
                        orientationWhiteAtBottom: orientationWhiteAtBottom,
                        animatingPiece: animatingPiece
                    )
                    .frame(width: Self.boardSize, height: Self.boardSize)
                    ArrowsOverlay(
                        boardState: boardState,
                        orientationWhiteAtBottom: orientationWhiteAtBottom,
                        engineLines: engineLines,
                        selectedEngineLineID: selectedEngineLineID,
                        maxSegments: maxSegments
                    )
                    .frame(width: Self.boardSize, height: Self.boardSize)
                    if !treePaths.isEmpty {
                        TreeArrowsOverlay(
                            boardState: boardState,
                            orientationWhiteAtBottom: orientationWhiteAtBottom,
                            paths: treePaths,
                            maxPlies: treeMaxPlies
                        )
                        .frame(width: Self.boardSize, height: Self.boardSize)
                    }
                }
                .frame(width: Self.boardSize, height: Self.boardSize)
                .overlay {
                    if dropHighlight {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                            .frame(width: Self.boardSize + 12, height: Self.boardSize + 12)
                            .allowsHitTesting(false)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(rankLabels.reversed(), id: \.self) { rank in
                        Text(rank)
                            .font(.caption)
                            .frame(width: Self.rankLabelWidth, height: 56)
                    }
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: Self.rankLabelWidth)
                ForEach(fileLabels, id: \.self) { file in
                    Text(file)
                        .font(.caption)
                        .frame(width: 56)
                }
                Spacer().frame(width: Self.rankLabelWidth)
            }
        }
    }
}

private struct SecondaryClickBoardOverlay: NSViewRepresentable {
    let orientationWhiteAtBottom: Bool
    let squareSize: CGFloat
    let onSelectSquare: (BoardSquare) -> Void

    func makeNSView(context: Context) -> SecondaryClickCaptureView {
        let view = SecondaryClickCaptureView()
        view.orientationWhiteAtBottom = orientationWhiteAtBottom
        view.squareSize = squareSize
        view.onSelectSquare = onSelectSquare
        return view
    }

    func updateNSView(_ nsView: SecondaryClickCaptureView, context: Context) {
        nsView.orientationWhiteAtBottom = orientationWhiteAtBottom
        nsView.squareSize = squareSize
        nsView.onSelectSquare = onSelectSquare
    }

    final class SecondaryClickCaptureView: NSView {
        var orientationWhiteAtBottom: Bool = true
        var squareSize: CGFloat = 56
        var onSelectSquare: ((BoardSquare) -> Void)?

        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point), let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown:
                return self
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return self
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            handleSecondaryClick(event)
        }

        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else { return }
            handleSecondaryClick(event)
        }

        private func handleSecondaryClick(_ event: NSEvent) {
            let localPoint = convert(event.locationInWindow, from: nil)
            guard let square = boardSquare(at: localPoint) else { return }
            onSelectSquare?(square)
        }

        // NOTE: this is a plain (non-flipped) NSView, so `point` has its origin at the bottom-left,
        // whereas the SwiftUI `BoardGridView` it sits over lays out top-down. The `7 - rowFromBottom`
        // flip below reconciles the two so a secondary click maps to the same logical square the user
        // sees. If this view is ever made `isFlipped`, drop the flip.
        private func boardSquare(at point: NSPoint) -> BoardSquare? {
            guard squareSize > 0 else { return nil }

            let col = Int(point.x / squareSize)
            let rowFromBottom = Int(point.y / squareSize)
            guard (0..<8).contains(col), (0..<8).contains(rowFromBottom) else { return nil }

            let rowFromTop = 7 - rowFromBottom
            let files = orientationWhiteAtBottom ? Array(0...7) : Array((0...7).reversed())
            let ranks = orientationWhiteAtBottom ? Array((0...7).reversed()) : Array(0...7)
            guard (0..<8).contains(rowFromTop) else { return nil }

            return BoardSquare(file: files[col], rank: ranks[rowFromTop])
        }
    }
}
