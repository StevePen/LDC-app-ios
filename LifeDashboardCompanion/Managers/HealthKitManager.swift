import Foundation
import HealthKit
import UIKit
import OSLog

/// @unchecked Sendable: HKHealthStore is thread-safe, `isAvailable` is set once in init,
/// and the @Published authorization status is only mutated via the @MainActor method.
final class HealthKitManager: ObservableObject, @unchecked Sendable {
    static let shared = HealthKitManager()

    let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "HealthKit")

    @Published var authorizationStatus: [HealthDataType: HKAuthorizationStatus] = [:]
    @Published var isAvailable: Bool

    static let lookbackDays: Int = 7

    /// Fixed lower bound for the first sync of every data type. Set to cover the
    /// backfill window Steve wants in Supabase (1 Sep 2025 onwards); once
    /// anchors are set the predicate is dropped and later syncs pick up from
    /// wherever the last POST left off.
    static let firstSyncStartDate: Date = {
        var components = DateComponents()
        components.year = 2025
        components.month = 9
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    /// Payload fragments produced by reading a single data type, safe to move across
    /// the task group boundary. @unchecked Sendable: the values are JSON value types
    /// (String, Int, Double, arrays, dictionaries) freshly built per task.
    private struct PayloadFragments: @unchecked Sendable {
        let pairs: [(String, Any)]
    }

    private init() {
        self.isAvailable = HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - Permissions

    var allReadTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for dataType in HealthDataType.allCases {
            types.formUnion(dataType.hkReadTypes)
        }
        return types
    }

    func readTypesFor(_ types: Set<HealthDataType>) -> Set<HKObjectType> {
        var hkTypes = Set<HKObjectType>()
        for dataType in types {
            hkTypes.formUnion(dataType.hkReadTypes)
        }
        return hkTypes
    }

    func requestAuthorization(for types: Set<HealthDataType>) async throws {
        let readTypes = readTypesFor(types)
        guard !readTypes.isEmpty else { return }
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        await updateAuthorizationStatus()
    }

    func requestAllAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: [], read: allReadTypes)
        await updateAuthorizationStatus()
    }

    @MainActor
    func updateAuthorizationStatus() {
        var statuses: [HealthDataType: HKAuthorizationStatus] = [:]
        for dataType in HealthDataType.allCases {
            if let sampleType = dataType.hkSampleTypes.first {
                statuses[dataType] = healthStore.authorizationStatus(for: sampleType)
            } else {
                statuses[dataType] = .notDetermined
            }
        }
        self.authorizationStatus = statuses
    }

    /// Most recent heart rate sample, used by the About screen's beating-heart easter egg.
    func latestHeartRateBPM() async -> Int? {
        guard isAvailable else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let bpm = (samples?.first as? HKQuantitySample)
                    .map { Int($0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))) }
                continuation.resume(returning: bpm)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Data Reading

    func readHealthData(
        for enabledTypes: Set<HealthDataType>
    ) async throws -> [String: Any] {
        let startDate = Calendar.current.date(
            byAdding: .day,
            value: -HealthKitManager.lookbackDays,
            to: Date()
        )!
        let endDate = Date()

        // Run all type queries in parallel; a failure in one type only skips that type
        let results = await withTaskGroup(
            of: PayloadFragments?.self
        ) { group -> [String: Any] in
            for dataType in enabledTypes {
                group.addTask {
                    do {
                        guard let pairs = try await self.readDataForType(dataType, start: startDate, end: endDate) else {
                            return nil
                        }
                        return PayloadFragments(pairs: pairs)
                    } catch {
                        self.logger.error("Read failed for \(dataType.rawValue): \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            var payload: [String: Any] = [:]
            for await result in group {
                for (key, value) in result?.pairs ?? [] {
                    payload[key] = value
                }
            }
            return payload
        }

        return results
    }

    // MARK: - Daily Totals

    /// Deduplicated daily step totals for the last `days` days including today, via
    /// HKStatisticsCollectionQuery which merges overlapping phone and watch samples
    /// instead of double counting. Returns oldest-first; empty when steps are unavailable.
    func readDailyStepTotals(days: Int) async -> [Int] {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
        let calendar = Calendar.current
        let end = Date()
        let startOfToday = calendar.startOfDay(for: end)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) else { return [] }

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                options: .cumulativeSum,
                anchorDate: startOfToday,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, results, _ in
                var totals: [Int] = []
                results?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let value = statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    totals.append(Int(value))
                }
                continuation.resume(returning: totals)
            }
            self.healthStore.execute(query)
        }
    }

    // MARK: - Incremental (Anchor-Based) Paged Reading

    /// One page of new samples for a single `HealthDataType`, produced by
    /// `readNextPage(for:firstSync:)`. Anchors are returned rather than persisted
    /// so the caller can save them only after the page's POST succeeds — advancing
    /// past records that were never uploaded is what lost samples in the previous
    /// implementation.
    struct HealthPage: @unchecked Sendable {
        let fragments: [String: Any]
        let anchors: [(HKSampleType, HKQueryAnchor)]
        let hasMore: Bool
        let recordCount: Int
    }

    /// Outcome of a single page read.
    enum HealthPageResult {
        case data(HealthPage)
        case empty
        case protectedDataUnavailable
    }

    /// Reads one page of new samples for `dataType`. Each underlying `HKSampleType`
    /// is queried through `HKAnchoredObjectQuery` capped at `SyncLimits`; the caller
    /// pages again while `hasMore` is true, persisting anchors between pages only
    /// on POST success.
    ///
    /// `firstSync` restricts every sample type to the last `lookbackDays` via a
    /// start-date predicate. Callers pass true when none of the type's sample
    /// types has a stored anchor yet.
    func readNextPage(
        for dataType: HealthDataType,
        firstSync: Bool
    ) async throws -> HealthPageResult {
        let isProtected = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        guard isProtected else {
            logger.info("Protected data unavailable (device locked) - skipping HealthKit read")
            return .protectedDataUnavailable
        }

        let limit = SyncLimits.maxRecordsPerSync(for: dataType)
        let predicate: NSPredicate? = firstSync ? Self.firstSyncPredicate() : nil
        let prefs = PreferencesManager.shared

        var samplesByType: [HKSampleType: [HKSample]] = [:]
        var newAnchors: [(HKSampleType, HKQueryAnchor)] = []
        var hasMore = false

        for sampleType in dataType.hkSampleTypes {
            let (samples, newAnchor) = try await pagedAnchoredQuery(
                sampleType: sampleType,
                anchor: prefs.loadAnchor(for: sampleType),
                limit: limit,
                predicate: predicate
            )
            samplesByType[sampleType] = samples
            newAnchors.append((sampleType, newAnchor))
            if samples.count >= limit { hasMore = true }
        }

        let fragments = try await formatFragments(for: dataType, samplesByType: samplesByType)
        let recordCount = fragments.values.reduce(0) { total, value in
            total + ((value as? [Any])?.count ?? 0)
        }

        guard recordCount > 0 else { return .empty }
        return .data(HealthPage(
            fragments: fragments,
            anchors: newAnchors,
            hasMore: hasMore,
            recordCount: recordCount
        ))
    }

    private static func firstSyncPredicate() -> NSPredicate {
        HKQuery.predicateForSamples(
            withStart: HealthKitManager.firstSyncStartDate,
            end: nil,
            options: .strictStartDate
        )
    }

    /// Runs an anchored query for one sample type capped at `limit`. When the
    /// returned count equals `limit` the caller must page again — the anchor
    /// represents this page only, not the full remaining tail.
    private func pagedAnchoredQuery(
        sampleType: HKSampleType,
        anchor: HKQueryAnchor?,
        limit: Int,
        predicate: NSPredicate?
    ) async throws -> ([HKSample], HKQueryAnchor) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, addedSamples, _, newAnchor, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (
                    addedSamples ?? [],
                    newAnchor ?? HKQueryAnchor(fromValue: 0)
                ))
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Payload Formatting (Incremental)

    /// Formats a batch of new samples grouped by sample type into payload fragments
    /// for one data type. Output shape is byte-compatible with `readDataForType`
    /// so downstream (raw JSONB in Supabase) stays unchanged.
    private func formatFragments(
        for dataType: HealthDataType,
        samplesByType: [HKSampleType: [HKSample]]
    ) async throws -> [String: Any] {
        func quantity(_ type: HKQuantityType) -> [HKQuantitySample] {
            (samplesByType[type] ?? []).compactMap { $0 as? HKQuantitySample }
        }
        func category(_ type: HKCategoryType) -> [HKCategorySample] {
            (samplesByType[type] ?? []).compactMap { $0 as? HKCategorySample }
        }

        switch dataType {
        case .steps:
            let mapped = quantity(HKQuantityType(.stepCount)).map { sample -> [String: Any] in
                record([
                    "count": Int(sample.quantity.doubleValue(for: .count())),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["steps": mapped]

        case .distance:
            let mapped = quantity(HKQuantityType(.distanceWalkingRunning)).map { sample -> [String: Any] in
                record([
                    "meters": sample.quantity.doubleValue(for: .meter()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["distance": mapped]

        case .activeCalories:
            let mapped = quantity(HKQuantityType(.activeEnergyBurned)).map { sample -> [String: Any] in
                record([
                    "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["active_calories": mapped]

        case .totalCalories:
            let combined = quantity(HKQuantityType(.activeEnergyBurned))
                + quantity(HKQuantityType(.basalEnergyBurned))
            let mapped = combined.map { sample -> [String: Any] in
                record([
                    "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["total_calories": mapped]

        case .weight:
            let mapped = quantity(HKQuantityType(.bodyMass)).map { sample -> [String: Any] in
                record([
                    "kilograms": sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["weight": mapped]

        case .height:
            let mapped = quantity(HKQuantityType(.height)).map { sample -> [String: Any] in
                record([
                    "meters": sample.quantity.doubleValue(for: .meter()),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["height": mapped]

        case .heartRate:
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let mapped = quantity(HKQuantityType(.heartRate)).map { sample -> [String: Any] in
                record([
                    "bpm": Int(sample.quantity.doubleValue(for: bpmUnit)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["heart_rate": mapped]

        case .restingHeartRate:
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let mapped = quantity(HKQuantityType(.restingHeartRate)).map { sample -> [String: Any] in
                record([
                    "bpm": Int(sample.quantity.doubleValue(for: bpmUnit)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["resting_heart_rate": mapped]

        case .heartRateVariability:
            let mapped = quantity(HKQuantityType(.heartRateVariabilitySDNN)).map { sample -> [String: Any] in
                record([
                    "heart_rate_variability_millis": sample.quantity.doubleValue(for: .secondUnit(with: .milli)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["heart_rate_variability": mapped]

        case .bloodPressure:
            let systolic = quantity(HKQuantityType(.bloodPressureSystolic))
            let diastolic = quantity(HKQuantityType(.bloodPressureDiastolic))
            let mmHg = HKUnit.millimeterOfMercury()
            var mapped: [[String: Any]] = []
            for systolicSample in systolic {
                let matchingDiastolic = diastolic.first {
                    abs($0.startDate.timeIntervalSince(systolicSample.startDate)) < 1
                }
                var fields: [String: Any] = [
                    "systolic": systolicSample.quantity.doubleValue(for: mmHg),
                    "time": systolicSample.startDate.iso8601String
                ]
                if let diastolicSample = matchingDiastolic {
                    fields["diastolic"] = diastolicSample.quantity.doubleValue(for: mmHg)
                }
                mapped.append(record(fields, from: systolicSample))
            }
            return mapped.isEmpty ? [:] : ["blood_pressure": mapped]

        case .bloodGlucose:
            let unit = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
            let mapped = quantity(HKQuantityType(.bloodGlucose)).map { sample -> [String: Any] in
                record([
                    "mmol_per_liter": sample.quantity.doubleValue(for: unit),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["blood_glucose": mapped]

        case .oxygenSaturation:
            let mapped = quantity(HKQuantityType(.oxygenSaturation)).map { sample -> [String: Any] in
                record([
                    "percentage": sample.quantity.doubleValue(for: .percent()) * 100,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["oxygen_saturation": mapped]

        case .bodyTemperature:
            let mapped = quantity(HKQuantityType(.bodyTemperature)).map { sample -> [String: Any] in
                record([
                    "celsius": sample.quantity.doubleValue(for: .degreeCelsius()),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["body_temperature": mapped]

        case .respiratoryRate:
            let mapped = quantity(HKQuantityType(.respiratoryRate)).map { sample -> [String: Any] in
                record([
                    "rate": sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["respiratory_rate": mapped]

        case .bodyFat:
            let mapped = quantity(HKQuantityType(.bodyFatPercentage)).map { sample -> [String: Any] in
                record([
                    "percentage": sample.quantity.doubleValue(for: .percent()) * 100,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["body_fat": mapped]

        case .leanBodyMass:
            let mapped = quantity(HKQuantityType(.leanBodyMass)).map { sample -> [String: Any] in
                record([
                    "kilograms": sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["lean_body_mass": mapped]

        case .sleep:
            let sessions = buildSleepSessions(from: category(HKCategoryType(.sleepAnalysis)))
            return sessions.isEmpty ? [:] : ["sleep": sessions]

        case .exercise:
            let workouts = (samplesByType[HKWorkoutType.workoutType()] ?? []).compactMap { $0 as? HKWorkout }
            guard !workouts.isEmpty else { return [:] }
            let summaries = workouts.map { buildWorkoutSummary($0) }
            var samples: [[String: Any]] = []
            for workout in workouts {
                let rows = try await fetchWorkoutSamples(for: workout)
                samples.append(contentsOf: rows)
            }
            var out: [String: Any] = ["exercise": summaries]
            if !samples.isEmpty { out["workout_samples"] = samples }
            return out

        case .hydration:
            let mapped = quantity(HKQuantityType(.dietaryWater)).map { sample -> [String: Any] in
                record([
                    "liters": sample.quantity.doubleValue(for: .liter()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["hydration": mapped]

        case .nutrition:
            let mapped = buildNutritionRecords(
                calories: quantity(HKQuantityType(.dietaryEnergyConsumed)),
                protein: quantity(HKQuantityType(.dietaryProtein)),
                carbs: quantity(HKQuantityType(.dietaryCarbohydrates)),
                fat: quantity(HKQuantityType(.dietaryFatTotal))
            )
            return mapped.isEmpty ? [:] : ["nutrition": mapped]

        case .mindfulness:
            let mapped = category(HKCategoryType(.mindfulSession)).map { sample -> [String: Any] in
                let duration = sample.endDate.timeIntervalSince(sample.startDate)
                return record([
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String,
                    "duration_seconds": Int(duration)
                ], from: sample)
            }
            return mapped.isEmpty ? [:] : ["mindfulness": mapped]

        case .menstruation:
            let flowSamples = category(HKCategoryType(.menstrualFlow)).compactMap { sample -> (HKCategorySample, String)? in
                guard let value = HKCategoryValueMenstrualFlow(rawValue: sample.value) else { return nil }
                switch value {
                case .light: return (sample, "light")
                case .medium: return (sample, "medium")
                case .heavy: return (sample, "heavy")
                case .unspecified: return (sample, "unknown")
                default: return nil  // .none means no bleeding: skip
                }
            }
            let mapped = flowSamples.map { sample, flow in
                record([
                    "flow": flow,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            guard !mapped.isEmpty else { return [:] }
            let periods = MenstruationPeriodBuilder.periods(
                from: flowSamples.map { FlowSample(start: $0.0.startDate, end: $0.0.endDate) }
            )
            return ["menstruation_flow": mapped, "menstruation_period": periods]
        }
    }

    private func buildSleepSessions(from samples: [HKCategorySample]) -> [[String: Any]] {
        let stageSamples = samples.compactMap { sample -> SleepStageSample? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
            let stage: String
            switch value {
            case .inBed: stage = "in_bed"
            case .asleepUnspecified: stage = "sleeping"
            case .asleepCore: stage = "light"
            case .asleepDeep: stage = "deep"
            case .asleepREM: stage = "rem"
            case .awake: stage = "awake"
            @unknown default: stage = "unknown"
            }
            return SleepStageSample(
                stage: stage,
                start: sample.startDate,
                end: sample.endDate,
                uuid: sample.uuid.uuidString,
                source: sample.sourceRevision.source.name
            )
        }
        return SleepSessionBuilder.sessions(from: stageSamples)
    }

    private func buildNutritionRecords(
        calories: [HKQuantitySample],
        protein: [HKQuantitySample],
        carbs: [HKQuantitySample],
        fat: [HKQuantitySample]
    ) -> [[String: Any]] {
        var mapped: [[String: Any]] = calories.map { sample -> [String: Any] in
            var fields: [String: Any] = [
                "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                "start_time": sample.startDate.iso8601String,
                "end_time": sample.endDate.iso8601String
            ]
            if let match = protein.first(where: { abs($0.startDate.timeIntervalSince(sample.startDate)) < 1 }) {
                fields["protein_grams"] = match.quantity.doubleValue(for: .gram())
            }
            if let match = carbs.first(where: { abs($0.startDate.timeIntervalSince(sample.startDate)) < 1 }) {
                fields["carbs_grams"] = match.quantity.doubleValue(for: .gram())
            }
            if let match = fat.first(where: { abs($0.startDate.timeIntervalSince(sample.startDate)) < 1 }) {
                fields["fat_grams"] = match.quantity.doubleValue(for: .gram())
            }
            return record(fields, from: sample)
        }
        for proteinSample in protein
        where !calories.contains(where: { abs($0.startDate.timeIntervalSince(proteinSample.startDate)) < 1 }) {
            mapped.append(record([
                "protein_grams": proteinSample.quantity.doubleValue(for: .gram()),
                "start_time": proteinSample.startDate.iso8601String,
                "end_time": proteinSample.endDate.iso8601String
            ], from: proteinSample))
        }
        return mapped
    }

    /// Adds the stable HealthKit UUID and the writing app/device to a payload record,
    /// so servers can deduplicate re-sent records and trace their origin.
    private func record(_ fields: [String: Any], from sample: HKSample) -> [String: Any] {
        var record = fields
        record["uuid"] = sample.uuid.uuidString
        record["source"] = sample.sourceRevision.source.name
        return record
    }

    // MARK: - Workout Detail (time-series, step 2)

    /// Pulls every relevant quantity sample recorded during `workout` as flat rows
    /// for the `workout_samples` payload key. One secondary HK query per sample
    /// type scoped by `HKQuery.predicateForObjects(from:)`. If a workout re-appears
    /// on a later sync (edited, moved), its samples are re-sent and deduped
    /// downstream on `(workout_uuid, uuid)`.
    private func fetchWorkoutSamples(for workout: HKWorkout) async throws -> [[String: Any]] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let workoutUuid = workout.uuid.uuidString
        var out: [[String: Any]] = []
        for (identifier, mapping) in Self.statMappings {
            guard let qType = HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)
            ) else { continue }
            let samples = try await readQuantitySamplesMatching(type: qType, predicate: predicate)
            for sample in samples {
                var row: [String: Any] = [
                    "workout_uuid": workoutUuid,
                    "type": mapping.publicKey,
                    "time": sample.startDate.iso8601String,
                    "value": sample.quantity.doubleValue(for: mapping.unit),
                    "unit": mapping.unitLabel,
                    "uuid": sample.uuid.uuidString,
                    "source": sample.sourceRevision.source.name
                ]
                if sample.startDate != sample.endDate {
                    row["end_time"] = sample.endDate.iso8601String
                }
                out.append(row)
            }
        }
        return out
    }

    /// Like `readQuantitySamples(type:start:end:limit:)` but driven by an arbitrary
    /// predicate (used with `HKQuery.predicateForObjects(from:)` to scope samples
    /// to a specific workout). No upper limit: the predicate already bounds the set.
    private func readQuantitySamplesMatching(
        type: HKQuantityType,
        predicate: NSPredicate
    ) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Workout Detail (summary, step 1)

    /// Builds the per-workout summary dict carried under the `exercise` payload key.
    /// Pulls everything available without secondary queries: allStatistics, activities,
    /// events, device, metadata (raw and parsed convenience fields).
    private func buildWorkoutSummary(_ workout: HKWorkout) -> [String: Any] {
        var fields: [String: Any] = [
            "type": workout.workoutActivityType.name,
            "start_time": workout.startDate.iso8601String,
            "end_time": workout.endDate.iso8601String,
            "duration_seconds": Int(workout.duration)
        ]

        let statistics = workoutStatisticsDict(workout.allStatistics)
        if !statistics.isEmpty { fields["statistics"] = statistics }

        let activities = workoutActivitiesArray(workout.workoutActivities)
        if !activities.isEmpty { fields["activities"] = activities }

        let events = workoutEventsArray(workout.workoutEvents ?? [])
        if !events.isEmpty { fields["events"] = events }

        let device = workoutDeviceDict(workout)
        if !device.isEmpty { fields["device"] = device }

        for (key, value) in workoutParsedMetadata(workout.metadata) {
            fields[key] = value
        }

        if let raw = workout.metadata, !raw.isEmpty {
            fields["metadata"] = jsonSafeMetadata(raw)
        }

        return record(fields, from: workout)
    }

    /// Converts `HKWorkout.allStatistics` ([HKQuantityType: HKStatistics]) to a nested
    /// JSON-safe dict keyed by a short public key per quantity type. Each entry carries
    /// a `unit` label plus whichever of `sum`, `avg`, `min`, `max` is applicable.
    private func workoutStatisticsDict(_ stats: [HKQuantityType: HKStatistics]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (type, s) in stats {
            guard let mapping = Self.statMappings[type.identifier] else { continue }
            var entry: [String: Any] = ["unit": mapping.unitLabel]
            if mapping.hasSum, let v = s.sumQuantity()?.doubleValue(for: mapping.unit) {
                entry["sum"] = v
            }
            if mapping.hasAvgMinMax {
                if let v = s.averageQuantity()?.doubleValue(for: mapping.unit) { entry["avg"] = v }
                if let v = s.minimumQuantity()?.doubleValue(for: mapping.unit) { entry["min"] = v }
                if let v = s.maximumQuantity()?.doubleValue(for: mapping.unit) { entry["max"] = v }
            }
            if entry.count > 1 {  // skip entries where nothing beyond `unit` was populated
                out[mapping.publicKey] = entry
            }
        }
        return out
    }

    private func workoutActivitiesArray(_ activities: [HKWorkoutActivity]) -> [[String: Any]] {
        activities.map { activity in
            var dict: [String: Any] = [
                "uuid": activity.uuid.uuidString,
                "type": activity.workoutConfiguration.activityType.name,
                "location_type": locationTypeName(activity.workoutConfiguration.locationType),
                "start_time": activity.startDate.iso8601String,
                "duration_seconds": Int(activity.duration)
            ]
            if let endDate = activity.endDate {
                dict["end_time"] = endDate.iso8601String
            }
            if activity.workoutConfiguration.swimmingLocationType != .unknown {
                dict["swimming_location_type"] = swimmingLocationTypeName(
                    activity.workoutConfiguration.swimmingLocationType
                )
            }
            if let lapLength = activity.workoutConfiguration.lapLength {
                dict["lap_length_m"] = lapLength.doubleValue(for: .meter())
            }
            let statistics = workoutStatisticsDict(activity.allStatistics)
            if !statistics.isEmpty { dict["statistics"] = statistics }
            if let metadata = activity.metadata, !metadata.isEmpty {
                dict["metadata"] = jsonSafeMetadata(metadata)
            }
            return dict
        }
    }

    private func workoutEventsArray(_ events: [HKWorkoutEvent]) -> [[String: Any]] {
        events.map { event in
            var dict: [String: Any] = [
                "type": eventTypeName(event.type),
                "start_time": event.dateInterval.start.iso8601String,
                "duration_seconds": event.dateInterval.duration
            ]
            if let metadata = event.metadata, !metadata.isEmpty {
                dict["metadata"] = jsonSafeMetadata(metadata)
            }
            return dict
        }
    }

    private func workoutDeviceDict(_ workout: HKWorkout) -> [String: Any] {
        var out: [String: Any] = [:]
        let revision = workout.sourceRevision
        out["source_version"] = revision.version ?? ""
        out["source_product_type"] = revision.productType ?? ""
        out["source_os_version"] = "\(revision.operatingSystemVersion.majorVersion)."
            + "\(revision.operatingSystemVersion.minorVersion)."
            + "\(revision.operatingSystemVersion.patchVersion)"
        if let device = workout.device {
            if let name = device.name { out["name"] = name }
            if let manufacturer = device.manufacturer { out["manufacturer"] = manufacturer }
            if let model = device.model { out["model"] = model }
            if let hardwareVersion = device.hardwareVersion { out["hardware_version"] = hardwareVersion }
            if let softwareVersion = device.softwareVersion { out["software_version"] = softwareVersion }
            if let firmwareVersion = device.firmwareVersion { out["firmware_version"] = firmwareVersion }
        }
        return out
    }

    /// Explicit conversions for well-known metadata keys so downstream can rely on
    /// consistent names and units. The raw dict is still carried under `metadata`.
    private func workoutParsedMetadata(_ metadata: [String: Any]?) -> [String: Any] {
        guard let md = metadata else { return [:] }
        var out: [String: Any] = [:]
        if let indoor = md[HKMetadataKeyIndoorWorkout] as? Bool {
            out["indoor"] = indoor
        }
        if let elevation = md[HKMetadataKeyElevationAscended] as? HKQuantity {
            out["elevation_ascended_m"] = elevation.doubleValue(for: .meter())
        }
        if let elevation = md[HKMetadataKeyElevationDescended] as? HKQuantity {
            out["elevation_descended_m"] = elevation.doubleValue(for: .meter())
        }
        if let temp = md[HKMetadataKeyWeatherTemperature] as? HKQuantity {
            out["weather_temperature_c"] = temp.doubleValue(for: .degreeCelsius())
        }
        if let humidity = md[HKMetadataKeyWeatherHumidity] as? HKQuantity {
            out["weather_humidity_percent"] = humidity.doubleValue(for: .percent()) * 100
        }
        if let condition = md[HKMetadataKeyWeatherCondition] as? Int {
            out["weather_condition_raw"] = condition
        }
        if let lapLength = md[HKMetadataKeyLapLength] as? HKQuantity {
            out["lap_length_m"] = lapLength.doubleValue(for: .meter())
        }
        if let locationType = md[HKMetadataKeySwimmingLocationType] as? Int {
            out["swimming_location_type_raw"] = locationType
        }
        if let strokeStyle = md[HKMetadataKeySwimmingStrokeStyle] as? Int {
            out["swimming_stroke_style_raw"] = strokeStyle
        }
        return out
    }

    /// Flattens an arbitrary metadata dict into values JSONSerialization can handle:
    /// String, NSNumber, Date (stringified), HKQuantity (description), nested arrays
    /// and dicts recurse. Anything else falls back to its `description`.
    private func jsonSafeMetadata(_ metadata: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in metadata {
            out[key] = jsonSafeValue(value)
        }
        return out
    }

    private func jsonSafeValue(_ value: Any) -> Any {
        switch value {
        case let s as String:
            return s
        case let d as Date:
            return d.iso8601String
        case let q as HKQuantity:
            return String(describing: q)
        case let n as NSNumber:
            return n
        case let arr as [Any]:
            return arr.map { jsonSafeValue($0) }
        case let dict as [String: Any]:
            return dict.mapValues { jsonSafeValue($0) }
        default:
            return String(describing: value)
        }
    }

    private func locationTypeName(_ type: HKWorkoutSessionLocationType) -> String {
        switch type {
        case .indoor: return "indoor"
        case .outdoor: return "outdoor"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private func swimmingLocationTypeName(_ type: HKWorkoutSwimmingLocationType) -> String {
        switch type {
        case .pool: return "pool"
        case .openWater: return "open_water"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private func eventTypeName(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: return "pause"
        case .resume: return "resume"
        case .lap: return "lap"
        case .marker: return "marker"
        case .motionPaused: return "motion_paused"
        case .motionResumed: return "motion_resumed"
        case .pauseOrResumeRequest: return "pause_or_resume_request"
        case .segment: return "segment"
        @unknown default: return "unknown"
        }
    }

    private struct StatMapping {
        let unit: HKUnit
        let unitLabel: String
        let publicKey: String
        let hasSum: Bool
        let hasAvgMinMax: Bool
    }

    private static let statMappings: [String: StatMapping] = {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let mps = HKUnit.meter().unitDivided(by: .second())
        let rpm = HKUnit.count().unitDivided(by: .minute())
        return [
            HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
                StatMapping(unit: .meter(), unitLabel: "m",
                            publicKey: "distance_walking_running",
                            hasSum: true, hasAvgMinMax: false),
            HKQuantityTypeIdentifier.distanceCycling.rawValue:
                StatMapping(unit: .meter(), unitLabel: "m",
                            publicKey: "distance_cycling",
                            hasSum: true, hasAvgMinMax: false),
            HKQuantityTypeIdentifier.distanceSwimming.rawValue:
                StatMapping(unit: .meter(), unitLabel: "m",
                            publicKey: "distance_swimming",
                            hasSum: true, hasAvgMinMax: false),
            HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
                StatMapping(unit: .kilocalorie(), unitLabel: "kcal",
                            publicKey: "active_energy",
                            hasSum: true, hasAvgMinMax: false),
            HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
                StatMapping(unit: .kilocalorie(), unitLabel: "kcal",
                            publicKey: "basal_energy",
                            hasSum: true, hasAvgMinMax: false),
            HKQuantityTypeIdentifier.heartRate.rawValue:
                StatMapping(unit: bpm, unitLabel: "bpm",
                            publicKey: "heart_rate",
                            hasSum: false, hasAvgMinMax: true),
            HKQuantityTypeIdentifier.stepCount.rawValue:
                StatMapping(unit: .count(), unitLabel: "count",
                            publicKey: "step_count",
                            hasSum: true, hasAvgMinMax: false),
            HKQuantityTypeIdentifier.flightsClimbed.rawValue:
                StatMapping(unit: .count(), unitLabel: "count",
                            publicKey: "flights_climbed",
                            hasSum: true, hasAvgMinMax: false),
            HKQuantityTypeIdentifier.runningPower.rawValue:
                StatMapping(unit: .watt(), unitLabel: "W",
                            publicKey: "running_power",
                            hasSum: false, hasAvgMinMax: true),
            HKQuantityTypeIdentifier.runningSpeed.rawValue:
                StatMapping(unit: mps, unitLabel: "m/s",
                            publicKey: "running_speed",
                            hasSum: false, hasAvgMinMax: true),
            HKQuantityTypeIdentifier.runningStrideLength.rawValue:
                StatMapping(unit: .meter(), unitLabel: "m",
                            publicKey: "running_stride_length",
                            hasSum: false, hasAvgMinMax: true),
            HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue:
                StatMapping(unit: .meterUnit(with: .centi), unitLabel: "cm",
                            publicKey: "running_vertical_oscillation",
                            hasSum: false, hasAvgMinMax: true),
            HKQuantityTypeIdentifier.runningGroundContactTime.rawValue:
                StatMapping(unit: .secondUnit(with: .milli), unitLabel: "ms",
                            publicKey: "running_ground_contact_time",
                            hasSum: false, hasAvgMinMax: true),
            HKQuantityTypeIdentifier.cyclingPower.rawValue:
                StatMapping(unit: .watt(), unitLabel: "W",
                            publicKey: "cycling_power",
                            hasSum: false, hasAvgMinMax: true),
            HKQuantityTypeIdentifier.cyclingSpeed.rawValue:
                StatMapping(unit: mps, unitLabel: "m/s",
                            publicKey: "cycling_speed",
                            hasSum: false, hasAvgMinMax: true),
            HKQuantityTypeIdentifier.cyclingCadence.rawValue:
                StatMapping(unit: rpm, unitLabel: "rpm",
                            publicKey: "cycling_cadence",
                            hasSum: false, hasAvgMinMax: true),
            HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue:
                StatMapping(unit: .count(), unitLabel: "count",
                            publicKey: "swimming_stroke_count",
                            hasSum: true, hasAvgMinMax: false)
        ]
    }()

    /// Reads data for a single HealthDataType. Returns (payloadKey, data) pairs or nil if empty.
    /// Most types produce one pair; menstruation produces both flow records and derived periods.
    /// Reads are capped oldest-first per type (see SyncLimits) to bound payload size.
    private func readDataForType(
        _ dataType: HealthDataType,
        start: Date,
        end: Date
    ) async throws -> [(String, Any)]? {
        let limit = SyncLimits.maxRecordsPerSync(for: dataType)
        switch dataType {
        case .steps:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.stepCount),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "count": Int(sample.quantity.doubleValue(for: .count())),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("steps", mapped)]

        case .distance:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.distanceWalkingRunning),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "meters": sample.quantity.doubleValue(for: .meter()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("distance", mapped)]

        case .activeCalories:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.activeEnergyBurned),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("active_calories", mapped)]

        case .totalCalories:
            async let activeRecords = readQuantitySamples(
                type: HKQuantityType(.activeEnergyBurned),
                start: start, end: end,
                limit: limit
            )
            async let basalRecords = readQuantitySamples(
                type: HKQuantityType(.basalEnergyBurned),
                start: start, end: end,
                limit: limit
            )
            let combined = try await SyncLimits.capOldestFirst(
                activeRecords + basalRecords,
                limit: limit,
                timeOf: { $0.startDate }
            )
            let mapped = combined.map { sample -> [String: Any] in
                record([
                    "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("total_calories", mapped)]

        case .weight:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bodyMass),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "kilograms": sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("weight", mapped)]

        case .height:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.height),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "meters": sample.quantity.doubleValue(for: .meter()),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("height", mapped)]

        case .heartRate:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.heartRate),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "bpm": Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("heart_rate", mapped)]

        case .restingHeartRate:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.restingHeartRate),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "bpm": Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("resting_heart_rate", mapped)]

        case .heartRateVariability:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.heartRateVariabilitySDNN),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "heart_rate_variability_millis": sample.quantity.doubleValue(for: .secondUnit(with: .milli)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("heart_rate_variability", mapped)]

        case .bloodPressure:
            async let systolicRecords = readQuantitySamples(
                type: HKQuantityType(.bloodPressureSystolic),
                start: start, end: end,
                limit: limit
            )
            async let diastolicRecords = readQuantitySamples(
                type: HKQuantityType(.bloodPressureDiastolic),
                start: start, end: end,
                limit: limit
            )
            let systolic = try await systolicRecords
            let diastolic = try await diastolicRecords
            let mmHg = HKUnit.millimeterOfMercury()
            var mapped: [[String: Any]] = []
            for systolicSample in systolic {
                let matchingDiastolic = diastolic.first {
                    abs($0.startDate.timeIntervalSince(systolicSample.startDate)) < 1
                }
                var fields: [String: Any] = [
                    "systolic": systolicSample.quantity.doubleValue(for: mmHg),
                    "time": systolicSample.startDate.iso8601String
                ]
                if let diastolicSample = matchingDiastolic {
                    fields["diastolic"] = diastolicSample.quantity.doubleValue(for: mmHg)
                }
                mapped.append(record(fields, from: systolicSample))
            }
            return mapped.isEmpty ? nil : [("blood_pressure", mapped)]

        case .bloodGlucose:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bloodGlucose),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "mmol_per_liter": sample.quantity.doubleValue(
                        for: HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
                    ),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("blood_glucose", mapped)]

        case .oxygenSaturation:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.oxygenSaturation),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "percentage": sample.quantity.doubleValue(for: .percent()) * 100,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("oxygen_saturation", mapped)]

        case .bodyTemperature:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bodyTemperature),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "celsius": sample.quantity.doubleValue(for: .degreeCelsius()),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("body_temperature", mapped)]

        case .respiratoryRate:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.respiratoryRate),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "rate": sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("respiratory_rate", mapped)]

        case .bodyFat:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bodyFatPercentage),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "percentage": sample.quantity.doubleValue(for: .percent()) * 100,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("body_fat", mapped)]

        case .leanBodyMass:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.leanBodyMass),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "kilograms": sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("lean_body_mass", mapped)]

        case .sleep:
            let sleepData = try await readSleepData(start: start, end: end, limit: limit)
            return sleepData.isEmpty ? nil : [("sleep", sleepData)]

        case .exercise:
            let workouts = try await readWorkouts(start: start, end: end, limit: limit)
            return workouts.isEmpty ? nil : [("exercise", workouts)]

        case .hydration:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.dietaryWater),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "liters": sample.quantity.doubleValue(for: .liter()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("hydration", mapped)]

        case .nutrition:
            let nutritionData = try await readNutritionData(start: start, end: end, limit: limit)
            return nutritionData.isEmpty ? nil : [("nutrition", nutritionData)]

        case .mindfulness:
            let records = try await readCategorySamples(
                type: HKCategoryType(.mindfulSession),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                let duration = sample.endDate.timeIntervalSince(sample.startDate)
                return record([
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String,
                    "duration_seconds": Int(duration)
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("mindfulness", mapped)]

        case .menstruation:
            let records = try await readCategorySamples(
                type: HKCategoryType(.menstrualFlow),
                start: start, end: end,
                limit: limit
            )
            let flowSamples = records.compactMap { sample -> (HKCategorySample, String)? in
                guard let value = HKCategoryValueMenstrualFlow(rawValue: sample.value) else { return nil }
                switch value {
                case .light: return (sample, "light")
                case .medium: return (sample, "medium")
                case .heavy: return (sample, "heavy")
                case .unspecified: return (sample, "unknown")
                default: return nil  // .none means no bleeding: skip
                }
            }
            let mapped = flowSamples.map { sample, flow in
                record([
                    "flow": flow,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            guard !mapped.isEmpty else { return nil }

            // HealthKit has no period record type; derive periods from consecutive flow
            // days so the payload matches the Android app's menstruation_period records.
            let periods = MenstruationPeriodBuilder.periods(
                from: flowSamples.map { FlowSample(start: $0.0.startDate, end: $0.0.endDate) }
            )
            return [("menstruation_flow", mapped), ("menstruation_period", periods)]
        }
    }

    // MARK: - Query Helpers

    /// Reads at most `limit` samples, oldest first (ascending sort + query limit), so payload
    /// size stays bounded and later syncs catch up without skipping records.
    private func readQuantitySamples(
        type: HKQuantityType,
        start: Date,
        end: Date,
        limit: Int
    ) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    private func readCategorySamples(
        type: HKCategoryType,
        start: Date,
        end: Date,
        limit: Int
    ) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    private func readSleepData(start: Date, end: Date, limit: Int) async throws -> [[String: Any]] {
        let samples = try await readCategorySamples(
            type: HKCategoryType(.sleepAnalysis),
            start: start, end: end,
            limit: limit
        )

        // Stage values match the Android companion app so both can feed the same backend.
        let stageSamples = samples.compactMap { sample -> SleepStageSample? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
            let stage: String
            switch value {
            case .inBed: stage = "in_bed"  // Container only, not a real stage
            case .asleepUnspecified: stage = "sleeping"
            case .asleepCore: stage = "light"
            case .asleepDeep: stage = "deep"
            case .asleepREM: stage = "rem"
            case .awake: stage = "awake"
            @unknown default: stage = "unknown"
            }
            return SleepStageSample(
                stage: stage,
                start: sample.startDate,
                end: sample.endDate,
                uuid: sample.uuid.uuidString,
                source: sample.sourceRevision.source.name
            )
        }

        return SleepSessionBuilder.sessions(from: stageSamples)
    }

    private func readWorkouts(start: Date, end: Date, limit: Int) async throws -> [[String: Any]] {
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }

        return workouts.map { workout in
            record([
                "type": workout.workoutActivityType.name,
                "start_time": workout.startDate.iso8601String,
                "end_time": workout.endDate.iso8601String,
                "duration_seconds": Int(workout.duration)
            ], from: workout)
        }
    }

    private func readNutritionData(start: Date, end: Date, limit: Int) async throws -> [[String: Any]] {
        let calorieRecords = try await readQuantitySamples(
            type: HKQuantityType(.dietaryEnergyConsumed),
            start: start, end: end,
            limit: limit
        )
        let proteinRecords = try await readQuantitySamples(
            type: HKQuantityType(.dietaryProtein),
            start: start, end: end,
            limit: limit
        )
        let carbRecords = try await readQuantitySamples(
            type: HKQuantityType(.dietaryCarbohydrates),
            start: start, end: end,
            limit: limit
        )
        let fatRecords = try await readQuantitySamples(
            type: HKQuantityType(.dietaryFatTotal),
            start: start, end: end,
            limit: limit
        )

        // Combine by matching timestamps
        var mapped: [[String: Any]] = calorieRecords.map { sample -> [String: Any] in
            var fields: [String: Any] = [
                "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                "start_time": sample.startDate.iso8601String,
                "end_time": sample.endDate.iso8601String
            ]
            if let protein = proteinRecords.first(where: { abs($0.startDate.timeIntervalSince(sample.startDate)) < 1 }) {
                fields["protein_grams"] = protein.quantity.doubleValue(for: .gram())
            }
            if let carb = carbRecords.first(where: { abs($0.startDate.timeIntervalSince(sample.startDate)) < 1 }) {
                fields["carbs_grams"] = carb.quantity.doubleValue(for: .gram())
            }
            if let fat = fatRecords.first(where: { abs($0.startDate.timeIntervalSince(sample.startDate)) < 1 }) {
                fields["fat_grams"] = fat.quantity.doubleValue(for: .gram())
            }
            return record(fields, from: sample)
        }

        // Also include standalone protein/carb/fat records not matched to calories
        for protein in proteinRecords
        where !calorieRecords.contains(where: { abs($0.startDate.timeIntervalSince(protein.startDate)) < 1 }) {
            mapped.append(record([
                "protein_grams": protein.quantity.doubleValue(for: .gram()),
                "start_time": protein.startDate.iso8601String,
                "end_time": protein.endDate.iso8601String
            ], from: protein))
        }

        return mapped
    }
}

// MARK: - Extensions

extension Date {
    // ISO8601DateFormatter is documented as thread-safe, unlike DateFormatter
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    var iso8601String: String {
        Date.iso8601Formatter.string(from: self)
    }
}

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .americanFootball: return "american_football"
        case .archery: return "archery"
        case .australianFootball: return "australian_football"
        case .badminton: return "badminton"
        case .baseball: return "baseball"
        case .basketball: return "basketball"
        case .bowling: return "bowling"
        case .boxing: return "boxing"
        case .climbing: return "climbing"
        case .cricket: return "cricket"
        case .crossTraining: return "cross_training"
        case .curling: return "curling"
        case .cycling: return "cycling"
        case .dance: return "dance"
        case .elliptical: return "elliptical"
        case .equestrianSports: return "equestrian_sports"
        case .fencing: return "fencing"
        case .fishing: return "fishing"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .golf: return "golf"
        case .gymnastics: return "gymnastics"
        case .handball: return "handball"
        case .hiking: return "hiking"
        case .hockey: return "hockey"
        case .hunting: return "hunting"
        case .lacrosse: return "lacrosse"
        case .martialArts: return "martial_arts"
        case .mindAndBody: return "mind_and_body"
        case .paddleSports: return "paddle_sports"
        case .play: return "play"
        case .preparationAndRecovery: return "preparation_and_recovery"
        case .racquetball: return "racquetball"
        case .rowing: return "rowing"
        case .rugby: return "rugby"
        case .running: return "running"
        case .sailing: return "sailing"
        case .skatingSports: return "skating_sports"
        case .snowSports: return "snow_sports"
        case .soccer: return "soccer"
        case .softball: return "softball"
        case .squash: return "squash"
        case .stairClimbing: return "stair_climbing"
        case .surfingSports: return "surfing_sports"
        case .swimming: return "swimming"
        case .tableTennis: return "table_tennis"
        case .tennis: return "tennis"
        case .trackAndField: return "track_and_field"
        case .traditionalStrengthTraining: return "traditional_strength_training"
        case .volleyball: return "volleyball"
        case .walking: return "walking"
        case .waterFitness: return "water_fitness"
        case .waterPolo: return "water_polo"
        case .waterSports: return "water_sports"
        case .wrestling: return "wrestling"
        case .yoga: return "yoga"
        case .pilates: return "pilates"
        case .highIntensityIntervalTraining: return "hiit"
        case .coreTraining: return "core_training"
        case .flexibility: return "flexibility"
        case .cooldown: return "cooldown"
        default: return "other"
        }
    }
}
