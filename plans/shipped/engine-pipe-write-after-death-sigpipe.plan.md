# Plan: (engine-pipe-write-after-death-sigpipe)

Rev 1 · 2026-09-01 · tier **standard** (process/lifetime surface; bounded diff
in two engine files plus a new test helper; no view-model or UI reach — not
`hi` because the change is confined to the write path and teardown of two
types, and the actor's concurrency model is deliberately left to
`(persistent-engine-serialize-searches)`).

Source: TODO.md §0 item 1; evidence `arch-reviews/2026-09-01-stability-performance.md` F1.

## Premise re-derived against the tree (368304f)

All F1 citations hold verbatim in this tree:

- `StockfishEngine.swift:68-72` — nested `send` uses legacy `FileHandle.write(_:)`
  (raises `NSFileHandleOperationException` on any write error, and the write
  itself raises SIGPIPE when the reader is gone).
- `:91-96` — `defer { send("quit"); writer.closeFile(); reader.readabilityHandler = nil; process.terminate() }`
  runs after the read loop ended; `:99-106` the timeout task calls
  `process.terminate()`, which produces the EOF that ends the loop. So every
  timeout, and every child that dies (at launch or mid-search), reaches the
  `quit` write against a dead pipe.
- Latent extra: the timeout task does `try? await Task.sleep(...)` and then
  unconditionally `fire()` + `terminate()` — so when the search finishes first
  and the task is cancelled, it STILL fires and terminates. Harmless today
  only because `runEngine` has already returned.
- `PersistentStockfishEngine.swift:120-135` — `ensureProcess` starts a child
  only `if process == nil`; a dead child is never replaced. `:166-171`
  `shutdownProcess` writes `quit` with the legacy API. `:62-66` per-search
  `send` also legacy. `:78` the first write of every search is `setoption`.
- No `SIGPIPE`, `F_SETNOSIGPIPE`, `write(contentsOf:)` anywhere under `PawnPilot/`.
- No unit test touches either engine (`PawnPilotTests.swift` has 35 methods,
  none engine-related).

## Goal

A Stockfish child that has exited — by timeout, by crash, at launch, or by
being killed — can never crash the app through the engine's stdin. Every such
case surfaces as a thrown `StockfishError`, and the persistent engine starts a
fresh child on the next `analyze`.

## Acceptance criteria (each is a test unless marked)

- A1 `EngineStdinWriter` unit test: spawn `/bin/cat` with a `Pipe` on stdin,
  wrap the write end, `terminate()` cat and `waitUntilExit()`, then
  `send("quit")`. The test process survives; `send` returns `false`; `isGone`
  is `true`; a second `send` returns `false` without touching the descriptor.
- A2 One-shot `StockfishEngine(engineURL: <real binary>, timeoutSeconds: 0.1)`
  with `EngineOptions(multiPV: 1, movetimeMs: 10_000, depth: nil)` throws
  `StockfishError.timeout`; no crash. (Real binary: located exactly as
  `AppViewModel.findEngineURL(in: .main)` does — make that function internal
  and reuse it; the test FAILS, not skips, when it is missing, because a green
  run is the bundle-layout proof per CLAUDE.md.)
- A3 One-shot engine against the fake UCI child configured to exit on `go`
  throws `StockfishError.engineGone` (uciok was seen, then EOF without
  `bestmove`); no crash.
- A4 One-shot engine against a fake that exits BEFORE answering `uci` throws
  `StockfishError.startFailed` — the launch-death route from the verifier note.
- A5 Persistent engine: `analyze` against the fake succeeds; kill the child
  with SIGKILL (pid via an internal test accessor), wait until the actor
  reports the child not running; `analyze` again succeeds on a fresh child
  (different pid). No crash.
- A6 Persistent engine against the exit-on-`go` fake: `analyze` throws
  `engineGone`; the following `analyze` (fake reconfigured healthy — a NEW
  engine URL is fine, the point is the actor restarts) succeeds.
- A7 Existing 35 tests still pass; `git grep -n 'readabilityHandler\|writer.write(\|\.write(data)'` under `PawnPilot/` finds nothing.
- A8 (manual, §5 `(sitting-sigpipe-timeout)`, optional) depth 30 + strict +
  Lines 10 → "Engine timed out while searching." instead of a quit.

## Design

### Tier 1 — `EngineStdinWriter` (new, `PawnPilot/NextMoveModels/Engine/EngineStdinWriter.swift`)

One owner per pipe. Marked `nonisolated final class` (the file is compiled
under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the persistent engine is an
actor and must call it synchronously). Not `Sendable`; single owner only —
never capture it in a `Task {}` or `onCancel` closure.

