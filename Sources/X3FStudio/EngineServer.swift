import Foundation

/// One `sppqd` process: SIGMA Photo Pro's Quattro engine behind a line protocol.
/// Requests are tab-separated `key=value` fields; the server answers one line per request.
/// The actor serialises access; a crashed or hung server is restarted on the next request.
actor EngineServer {
    enum Failure: LocalizedError {
        case notInstalled, engineUnavailable(String), failed(String), crashed, timeout, badReply
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "SIGMA Photo Pro 6 is not installed in /Applications. X3F Studio renders with its Quattro engine."
            case .engineUnavailable(let m): return "The SIGMA engine could not be started: \(m)"
            case .failed(let m): return m
            case .crashed: return "The SIGMA engine stopped unexpectedly."
            case .timeout: return "The SIGMA engine did not respond in time."
            case .badReply: return "Unexpected reply from the engine server."
            }
        }
    }

    struct Reply {
        var fields: [String: String]
        subscript(_ k: String) -> String? { fields[k] }
        func int(_ k: String) -> Int? { fields[k].flatMap { Int($0) } }
        func double(_ k: String) -> Double? { fields[k].flatMap { Double($0) } }
    }

    let name: String
    private let tmpDir: URL
    private let logURL: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [String: CheckedContinuation<Reply, Error>] = [:]
    private var starting: Task<Void, Error>?

    static let sigmaPhotoProURL = URL(fileURLWithPath: "/Applications/SIGMA_PhotoPro6.app")
    static var isSigmaPhotoProInstalled: Bool {
        FileManager.default.fileExists(atPath: sigmaPhotoProURL.appendingPathComponent("Contents/MonoBundle/Sensor/lib95_QuattroDLLForMac.dylib").path)
    }

    init(name: String, tmpDir: URL, logURL: URL) {
        self.name = name
        self.tmpDir = tmpDir
        self.logURL = logURL
    }

    // MARK: - Public requests

    /// Camera-recorded settings and geometry straight from the file (no engine needed).
    func info(of file: URL) async throws -> Reply {
        try await send("info", [("in", file.path)])
    }

    enum Mode {
        case quick(width: Int, height: Int)   // SPP's quick-display path: 8-bit, fast, at the size it is shown (≤ half)
        case full                             // SPP's 16-bit save path
    }

    struct RenderResult { var width: Int; var height: Int; var rotation: Int; var bytesPerPixel: Int; var engineMillis: Double }

    /// Parameter cells SIGMA Photo Pro 6.9 sets differently from the block our server was captured
    /// with (recorded with the shim in tools/sppcap and bisected on SDIM0433, 9 Nov 2026):
    /// the ghost-colour cell 536 is 0 in every SPP call although each X3F header says 1 (1 renders
    /// clipped highlights flat and cool); overexposure correction is off with its default level
    /// (448 = 0, 452 = 5, 464 = 5; on with level 0 it darkens highlights); the processing-version
    /// cells 42/46 are 2/3; chroma/luma noise reduction 240/248 are 0. Sent as raw pokes until the
    /// server's Quattro defaults carry them.
    /// Only what SIGMA Photo Pro itself always does to a Quattro request (ghost-colour correction off,
    /// processing version 2/3); overexposure correction and noise reduction follow the camera's header.
    static let quattroPokes = "536:u16:0;42:u16:2;46:u16:3"

    /// Which part of the sensor frame the engine develops.
    enum Frame {
        case camera            // the camera's own aspect-ratio crop (the default framing)
        case full              // the whole frame, for the crop tool
        case trim(CropRect)    // the user's crop
    }

    func render(file: URL, settings: SPPSettings, mode: Mode, engine: EngineKind, look: SPPColorAdjustment = SPPColorAdjustment(),
                frame: Frame = .camera, output: URL) async throws -> RenderResult {
        var fields: [(String, String)] = [("in", file.path), ("out", output.path)]
        switch frame {
        case .camera: fields.append(("crop", "1"))
        case .full: fields.append(("crop", "0"))
        case .trim(let c): fields += [("crop", "0"), ("trim", c.trimField)]
        }
        if engine == .quattro { fields.append(("set", EngineServer.quattroPokes + (look.isNeutral ? "" : ";" + look.pokes))) }
        else if !look.isNeutral { fields.append(("set", look.pokes)) }   // the Merrill engine takes the same colour grid cells
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        fields += [("exp", f(settings.exposure)), ("con", f(settings.contrast)), ("sha", f(settings.shadow)), ("hil", f(settings.highlight)),
                   ("sat", f(settings.saturation)), ("shp", f(settings.sharpness)), ("fill", f(settings.fillLight)),
                   ("wb", String(settings.whiteBalance)), ("cm", String(settings.colorMode))]
        switch mode {
        case .quick(let w, let h):
            fields += [("fmt", "rgb8"), ("desig", "0"), ("w", String(max(64, w & ~1))), ("h", String(max(64, h & ~1)))]
        case .full:
            fields += [("fmt", "tif"), ("desig", "5")]
        }
        let r = try await send("render", fields, timeout: 120)
        guard let w = r.int("w"), let h = r.int("h") else { throw Failure.badReply }
        return RenderResult(width: w, height: h, rotation: r.int("rot") ?? 0, bytesPerPixel: r.int("bpp") ?? 3, engineMillis: r.double("engine_ms") ?? 0)
    }

    func shutdown() {
        if let p = process, p.isRunning {
            try? stdin?.write(contentsOf: Data("quit\n".utf8))
            p.waitUntilExit()
        }
        cleanup(error: Failure.crashed)
    }

    // MARK: - Protocol

    private func send(_ cmd: String, _ fields: [(String, String)], timeout: TimeInterval = 60) async throws -> Reply {
        try await ensureRunning()
        let id = String(nextID); nextID += 1
        var line = cmd + "\tid=" + id
        for (k, v) in fields {
            guard !v.contains("\t"), !v.contains("\n") else { throw Failure.failed("Invalid characters in path") }
            line += "\t\(k)=\(v)"
        }
        line += "\n"
        guard let stdin else { throw Failure.crashed }
        let data = Data(line.utf8)

        let reply: Reply = try await withThrowingTaskGroup(of: Reply.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw Failure.crashed }
                return try await self.request(id: id, data: data, stdin: stdin)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            do {
                return try await group.next()!
            } catch Failure.timeout {
                await self.cleanup(error: Failure.timeout)
                throw Failure.timeout
            }
        }
        if reply["__status"] == "ok" { return reply }
        let msg = reply["msg"] ?? "Engine error"
        if msg.contains("SIGMA Photo Pro engine") || msg.contains("dlopen") { throw Failure.engineUnavailable(msg) }
        throw Failure.failed(msg)
    }

    /// Registers the reply continuation *before* the request is written, so a fast reply can't be missed.
    private func request(id: String, data: Data, stdin: FileHandle) async throws -> Reply {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Reply, Error>) in
            pending[id] = c
            do { try stdin.write(contentsOf: data) } catch {
                pending.removeValue(forKey: id)
                c.resume(throwing: Failure.crashed)
            }
        }
    }

    private func ensureRunning() async throws {
        if let p = process, p.isRunning { return }
        if let s = starting { try await s.value; return }
        let t = Task { try await self.launch() }
        starting = t
        defer { starting = nil }
        try await t.value
    }

    private func launch() async throws {
        guard EngineServer.isSigmaPhotoProInstalled else { throw Failure.notInstalled }
        guard let exe = Bundle.main.url(forResource: "sppqd", withExtension: nil) ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("sppqd"),
              let params = Bundle.main.url(forResource: "010_params", withExtension: "bin") ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("010_params.bin")
        else { throw Failure.engineUnavailable("engine server missing from the app bundle") }
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let p = Process()
        p.executableURL = exe
        p.arguments = [params.path]
        // The engine resolves some of its data relative to the working directory
        // (getcwd() + "/Contents/Resources/GData/…"); SIGMA Photo Pro's own host runs from the
        // app bundle root (measured with the recording shim in tools/sppcap), so mirror that.
        if FileManager.default.fileExists(atPath: EngineServer.sigmaPhotoProURL.path) { p.currentDirectoryURL = EngineServer.sigmaPhotoProURL }
        var env = ProcessInfo.processInfo.environment
        env["SPPQ_PARAMS"] = params.path
        env["TMPDIR"] = tmpDir.path
        env["SPPQD_VERBOSE"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.standardError
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.cleanup(error: Failure.crashed) }
        }
        buffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self else { return }
            Task { await self.consume(data) }
        }
        // start the process with the ready-line continuation already registered
        _ = try await withThrowingTaskGroup(of: Reply.self) { group -> Reply in
            group.addTask { [weak self] in
                guard let self else { throw Failure.crashed }
                return try await self.start(p, stdin: inPipe.fileHandleForWriting, stdout: outPipe.fileHandleForReading)
            }
            group.addTask { try await Task.sleep(nanoseconds: 15_000_000_000); throw Failure.timeout }
            defer { group.cancelAll() }
            do { return try await group.next()! } catch Failure.timeout { await self.cleanup(error: Failure.timeout); throw Failure.timeout }
        }
    }

    private func start(_ p: Process, stdin inFH: FileHandle, stdout outFH: FileHandle) async throws -> Reply {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Reply, Error>) in
            pending["__ready"] = c
            do {
                try p.run()
                process = p; stdin = inFH; stdout = outFH
            } catch {
                pending.removeValue(forKey: "__ready")
                c.resume(throwing: Failure.engineUnavailable(error.localizedDescription))
            }
        }
    }

    private func consume(_ data: Data) {
        if data.isEmpty { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        var parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return }
        let status = parts.removeFirst()
        var fields: [String: String] = ["__status": status]
        for p in parts {
            if let eq = p.firstIndex(of: "=") { fields[String(p[..<eq])] = String(p[p.index(after: eq)...]) }
        }
        if status == "ready" {
            pending.removeValue(forKey: "__ready")?.resume(returning: Reply(fields: fields))
            return
        }
        if status == "dbg" { return }
        guard let id = fields["id"], let c = pending.removeValue(forKey: id) else { return }
        c.resume(returning: Reply(fields: fields))
    }

    private func cleanup(error: Error) {
        stdout?.readabilityHandler = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil; stdin = nil; stdout = nil
        let waiting = pending; pending = [:]
        for (_, c) in waiting { c.resume(throwing: error) }
    }
}
