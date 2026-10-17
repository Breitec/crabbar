import Foundation
import Darwin

/// Spawns processes with an argument array (never through a shell string), in their own process group so a
/// hung `claude` can be killed together with its children. stdout and stderr go to temp files, as in the
/// original: waiting ends with the process itself, background children that keep the output open do not block.
final class Proc: @unchecked Sendable {
  struct Output: Sendable {
    var code: Int32
    var out: Data
    var err: Data
    var timedOut: Bool
    var text: String { String(decoding: out, as: UTF8.self) }
    var errText: String { String(decoding: err, as: UTF8.self) }
  }

  /// Headless helpers started by the app (claude -p probes, chat, tasks): not counted as user sessions.
  nonisolated(unsafe) static var own = Set<pid_t>()
  static let ownLock = NSLock()

  static func isOwn(_ pid: pid_t) -> Bool {
    ownLock.lock(); defer { ownLock.unlock() }
    return own.contains(pid)
  }

  let pid: pid_t
  private let outPath: String
  private let errPath: String

  private init(pid: pid_t, outPath: String, errPath: String) {
    self.pid = pid
    self.outPath = outPath
    self.errPath = errPath
  }

  nonisolated(unsafe) static var extraPath = ""

  static func environment(_ extra: [String: String] = [:]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let base = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    var parts = extraPath.split(separator: ":").map(String.init) + (env["PATH"] ?? "").split(separator: ":").map(String.init)
    for b in base where !parts.contains(b) { parts.append(b) }
    var seen = Set<String>()
    env["PATH"] = parts.filter { seen.insert($0).inserted }.joined(separator: ":")
    env["HOME"] = home
    env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
    env.removeValue(forKey: "CLAUDECODE")
    env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
    for (k, v) in extra { env[k] = v }
    return env
  }

