import Foundation
import OSLog
import WidgetKit

actor HealthSyncManager {
    static let shared = HealthSyncManager()

    // These references are immutable and point to Sendable-safe singletons,
    // so they don't need actor isolation. Only `pendingSyncTask` does.
    nonisolated private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "HealthSync")
    nonisolated private let prefs = PreferencesManager.shared
    nonisolated private let healthKit = HealthKitManager.shared
    nonisolated private let pendingStore = PendingSyncStore.shared
    nonisolated private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    /// Chain of in-flight sync tasks. Every call waits for the previous one to
    /// finish before starting. Concurrent triggers (observer debounce, app
    /// launch, UI button, BG task) would otherwise both fetch the same anchor
    /// and POST duplicate pages until the anchor caught up.
    private var pendingSyncTask: Task<HealthSyncResult, Never>?

    private init() {}

    // MARK: - Full Sync (all enabled types)

    /// UI "Sync now", Siri intent and BGProcessingTask entry point. Routes through
    /// the same paged engine as observer-triggered incremental sync: no-anchor
    /// sample types get the last-`lookbackDays` predicate, existing ones catch up
    /// from where they last posted. The old "always send the last 7 days" shape
    /// caused records past `SyncLimits` to be silently dropped on every call.
    func performSync() async -> HealthSyncResult {
        let enabledTypes = prefs.healthEnabledDataTypes
        guard !enabledTypes.isEmpty else { return .noData }
        return await performIncrementalSync(types: enabledTypes)
    }

    // MARK: - Incremental Sync (anchor-based, paged per type)

    /// Public entry: serializes overlapping callers through `pendingSyncTask`
    /// so no two runs can share an anchor position and duplicate pages.
    func performIncrementalSync(types: Set<HealthDataType>) async -> HealthSyncResult {
        let previous = pendingSyncTask
        let task = Task { () -> HealthSyncResult in
            if let previous {
                _ = await previous.value
            }
            return await self.runIncrementalSync(types: types)
        }
        pendingSyncTask = task
        let result = await task.value
        if pendingSyncTask == task {
            pendingSyncTask = nil
        }
        return result
    }

    /// For each data type, reads one page's worth of new samples via anchored
    /// queries capped at `SyncLimits`, POSTs the page, and only then persists the
    /// updated anchors. Pages until the last read returned fewer than the cap.
    /// A failed POST bails out for that type without advancing anchors, so records
    /// are retried on the next sync rather than lost.
    private func runIncrementalSync(types: Set<HealthDataType>) async -> HealthSyncResult {
        let webhookUrls = prefs.healthWebhookUrls
        let headers = prefs.healthWebhookHeaders

        guard !types.isEmpty, !webhookUrls.isEmpty else { return .noData }

        var syncCounts: [HealthDataType: Int] = [:]
        var totalRecords = 0
        var anyFailure = false
        var deviceLocked = false

        typeLoop: for dataType in types {
            // "First sync" for a type means none of its underlying sample types has
            // an anchor at the moment this catch-up starts. This flag must stick
            // across every page of the run — recomputing it per page flipped to
            // false as soon as page 1 saved an anchor, which dropped the last-7-days
            // predicate and walked HealthKit history back to 2018.
            let firstSync = dataType.hkSampleTypes.allSatisfy { prefs.loadAnchor(for: $0) == nil }

            pageLoop: while true {
                let outcome: HealthKitManager.HealthPageResult
                do {
                    outcome = try await healthKit.readNextPage(for: dataType, firstSync: firstSync)
                } catch {
                    logger.error("Read failed for \(dataType.rawValue): \(error.localizedDescription)")
                    anyFailure = true
                    break pageLoop
                }

                switch outcome {
                case .protectedDataUnavailable:
                    deviceLocked = true
                    break typeLoop

                case .empty:
                    break pageLoop

                case .data(let page):
                    var payload = page.fragments
                    payload["timestamp"] = Date().iso8601String
                    payload["app_version"] = appVersion
                    payload["source"] = "healthkit_ios"

                    guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                        logger.error("Failed to serialize page payload for \(dataType.rawValue)")
                        anyFailure = true
                        break pageLoop
                    }

                    let success = await WebhookManager.shared.post(
                        body: body,
                        urls: webhookUrls,
                        headers: headers,
                        logType: .healthConnect,
                        dataType: "health_connect",
                        recordCount: page.recordCount
                    )

                    guard success else {
                        enqueueBody(body, urls: webhookUrls, headers: headers, totalRecords: page.recordCount)
                        anyFailure = true
                        break pageLoop
                    }

                    for (sampleType, newAnchor) in page.anchors {
                        prefs.saveAnchor(newAnchor, for: sampleType)
                    }
                    syncCounts[dataType, default: 0] += page.recordCount
                    totalRecords += page.recordCount
                    await MqttPublisher.shared.publish(healthPayload: page.fragments)

                    if !page.hasMore {
                        break pageLoop
                    }
                    // else fall through — while loop pages again with new anchors.
                }
            }
        }

        updateWidgetStatus(success: !anyFailure && !deviceLocked, records: totalRecords)

        if deviceLocked && totalRecords == 0 {
            return .failure(error: "Device locked - data encrypted")
        }
        if totalRecords == 0 && !anyFailure && !deviceLocked {
            return .noData
        }
        if anyFailure || deviceLocked {
            return .failure(error: totalRecords > 0 ? "Partial sync - retry queued" : "Sync failed")
        }
        return .success(syncCounts: syncCounts)
    }

    /// Pushes the latest sync result to the app group so the home screen widget stays
    /// current, and tracks the failure streak for the local failure notification.
    private func updateWidgetStatus(success: Bool, records: Int) {
        SharedSyncStatus.record(success: success, records: success ? records : 0)
        WidgetCenter.shared.reloadAllTimelines()
        SyncFailureNotifier.shared.recordResult(success: success, lastError: nil)
    }

    // MARK: - Pending Queue Drain

    func drainPendingQueue() async {
        let items = pendingStore.dequeueAll()
        guard !items.isEmpty else { return }

        logger.info("Draining pending sync queue: \(items.count) item(s)")

        for item in items {
            let success = await WebhookManager.shared.post(
                body: item.payload,
                urls: item.urls,
                headers: item.headers,
                logType: LogType(rawValue: item.logType) ?? .healthConnect,
                dataType: item.dataType,
                recordCount: item.recordCount
            )

            if success {
                pendingStore.remove(id: item.id)
                logger.info("Pending sync item \(item.id) delivered successfully")
            } else {
                pendingStore.updateAttempt(id: item.id, error: "Retry failed")
                logger.info("Pending sync retry failed, stopping drain")
                break
            }
        }
    }

    // MARK: - Preview

    nonisolated func buildPreviewPayload() async throws -> [String: Any] {
        let enabledTypes = prefs.healthEnabledDataTypes

        var payload = try await healthKit.readHealthData(for: enabledTypes)
        payload["timestamp"] = Date().iso8601String
        payload["app_version"] = appVersion
        payload["source"] = "healthkit_ios"

        return payload
    }

    // MARK: - Private Helpers

    private func enqueueBody(
        _ body: Data,
        urls: [String],
        headers: [String: String],
        totalRecords: Int
    ) {
        pendingStore.enqueue(
            payload: body,
            urls: urls,
            headers: headers,
            logType: LogType.healthConnect.rawValue,
            dataType: "health_connect",
            recordCount: totalRecords
        )

        logger.info("Enqueued failed sync payload (\(totalRecords) records) for retry")
    }
}