```swift
import Foundation

/// Owns the write end of a child's stdin pipe. After the first failed write
/// (EPIPE: the child is gone), after `markGone()`, or after `close()`, every
/// further `send` is a no-op returning `false`. Never raises SIGPIPE: the
/// descriptor is flagged `F_SETNOSIGPIPE` (local to this fd — no global
/// `signal()` handler). Never raises an ObjC exception: uses the throwing
/// `write(contentsOf:)`.
nonisolated final class EngineStdinWriter {
    private let handle: FileHandle
    private(set) var isGone = false
    private var isClosed = false

    init(handle: FileHandle) {
        self.handle = handle
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Writes `command` + "\n". Returns `false` if the engine is gone.
    @discardableResult
    func send(_ command: String) -> Bool {
        guard !isGone, !isClosed, let data = (command + "\n").data(using: .utf8) else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            isGone = true       // EPIPE or any other write failure: treat as gone
            return false
        }
    }

    /// The reader saw EOF or the child was observed to exit.
    func markGone() { isGone = true }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }
}
```

Revert: delete the file (no other tier compiles without it, so revert is
all-or-nothing with Tier 2). Pays off only with Tier 2.

### Tier 2 — `StockfishEngine.runEngine`

- Create `writer = EngineStdinWriter(handle: stdinPipe.fileHandleForWriting)`
  BEFORE `process.run()` (the fcntl must precede any write; before/after `run`
  does not matter for the flag itself, but keep it first so no write can ever
  precede it).
- `send` becomes `writer.send(_)`; keep the nested `func send(_:)` name so
  `apply(options:send:)` is untouched.
- Track `var sawBestmove = false` (set in the `bestmove` branch before `break`).
- After the loop: `if !sawBestmove { writer.markGone() }` — the loop ended on
  EOF, the child is gone.
- Error precedence after the loop:
  1. `timeoutBox.isFired()` → `.timeout` (unchanged).
  2. `!sawBestmove && !gotUciOK` → `.startFailed` (died at launch).
  3. `!sawBestmove` → `.engineGone`.
  4. else return lines (unchanged).
- `defer` becomes: `writer.send("quit")` (no-op if gone), `writer.close()`,
  `if process.isRunning { process.terminate() }`. Drop the dead
  `reader.readabilityHandler = nil`.
- Timeout task: `do { try await Task.sleep(...) } catch { return }` so a
  cancelled timer neither fires nor terminates. Keep the existing
  `defer { timeoutTask?.cancel() }`.
- Throwing a timeout INSIDE the loop (the `isFired` check at the top) is
  unchanged — the defer is now safe whether or not the child is still alive.

Revert: `git revert` of the tier's commit; nothing else depends on it.
Pays off alone (A2–A4).

### Tier 3 — `PersistentStockfishEngine`

Scope discipline: this tier changes ONLY write safety, liveness, and restart.
It does not touch the reentrancy, the per-search `bytes.lines` iterators, or
cancellation-vs-teardown — those are `(persistent-engine-serialize-searches)`.

- Replace `private var writer: FileHandle?` with `private var writer: EngineStdinWriter?`.
- Add `private var childExited = false` and an internal `enum` is NOT needed;
  keep it a flag. Set it from `process.terminationHandler`:
  ```swift
  process.terminationHandler = { [weak self] exited in
      let pid = exited.processIdentifier
      Task { await self?.childDidExit(pid: pid) }
  }
  ```
  `childDidExit(pid:)` (actor-isolated, private): `if process?.processIdentifier == pid { childExited = true; writer?.markGone() }`.
  (Compare by pid, not object identity — `Process` is not `Sendable`.)
- `startProcess`: set `writer = EngineStdinWriter(handle: stdinPipe.fileHandleForWriting)`
  before `run()`; reset `childExited = false` after a successful `run()`.
- `ensureProcess`:
  ```swift
  if let process, childExited || !process.isRunning {
      shutdownProcess()          // dead child: tear down so we start fresh
  }
  if process == nil { try startProcess() }
  if !didHandshake { ... handshake via `try send("uci")` / `try send("isready")` ... }
  ```
- New actor-isolated `private func send(_ command: String) throws`:
  `guard let writer, writer.send(command) else { throw StockfishError.engineGone }`.
  Every write site (`:62-66`, `:78-97`, `:126-132`) goes through it — the
  nested `send` in `runSearch` is deleted and its callers become `try send(...)`.
