import Foundation

final class QuotaSnapshotService {
    private let sessionDirectory: URL
    private let appServerProvider: CodexAppServerQuotaProvider
    private let decoderFormatter: ISO8601DateFormatter
    private let fallbackFormatter: ISO8601DateFormatter
    private var cachedSignature: String?
    private var cachedLogSnapshot: SnapshotCandidate?
    private var lastValidSnapshot: QuotaSnapshot?
    private var lastValidReferenceDate: Date?

    init(
        sessionDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        appServerProvider: CodexAppServerQuotaProvider = CodexAppServerQuotaProvider()
    ) {
        self.sessionDirectory = sessionDirectory
        self.appServerProvider = appServerProvider
        self.decoderFormatter = ISO8601DateFormatter()
        self.decoderFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fallbackFormatter = ISO8601DateFormatter()
        self.fallbackFormatter.formatOptions = [.withInternetDateTime]
    }

    func latestSnapshot(forceReload: Bool = false) -> QuotaSnapshot? {
        if let snapshot = appServerProvider.latestSnapshot() {
            lastValidSnapshot = snapshot
            lastValidReferenceDate = snapshotDate(snapshot)
            return snapshot
        }

        if let candidate = latestLogSnapshot(forceReload: forceReload) {
            // 日志快照的新旧必须按日志事件时间判断；timestamp 缺失时用文件修改时间兜底，
            // 不能用 detectedAt，否则旧日志会因为“刚被解析”而覆盖 app-server 的新值。
            if let lastValidReferenceDate, candidate.referenceDate < lastValidReferenceDate {
                return lastValidSnapshot
            }
            lastValidSnapshot = candidate.snapshot
            lastValidReferenceDate = candidate.referenceDate
            return candidate.snapshot
        }

        return lastValidSnapshot
    }

    func stop() {
        appServerProvider.stop()
    }

    private func latestLogSnapshot(forceReload: Bool = false) -> SnapshotCandidate? {
        let files = newestSessionFiles(limit: 120)
        let signature = files
            .map { "\($0.url.path)::\($0.modifiedAt.timeIntervalSince1970)::\($0.fileSize)" }
            .joined(separator: "|")

        if !forceReload, signature == cachedSignature {
            return cachedLogSnapshot
        }

        let candidate = files
            .map(\.url)
            .compactMap(parseSnapshotWithReferenceDate(from:))
            .max { lhs, rhs in
                if lhs.referenceDate == rhs.referenceDate {
                    return lhs.fileModifiedAt < rhs.fileModifiedAt
                }
                return lhs.referenceDate < rhs.referenceDate
            }

        cachedSignature = signature
        if let candidate {
            cachedLogSnapshot = candidate
            return candidate
        }
        return cachedLogSnapshot
    }

    private func newestSessionFiles(limit: Int) -> [(url: URL, modifiedAt: Date, fileSize: UInt64)] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date, fileSize: UInt64)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files.append((fileURL, values?.contentModificationDate ?? .distantPast, UInt64(values?.fileSize ?? 0)))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map { $0 }
    }

    private func parseSnapshotWithReferenceDate(from fileURL: URL) -> SnapshotCandidate? {
        let lines = recentLines(from: fileURL, maxBytes: 4 * 1024 * 1024)
        let fileModifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

        for rawLine in lines.reversed() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            guard
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                payload["type"] as? String == "event_msg",
                let innerPayload = payload["payload"] as? [String: Any],
                innerPayload["type"] as? String == "token_count",
                let rateLimits = innerPayload["rate_limits"] as? [String: Any],
                let primaryPayload = rateLimits["primary"] as? [String: Any],
                let primary = parseWindow(primaryPayload)
            else {
                continue
            }

            let secondary = (rateLimits["secondary"] as? [String: Any]).flatMap(parseWindow(_:))
            let timestamp = parseTimestamp(payload["timestamp"] as? String)

            let snapshot = QuotaSnapshot(
                sourceFileName: fileURL.lastPathComponent,
                eventTimestamp: timestamp,
                detectedAt: Date(),
                planType: rateLimits["plan_type"] as? String,
                primary: primary,
                secondary: secondary
            )

            if let resetsAt = snapshot.primary.resetsAt, resetsAt <= Date() {
                continue
            }

            let candidate = SnapshotCandidate(
                snapshot: snapshot,
                referenceDate: timestamp ?? fileModifiedAt,
                fileModifiedAt: fileModifiedAt
            )

            let limitId = (rateLimits["limit_id"] as? String)?.lowercased()
            guard limitId == "codex" else { continue }
            return candidate
        }

        return nil
    }

    private func parseWindow(_ payload: [String: Any]) -> WindowQuota? {
        guard let windowMinutes = payload["window_minutes"] as? Int ?? Int("\(payload["window_minutes"] ?? "")") else {
            return nil
        }

        let usedPercent = clampPercent(payload["used_percent"])
        let resetsEpoch = payload["resets_at"] as? Int ?? Int("\(payload["resets_at"] ?? "")")

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

    private func recentLines(from fileURL: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }
        defer { try? handle.close() }

        let totalBytes = (try? handle.seekToEnd()) ?? 0
        let readOffset = totalBytes > UInt64(maxBytes) ? totalBytes - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: readOffset)

        var data = handle.readDataToEndOfFile()
        if readOffset > 0, let newlineRange = data.range(of: Data([0x0A])) {
            data = data.subdata(in: newlineRange.upperBound..<data.count)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.components(separatedBy: .newlines)
    }

    private func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let value = decoderFormatter.date(from: raw) {
            return value
        }
        return fallbackFormatter.date(from: raw)
    }

    /// 统一快照时间口径，日志优先用事件时间，app-server 这类实时数据则使用检测时间。
    private func snapshotDate(_ snapshot: QuotaSnapshot) -> Date {
        snapshot.eventTimestamp ?? snapshot.detectedAt
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
}

private struct SnapshotCandidate {
    let snapshot: QuotaSnapshot
    let referenceDate: Date
    let fileModifiedAt: Date
}
