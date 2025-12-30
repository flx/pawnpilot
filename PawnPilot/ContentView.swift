import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
//import NextMoveKit
//import FENDetectorKit

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
    @State private var selectedSquare: BoardSquare?
    @State private var dropHighlight = false
    @State private var nextMoveSelection: String
    private let boardColumnWidth: CGFloat = 492
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
        _nextMoveSelection = State(initialValue: viewModel.boardState.activeColor)
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
        .frame(minWidth: 960, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity, alignment: .topLeading)
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
                BoardWithCoords(
                    boardState: viewModel.boardState,
                    orientationWhiteAtBottom: viewModel.orientationWhiteAtBottom,
                    selected: $selectedSquare,
                    lastMove: viewModel.lastMove,
                    legalTargets: viewModel.legalDestinations,
                    engineLines: displayedEngineLines,
                    selectedEngineLineID: viewModel.selectedEngineLineID,
                    treePaths: displayedTreePaths,
                    treeMaxPlies: treeMaxPlies,
                    maxSegments: viewModel.maxArrowsPerLine,
                    dropHighlight: dropHighlight,
                    animatingPiece: viewModel.animatingPiece,
                    showThreatOverlay: viewModel.showThreatOverlay,
                    threatMapWhite: viewModel.threatMapWhite,
                    threatMapBlack: viewModel.threatMapBlack
                ) { from, to in
                    viewModel.applyUserMove(from: from, to: to)
                    selectedSquare = nil
                    viewModel.updateLegalMoves(for: selectedSquare)
                }
                .onChange(of: selectedSquare) { newSelection in
                    viewModel.updateLegalMoves(for: newSelection)
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $dropHighlight) { providers in
                    handleDrop(providers: providers)
                }
                scoreStrip(
                    lines: displayedEngineLines,
                    bottomColor: viewModel.orientationWhiteAtBottom ? "w" : "b",
                    perspectiveColor: viewModel.boardState.activeColor,
                    overrideScore: scoreOverrideText
                )
        }
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            engineParametersBox
            playAgainstComputerBox
            analyzeMoveTreeBox
            analyzeLinesBox
            boardBox
        }
        .frame(minWidth: 320, alignment: .topLeading)
    }

    private var engineParametersBox: some View {
        GroupBox("Engine Parameters") {
            VStack(alignment: .leading, spacing: 8) {
                strengthControl
                analysisControls
            }
        }
    }

    private var playAgainstComputerBox: some View {
        GroupBox("Play Against Bot") {
            VStack(alignment: .leading, spacing: 8) {
                randomnessControl
                HStack(spacing: 6) {
                    Button("Bot Move", action: viewModel.engineMove)
                        .disabled(viewModel.isEngineThinking)
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .opacity(viewModel.isEngineThinking ? 1 : 0)
                    Toggle("Keep playing", isOn: $viewModel.keepPlaying)
                        .toggleStyle(.switch)
                        .disabled(viewModel.interactionMode != .playAgainstComputer)
                }
            }
        }
        .groupBoxStyle(ModeGroupBoxStyle(isActive: viewModel.interactionMode == .playAgainstComputer))
    }

    private var analyzeMoveTreeBox: some View {
        GroupBox("Analyze Variations") {
            VStack(alignment: .leading, spacing: 8) {
                treeBranchControl
                HStack(spacing: 6) {
                    Button("Analyze", action: viewModel.analyzeMoveTree)
                        .disabled(viewModel.isTreeAnalyzing)
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .opacity(viewModel.isTreeAnalyzing ? 1 : 0)
                }
            }
        }
        .groupBoxStyle(ModeGroupBoxStyle(isActive: viewModel.interactionMode == .analyzeMoveTree))
    }

    private var analyzeLinesBox: some View {
        GroupBox("Analyze Best Lines") {
            VStack(alignment: .leading, spacing: 8) {
                linesControl
                arrowCountControl
                HStack(spacing: 6) {
                    Button("Analyze", action: viewModel.analyze)
                        .disabled(viewModel.isAnalyzing)
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .opacity(viewModel.isAnalyzing ? 1 : 0)
                }
            }
        }
        .groupBoxStyle(ModeGroupBoxStyle(isActive: viewModel.interactionMode == .analyzeLines))
    }

    private var boardBox: some View {
        GroupBox("Board") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Open Image…", action: viewModel.openImageFromPanel)
                    Button("Rotate Position", action: viewModel.rotatePosition)
                    Spacer()
                    Toggle("Flip Board", isOn: flipBoardBinding.animation(.easeInOut(duration: 0.15)))
                        .toggleStyle(.switch)
                    Toggle("Show Threat Map", isOn: $viewModel.showThreatOverlay)
                        .toggleStyle(.switch)
                }
                HStack {
                    nextMoveControl
                    Spacer()
                    Button("Reset Board", action: viewModel.resetBoard)
                    Button("Undo Move", action: viewModel.undo)
                        .disabled(!viewModel.canUndo)
                    Button("Redo Move", action: viewModel.redo)
                        .disabled(!viewModel.canRedo)
                }
            }
        }
    }

    private var nextMoveControl: some View {
        HStack(spacing: 6) {
            Text("Next move")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()
                .lineLimit(1)
            Picker("Next move", selection: $nextMoveSelection) {
                Text("White").tag("w")
                Text("Black").tag("b")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
        }
        .frame(minWidth: 230, alignment: .leading)
        .layoutPriority(1)
        .onChange(of: nextMoveSelection) { newValue in
            viewModel.setSideToMove(newValue)
        }
        .onChange(of: viewModel.boardState.activeColor) { newValue in
            if nextMoveSelection != newValue {
                nextMoveSelection = newValue
            }
        }
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

    private func labeledSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        HStack {
            Text(title)
                .frame(width: 110, alignment: .leading)
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
        let bottomColor = viewModel.orientationWhiteAtBottom ? "w" : "b"
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
                Label("Detected \(output.fen)", systemImage: "checkmark.circle")
                    .lineLimit(2)
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

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.interactionMode == .analyzeMoveTree ? "Variations" : "Best Lines")
                    .font(.headline)
                Spacer()
                if viewModel.interactionMode == .analyzeLines {
                    Button("Play Selected Moves") {
                        viewModel.playSelectedLine()
                    }
                    .disabled(
                        viewModel.selectedEngineLineID == nil
                            || viewModel.isAnalyzing
                    )
                }
            }
            Group {
                if viewModel.interactionMode == .playAgainstComputer {
                    Text("Play mode active - analysis lines hidden.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if viewModel.interactionMode == .analyzeMoveTree {
                    if viewModel.treeNodes.isEmpty {
                        Text("No tree output yet.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                TreeNodesView(
                                    nodes: viewModel.treeNodes,
                                    selectedID: viewModel.selectedTreeNodeID,
                                    basePath: currentTreeBasePath,
                                    bottomColor: viewModel.orientationWhiteAtBottom ? "w" : "b",
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
                    Text("No engine output yet.")
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
            Text(viewModel.statusMessage ?? "Ready.")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct ModeGroupBoxStyle: GroupBoxStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            configuration.label
                .font(.headline)
            configuration.content
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: Color.black.opacity(0.06), radius: 1.5, x: 0, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isActive ? Color.black.opacity(0.6) : Color.clear, lineWidth: 2)
                )
        }
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
    let bottomColor: String
    let lineColor: (Int) -> Color
    let onSelect: (TreeMoveNode.ID?) -> Void
    @State private var isActive = false

    private var visibleNodes: [TreeMoveNode] {
        guard let selectedID, let selected = nodes.first(where: { $0.id == selectedID }) else {
            return nodes.filter { $0.choicePath.count == 1 }
        }
        let selectedPath = selected.choicePath
        let maxDepth = selectedPath.count + 1
        return nodes.filter { node in
            let depth = node.choicePath.count
            guard depth >= 1, depth <= maxDepth else { return false }
            if depth == 1 { return true }
            let prefixLen = depth - 1
            return Array(node.choicePath.prefix(prefixLen)) == Array(selectedPath.prefix(prefixLen))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleNodes) { node in
                let indent = CGFloat(max(0, node.choicePath.count - 1)) * 14
                let lineNumber = lineNumberLabel(for: node)
                HStack(spacing: 8) {
                    Text(lineNumber ?? "")
                        .font(.system(.body, design: .monospaced).monospacedDigit())
                        .frame(width: 20, alignment: .trailing)
                        .lineLimit(1)
                        .opacity(lineNumber == nil ? 0 : 1)
                    Text(scoreTextForBottomPerspective(score: node.score, bottomColor: bottomColor, perspectiveColor: node.scorePerspective))
                    Text(node.uci)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                }
                .padding(8)
                .padding(.leading, indent)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor(for: node, isSelected: node.id == selectedID))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelectedBorder(node: node), lineWidth: 2)
                )
                .onTapGesture {
                    if selectedID == node.id {
                        onSelect(nil)
                    } else {
                        onSelect(node.id)
                    }
                    isActive = true
                }
                .id(node.id)
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
        let currentNodes = visibleNodes
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

    private func backgroundColor(for node: TreeMoveNode, isSelected: Bool) -> Color {
        let depth = node.choicePath.count
        let baseDepth = basePath.count
        let isChild = depth == baseDepth + 1 && pathHasPrefix(node.choicePath, basePath)
        let baseOpacity: Double = isSelected ? 0.45 : 0.25
        if isChild, let childIndex = node.choicePath.last {
            return lineColor(childIndex).opacity(baseOpacity)
        }
        return Color.gray.opacity(isSelected ? 0.30 : 0.12)
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
}

struct BoardGridView: View {
    let boardState: BoardState
    let orientationWhiteAtBottom: Bool
    @Binding var selected: BoardSquare?
    let lastMove: ChessMove?
    let legalTargets: [BoardSquare]
    let showThreatOverlay: Bool
    let threatMapWhite: [BoardSquare: Int]
    let threatMapBlack: [BoardSquare: Int]
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
        let whiteThreats = threatMapWhite[square] ?? 0
        let blackThreats = threatMapBlack[square] ?? 0

        return Rectangle()
            .fill(isLight ? lightColor : darkColor)
            .overlay(
                ZStack {
                    if showThreatOverlay {
                        threatOverlays(white: whiteThreats, black: blackThreats)
                    }
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

    @ViewBuilder
    private func threatOverlays(white: Int, black: Int) -> some View {
        let baseCorner: CGFloat = 2
        let baseInset: CGFloat = 0
        if white > 0 && black > 0 {
            let whiteWidth = threatLineWidth(white)
            let blackWidth = threatLineWidth(black)
            RoundedRectangle(cornerRadius: baseCorner)
                .inset(by: baseInset)
                .strokeBorder(Color.red.opacity(threatOpacity(white)), lineWidth: whiteWidth)
            RoundedRectangle(cornerRadius: max(1, baseCorner - 0))
                .inset(by: baseInset + whiteWidth)
                .strokeBorder(Color.blue.opacity(threatOpacity(black)), lineWidth: blackWidth)
        } else if white > 0 {
            RoundedRectangle(cornerRadius: baseCorner)
                .inset(by: baseInset)
                .strokeBorder(Color.red.opacity(threatOpacity(white)), lineWidth: threatLineWidth(white))
        } else if black > 0 {
            RoundedRectangle(cornerRadius: baseCorner)
                .inset(by: baseInset)
                .strokeBorder(Color.blue.opacity(threatOpacity(black)), lineWidth: threatLineWidth(black))
        }
    }

    private func threatLineWidth(_ count: Int) -> CGFloat {
        switch count {
        case 0: return 0
        case 1: return 3.0
        case 2: return 4.0
        case 3: return 5.0
        default: return 6.0
        }
    }

    private func threatOpacity(_ count: Int) -> Double {
        switch count {
        case 0: return 0
        case 1: return 0.45
        case 2: return 0.55
        case 3: return 0.65
        default: return 0.75
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
            let overlapPositions = overlapPositions(for: renderSegments)

            ForEach(renderSegments) { render in
                let segment = render.segment
                let fromPoint = center(for: segment.from, files: files, ranks: ranks, square: squareSize)
                let toPoint = center(for: segment.to, files: files, ranks: ranks, square: squareSize)
                let offset = offset(for: render, from: fromPoint, to: toPoint, overlapPositions: overlapPositions)
                let startPoint = CGPoint(x: fromPoint.x + offset.x, y: fromPoint.y + offset.y)
                let endPoint = CGPoint(x: toPoint.x + offset.x, y: toPoint.y + offset.y)
                ArrowShape(start: startPoint, end: endPoint)
                    .stroke(color(for: render.lineIndex).opacity(segment.opacity), style: StrokeStyle(lineWidth: segment.lineWidth, lineCap: .round))
                    .overlay(
                        Group {
                            if !segment.label.isEmpty {
                                Text(segment.label)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Circle().fill(color(for: render.lineIndex)))
                                    .position(midpoint(from: startPoint, to: endPoint))
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

    private func center(for square: BoardSquare, files: [Int], ranks: [Int], square squareSize: CGFloat) -> CGPoint {
        guard let col = files.firstIndex(of: square.file), let row = ranks.firstIndex(of: square.rank) else {
            return .zero
        }
        let x = (CGFloat(col) + 0.5) * squareSize
        let y = (CGFloat(row) + 0.5) * squareSize
        return CGPoint(x: x, y: y)
    }

    private func midpoint(from: CGPoint, to: CGPoint) -> CGPoint {
        CGPoint(x: (from.x + to.x) * 0.5, y: (from.y + to.y) * 0.5)
    }

    private func overlapPositions(for segments: [RenderSegment]) -> [SegmentKey: OverlapPosition] {
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

    private func overlapKey(for segment: ArrowSegment) -> OverlapKey? {
        let dx = segment.to.file - segment.from.file
        let dy = segment.to.rank - segment.from.rank
        guard dx != 0 || dy != 0 else { return nil }
        let dirX = dx == 0 ? 0 : dx / abs(dx)
        let dirY = dy == 0 ? 0 : dy / abs(dy)
        return OverlapKey(from: segment.from, dirX: dirX, dirY: dirY)
    }

    private func offset(
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

    private func color(for index: Int) -> Color {
        treeBaseColor(index).opacity(0.8)
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
            let overlapPositions = overlapPositions(for: renderSegments)

            ForEach(renderSegments) { render in
                let segment = render.segment
                let fromPoint = center(for: segment.from, files: files, ranks: ranks, square: squareSize)
                let toPoint = center(for: segment.to, files: files, ranks: ranks, square: squareSize)
                let offset = offset(for: render, from: fromPoint, to: toPoint, overlapPositions: overlapPositions)
                let startPoint = CGPoint(x: fromPoint.x + offset.x, y: fromPoint.y + offset.y)
                let endPoint = CGPoint(x: toPoint.x + offset.x, y: toPoint.y + offset.y)
                ArrowShape(start: startPoint, end: endPoint)
                    .stroke(color(for: render.lineIndex).opacity(segment.opacity), style: StrokeStyle(lineWidth: segment.lineWidth, lineCap: .round))
                    .overlay(
                        Text(segment.label)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(color(for: render.lineIndex)))
                            .position(midpoint(from: startPoint, to: endPoint))
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

    private func center(for square: BoardSquare, files: [Int], ranks: [Int], square squareSize: CGFloat) -> CGPoint {
        guard let col = files.firstIndex(of: square.file), let row = ranks.firstIndex(of: square.rank) else {
            return .zero
        }
        let x = (CGFloat(col) + 0.5) * squareSize
        let y = (CGFloat(row) + 0.5) * squareSize
        return CGPoint(x: x, y: y)
    }

    private func midpoint(from: CGPoint, to: CGPoint) -> CGPoint {
        CGPoint(x: (from.x + to.x) * 0.5, y: (from.y + to.y) * 0.5)
    }

    private func overlapPositions(for segments: [RenderSegment]) -> [SegmentKey: OverlapPosition] {
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

    private func overlapKey(for segment: ArrowSegment) -> OverlapKey? {
        let dx = segment.to.file - segment.from.file
        let dy = segment.to.rank - segment.from.rank
        guard dx != 0 || dy != 0 else { return nil }
        let dirX = dx == 0 ? 0 : dx / abs(dx)
        let dirY = dy == 0 ? 0 : dy / abs(dy)
        return OverlapKey(from: segment.from, dirX: dirX, dirY: dirY)
    }

    private func offset(
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

    private func color(for index: Int) -> Color {
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

private func bestScoreText(lines: [EngineLine]) -> String {
    guard let first = lines.first else { return "--" }
    return scoreText(first.score)
}

private func scoreStrip(lines: [EngineLine], bottomColor: String, perspectiveColor: String, overrideScore: String? = nil) -> some View {
    let displayScore = overrideScore ?? sideScoreText(
        lines: lines,
        bottomColor: bottomColor,
        perspectiveColor: perspectiveColor
    )
    let label = bottomColor == "w" ? "Score for white" : "Score for black"
    return HStack {
        Spacer()
        Text("\(label): \(displayScore)")
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.secondary.opacity(0.1))
            )
        Spacer()
    }
}

private func sideScoreText(lines: [EngineLine], bottomColor: String, perspectiveColor: String) -> String {
    guard let first = lines.first else { return "--" }
    return scoreTextForBottomPerspective(
        score: first.score,
        bottomColor: bottomColor,
        perspectiveColor: perspectiveColor
    )
}

private func scoreTextForBottomPerspective(score: EngineScore, bottomColor: String, perspectiveColor: String) -> String {
    let adjusted = adjustedScoreForBottom(score: score, bottomColor: bottomColor, perspectiveColor: perspectiveColor)
    return scoreText(adjusted)
}

private func adjustedScoreForBottom(score: EngineScore, bottomColor: String, perspectiveColor: String) -> EngineScore {
    let normalizedBottom = normalizedColor(bottomColor)
    let normalizedPerspective = normalizedColor(perspectiveColor)
    let sameSide = normalizedBottom == normalizedPerspective
    switch score {
    case .cp(let v):
        return .cp(sameSide ? v : -v)
    case .mate(let m):
        return .mate(sameSide ? m : -m)
    }
}

private func normalizedColor(_ color: String) -> String {
    color == "b" ? "b" : "w"
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
                let from = center(for: anim.from, files: files, ranks: ranks, square: squareSize)
                let to = center(for: anim.to, files: files, ranks: ranks, square: squareSize)
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

    private func center(for square: BoardSquare, files: [Int], ranks: [Int], square squareSize: CGFloat) -> CGPoint {
        guard let col = files.firstIndex(of: square.file), let row = ranks.firstIndex(of: square.rank) else {
            return .zero
        }
        let x = (CGFloat(col) + 0.5) * squareSize
        let y = (CGFloat(row) + 0.5) * squareSize
        return CGPoint(x: x, y: y)
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
    let showThreatOverlay: Bool
    let threatMapWhite: [BoardSquare: Int]
    let threatMapBlack: [BoardSquare: Int]
    let onMove: (BoardSquare, BoardSquare) -> Void

    private var fileLabels: [String] {
        let labels = ["a","b","c","d","e","f","g","h"]
        return orientationWhiteAtBottom ? labels : labels.reversed()
    }

    private var rankLabels: [String] {
        let labels = ["1","2","3","4","5","6","7","8"]
        return orientationWhiteAtBottom ? labels : labels.reversed()
    }

    private var boardSize: CGFloat { 56 * 8 } // matches square size in BoardGridView

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Spacer().frame(width: 18)
                ForEach(fileLabels, id: \.self) { file in
                    Text(file)
                        .font(.caption)
                        .frame(width: 56)
                }
                Spacer().frame(width: 18)
            }
            HStack(spacing: 4) {
                VStack(spacing: 0) {
                    ForEach(rankLabels.reversed(), id: \.self) { rank in
                        Text(rank)
                            .font(.caption)
                            .frame(width: 18, height: 56)
                    }
                }
                ZStack {
                    BoardGridView(
                        boardState: boardState,
                        orientationWhiteAtBottom: orientationWhiteAtBottom,
                        selected: $selected,
                        lastMove: lastMove,
                        legalTargets: legalTargets,
                        showThreatOverlay: showThreatOverlay,
                        threatMapWhite: threatMapWhite,
                        threatMapBlack: threatMapBlack,
                        animatingPiece: animatingPiece,
                        onMove: onMove
                    )
                    .frame(width: boardSize, height: boardSize)
                    AnimatingPieceOverlay(
                        orientationWhiteAtBottom: orientationWhiteAtBottom,
                        animatingPiece: animatingPiece
                    )
                    .frame(width: boardSize, height: boardSize)
                    ArrowsOverlay(
                        boardState: boardState,
                        orientationWhiteAtBottom: orientationWhiteAtBottom,
                        engineLines: engineLines,
                        selectedEngineLineID: selectedEngineLineID,
                        maxSegments: maxSegments
                    )
                    .frame(width: boardSize, height: boardSize)
                    if !treePaths.isEmpty {
                        TreeArrowsOverlay(
                            boardState: boardState,
                            orientationWhiteAtBottom: orientationWhiteAtBottom,
                            paths: treePaths,
                            maxPlies: treeMaxPlies
                        )
                        .frame(width: boardSize, height: boardSize)
                    }
                }
                .frame(width: boardSize, height: boardSize)
                .overlay {
                    if dropHighlight {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                            .frame(width: boardSize + 12, height: boardSize + 12)
                            .allowsHitTesting(false)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(rankLabels.reversed(), id: \.self) { rank in
                        Text(rank)
                            .font(.caption)
                            .frame(width: 18, height: 56)
                    }
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: 18)
                ForEach(fileLabels, id: \.self) { file in
                    Text(file)
                        .font(.caption)
                        .frame(width: 56)
                }
                Spacer().frame(width: 18)
            }
        }
    }
}
