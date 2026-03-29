import Foundation
import os

/// Manages the local ASR Python server process.
/// On Apple Silicon: starts Qwen3-ASR server (MLX/Metal).
/// On Intel: starts SenseVoice server (ONNX/CPU).
actor SenseVoiceServerManager {
    static let shared = SenseVoiceServerManager()

    /// Whether this Mac has Apple Silicon (ARM64).
    private static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    /// Port of the running server, accessible synchronously from any isolation context.
    /// Set by actor-isolated `start()`, read by sync callers like KeychainService.
    nonisolated(unsafe) private(set) static var currentPort: Int?

    private let logger = Logger(subsystem: "com.type4me.sensevoice", category: "ServerManager")

    private var process: Process?
    private(set) var port: Int?
    private var stdoutPipe: Pipe?

    var isRunning: Bool { process?.isRunning ?? false }

    var serverWSURL: URL? {
        guard let port else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)/ws")
    }

    var healthURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/health")
    }

    /// Start the local ASR server (Qwen3-ASR on ARM64, SenseVoice on x86_64).
    func start() async throws {
        guard !isRunning else {
            logger.info("Server already running on port \(self.port ?? 0)")
            return
        }

        let proc = Process()
        var args: [String] = []

        if Self.isAppleSilicon {
            try configureQwen3Server(proc: proc, args: &args)
        } else {
            try configureSenseVoiceServer(proc: proc, args: &args)
        }

        // LLM model (optional, for local chat completions endpoint)
        if let llmPath = LocalQwenLLMConfig.modelPath {
            args += ["--llm-model", llmPath]
            logger.info("LLM model found at \(llmPath)")
        }

        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        // Log stderr to debug file instead of discarding
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let msg = String(data: data, encoding: .utf8) else { return }
            for line in msg.split(separator: "\n") where !line.isEmpty {
                DebugFileLogger.log("sensevoice-server: \(line)")
            }
        }
        self.stdoutPipe = pipe

        let serverType = Self.isAppleSilicon ? "Qwen3-ASR" : "SenseVoice"
        logger.info("Starting \(serverType) server: \(proc.executableURL?.path ?? "?")")

        do {
            try proc.run()
        } catch {
            logger.error("Failed to start server: \(error)")
            throw ServerError.launchFailed(error)
        }
        self.process = proc

        // Read PORT:xxxxx from stdout (with timeout)
        let portResult = await readPortFromStdout(pipe: pipe, timeout: 60)
        guard let discoveredPort = portResult else {
            proc.terminate()
            self.process = nil
            throw ServerError.portDiscoveryFailed
        }
        self.port = discoveredPort
        Self.currentPort = discoveredPort
        logger.info("SenseVoice server started on port \(discoveredPort)")

        // Wait for health check
        let healthy = await waitForHealth(timeout: 30)
        if !healthy {
            logger.warning("Server started but health check not responding yet")
        }
    }

    /// Stop the server process.
    func stop() {
        guard let proc = process else { return }
        if proc.isRunning {
            proc.terminate()
        }
        process = nil
        port = nil
        Self.currentPort = nil
        stdoutPipe = nil
        logger.info("SenseVoice server stopped")
    }

    /// Check if the server is healthy.
    nonisolated func isHealthy() async -> Bool {
        guard let url = await healthURL else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Private

    // MARK: - Qwen3-ASR (Apple Silicon)

    private func configureQwen3Server(proc: Process, args: inout [String]) throws {
        let serverScript: String
        let executable: String

        // Dev mode: qwen3-asr-server/.venv/bin/python + server.py
        // Production: bundled binary at Contents/MacOS/qwen3-asr-server
        let devDir = findDevServerDir(name: "qwen3-asr-server")
        if let dir = devDir {
            executable = (dir as NSString).appendingPathComponent(".venv/bin/python")
            serverScript = (dir as NSString).appendingPathComponent("server.py")
            guard FileManager.default.fileExists(atPath: executable) else {
                throw ServerError.venvNotFound
            }
        } else {
            let bundledBinary = Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("qwen3-asr-server")
                .path
            guard let bin = bundledBinary, FileManager.default.fileExists(atPath: bin) else {
                throw ServerError.serverNotFound
            }
            executable = bin
            serverScript = ""
        }

        // Model path: bundled or ModelScope cache
        guard let modelPath = resolveQwen3ModelPath() else {
            throw ServerError.modelNotFound
        }
        logger.info("Qwen3-ASR model: \(modelPath)")

        // Hotwords file (same as SenseVoice)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let hotwordsPath = appSupport
            .appendingPathComponent("Type4Me")
            .appendingPathComponent("hotwords.txt")
        let hotwordsFile = FileManager.default.fileExists(atPath: hotwordsPath.path) ? hotwordsPath.path : ""

        proc.executableURL = URL(fileURLWithPath: executable)
        if !serverScript.isEmpty {
            args.append(serverScript)
        }
        args += [
            "--model-path", modelPath,
            "--port", "0",
            "--hotwords-file", hotwordsFile,
        ]
        logger.info("Starting Qwen3-ASR server")
    }

    private func resolveQwen3ModelPath() -> String? {
        // 1. Bundled in app (production DMG)
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent("Qwen3-ASR")
        if let b = bundled, FileManager.default.fileExists(atPath: b.path) {
            return b.path
        }
        // 2. App Support (user-downloaded)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let userModel = appSupport
            .appendingPathComponent("Type4Me")
            .appendingPathComponent("Models/Qwen3-ASR")
        if FileManager.default.fileExists(atPath: userModel.path) {
            return userModel.path
        }
        // 3. ModelScope cache (dev fallback)
        let cache06 = NSHomeDirectory() + "/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-0.6B"
        if FileManager.default.fileExists(atPath: cache06) { return cache06 }
        let cache17 = NSHomeDirectory() + "/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-1.7B"
        if FileManager.default.fileExists(atPath: cache17) { return cache17 }
        return nil
    }

    // MARK: - SenseVoice (Intel fallback)

    private func configureSenseVoiceServer(proc: Process, args: inout [String]) throws {
        let serverScript: String
        let executable: String

        let devDir = findDevServerDir(name: "sensevoice-server")
        if let dir = devDir {
            executable = (dir as NSString).appendingPathComponent(".venv/bin/python")
            serverScript = (dir as NSString).appendingPathComponent("server.py")
            guard FileManager.default.fileExists(atPath: executable) else {
                throw ServerError.venvNotFound
            }
        } else {
            let bundledBinary = Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("sensevoice-server")
                .path
            guard let bin = bundledBinary, FileManager.default.fileExists(atPath: bin) else {
                throw ServerError.serverNotFound
            }
            executable = bin
            serverScript = ""
        }

        let bundledModel = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent("SenseVoiceSmall")
        let modelDir: String
        if let bundled = bundledModel, FileManager.default.fileExists(atPath: bundled.path) {
            modelDir = bundled.path
        } else {
            modelDir = "iic/SenseVoiceSmall"
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let hotwordsPath = appSupport
            .appendingPathComponent("Type4Me")
            .appendingPathComponent("hotwords.txt")
        let hotwordsFile = FileManager.default.fileExists(atPath: hotwordsPath.path) ? hotwordsPath.path : ""

        proc.executableURL = URL(fileURLWithPath: executable)
        if !serverScript.isEmpty {
            args.append(serverScript)
        }
        args += [
            "--model-dir", modelDir,
            "--port", "0",
            "--hotwords-file", hotwordsFile,
            "--beam-size", "3",
            "--context-score", "6.0",
            "--device", "auto",
            "--language", "auto",
            "--textnorm",
            "--padding", "8",
            "--chunk-size", "10",
        ]
        logger.info("Starting SenseVoice server")
    }

    // MARK: - Dev server discovery

    private func findDevServerDir(name: String) -> String? {
        // Walk up from binary location to find server directory
        var dir = Bundle.main.bundlePath
        for _ in 0..<5 {
            dir = (dir as NSString).deletingLastPathComponent
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: (candidate as NSString).appendingPathComponent("server.py")) {
                return candidate
            }
        }
        let home = NSHomeDirectory()
        let fallback = (home as NSString).appendingPathComponent("projects/type4me/\(name)")
        if FileManager.default.fileExists(atPath: (fallback as NSString).appendingPathComponent("server.py")) {
            return fallback
        }
        return nil
    }

    private func readPortFromStdout(pipe: Pipe, timeout: Int) async -> Int? {
        return await withCheckedContinuation { continuation in
            let handle = pipe.fileHandleForReading
            var resolved = false

            // Read in background
            DispatchQueue.global().async {
                while true {
                    let data = handle.availableData
                    guard !data.isEmpty else { break }
                    if let output = String(data: data, encoding: .utf8) {
                        for line in output.split(separator: "\n") {
                            if line.hasPrefix("PORT:"),
                               let portNum = Int(line.dropFirst(5)) {
                                if !resolved {
                                    resolved = true
                                    continuation.resume(returning: portNum)
                                }
                                return
                            }
                        }
                    }
                }
                if !resolved {
                    resolved = true
                    continuation.resume(returning: nil)
                }
            }

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                if !resolved {
                    resolved = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func waitForHealth(timeout: Int) async -> Bool {
        for _ in 0..<timeout {
            if await isHealthy() { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // MARK: - Errors

    enum ServerError: Error, LocalizedError {
        case serverNotFound
        case venvNotFound
        case modelNotFound
        case launchFailed(Error)
        case portDiscoveryFailed

        var errorDescription: String? {
            switch self {
            case .serverNotFound:
                return L("SenseVoice 服务未找到", "SenseVoice server not found")
            case .venvNotFound:
                return L("Python 环境未配置", "Python environment not configured")
            case .modelNotFound:
                return L("本地 ASR 模型未找到，请先下载", "Local ASR model not found, please download first")
            case .launchFailed(let e):
                return L("服务启动失败: \(e.localizedDescription)", "Server launch failed: \(e.localizedDescription)")
            case .portDiscoveryFailed:
                return L("服务端口发现失败", "Server port discovery failed")
            }
        }
    }
}
