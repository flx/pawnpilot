import Foundation

/// Pure move-tree logic, separated from `AppViewModel`'s stateful orchestration so it can be
/// reasoned about and unit-tested without a view model or engine. `AppViewModel` owns the
/// published state and async expansion; everything here is a deterministic function of its inputs.
enum MoveTreeLogic {
    /// Stable string key for a choice path, e.g. `[0, 2, 1] -> "0.2.1"`.
    static func pathKey(_ path: [Int]) -> String {
        path.map(String.init).joined(separator: ".")
    }

    /// Whether `path` begins with `prefix`.
    static func pathHasPrefix(_ path: [Int], _ prefix: [Int]) -> Bool {
        guard path.count >= prefix.count else { return false }
        return Array(path.prefix(prefix.count)) == prefix
    }

    /// Lexicographic ordering of choice paths used to sort the flattened node list.
    static func compareChoicePath(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (l, r) in zip(lhs, rhs) where l != r {
            return l < r
        }
        return lhs.count < rhs.count
    }

    /// Number of distinct first moves across the engine lines.
    static func countUniqueFirstMoves(in lines: [EngineLine]) -> Int {
        var seen: Set<String> = []
        for line in lines {
            if let move = line.moves.first {
                seen.insert(move)
            }
        }
        return seen.count
    }

    /// Index the nodes by their path key for O(1) parent/child lookup.
    static func nodeMap(from nodes: [TreeMoveNode]) -> [String: TreeMoveNode] {
        var map: [String: TreeMoveNode] = [:]
        for node in nodes {
            map[pathKey(node.choicePath)] = node
        }
        return map
    }

    /// Replay the moves along `path` from `rootState`, returning the resulting position and the
    /// final move. Returns `nil` if any node is missing or its UCI cannot be applied.
    static func state(
        forPath path: [Int],
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

    /// One ply of a tree replay: everything the view needs to render the position *before* the
    /// move while the piece is in flight, plus the move itself.
    struct TreeFrame {
        /// The position before `move` is applied.
        let stateBefore: BoardState
        /// The highlight to show while `move` is in flight — the move that led to `stateBefore`,
        /// so frame 0 (which starts from the root) carries nil.
        let lastMoveBefore: ChessMove?
        let move: ChessMove
        /// The piece standing on `move.from` in `stateBefore`.
        let piece: Piece
    }

    /// Replay `path` from `rootState` as a sequence of frames plus the position it ends in.
    ///
    /// PREFIX semantics: the walk stops at the first node that is missing, whose UCI cannot be
    /// parsed, or whose `from` square is empty, and returns the frames and state reached so far.
    /// An empty path (or one whose first node is unresolvable) yields no frames and the root.
    static func frames(
        forPath path: [Int],
        rootState: BoardState,
        nodeMap: [String: TreeMoveNode]
    ) -> (frames: [TreeFrame], finalState: BoardState, finalLastMove: ChessMove?) {
        var frames: [TreeFrame] = []
        var state = rootState
        var lastMove: ChessMove?
        var currentPath: [Int] = []
        for index in path {
            currentPath.append(index)
            guard
                let node = nodeMap[pathKey(currentPath)],
                let move = state.move(fromUCI: node.uci),
                let piece = state.piece(at: move.from)
            else {
                break
            }
            frames.append(TreeFrame(stateBefore: state, lastMoveBefore: lastMove, move: move, piece: piece))
            state.apply(move: move)
            lastMove = move
        }
        return (frames, state, lastMove)
    }

    /// Build the new child nodes for a chunk of engine lines, deduplicating by first move and
    /// skipping paths already present in `existing`. Stops once `branchCount` unique moves are seen.
    static func buildChunkNodes(
        lines: [EngineLine],
        basePath: [Int],
        basePlyIndex: Int,
        branchCount: Int,
        scorePerspective: PieceColor,
        existing: [String: TreeMoveNode]
    ) -> [TreeMoveNode] {
        var nodeMap = existing
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
}
