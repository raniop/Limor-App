import SwiftUI

struct WeatherDetailView: View {
    let lat: Double
    let lng: Double
    let cityName: String?

    @State private var detail: WeatherDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            background
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let detail {
                        heroCard(current: detail.current)
                        if !detail.hourly.isEmpty {
                            hourlyCard(detail.hourly)
                        }
                        if !detail.daily.isEmpty {
                            dailyCard(detail.daily)
                        }
                        metricsCard(current: detail.current,
                                    todaySunrise: detail.daily.first?.sunrise,
                                    todaySunset: detail.daily.first?.sunset)
                    } else if isLoading {
                        ProgressView().tint(.white).frame(height: 300)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.white)
                            .padding()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .refreshable { await reload() }
        }
        .navigationTitle(cityName ?? "מזג אוויר")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await reload() }
    }

    // MARK: - Background gradient based on condition + time

    private var background: some View {
        let gradient = backgroundGradient(for: detail?.current)
        return ZStack {
            gradient.ignoresSafeArea()
            // Subtle decorative blobs
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: 140, y: -260)
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: -130, y: 280)
        }
        .ignoresSafeArea()
    }

    private func backgroundGradient(for current: WeatherDetail.CurrentWeather?) -> LinearGradient {
        let isNight = isNighttimeNow()
        guard let current else {
            return LinearGradient(colors: [.limorIndigo, .limorViolet], startPoint: .top, endPoint: .bottom)
        }
        if current.icon.contains("sun") {
            return isNight
                ? LinearGradient(colors: [.indigo, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.3), Color(red: 1, green: 0.78, blue: 0.45)], startPoint: .top, endPoint: .bottom)
        }
        if current.icon.contains("rain") || current.icon.contains("drizzle") {
            return LinearGradient(colors: [.limorIndigo, Color(red: 0.2, green: 0.4, blue: 0.6)], startPoint: .top, endPoint: .bottom)
        }
        if current.icon.contains("snow") {
            return LinearGradient(colors: [Color(red: 0.7, green: 0.85, blue: 1.0), Color(red: 0.5, green: 0.6, blue: 0.85)], startPoint: .top, endPoint: .bottom)
        }
        if current.icon.contains("bolt") {
            return LinearGradient(colors: [.indigo, .purple.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
        if current.icon.contains("fog") {
            return LinearGradient(colors: [.gray, Color(red: 0.5, green: 0.55, blue: 0.65)], startPoint: .top, endPoint: .bottom)
        }
        // Cloudy default
        return LinearGradient(colors: [Color(red: 0.45, green: 0.6, blue: 0.85), Color(red: 0.6, green: 0.7, blue: 0.85)], startPoint: .top, endPoint: .bottom)
    }

    private func isNighttimeNow() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 6 || hour >= 19
    }

    // MARK: - Hero card

    private func heroCard(current: WeatherDetail.CurrentWeather) -> some View {
        VStack(spacing: 6) {
            Image(systemName: current.icon)
                .font(.system(size: 80, weight: .semibold))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
                .padding(.top, 8)
            Text("\(Int(current.temp_c.rounded()))°")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            Text(current.condition)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
            Text("מורגש כמו \(Int(current.feels_like_c.rounded()))°")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Hourly

    private func hourlyCard(_ hours: [WeatherDetail.HourlyForecast]) -> some View {
        glassCard(title: "השעות הקרובות", icon: "clock.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(hours.prefix(24)) { h in
                        VStack(spacing: 6) {
                            Text(formatHour(h.time))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            Image(systemName: h.icon)
                                .font(.title3)
                                .foregroundStyle(.white)
                                .symbolRenderingMode(.hierarchical)
                                .frame(height: 28)
                            Text("\(Int(h.temp_c.rounded()))°")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                            if let p = h.precipitation_probability, p > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "drop.fill").font(.caption2)
                                    Text("\(p)%").font(.caption2.weight(.semibold).monospacedDigit())
                                }
                                .foregroundStyle(.cyan)
                            } else {
                                Text(" ").font(.caption2)
                            }
                        }
                        .frame(width: 50)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            }
        }
    }

    private func formatHour(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter.limorPermissive.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: - Daily

    private func dailyCard(_ days: [WeatherDetail.DailyForecast]) -> some View {
        glassCard(title: "תחזית 7 ימים", icon: "calendar") {
            VStack(spacing: 10) {
                ForEach(days.prefix(7)) { d in
                    HStack {
                        Text(formatDay(d.date))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 90, alignment: .leading)
                        Image(systemName: d.icon)
                            .font(.body)
                            .foregroundStyle(.white)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 28)
                        if let p = d.precipitation_probability_max, p > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "drop.fill").font(.caption2)
                                Text("\(p)%").font(.caption2.weight(.bold).monospacedDigit())
                            }
                            .foregroundStyle(.cyan)
                        }
                        Spacer()
                        Text("\(Int(d.min_temp_c.rounded()))°")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 40, alignment: .trailing)
                        Text("\(Int(d.max_temp_c.rounded()))°")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func formatDay(_ ymd: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let date = inFmt.date(from: ymd) else { return ymd }
        if Calendar.current.isDateInToday(date) { return "היום" }
        if Calendar.current.isDateInTomorrow(date) { return "מחר" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "EEEE d.M"
        return f.string(from: date)
    }

    // MARK: - Metrics

    private func metricsCard(current: WeatherDetail.CurrentWeather,
                              todaySunrise: String?, todaySunset: String?) -> some View {
        glassCard(title: "פרטים נוספים", icon: "info.circle.fill") {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                if let h = current.humidity_percent {
                    metric(icon: "humidity.fill", label: "לחות", value: "\(h)%")
                }
                if let w = current.wind_speed_kmh {
                    metric(
                        icon: "wind",
                        label: "רוח",
                        value: String(format: "%.0f קמ\"ש %@", w, windDirection(current.wind_direction_deg))
                    )
                }
                if let uv = current.uv_index {
                    metric(icon: "sun.max.fill", label: "UV",
                           value: "\(Int(uv.rounded())) (\(uvLabel(uv)))")
                }
                if let v = current.visibility_km {
                    metric(icon: "eye.fill", label: "ראות",
                           value: String(format: "%.0f ק\"מ", v))
                }
                if let p = current.precipitation_mm {
                    metric(icon: "drop.fill", label: "משקעים",
                           value: String(format: "%.1f מ\"מ", p))
                }
                if let sunrise = todaySunrise {
                    metric(icon: "sunrise.fill", label: "זריחה",
                           value: formatTimeOfDay(sunrise))
                }
                if let sunset = todaySunset {
                    metric(icon: "sunset.fill", label: "שקיעה",
                           value: formatTimeOfDay(sunset))
                }
            }
        }
    }

    private func metric(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.18)).frame(width: 32, height: 32)
                Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                Text(value).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(.white)
            }
            Spacer()
        }
    }

    private func windDirection(_ deg: Double?) -> String {
        guard let deg else { return "" }
        let dirs = ["צפון", "צ-מז", "מזרח", "ד-מז", "דרום", "ד-מע", "מערב", "צ-מע"]
        let idx = Int((deg / 45).rounded()) % 8
        return dirs[(idx + 8) % 8]
    }

    private func uvLabel(_ uv: Double) -> String {
        switch uv {
        case ..<3: return "נמוך"
        case 3..<6: return "בינוני"
        case 6..<8: return "גבוה"
        case 8..<11: return "גבוה מאוד"
        default: return "קיצוני"
        }
    }

    private func formatTimeOfDay(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter.limorPermissive.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: - Glass card wrapper

    private func glassCard<Content: View>(
        title: String, icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.bold))
                Text(title).font(.caption.weight(.bold))
            }
            .foregroundStyle(.white.opacity(0.85))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 0.6)
        )
    }

    // MARK: - Networking

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await APIClient.shared.weatherDetail(lat: lat, lng: lng)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension ISO8601DateFormatter {
    /// Open-Meteo returns timestamps without fractional seconds and sometimes
    /// without timezone — accept both "2026-05-10T12:00" and full ISO.
    static let limorPermissive: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