  /// Children must not inherit the blocked signal mask of GCD worker threads.
  static func resetSignals(_ attr: inout posix_spawnattr_t?, flags: Int32) {
    var none = sigset_t()
    sigemptyset(&none)
    posix_spawnattr_setsigmask(&attr, &none)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for s in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGWINCH] { sigaddset(&defaults, s) }
    posix_spawnattr_setsigdefault(&attr, &defaults)
    posix_spawnattr_setflags(&attr, Int16(flags | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
  }

  static func spawn(_ exe: String, _ args: [String], cwd: String? = nil, stdin: Data? = nil,
                    env: [String: String] = [:]) throws -> Proc {
    let tmp = FileManager.default.temporaryDirectory
    let tag = UUID().uuidString.prefix(8)
    var inPath: String?
    if let stdin {
      let u = tmp.appendingPathComponent("clawd-in-\(tag).txt")
      try stdin.write(to: u)
      inPath = u.path
    }
    let outPath = tmp.appendingPathComponent("clawd-out-\(tag).txt").path
    let errPath = tmp.appendingPathComponent("clawd-err-\(tag).txt").path

    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    defer { posix_spawn_file_actions_destroy(&fa) }
    posix_spawn_file_actions_addopen(&fa, 0, inPath ?? "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, outPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_addopen(&fa, 2, errPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    if let cwd { posix_spawn_file_actions_addchdir_np(&fa, cwd) }

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    resetSignals(&attr, flags: POSIX_SPAWN_SETPGROUP)
    posix_spawnattr_setpgroup(&attr, 0)

    let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let envp: [UnsafeMutablePointer<CChar>?] = environment(env).map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { envp.forEach { free($0) } }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
    // The child opened stdin already (file actions run before exec), so the temp file can go now.
    if let p = inPath { try? FileManager.default.removeItem(atPath: p) }
    if rc != 0 {
      try? FileManager.default.removeItem(atPath: outPath)
      try? FileManager.default.removeItem(atPath: errPath)
      throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .ENOENT)
    }
    ownLock.lock(); own.insert(pid); ownLock.unlock()
    return Proc(pid: pid, outPath: outPath, errPath: errPath)
  }

  /// Waits for the process, killing its whole group after `timeout` seconds.
  func wait(timeout: TimeInterval) async -> Output {
    await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
      let pid = self.pid, outPath = self.outPath, errPath = self.errPath
      DispatchQueue.global(qos: .utility).async {
        let lock = NSLock()
        var timedOut = false
        let killer = DispatchWorkItem {
          lock.lock(); timedOut = true; lock.unlock()
          Darwin.kill(-pid, SIGTERM)
          DispatchQueue.global().asyncAfter(deadline: .now() + 3) { Darwin.kill(-pid, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        killer.cancel()
        Proc.ownLock.lock(); Proc.own.remove(pid); Proc.ownLock.unlock()
        let out = FileManager.default.contents(atPath: outPath) ?? Data()
        let err = FileManager.default.contents(atPath: errPath) ?? Data()
        try? FileManager.default.removeItem(atPath: outPath)
        try? FileManager.default.removeItem(atPath: errPath)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        lock.lock(); let t = timedOut; lock.unlock()
        cont.resume(returning: Output(code: code, out: out, err: err, timedOut: t))
      }
    }
  }

  func kill() {
    Darwin.kill(-pid, SIGTERM)
    let p = pid
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { Darwin.kill(-p, SIGKILL) }
  }

  static func run(_ exe: String, _ args: [String], cwd: String? = nil, stdin: Data? = nil,
                  timeout: TimeInterval = 60) async -> Output {
    do {
      let p = try spawn(exe, args, cwd: cwd, stdin: stdin)
      return await p.wait(timeout: timeout)
    } catch {
      return Output(code: -1, out: Data(), err: "\(error)".data(using: .utf8)!, timedOut: false)
    }
  }

  /// PATH from the user's login shell, so tasks can reach npx, gh, uvx and friends.
  static func loadLoginPath() async {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let r = await run(shell, ["-l", "-c", "printf %s \"$PATH\""], timeout: 8)
    let p = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if r.code == 0, !p.isEmpty, !p.contains("\n") { extraPath = p }
  }
}

/// A process on a pseudo terminal (Clawd's interactive `claude` session kept in the background). Its own
/// session and group; the reader thread owns and closes the master side.
final class PtyProc: @unchecked Sendable {
  let pid: pid_t
  private let lock = NSLock()
  private var reaped = false

  init(pid: pid_t, master: Int32) {
    self.pid = pid
    DispatchQueue.global(qos: .background).async {
      var buf = [UInt8](repeating: 0, count: 4096)
      while true {
        let n = read(master, &buf, buf.count)
        if n > 0 { continue }
        if n < 0 && errno == EINTR { continue }
        break
      }
      close(master)
    }
  }

  static func spawn(_ exe: String, _ args: [String], cwd: String) throws -> PtyProc {
    var m: Int32 = 0, s: Int32 = 0
    var ws = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&m, &s, nil, nil, &ws) == 0 else { throw POSIXError(.ENXIO) }
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    defer { posix_spawn_file_actions_destroy(&fa) }
    for fd: Int32 in 0...2 { posix_spawn_file_actions_adddup2(&fa, s, fd) }
    posix_spawn_file_actions_addchdir_np(&fa, cwd)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    Proc.resetSignals(&attr, flags: POSIX_SPAWN_SETSID)
    let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let envp: [UnsafeMutablePointer<CChar>?] = Proc.environment(["TERM": "xterm-256color"]).map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { envp.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
    close(s)
    if rc != 0 { close(m); throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .ENOENT) }
    return PtyProc(pid: pid, master: m)
  }

  /// True once the process has ended on its own (and is reaped now).
  func reap() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if reaped { return true }
    var st: Int32 = 0
    if waitpid(pid, &st, WNOHANG) == pid { reaped = true }
    return reaped
  }

  /// SIGTERM to the whole group, SIGKILL after 3 s, then reap.
  func terminate() {
    if reap() { return }
    Darwin.kill(-pid, SIGTERM)
    let p = pid
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
      lock.lock()
      let done = reaped
      lock.unlock()
      if done { return }
      Darwin.kill(-p, SIGKILL)
      var st: Int32 = 0
      while waitpid(p, &st, 0) == -1 && errno == EINTR {}
      lock.lock(); reaped = true; lock.unlock()
    }
  }
}
