# Plan: (persistent-engine-serialize-searches)

Rev 3 · 2026-09-01 · tier **hi** (actor concurrency; process lifetime; the
change replaces the persistent engine's whole I/O and control model. Both adv
reviewers on the code; `adv-review-plan` ran twice on this plan — Rev 1 and
Rev 2 both returned "do not build as scoped"; Rev 3 folds in every confirmed
finding of both rounds, see Decisions. **No `/arch-review`**, reasons under
Decisions.)

Source: TODO.md §0 item 1 (was item 2); evidence `arch-reviews/2026-09-01-stability-performance.md` F2.
Builds on `(engine-pipe-write-after-death-sigpipe)` (`f6950bd`):
`EngineStdinWriter`, `StockfishError.engineGone`, the `arguments:` initialiser
parameter, the `…ForTesting()` accessors, and the `FakeUCIEngine` test double.

## Premise re-derived against the tree (`f6950bd`, line numbers checked 2026-09-01)

`PawnPilot/NextMoveModels/Engine/PersistentStockfishEngine.swift`:

- `analyze` (`:24-53`) wraps `runSearch` in a `withThrowingTaskGroup` with a
  sleeping child that throws `.timeout` (`:32-45`); `catch { shutdownProcess() }`
  (`:49-52`) acts on whatever `process` is current.
- Nothing records "a search is in flight". Actors are reentrant at every
  `await`; `runSearch` awaits in `ensureProcess()` (`:60`), `readUntil("readyok")`
  (`:90`), and `for try await line in reader.bytes.lines` (`:100`). A second
  `analyze` entering during any of those sends `setoption`/`isready`/`position`/`go`
  into the running search and opens a second `bytes.lines` iterator on the same
  `FileHandle` — the split-output stall F2 describes.
- Every `readUntil` and every `runSearch` creates a fresh `reader.bytes.lines`
  (`:100`, `:216`; `readUntil` is called at `:90, :139, :141`); whatever the
  previous iterator had buffered past its last consumed line is lost. Both plan
  reviewers reproduced it by probe (a fresh `bytes.lines` after a `break` hangs
  waiting for bytes it already dropped).
- `withTaskCancellationHandler … onCancel: { Task { await shutdownProcess() } }`
  (`:125-127`): cancellation tears the child down while the search still holds
  its `reader`, killing the child for what should be an abort of one search.
- `readUntil` throws `.startFailed` on EOF (`:215-220`) even for the per-search
  `isready` round-trip at `:90` — a mid-session death reads "Stockfish failed
  to launch." (item 1 review, finding 2).
- `AppViewModel` cancels `treeExpansionTask` at `:218, :274, :678`; `selectTreeNode`
  spawns `expandTreeForSelection` unstored (`:345`); `expandTreeChunk` retries
  `treeEngine.analyze` up to three times (`:798-814`); the actor is built with
  the default `timeoutSeconds: 300` (`:112`).

