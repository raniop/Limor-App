import Foundation
import HealthKit

/// Read-only HealthKit aggregator. Pulls a comprehensive daily snapshot —
/// activity rings, heart, fitness, body, sleep, last workout — and exposes
/// it via `summary`.
@MainActor
final class HealthManager: ObservableObject {
    static let shared = HealthManager()

    private let store = HKHealthStore()
    @Published private(set) var hasAccess = false
    @Published private(set) var summary: HealthSummary?
    @Published private(set) var isAvailable: Bool = HKHealthStore.isHealthDataAvailable()

    private var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = []
        // Activity
        addQuantity(.stepCount, to: &set)
        addQuantity(.activeEnergyBurned, to: &set)
        addQuantity(.basalEnergyBurned, to: &set)
        addQuantity(.distanceWalkingRunning, to: &set)
        addQuantity(.appleExerciseTime, to: &set)
        addQuantity(.appleStandTime, to: &set)
        // Heart
        addQuantity(.heartRate, to: &set)
        addQuantity(.restingHeartRate, to: &set)
        addQuantity(.walkingHeartRateAverage, to: &set)
        addQuantity(.heartRateVariabilitySDNN, to: &set)
        // Fitness
        addQuantity(.vo2Max, to: &set)
        // Body
        addQuantity(.bodyMass, to: &set)
        addQuantity(.bodyFatPercentage, to: &set)
        // Workouts
        set.insert(HKObjectType.workoutType())
        // Sleep + mindfulness
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { set.insert(sleep) }
        if let mind = HKObjectType.categoryType(forIdentifier: .mindfulSession) { set.insert(mind) }
        return set
    }

    private func addQuantity(_ id: HKQuantityTypeIdentifier, to set: inout Set<HKObjectType>) {
        if let t = HKQuantityType.quantityType(forIdentifier: id) { set.insert(t) }
    }

    func requestAccess() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            hasAccess = true
            return true
        } catch {
            hasAccess = false
            return false
        }
    }

    /// Pulls a comprehensive snapshot. Each query runs in parallel; missing data
    /// → nil so the UI can render a partial card.
    func loadToday() async {
        guard hasAccess else { return }

        let today = bounds(.day)
        let week = bounds(.weekOfYear)

        async let steps     = sumQuantity(.stepCount,                unit: .count(),       predicate: today)
        async let actCals   = sumQuantity(.activeEnergyBurned,       unit: .kilocalorie(),  predicate: today)
        async let restCals  = sumQuantity(.basalEnergyBurned,        unit: .kilocalorie(),  predicate: today)
        async let dist      = sumQuantity(.distanceWalkingRunning,   unit: .meter(),        predicate: today)
        async let exMins    = sumQuantity(.appleExerciseTime,        unit: .minute(),       predicate: today)
        async let standT    = sumQuantity(.appleStandTime,           unit: .minute(),       predicate: today)
        async let mindMins  = sleepOrMindfulMinutes(.mindfulSession, predicate: today)
        async let sleepNightVal = sleepLastNight()
        async let sleepAvgVal   = sleepAverage7Nights()

        async let rhr       = mostRecentQuantity(.restingHeartRate,        unit: HKUnit(from: "count/min"))
        async let walkHR    = mostRecentQuantity(.walkingHeartRateAverage, unit: HKUnit(from: "count/min"))
        async let hrv       = mostRecentQuantity(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli))
        async let vo2       = mostRecentQuantity(.vo2Max,                  unit: HKUnit(from: "ml/(kg*min)"))
        async let weight    = mostRecentQuantity(.bodyMass,                unit: .gramUnit(with: .kilo))
        async let bodyFat   = mostRecentQuantity(.bodyFatPercentage,       unit: .percent())

        async let lastWO    = lastWorkout()
        async let weekWOs   = workoutsInRange(predicate: week)

        let (s, ac, rc, d, e, st) = await (steps, actCals, restCals, dist, exMins, standT)
        let (mm, lastNight, weekAvg) = await (mindMins, sleepNightVal, sleepAvgVal)
        let (r, w, h, v, wt, bf) = await (rhr, walkHR, hrv, vo2, weight, bodyFat)
        let (lw, ww) = await (lastWO, weekWOs)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let isoFmt = ISO8601DateFormatter()

        let standHours = st.map { Int(($0 / 60.0).rounded()) }
        let weekMinutes = ww.reduce(0.0) { $0 + ($1.duration / 60.0) }

        self.summary = HealthSummary(
            steps: s.map { Int($0) },
            active_calories_kcal: ac,
            resting_calories_kcal: rc,
            distance_km: d.map { $0 / 1000 },
            exercise_minutes: e.map { Int($0) },
            stand_hours: standHours,
            resting_heart_rate: r.map { Int($0.rounded()) },
            walking_heart_rate_avg: w.map { Int($0.rounded()) },
            heart_rate_variability_ms: h,
            vo2_max: v,
            weight_kg: wt,
            body_fat_percent: bf.map { $0 * 100 },   // HK returns 0..1
            sleep_hours: lastNight?.hours,
            sleep_bedtime_iso: lastNight?.bedtime.map { isoFmt.string(from: $0) },
            sleep_wake_time_iso: lastNight?.wakeTime.map { isoFmt.string(from: $0) },
            sleep_avg_hours_last_7: weekAvg,
            mindful_minutes: mm,
            last_workout: lw.map { workoutToSummary($0) },
            workouts_this_week: ww.count,
            workout_minutes_this_week: weekMinutes,
            date: dateFmt.string(from: Date())
        )
    }

    // MARK: - Predicates

    private enum Range { case day, weekOfYear }
    private func bounds(_ range: Range) -> NSPredicate {
        let cal = Calendar.current
        let now = Date()
        let start: Date
        switch range {
        case .day:
            start = cal.startOfDay(for: now)
        case .weekOfYear:
            start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        }
        return HKQuery.predicateForSamples(withStart: start, end: now, options: [.strictStartDate])
    }

    // MARK: - Quantity helpers

    private func sumQuantity(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        predicate: NSPredicate
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func mostRecentQuantity(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: sort) { _, samples, _ in
                if let sample = samples?.first as? HKQuantitySample {
                    continuation.resume(returning: sample.quantity.doubleValue(for: unit))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Sleep + mindfulness

    /// Aggregate stats for one night of sleep — total hours, when the user
    /// fell asleep, and when they woke up. All optional so partial-data
    /// nights still surface what we have.
    private struct SleepNight {
        let hours: Double
        let bedtime: Date?      // earliest "asleep" sample's startDate
        let wakeTime: Date?     // latest "asleep" sample's endDate
    }

    /// Sleep stages that count toward "actually asleep" — excludes inBed/awake.
    private static let asleepValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleep.rawValue,
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
    ]

    /// Last night's sleep — total hours + bedtime + wake time. Window is
    /// yesterday 18:00 → today 14:00 to cover most sleep schedules.
    private func sleepLastNight() async -> SleepNight? {
        let cal = Calendar.current
        let now = Date()
        let endOfWindow = cal.date(bySettingHour: 14, minute: 0, second: 0, of: now) ?? now
        let yesterdayEvening = cal.date(byAdding: .hour, value: -20, to: endOfWindow) ?? now
        return await sleepInWindow(start: yesterdayEvening, end: endOfWindow)
    }

    /// Average sleep hours over the last 7 completed nights. Skips nights
    /// with no data so a single missed night doesn't drag the average to 0.
    /// Returns nil if fewer than 3 nights have data (sample size too small to
    /// be meaningful).
    private func sleepAverage7Nights() async -> Double? {
        let cal = Calendar.current
        let now = Date()
        // Each "night" runs from 18:00 day N → 14:00 day N+1.
        var nightWindows: [(Date, Date)] = []
        for daysBack in 1...7 {
            guard let end = cal.date(byAdding: .day, value: -(daysBack - 1), to: cal.date(bySettingHour: 14, minute: 0, second: 0, of: now) ?? now),
                  let start = cal.date(byAdding: .hour, value: -20, to: end) else { continue }
            nightWindows.append((start, end))
        }

        let nights = await withTaskGroup(of: SleepNight?.self, returning: [SleepNight].self) { group in
            for (start, end) in nightWindows {
                group.addTask { [self] in await self.sleepInWindow(start: start, end: end) }
            }
            var results: [SleepNight] = []
            for await n in group { if let n, n.hours > 0 { results.append(n) } }
            return results
        }

        guard nights.count >= 3 else { return nil }
        let total = nights.reduce(0.0) { $0 + $1.hours }
        let avg = total / Double(nights.count)
        let perNight = nights
            .sorted { ($0.bedtime ?? .distantPast) < ($1.bedtime ?? .distantPast) }
            .map { String(format: "%.2fh", $0.hours) }
            .joined(separator: ", ")
        NSLog("[sleep] 7-night nights=[%@] avg=%.2fh", perNight, avg)
        return avg
    }

    /// Core sleep query for an arbitrary window — used by both the per-night
    /// "last night" call and the 7-night average.
    private func sleepInWindow(start: Date, end: Date) async -> SleepNight? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: nil); return
                }
                let asleep = samples.filter { Self.asleepValues.contains($0.value) }
                guard !asleep.isEmpty else {
                    continuation.resume(returning: nil); return
                }
                // **Union, not sum**: Apple Watch + third-party apps + the
                // deprecated `asleep` value coexisting with the newer
                // staged values (`asleepCore` / `asleepDeep` / `asleepREM`)
                // produce overlapping samples covering the same minutes
                // multiple times. A naive `endDate − startDate` reduce
                // would double-count every overlap and inflate both
                // "שינה אתמול" and the 7-night average. Merging intervals
                // gives us the actual wall-clock time the user was asleep.
                let totalSeconds = Self.unionDuration(asleep)
                let bedtime = asleep.map(\.startDate).min()
                let wakeTime = asleep.map(\.endDate).max()
                continuation.resume(returning: SleepNight(
                    hours: totalSeconds / 3600.0,
                    bedtime: bedtime,
                    wakeTime: wakeTime
                ))
            }
            self.store.execute(query)
        }
    }

    /// Total wall-clock seconds covered by *the union of* a set of samples'
    /// [startDate, endDate] intervals. Overlapping samples count once.
    private static func unionDuration(_ samples: [HKCategorySample]) -> TimeInterval {
        let sorted = samples
            .map { (start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for s in sorted {
            if var last = merged.last, last.end >= s.start {
                last.end = max(last.end, s.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        return merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    private func sleepOrMindfulMinutes(
        _ id: HKCategoryTypeIdentifier,
        predicate: NSPredicate
    ) async -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: id) else { return nil }
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
                    continuation.resume(returning: nil); return
                }
                let total = samples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                continuation.resume(returning: total / 60.0)
            }
            self.store.execute(query)
        }
    }

    // MARK: - Workouts

    private func lastWorkout() async -> HKWorkout? {
        return await withCheckedContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: nil,
                limit: 1,
                sortDescriptors: sort
            ) { _, samples, _ in
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(query)
        }
    }

    private func workoutsInRange(predicate: NSPredicate) async -> [HKWorkout] {
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    private func workoutToSummary(_ w: HKWorkout) -> WorkoutSummary {
        let kcalUnit = HKUnit.kilocalorie()
        let calories = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: kcalUnit)
        let distance = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter())
            ?? w.statistics(for: HKQuantityType(.distanceCycling))?
            .sumQuantity()?.doubleValue(for: .meter())
        let avgHR = w.statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?.doubleValue(for: HKUnit(from: "count/min"))

        let (name, symbol) = activityName(for: w.workoutActivityType)

        return WorkoutSummary(
            activity_name: name,
            activity_symbol: symbol,
            start_at: ISO8601DateFormatter.limor.string(from: w.startDate),
            duration_minutes: w.duration / 60.0,
            calories_kcal: calories,
            distance_km: distance.map { $0 / 1000 },
            avg_heart_rate: avgHR.map { Int($0.rounded()) }
        )
    }

    private func activityName(for type: HKWorkoutActivityType) -> (String, String) {
        switch type {
        case .running:           return (tr("ריצה", "Running"), "figure.run")
        case .walking:           return (tr("הליכה", "Walking"), "figure.walk")
        case .cycling:           return (tr("אופניים", "Cycling"), "figure.outdoor.cycle")
        case .swimming:          return (tr("שחייה", "Swimming"), "figure.pool.swim")
        case .hiking:            return (tr("טיול", "Hiking"), "figure.hiking")
        case .yoga:              return (tr("יוגה", "Yoga"), "figure.yoga")
        case .traditionalStrengthTraining,
             .functionalStrengthTraining: return (tr("כושר", "Strength training"), "figure.strengthtraining.traditional")
        case .crossTraining:     return ("Cross-Training", "figure.cross.training")
        case .pilates:           return (tr("פילאטיס", "Pilates"), "figure.pilates")
        case .dance:             return (tr("ריקוד", "Dance"), "figure.dance")
        case .boxing,
             .martialArts,
             .kickboxing:        return (tr("חבטות", "Boxing"), "figure.boxing")
        case .basketball:        return (tr("כדורסל", "Basketball"), "figure.basketball")
        case .soccer:            return (tr("כדורגל", "Soccer"), "figure.soccer")
        case .tennis:            return (tr("טניס", "Tennis"), "figure.tennis")
        case .rowing:            return (tr("חתירה", "Rowing"), "figure.rower")
        case .stairs,
             .stairClimbing:     return (tr("מדרגות", "Stairs"), "figure.stairs")
        case .elliptical:        return (tr("אליפטי", "Elliptical"), "figure.elliptical")
        case .highIntensityIntervalTraining: return ("HIIT", "figure.highintensity.intervaltraining")
        case .mindAndBody:       return (tr("מיינדפולנס", "Mindfulness"), "brain.head.profile")
        default:                 return (tr("אימון", "Workout"), "figure.mixed.cardio")
        }
    }
}
