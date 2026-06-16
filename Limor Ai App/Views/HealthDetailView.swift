import SwiftUI

/// Full breakdown of today's health data. Pushed onto the navigation stack
/// from NowView's compressed health card.
struct HealthDetailView: View {
    let summary: HealthSummary

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if !activityRows.isEmpty {
                    sectionCard(icon: "figure.run", title: tr("פעילות", "Activity"), tint: .limorMint, rows: activityRows)
                }
                if !heartRows.isEmpty {
                    sectionCard(icon: "heart.fill", title: tr("לב וכושר", "Heart & Fitness"), tint: .limorCoral, rows: heartRows)
                }
                if !recoveryRows.isEmpty {
                    sectionCard(icon: "moon.zzz.fill", title: tr("מנוחה ושינה", "Rest & Sleep"), tint: .limorViolet, rows: recoveryRows)
                }
                if !bodyRows.isEmpty {
                    sectionCard(icon: "figure.arms.open", title: tr("גוף", "Body"), tint: .limorIndigo, rows: bodyRows)
                }
                if let workout = summary.last_workout {
                    LastWorkoutCard(
                        workout: workout,
                        weekCount: summary.workouts_this_week,
                        weekMinutes: summary.workout_minutes_this_week
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 32)
        }
        .background(LiquidBackdrop().ignoresSafeArea())
        .navigationTitle(tr("בריאות", "Health"))
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Row builders

    private var activityRows: [HealthDetailRowData] {
        var rows: [HealthDetailRowData] = []
        if let steps = summary.steps {
            rows.append(.init(icon: "figure.walk", label: tr("צעדים", "Steps"),
                              value: stepsString(steps), tint: .limorMint))
        }
        if let cals = summary.active_calories_kcal, cals > 0 {
            rows.append(.init(icon: "flame.fill", label: tr("קלוריות פעילות", "Active calories"),
                              value: "\(Int(cals.rounded())) kcal", tint: .limorCoral))
        }
        if let cals = summary.resting_calories_kcal, cals > 0 {
            rows.append(.init(icon: "moon.fill", label: tr("קלוריות מנוחה", "Resting calories"),
                              value: "\(Int(cals.rounded())) kcal", tint: .limorMuted))
        }
        if let mins = summary.exercise_minutes, mins > 0 {
            rows.append(.init(icon: "stopwatch.fill", label: tr("דקות פעילות", "Exercise minutes"),
                              value: "\(mins)", tint: .limorViolet))
        }
        if let stand = summary.stand_hours, stand > 0 {
            rows.append(.init(icon: "figure.stand", label: tr("שעות עמידה", "Stand hours"),
                              value: "\(stand)", tint: .limorIndigo))
        }
        if let dist = summary.distance_km, dist > 0 {
            rows.append(.init(icon: "map.fill", label: tr("מרחק", "Distance"),
                              value: String(format: tr("%.2f ק\"מ", "%.2f km"), dist), tint: .limorIndigo))
        }
        return rows
    }

    private var heartRows: [HealthDetailRowData] {
        var rows: [HealthDetailRowData] = []
        if let rhr = summary.resting_heart_rate {
            rows.append(.init(icon: "heart.fill", label: tr("דופק במנוחה", "Resting heart rate"),
                              value: "\(rhr) bpm", tint: .limorCoral))
        }
        if let walking = summary.walking_heart_rate_avg {
            rows.append(.init(icon: "figure.walk.motion", label: tr("דופק בהליכה", "Walking heart rate"),
                              value: "\(walking) bpm", tint: .limorCoral))
        }
        if let hrv = summary.heart_rate_variability_ms {
            rows.append(.init(icon: "waveform.path.ecg", label: "HRV",
                              value: String(format: "%.0f ms", hrv), tint: .limorCoral))
        }
        if let vo2 = summary.vo2_max {
            rows.append(.init(icon: "lungs.fill", label: "VO2 Max",
                              value: String(format: "%.1f", vo2), tint: .limorMint))
        }
        return rows
    }

    private var recoveryRows: [HealthDetailRowData] {
        var rows: [HealthDetailRowData] = []
        if let sleep = summary.sleep_hours, sleep > 0 {
            rows.append(.init(icon: "moon.zzz.fill", label: tr("שינה אתמול", "Sleep last night"),
                              value: String(format: tr("%.1f שעות", "%.1f hrs"), sleep), tint: .limorViolet))
        }
        if let bedtime = summary.sleep_bedtime_iso, let date = isoDate(bedtime) {
            rows.append(.init(icon: "bed.double.fill", label: tr("הלכת לישון", "Went to bed"),
                              value: hourMinute(date), tint: .limorIndigo))
        }
        if let wake = summary.sleep_wake_time_iso, let date = isoDate(wake) {
            rows.append(.init(icon: "sunrise.fill", label: tr("התעוררת", "Woke up"),
                              value: hourMinute(date), tint: .limorWarning))
        }
        if let avg = summary.sleep_avg_hours_last_7, avg > 0 {
            rows.append(.init(icon: "chart.bar.fill", label: tr("ממוצע 7 ימים", "7-day average"),
                              value: String(format: tr("%.1f שעות", "%.1f hrs"), avg), tint: .limorMint))
        }
        if let mindful = summary.mindful_minutes, mindful > 0 {
            rows.append(.init(icon: "brain.head.profile", label: tr("מיינדפולנס", "Mindfulness"),
                              value: tr("\(Int(mindful)) דק'", "\(Int(mindful)) min"), tint: .limorMint))
        }
        return rows
    }

    private func isoDate(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }

    private func hourMinute(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private var bodyRows: [HealthDetailRowData] {
        var rows: [HealthDetailRowData] = []
        if let weight = summary.weight_kg {
            rows.append(.init(icon: "scalemass.fill", label: tr("משקל", "Weight"),
                              value: String(format: tr("%.1f ק\"ג", "%.1f kg"), weight), tint: .limorIndigo))
        }
        if let bf = summary.body_fat_percent, bf > 0 {
            rows.append(.init(icon: "drop.fill", label: tr("אחוז שומן", "Body fat"),
                              value: String(format: "%.1f%%", bf), tint: .limorViolet))
        }
        return rows
    }

    private func sectionCard(icon: String, title: String, tint: Color, rows: [HealthDetailRowData]) -> some View {
        GlassCard(padding: 18, tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(tint.opacity(0.18)).frame(width: 28, height: 28)
                        Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
                    }
                    Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.limorInk)
                    Spacer()
                }
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        HealthDetailFullRow(row: row)
                    }
                }
            }
        }
    }

    private func stepsString(_ steps: Int) -> String {
        if steps >= 1000 {
            return String(format: "%.1fK", Double(steps) / 1000)
        }
        return "\(steps)"
    }
}

struct HealthDetailFullRow: View {
    let row: HealthDetailRowData

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(row.tint.opacity(0.15)).frame(width: 32, height: 32)
                Image(systemName: row.icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(row.tint)
            }
            Text(row.label)
                .font(.subheadline)
                .foregroundStyle(.limorInk)
            Spacer()
            Text(row.value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(row.tint)
        }
    }
}
