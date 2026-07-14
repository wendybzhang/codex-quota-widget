import Foundation

final class CodexAppServerQuotaProvider {
    private final class PendingResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var message: [String: Any]?
    }

    private let codexURL: URL
    private let queue = DispatchQueue(label: "com.wendy.codex-quota-widget.app-server")
    private let lock = NSLock()

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = ""
    private var pendingResponses: [Int: PendingResponse] = [:]
    private var nextRequestID = 1
    private var initialized = false

    init(codexURL: URL? = nil) {
        self.codexURL = codexURL ?? Self.discoverCodexURL()
    }

    func latestSnapshot(timeout: TimeInterval = 3) -> QuotaSnapshot? {
        queue.sync {
            guard startIfNeeded() else {
                return nil
            }

            if !initialized {
                // Recent Codex app-server builds can delay the initialize response until
                // a later request is sent. Treat initialize as a best-effort handshake
                // instead of blocking the rate-limit read path on it.
                _ = initialize(timeout: min(timeout, 0.5))
                initialized = true
            }

            guard
                let message = sendRequest(method: "account/rateLimits/read", params: NSNull(), timeout: timeout),
                let result = message["result"] as? [String: Any]
            else {
                stopLocked()
                return nil
            }

            return parseSnapshot(from: result)
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    private func initialize(timeout: TimeInterval) -> Bool {
        let params: [String: Any] = [
            "clientInfo": [
                "name": "codex-quota-widget",
                "title": "Codex Quota Widget",
                "version": "2.0",
            ],
            "capabilities": [
                "experimentalApi": true,
                "optOutNotificationMethods": [],
            ],
        ]

        return sendRequest(method: "initialize", params: params, timeout: timeout)?["result"] != nil
    }

    private func startIfNeeded() -> Bool {
        if process?.isRunning == true, inputPipe != nil {
            return true
        }

        stopLocked()

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = codexURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] _ in
            self?.lock.lock()
            self?.initialized = false
            self?.lock.unlock()
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleOutput(data)
        }

        // Drain stderr so app-server warnings never block the child process.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            return false
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.outputBuffer = ""
        self.initialized = false
        return true
    }

    private func stopLocked() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        inputPipe?.fileHandleForWriting.closeFile()
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer = ""
        pendingResponses.removeAll()
        initialized = false
    }

    private func sendRequest(method: String, params: Any, timeout: TimeInterval) -> [String: Any]? {
        guard let inputPipe else {
            return nil
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let pending = PendingResponse()
        lock.lock()
        pendingResponses[requestID] = pending
        lock.unlock()

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params,
        ]

        guard
            JSONSerialization.isValidJSONObject(request),
            var data = try? JSONSerialization.data(withJSONObject: request)
        else {
            removePendingResponse(requestID)
            return nil
        }

        data.append(0x0A)
        inputPipe.fileHandleForWriting.write(data)

        let waitResult = pending.semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        let message = pending.message
        pendingResponses[requestID] = nil
        lock.unlock()

        guard waitResult == .success else {
            return nil
        }
        return message
    }

    private func removePendingResponse(_ requestID: Int) {
        lock.lock()
        pendingResponses[requestID] = nil
        lock.unlock()
    }

    private func handleOutput(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }

        lock.lock()
        outputBuffer.append(text)

        while let newlineIndex = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            outputBuffer.removeSubrange(...newlineIndex)
            handleLineLocked(line)
        }

        lock.unlock()
    }

    private func handleLineLocked(_ line: String) {
        guard
            !line.isEmpty,
            let data = line.data(using: .utf8),
            let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let requestID = (message["id"] as? NSNumber)?.intValue ?? Int("\(message["id"] ?? "")"),
            let pending = pendingResponses[requestID]
        else {
            return
        }

        pending.message = message
        pending.semaphore.signal()
    }

    private func parseSnapshot(from result: [String: Any]) -> QuotaSnapshot? {
        let rateLimitsByID = result["rateLimitsByLimitId"] as? [String: Any]
        let codexRateLimits = rateLimitsByID?["codex"] as? [String: Any]
        let fallbackRateLimits = result["rateLimits"] as? [String: Any]

        guard
            let rateLimits = codexRateLimits ?? fallbackRateLimits,
            (rateLimits["limitId"] as? String) == "codex",
            let primaryPayload = rateLimits["primary"] as? [String: Any],
            let primary = parseWindow(primaryPayload)
        else {
            return nil
        }

        let secondary = (rateLimits["secondary"] as? [String: Any]).flatMap(parseWindow(_:))

        return QuotaSnapshot(
            sourceFileName: "Codex app-server",
            eventTimestamp: Date(),
            detectedAt: Date(),
            planType: rateLimits["planType"] as? String,
            primary: primary,
            secondary: secondary
        )
    }

    private func parseWindow(_ payload: [String: Any]) -> WindowQuota? {
        let windowMinutes = (payload["windowDurationMins"] as? NSNumber)?.intValue
            ?? Int("\(payload["windowDurationMins"] ?? "")")
        guard let windowMinutes else {
            return nil
        }

        let usedPercent = clampPercent(payload["usedPercent"])
        let resetsEpoch = (payload["resetsAt"] as? NSNumber)?.intValue
            ?? Int("\(payload["resetsAt"] ?? "")")

        return WindowQuota(
            label: windowLabel(minutes: windowMinutes),
            usedPercent: usedPercent,
            remainingPercent: max(0, 100 - usedPercent),
            resetsAt: resetsEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private func clampPercent(_ value: Any?) -> Double {
        guard let value else { return 0 }
        let number = (value as? NSNumber)?.doubleValue ?? Double("\(value)") ?? 0
        return min(max(number, 0), 100)
    }

    private func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300:
            return "5h"
        case 10080:
            return "7d"
        case let value where value % 1440 == 0:
            return "\(value / 1440)d"
        case let value where value % 60 == 0:
            return "\(value / 60)h"
        default:
            return "\(minutes)m"
        }
    }

    private static func discoverCodexURL() -> URL {
        let fileManager = FileManager.default
        for candidate in codexURLCandidates() where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
    }

    private static func codexURLCandidates() -> [URL] {
        var candidates: [URL] = []

        if let overridePath = ProcessInfo.processInfo.environment["CODEX_QUOTA_WIDGET_CODEX_PATH"], !overridePath.isEmpty {
            candidates.append(URL(fileURLWithPath: overridePath))
        }

        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        let appNames = ["Codex.app", "ChatGPT.app"]

        for directory in applicationDirectories {
            for appName in appNames {
                candidates.append(
                    directory
                        .appendingPathComponent(appName, isDirectory: true)
                        .appendingPathComponent("Contents/Resources/codex")
                )
            }
        }

        return candidates
    }
}