Probe-verified facts this design rests on (round 2 reviewer, sources under the
job's `tmp/probe2/`): `AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator`
is nameable, storable in actor state, and its buffer survives copy-out /
`next()` / copy-back; closing the read `FileHandle` from an actor method while
another task is suspended in `next()` on the same actor makes `next()` return
`nil` promptly with no exception (and proves `await next()` releases the actor);
awaiting an unstructured `Task`'s `.value` is not interrupted by the awaiter's
cancellation; a `Task { [self] in … }` inside the `withTaskCancellationHandler`
operation closure of a `public actor` compiles in Swift 5 mode.

## Goal

No two searches ever interleave on one child process. A search whose awaiting
task is cancelled aborts — with `stop` if `go` was already sent, before `go`
otherwise — leaves the child alive and aligned, and the next search proceeds on
the same child. When `timeoutSeconds` is non-nil, every `analyze` call completes
within it or throws: the clock runs from entry and covers queue wait, restart,
handshake and search; a timed-out search kills the child it was using and the
next call restarts one. Every teardown acts only on the child generation it
belongs to.

## Acceptance criteria (tests unless marked; fake = `FakeUCIEngine` upgraded per Tier 4)

- B1 Three `analyze` calls started concurrently (`async let`; fake delay 20 ms;
  `go depth 3`, `go depth 5`, `go depth 7`) all complete, each with exactly one
  line at the depth it asked for. Order-agnostic log check: the command log
  contains three `go` lines and three `<bestmove` lines, and between any `go`
  and the next `<bestmove` there is no other `go`. Child pid unchanged.
- B2 `extraLineAfterBestmove: true` (a PARSEABLE stale line
  `info depth 99 multipv 2 score cp 999 nodes 1 nps 1 pv a2a3` after `bestmove`;
  the fake answers `isready` only after its search subshell has exited, so the
  stale line always precedes `readyok`). Three sequential `analyze` calls each
  return exactly one line at their own depth with `cp 10`.
- B3 Cancel during a search: `go depth 200`, delay 50 ms; the test waits until
  the log contains `go` (poll, ≤3 s), then cancels the awaiting task. The task
  ends with `CancellationError` within 3 s; the log contains `stop` and exactly
  one `<bestmove`; pid unchanged; the next `analyze` on the same actor returns
  its own depth.
- B3b Cancel during preparation: fake `uciDelayMs: 1500` (the child sleeps
  before answering `uci`); the test waits until the log contains `uci`, then
  cancels. `CancellationError` within 3 s; the log has no `go`; the child is
  still running (pid non-nil, unchanged); the next `analyze` (same actor)
  completes on the same pid (the handshake finishes on its own; the second
  call finds a handshaken child).
- B4 Cancel while queued (`go depth 7` queued behind a slow search): the log
  never shows `go depth 7`; the queued task ends with `CancellationError`; the
  running search's result is unaffected. And B4b: a task cancelled BEFORE it
  calls `analyze` on an IDLE actor gets `CancellationError` and the log stays
  empty (no `uci`, no `go`).
- B5 Timeout during a search (`timeoutSeconds: 0.5`, delay 100 ms, `go depth 100`):
  `.timeout` within 3 s; the next `analyze` succeeds on a NEW pid.
- B5b Timeout during the handshake (`uciDelayMs: 2000`, `uciDelayOnlyOnce: true`,
  `timeoutSeconds: 0.5`): `.timeout` (NOT `startFailed`) within 3 s; the next
  `analyze` succeeds on a new pid (the second child answers `uci` at once).
- B6 Timeout while queued: search 1 slow (delay 50 ms, depth 200) on an actor
  with `timeoutSeconds: 0.5`; search 2 queued immediately. Both throw
  `.timeout`; the log never shows a second `go`; the next `analyze` succeeds
  on a new pid.
- B7 Child killed mid-search with a second `analyze` queued: search 1 throws
  `engineGone`; search 2 restarts the child and succeeds; pids differ.
  (Robustness only — under the slot, search 2's child does not exist when
  search 1 tears down, so this cannot discriminate generation keying; see
  Decisions.)
- B8 Handshake failure with a queued caller (`exitBeforeUCI`): both calls
  throw `startFailed` within the bound — the slot is released on handshake
  failure, nothing hangs.
- B9 Item 1's A1–A6 including A3b (`EngineProcessTests`) against the upgraded
  fake, and the 35 pre-existing tests, still pass.
- B10 (manual, §5, and item 3's acceptance — NOT this item's) Variations →
  Analyze → select a node → make a board move → Analyze: a fresh tree.

## Design

Tiers 1–3 are ONE atomic change (each is inert without the others; the tier
headings are exposition and review order, not increments). Tier 4 lands first
in the same commit series only if the implementer prefers — B9 is its gate.

### Tier 1 — one child, one iterator, generation-keyed

```swift
private struct Child {
    let generation: Int
    let process: Process
    let writer: EngineStdinWriter
    let reader: FileHandle
    var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator   // the ONE iterator, for the child's whole life
    var handshaken = false
    var exited = false          // terminationHandler (pid-keyed), or killChild
    var readerClosed = false    // killChild closed the read end; teardown must not close it again
}
private var child: Child?
private var generationCounter = 0
```

No `AsyncStream`, no detached reader task. The iterator is created once in
`startChild()` and stored; every consumer runs while holding the slot (Tier 2),
so there is exactly one consumer at any time; the pipe provides back-pressure.
The iterator's cancellation-awareness is irrelevant because the consuming task
is never cancelled (Tier 3).

`nextLine(generation:) async -> String?` — the ONLY place `next()` is called:

```swift
guard let current = child, current.generation == generation, !current.readerClosed else { return nil }
var it = current.lines
let line: String?
do { line = try await it.next() } catch { line = nil }        // closed/EBADF → EOF
if let still = child, still.generation == generation, !still.readerClosed { child!.lines = it }
return line
```

`startChild()` (sync): pipes; `EngineStdinWriter` (fcntl before `run`);
`Process` with `arguments`; `terminationHandler` → `Task { [weak self] in await self?.childDidExit(pid:) }`
(sets `exited`, `writer.markGone()`, keyed by pid); `run()` (failure →
`startFailed`); close the parent's copies; `generationCounter += 1`; assign
`child` (`handshaken == false`). Returns the generation.

`ensureChild(for ticket:) async throws -> Int`:
1. `if let c = child, c.exited || c.readerClosed || !c.process.isRunning { teardown(generation: c.generation) }`.
2. `if child == nil { _ = try startChild() }`.
3. `running!.generation = child!.generation` — recorded BEFORE any await, so
   `timeOut` can kill exactly the child this ticket uses.
4. If `!child!.handshaken`: `try send("uci")`, `try await drain(until: "uciok", generation:)`,
   `try send("isready")`, `try await drain(until: "readyok", generation:)`,
   `child!.handshaken = true`. Any error → `teardown(generation:)`, then
   `throw StockfishError.startFailed` — unless the ticket is timed out, which
   `performSearch`'s catch maps first (see Tier 3).
5. Return the generation.

`teardown(generation:)` (sync, idempotent, keyed): `guard let c = child, c.generation == generation`;
`c.writer.send("quit")` (no-op if gone); `c.writer.close()`;
`if !c.readerClosed { try? c.reader.close() }` (the THROWING `close()`, never
`closeFile()`); `if c.process.isRunning { c.process.terminate() }`; `child = nil`.

`killChild(generation:)` (sync, keyed; the timeout's escape): `guard let c = child, c.generation == generation, !c.readerClosed`;
`if c.process.isRunning { kill(c.process.processIdentifier, SIGKILL) }`;
`c.writer.markGone()`; `try? c.reader.close()`; `child!.readerClosed = true; child!.exited = true`.
Closing the read end guarantees the blocked `next()` returns even if a
grandchild holds the write end; SIGKILL guarantees the real Stockfish is gone;
`exited`+`readerClosed` guarantee `ensureChild` never reuses it and `nextLine`
never writes a stale iterator back.

Test accessors (kept — item 1's A5/A6 use them):
`childProcessIdentifierForTesting() -> Int32?` = `child?.process.processIdentifier`;
`isChildRunningForTesting() -> Bool` = `child?.process.isRunning ?? false`.

### Tier 2 — tickets, the slot, the clock, and latched signals

```swift
private enum Phase { case preparing, searching, finished }
private struct Running {
    let ticket: Int
    var phase: Phase = .preparing
    var generation: Int?          // the child this ticket uses, once known
    var timedOut = false          // latched by timeOut(ticket:)
    var cancelRequested = false   // latched by cancel(ticket:)
}
private var nextTicket = 0
private var running: Running?
private var waiters: [(ticket: Int, continuation: CheckedContinuation<Void, Error>)] = []
```

Tickets are monotonic and never reused; a signal for a ticket that is neither
waiting nor running is a no-op.

`analyze(fen:options:requireFullDepth:)`:

```swift
guard engineURL != nil else { throw StockfishError.notFound }
let ticket = nextTicket; nextTicket += 1
let clock: Task<Void, Never>? = timeoutSeconds.map { seconds in
    Task { [weak self] in
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) } catch { return }
        await self?.timeOut(ticket: ticket)
    }
}
defer { clock?.cancel() }
return try await withTaskCancellationHandler {
    try await acquireSlot(ticket: ticket)
    defer { releaseSlot(ticket: ticket) }
    try Task.checkCancellation()                                 // idle-path cancel (B4b): nothing has been sent yet
    let search = Task { [self] in                                // actor-isolated, UNSTRUCTURED: never cancelled
        try await self.performSearch(ticket: ticket, fen: fen, options: options, requireFullDepth: requireFullDepth)
    }
    let lines = try await search.value                           // not interrupted by the caller's cancellation
    try Task.checkCancellation()                                 // cancelled during the drain → CancellationError, child alive
    return lines
} onCancel: {
    Task { [weak self] in await self?.cancel(ticket: ticket) }
}
```

`acquireSlot(ticket:)`: if `running == nil` → `running = Running(ticket: ticket); return`.
Otherwise `try await withCheckedThrowingContinuation { c in if Task.isCancelled { c.resume(throwing: CancellationError()); return }; waiters.append((ticket, c)) }`.
(The check runs synchronously on the actor before the suspension, so an
`onCancel` that fired before the waiter existed cannot strand it. Removal from
`waiters` is the claim; exactly one party resumes each continuation.)

`releaseSlot(ticket:)`: `guard running?.ticket == ticket`; `running = nil`;
if `waiters` is non-empty: `removeFirst()`, `running = Running(ticket: next.ticket)`,
`next.continuation.resume()` — one synchronous actor step, no third caller can slip in.

`cancel(ticket:)`: waiter → remove, `resume(throwing: CancellationError())`.
Else `if running?.ticket == ticket { running!.cancelRequested = true; if running!.phase == .searching { try? send("stop") } }`.
A cancel in `.preparing` is LATCHED and honoured at the next checkpoint (Tier 3),
never dropped.

`timeOut(ticket:)`: waiter → remove, `resume(throwing: StockfishError.timeout)`.
Else `if running?.ticket == ticket, running!.phase != .finished { running!.timedOut = true; if let gen = running!.generation { killChild(generation: gen) } }`.
A ticket that has not yet chosen a child (`generation == nil`) kills nothing —
the latch makes its first checkpoint throw `.timeout` — so a healthy child left
by the previous search is never killed for a queue-wait timeout. A ticket
already `.finished` is left alone (its lines are returned; the child lives).

`checkSignals(ticket:) throws`: `guard let r = running, r.ticket == ticket else { throw StockfishError.engineGone }`;
`if r.timedOut { throw StockfishError.timeout }`; `if r.cancelRequested { throw CancellationError() }`.

**No public `stop()`.** Cancellation of the awaiting task is the abort primitive.

### Tier 3 — the search, in a task the caller cannot cancel

`performSearch(ticket:…)` (actor-isolated; runs inside the unstructured task):

```swift
var generation: Int?
do {
    try checkSignals(ticket: ticket)                              // (1) timed out / cancelled while queued-then-promoted: start nothing
    generation = try await ensureChild(for: ticket)               // INSIDE the do: a timeout during the handshake maps to .timeout below
    try checkSignals(ticket: ticket)                              // (2) after the handshake
    try send(setoption …); try send("isready"); try await drain(until: "readyok", generation: generation!)
    try checkSignals(ticket: ticket)                              // (3) stream aligned at readyok; a cancel latched during preparing throws HERE, before go
    try send("position fen …"); try send("go …")
    running!.phase = .searching
    var sawBestmove = false; var stopSent = false; var latest: [Int: EngineLine] = [:]
    while let line = await nextLine(generation: generation!) {
        if let info = parseInfo(line: line) { latest[info.multipv] = info }
        if requireFullDepth, targetDepth != nil, !stopSent, hasAllLinesAtDepth() { try send("stop"); stopSent = true }
        if line.hasPrefix("bestmove ") { sawBestmove = true; break }
    }
    running!.phase = .finished
    guard sawBestmove else { throw StockfishError.engineGone }
    return latest.values.sorted { $0.multipv < $1.multipv }
} catch {
    running?.phase = .finished
    if running?.ticket == ticket, running!.timedOut {             // precedence: timeout beats everything
        if let generation { teardown(generation: generation) }
        throw StockfishError.timeout
    }
    if error is CancellationError { throw error }                // thrown only at (1)–(3): child alive and aligned
    if error is StockfishError, let generation { teardown(generation: generation) }   // engineGone / startFailed: this generation only
    throw error
}
```

`drain(until:generation:)`: loop `nextLine`; return on the target line; `nil`
→ `throw StockfishError.engineGone` (the handshake caller maps it to
`startFailed`; the per-search `readyok` correctly reports `engineGone`). Lines
drained before `readyok` are discarded — B2's stale line goes there.

Error precedence, total and ordered: `.timeout` (ticket latched) → `startFailed`
(handshake) → `engineGone` (EOF without `bestmove`) → lines; then, in `analyze`,
`CancellationError` if the caller was cancelled.

Where `CancellationError` can surface today: only `expandTreeChunk`
(`AppViewModel.swift:837-841`) catches `analyze`'s errors, and it guards on
`treeToken`. At `:213-218` and `:670-678` the token is replaced BEFORE the
cancel; at `:274-279` the cancel comes first and the token is replaced five
lines later — safe only because `AppViewModel` is `@MainActor` and there is no
suspension point between the two, so the cancelled task cannot observe the
interval. **The invariant item 3 must keep: a cancel site replaces `treeToken`
in the same synchronous main-actor step as the `cancel()`**, or filters
`CancellationError` explicitly. Otherwise the status bar would show
"The operation couldn't be completed. (Swift.CancellationError error 1.)" —
a UI change. Written into item 3's TODO entry by `/done` of this item.

### Tier 4 — test double upgrade (`PawnPilotTests/FakeUCIEngine.swift`)

Changes:
- **Command log** `LOG` (`scriptURL.path + ".log"`): every received line is
  appended; the search subshell appends `<bestmove` right before printing
  `bestmove`. `Launch` gains `commandLog() -> [String]` and `cleanUp()` also
  removes the log and the STOP marker.
- `go depth N` is honoured; `go movetime`/bare `go` use the baked `depth`.
- The search runs in a background subshell; the main loop keeps reading stdin.
  `stop` touches a STOP marker; the subshell checks it after each info line
  and then prints `bestmove` exactly once. `go` removes the marker and `wait`s
  for any previous subshell first. `isready` ALSO `wait`s for a finished
  subshell before answering, so a trailing stale line always precedes
  `readyok` (B2 determinism). `quit`/EOF touch STOP, wait, exit.
- **Parent-liveness check** in the subshell loop (`kill -0 $MAIN`): after the
  main shell is killed AND reaped by Foundation (milliseconds), the subshell
  exits within one delay, so EOF arrives promptly (B5, B7, A5).
- `uciDelayMs` (+ `uciDelayOnlyOnce` via the marker file) sleeps before
  answering `uci` — a long, deterministic preparing/handshake window (B3b, B5b).
- `extraLineAfterBestmove` prints `info depth 99 multipv 2 score cp 999 nodes 1 nps 1 pv a2a3`.
- **Swift-literal hygiene:** the script lives in a Swift `"""` literal, so the
  shell pattern is written `*"depth "*)` (no backslash-space, which is an
  invalid Swift escape) and `printf '%s\\n'` uses `\\n`.

```sh
#!/bin/sh
LOG="…"; STOP="…"; MARKER="…"; MAIN=$$
if [ EXIT_BEFORE_UCI -eq 1 ]; then exit 2; fi
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$LOG"
  case "$line" in
    uci)
      if [ UCI_DELAY_MS -gt 0 ]; then
        if [ UCI_DELAY_ONCE -eq 0 ] || [ ! -f "$MARKER" ]; then touch "$MARKER"; sleep UCI_DELAY_S; fi
      fi
      echo "id name FakeUCI"; echo "id author PawnPilotTests"; echo "uciok" ;;
    isready)
      if [ -n "$SEARCH_PID" ]; then wait "$SEARCH_PID"; SEARCH_PID=""; fi
      echo "readyok" ;;
    go*)
      if [ EXIT_ON_GO -eq 1 ]; then
        if [ ONCE -eq 0 ] || [ ! -f "$MARKER" ]; then touch "$MARKER"; exit 3; fi
      fi
      if [ -n "$SEARCH_PID" ]; then wait "$SEARCH_PID"; SEARCH_PID=""; fi
      rm -f "$STOP"
      case "$line" in *"depth "*) n=${line##*depth }; n=${n%% *} ;; *) n=DEPTH ;; esac
      (
        d=1
        while [ "$d" -le "$n" ]; do
          echo "info depth $d multipv 1 score cp 10 nodes 100 nps 1000 pv e2e4 e7e5"
          if [ -f "$STOP" ]; then break; fi
          if ! kill -0 "$MAIN" 2>/dev/null; then exit 0; fi
          if [ DELAY_MS -gt 0 ]; then sleep DELAY_S; fi
          d=$((d+1))
        done
        printf '%s\n' "<bestmove" >> "$LOG"
        echo "bestmove e2e4 ponder e7e5"
        if [ EXTRA -eq 1 ]; then echo "info depth 99 multipv 2 score cp 999 nodes 1 nps 1 pv a2a3"; fi
      ) &
      SEARCH_PID=$! ;;
    stop) touch "$STOP" ;;
    quit) touch "$STOP"; if [ -n "$SEARCH_PID" ]; then wait "$SEARCH_PID"; fi; exit 0 ;;
    *) ;;
  esac
done
touch "$STOP"; if [ -n "$SEARCH_PID" ]; then wait "$SEARCH_PID"; fi
exit 0
```

(`MARKER` is shared by `exitOnGoOnlyOnce` and `uciDelayOnlyOnce`; a script
uses at most one of them.) Item 1's tests: A3/A6 (`exitOnGo`) exit before any
subshell; A3b/A4 unchanged; A5 kills the fake AFTER its search finished, so
EOF is immediate and `isChildRunningForTesting()` stays deterministic.

### Tier 5 — `PawnPilotTests/EngineSerializationTests.swift`: B1–B8

Every wait bounded (`timeoutSeconds:` ≤ 5 s on every actor; "within 3 s"
assertions against fake delays of 20–100 ms; log polling with ≤3 s deadlines
and 20 ms sleeps). Each test registers `addTeardownBlock { launch.cleanUp() }`.
Log assertions read `launch.commandLog()`.

## Interfaces between tiers

- Tier 1 → 2, 3: `Child`, `nextLine(generation:)`, `startChild()`, `ensureChild(for:)`,
  `teardown(generation:)`, `killChild(generation:)`, `send(_:)` (item 1's),
  and the two `…ForTesting()` accessors (item 1's tests).
- Tier 2 ↔ 3: `performSearch(ticket:…)` runs only while `running?.ticket == ticket`;
  `checkSignals(ticket:)`; `Running.generation` is written by `ensureChild`.
- Tier 4 → 5, and → item 1's tests (compatibility constraint above).
- `EngineAnalyzing`, the initialiser, `AppViewModel`: unchanged.

## Load-bearing assumptions

- (Probe-verified, round 2) the stored iterator; close-under-read → `nil`;
  `.value` uninterruptible; the Task-in-closure compiles.
- `Process.terminationHandler` fires without `waitUntilExit` — item 1's A5.
- Foundation reaps a SIGKILLed child within milliseconds (so the fake's
  `kill -0 $MAIN` fails and its subshell exits within one delay). If slower:
  B5 still passes (the actor closed its read end in `killChild`, so its loop
  does not wait for EOF); B7 — where the TEST kills the child and the actor
  waits for EOF — would fail cleanly with `.timeout` at its 5 s clock instead
  of `engineGone` (behaviour review, finding 8). The edge review measured the
  reap at milliseconds and the recovery paths at 2.3× headroom under 10× CPU
  load; the recovery clocks were raised from 0.5 s to 1 s anyway.
- `timeoutSeconds == nil` disables the clock entirely (the initialiser allows
  it; production passes 300). The Goal's bound applies only when non-nil.

## Out of scope (explicit)

- Retiring `StockfishEngine`, one actor for all three modes — `(engine-consolidate)`.
- Storing the view model's tasks, cancelling them, `isEngineThinking`, the
  `treeToken` invariant at new cancel sites — `(view-model-task-ownership-and-cancel)`;
  the manual repro B10 is that item's acceptance.
- Retry-after-death inside `analyze` (item 1 decision stands).
- Re-queuing a dropped tree expansion — `(tree-selection-expansion-dropped-while-busy)`.
- A public `stop()`; a queue cap or newest-wins policy (item 3 empties the
  queue by cancelling superseded callers).
- An fd-leak census across restarts (round 2 G4): no oracle within reach that
  is not itself flaky; `readerClosed` + the throwing `close()` are the
  discipline, reviewed not measured.

## Decisions taken

- 2026-09-01 · **Rev 1 → Rev 2** on the round-1 review: an `AsyncStream`
  consumed inside the caller's task terminates on cancellation, so "stop,
  drain to `bestmove`, keep the child" was impossible as designed. Rev 2: no
  stream; one stored `bytes.lines` iterator per child, consumed by an
  unstructured actor task that is never cancelled.
- 2026-09-01 · **Rev 2 → Rev 3** on the round-2 review (Tier 1 mechanism and
  the slot were probe-verified sound; the signals were honoured in one of
  three phases): per-ticket LATCHED `timedOut`/`cancelRequested` in a `Running`
  record, checked at three checkpoints; `ensureChild` inside the `do` so a
  handshake timeout maps to `.timeout`; `Running.generation` recorded before
  any await so `timeOut` kills exactly the child in use and never a healthy
  child left by the previous search; `Task.checkCancellation()` on the idle
  path; `killChild` marks `exited`/`readerClosed`/`markGone` and `ensureChild`
  tests all three; `.finished` phase ignores a late clock; B1 order-agnostic;
  B3 synchronised on the log; B3b/B5b via a slow-handshake fake option; B2
  made deterministic by `isready` waiting for the subshell; the `:274-279`
  trace corrected and the real invariant handed to item 3; the test accessors
  listed as an interface; the Swift-literal escape fixed; premise line
  numbers corrected.
- 2026-09-01 · No third plan-review round. Two rounds found the mechanism
  sound and the residual defects all in signal handling, which Rev 3 closes
  with a uniform latch-and-checkpoint rule. The hi-tier code review (both
  reviewers) is the next net, and it sees the real code. Alternative: a
  third round at ~30 min. Rejected as diminishing returns on a plan.
- 2026-09-01 · The timeout clock starts at `analyze` entry and covers queue
  wait, restart, handshake and search; its escape is `killChild` (SIGKILL +
  close the read end), independent of EOF. No task group.
- 2026-09-01 · No public `stop()` (deviates from the TODO's direction). A
  `stop()` that cannot name its search would let a stale abort from the view
  model truncate a newer search silently; task cancellation is ticket-keyed
  and is the primitive item 3 and `(engine-consolidate)` will use.
- 2026-09-01 · Cancellation → `CancellationError`, never partial lines. A
  cancel before `go` throws at a checkpoint with the child alive and the
  stream aligned at `readyok`; a cancel after `go` sends `stop`, drains to
  `bestmove`, then throws in `analyze`.
- 2026-09-01 · FIFO kept. A queued caller waits for the running search but
  never longer than its own clock; item 3 empties the queue by cancelling
  superseded callers. Between the two items a stale selection expansion
  queues instead of interleaving — a latency, not a stall, and strictly
  better than F2. **Its size (corrected by the behaviour review):** the
  instantaneous queue depth is ≈ one entry (`guard !isTreeAnalyzing`), but
  `expandTreeChunk`'s retry loop (`AppViewModel.swift:803-814`) re-checks
  `treeToken` only AFTER its up-to-three attempts, so one stale expansion can
  occupy the slot for up to three full searches. Item 3 must re-check the
  token between attempts as well as cancel the task.
- 2026-09-01 · Cancel-drain is bounded by the clock: a child that ignores
  `stop` is killed at `timeoutSeconds`. Accepted knowingly.
- 2026-09-01 · Generation keys on `teardown`/`killChild`/`childDidExit` are
  belt-and-braces: under the slot no test can reach a cross-generation
  teardown (round 2, D6). Kept because they are cheap and they protect
  against the next reentrancy bug; B7 is a robustness test, not a keying test.
- 2026-09-01 · No `/arch-review`: no public method is added, `analyze`'s
  error set is `StockfishError` plus Swift's `CancellationError` (which any
  `async throws` caller must tolerate), and the liveness contract is
  strengthened, not changed. The structural question raised in round 1 —
  whether `stop()` is the right primitive — is answered by not adding it.
- 2026-09-01 · Tiers 1–3 ship as one commit; the plan's tier split is for
  reading, not for staged reverts (round 2, T1).
- 2026-09-01 · **Code review (both reviewers: ship) — accepted and fixed:**
  a `deinit` closes the child's stdin/stdout and terminates it (`Process`
  self-retains while running, so dropping the actor otherwise orphans one
  `/bin/sh` per test actor and recreates `.stop`/`.log` after `cleanUp()`);
  the fake no longer writes markers after EOF or on `quit` (an in-flight
  subshell exits via the parent-liveness check instead); `cancel`'s `stop`
  is generation-keyed like every other write; a line read after `killChild`
  closed the read end is treated as EOF, so a buffered `bestmove` cannot let
  a timed-out search return lines and skip its teardown; B3b asserts the
  handshake was not redone; recovery clocks 0.5 s → 1 s.
- 2026-09-01 · **Recorded, not changed:** a child that ignores `stop` holds
  the FIFO slot until the clock (300 s in production) and the cancelling
  caller then gets `.timeout`, not `CancellationError` — item 3 must not
  assume "cancel ⇒ prompt" for a wedged engine. A per-search `readyok` EOF
  now reads "Stockfish engine exited unexpectedly." where it read "Stockfish
  failed to launch." — a correction on a failure path, consistent with item
  1's `engineGone` decision. A handshake that fails on its own while the
  caller is being cancelled reports `startFailed`, not `CancellationError`
  (the latched cancel is consulted only at checkpoints). Checkpoint (1) and
  the queued-ness of B8's second caller are not deterministically exercised;
  both are defence in depth behind checkpoints (2)/(3) and B6.