- `runSearch`: after the `for try await` loop, if the loop ended without a
  `bestmove` line, `writer?.markGone(); childExited = true;` and throw
  `.engineGone` (today it silently returns partial lines — that is the
  "engine died mid-search" case F1 describes; returning `[]` there shows the
  misleading "Engine returned no lines."). Track with `var sawBestmove`.
- `shutdownProcess`: `writer?.send("quit")` (no-op when gone), `writer?.close()`,
  `reader?.closeFile()` (keep), `if let process, process.isRunning { process.terminate() }`,
  then nil everything, `didHandshake = false`, `childExited = false`. Drop the
  dead `readabilityHandler = nil`.
- Test accessors (internal, actor-isolated, `// for tests` comment):
  `func childProcessIdentifierForTesting() -> Int32?` and
  `func isChildRunningForTesting() -> Bool` (`process?.isRunning ?? false`).

Revert: revert the tier's commit; Tier 2 stands alone. Pays off alone (A5–A6).

### Tier 4 — `StockfishError.engineGone` + strings

- `case engineGone` with `errorDescription` =
  `String(localized: "Stockfish engine exited unexpectedly.")`.
- Add the key to all nine `*.lproj/Localizable.strings` next to
  "Stockfish failed to launch." (translations: de "Die Stockfish-Engine wurde
  unerwartet beendet.", es "El motor Stockfish se cerró inesperadamente.",
  fr "Le moteur Stockfish s’est arrêté de façon inattendue.", it "Il motore
  Stockfish si è chiuso inaspettatamente.", ja "Stockfish エンジンが予期せず終了しました。",
  ko "Stockfish 엔진이 예기치 않게 종료되었습니다.", pt-BR "O mecanismo Stockfish foi
  encerrado inesperadamente.", zh-Hans "Stockfish 引擎意外退出。").
  This is a message on a path that previously crashed, not a change to
  existing copy — consistent with the UI-unchanged constraint.

Compiles only together with Tiers 2–3 (they throw it). Ship Tiers 1–4 as ONE
commit; they are one logical change. The tiers above are the review order,
not separate commits.

### Tier 5 — test double + tests (`PawnPilotTests/`)

`PawnPilotTests/FakeUCIEngine.swift` — a Swift test helper that WRITES a
`/bin/sh` script to a per-call temporary file (`FileManager.default.temporaryDirectory`,
unique name, `chmod 0o755`) and returns its URL. This absorbs
`(fake-uci-engine-test-double)` from §4: parameters are baked into the script
text, so no environment variables and no cross-test interference (the scheme
has `parallelizable = "YES"`).

```swift
enum FakeUCIEngine {
    struct Script {
        var depth = 3                    // info lines emitted per `go`
        var infoDelayMs = 0              // sleep between info lines
        var extraLineAfterBestmove = false
        var exitOnGo = false             // child exits with status 3 instead of searching
        var exitBeforeUCI = false        // child exits immediately (launch-death route)
    }
    static func makeExecutable(_ script: Script = Script()) throws -> URL
}
```

Script behaviour (synchronous `go` — `stop` after a finished search is a
no-op, as in real Stockfish; `stop` is NOT responsive mid-search in this
revision — `(persistent-engine-serialize-searches)` may extend it):

```sh
#!/bin/sh
# Generated by PawnPilotTests/FakeUCIEngine.swift — do not edit by hand.
if [ EXIT_BEFORE_UCI -eq 1 ]; then exit 2; fi
while IFS= read -r line; do
  case "$line" in
    uci) echo "id name FakeUCI"; echo "id author PawnPilotTests"; echo "uciok" ;;
    isready) echo "readyok" ;;
    go*)
      if [ EXIT_ON_GO -eq 1 ]; then exit 3; fi
      d=1
      while [ $d -le DEPTH ]; do
        echo "info depth $d multipv 1 score cp 10 nodes 100 nps 1000 pv e2e4 e7e5"
        if [ DELAY_MS -gt 0 ]; then sleep DELAY_S; fi
        d=$((d+1))
      done
      echo "bestmove e2e4 ponder e7e5"
      if [ EXTRA -eq 1 ]; then echo "info string after-bestmove"; fi ;;
    quit) exit 0 ;;
    *) ;;
  esac
done
exit 0
```

(`DELAY_S` is the fractional seconds string, e.g. `0.05`; macOS `sleep`
accepts it.) Tokens in CAPS are substituted by the Swift helper.

`PawnPilotTests/EngineProcessTests.swift` — `final class EngineProcessTests: XCTestCase`
with A1–A6. A2 needs the real binary: mark that one test `@MainActor` and use
`AppViewModel.findEngineURL(in: .main)` (drop `private` on that static func —
the only `AppViewModel` edit in this item). Timeouts on every `await` (use
`timeoutSeconds:` on the engines, ≤ 5 s, so a regression fails fast rather
than hanging the suite).

Revert: delete the two test files and restore `private`. Pays off alone as
the regression net.

## Interfaces between tiers

- Tier 1 → 2, 3: `EngineStdinWriter.send/markGone/close/isGone`.
- Tier 4 → 2, 3: `StockfishError.engineGone`.
- Tier 3 → 5: the two `…ForTesting()` accessors.
- Tier 5 → `AppViewModel.findEngineURL` visibility.

## Load-bearing assumptions

- `FileHandle.write(contentsOf:)` throws (does not raise) on EPIPE and on a
  closed descriptor on this OS. If false for the closed case: `isClosed`
  guard already prevents the call. If false for EPIPE: A1 crashes the test
  process — and `F_SETNOSIGPIPE` + the throwing API is Apple's documented
  route, so this would be a platform bug; fallback would be `Darwin.write`
  directly. Small rewrite (the class body).
- `Process.isRunning`/`terminationHandler` observe exit without anyone
  calling `waitUntilExit` (NSTask watches the pid with a dispatch source).
  If false: A5's wait never completes → the test's deadline fails it; then
  poll `kill(pid, 0) == -1 && errno == ESRCH` instead. Small.
- The sandboxed test host may exec a shebang script from its temporary
  directory. If denied: bundle the script under `PawnPilotTests/Fixtures/`
  instead and parameterise by wrapper scripts. Medium (helper only).
- `Process.terminate()` on an already-exited process does not raise. Guarded
  by `isRunning` anyway.

## Out of scope (explicit)

- Any change to reentrancy, the reader design, `stop()`, cancellation
  teardown — `(persistent-engine-serialize-searches)`.
- Consolidating the two engines — `(engine-consolidate)`.
- Cancellation handling in `runEngine` — `(view-model-task-ownership-and-cancel)`.
- A `stop`-responsive fake; a Swift executable target for the fake.

## Decisions taken

- 2026-09-01 · Plan review skipped (standard tier, "genuinely simple" clause
  in ship.md): the direction is fully specified by F1 and the change is
  confined to two files' write/teardown paths. Code review by
  `adv-review-edge` is NOT skipped.
- 2026-09-01 · New error case `engineGone` rather than reusing
  `startFailed`: a mid-search death is not a launch failure, and the
  acceptance says "reports engine gone". Launch-death (EOF before `uciok`)
  keeps `startFailed`, matching the verifier's expectation.
- 2026-09-01 · EOF-without-`bestmove` now THROWS (`engineGone`) in both
  engines instead of returning partial lines. Alternative: keep returning
  the partial list. Rejected: it shows "Engine returned no lines." for a
  crash, and a partial MultiPV set from a dead engine is not a result.
- 2026-09-01 · The fake is a generated shell script, not an executable
  target or an env-var-configured script: no pbxproj target, and the scheme
  runs test classes in parallel so env vars would leak across tests.
- 2026-09-01 · No retry-on-death inside `analyze`. If the child dies and the
  actor has not yet observed it, that one call fails with `engineGone` and
  the next restarts. Simpler; the actor rewrite in the next item owns the
  policy. Recorded in the commit.
- 2026-09-01 · The one-shot engine is left MainActor-isolated (default). Its
  work is I/O-bound and suspends; moving it is `(engine-consolidate)`.
- 2026-09-01 · **Load-bearing assumption 3 was FALSE.** First gate run: A1, A2,
  A4 passed (no SIGPIPE; real-binary timeout → `.timeout`), but A3/A5/A6 got
  `startFailed`: the sandboxed test host cannot exec a script file written
  into its own container (while `/bin/cat` spawns fine — A1). Fix: both
  engines gain `arguments: [String] = []` (defaulted; `AppViewModel` call
  sites unchanged) and the fake is launched as `/bin/sh <script>`. Alternative
  rejected: bundling the script as a test resource — parameterisation would
  then need env vars, and whether a synchronized group copies `.sh` files as
  resources was unverified.
- 2026-09-01 · A6 strengthened after the implementer flagged it as weak: the
  fake gains `exitOnGoOnlyOnce` (a marker file next to the script), so the
  SAME actor is shown to throw `engineGone` and then recover on its next
  `analyze`. A3b added so a healthy fake conversation is asserted end-to-end
  (guards A3/A4 against passing for the wrong reason, which is exactly what
  happened in gate run 1).
- 2026-09-01 · Timeout task's `terminate()` guarded by `isRunning` (the
  implementer omitted the guard the plan specified).
