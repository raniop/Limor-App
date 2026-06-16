import CoreLocation
import Foundation
import MapKit
import UserNotifications

/// "Time to leave" notifications: for each upcoming meeting that has an
/// address, geocode it, ask MapKit for the driving ETA from the user's
/// current location, and schedule a local notification at
/// `start − travelTime − buffer`. Pure on-device (CoreLocation + MapKit +
/// UNUserNotificationCenter) — additive to the 2h-before lead notification.
///
/// Recomputed on foreground but throttled, since geocoding + directions are
/// rate-limited network calls.
@MainActor
enum DepartureNotifier {

    private static let prefix = "limor.departure."
    private static let lookaheadDays = 2
    private static let maxMeetings = 5
    /// Leave this many minutes earlier than the raw ETA suggests — parking,
    /// walking from the car, a little traffic slack.
    private static let bufferSeconds: TimeInterval = 8 * 60
    private static let throttle: TimeInterval = 20 * 60
    private static var lastRun: Date = .distantPast

    static func reschedule(force: Bool = false) async {
        if !force, Date().timeIntervalSince(lastRun) < throttle { return }

        await cancelAll()
        guard SharedStore.departureNotifEnabled else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        guard allowed else { return }

        // Need a current location to measure travel time from.
        guard let origin = LocationManager.shared.coordinate else { return }

        let now = Date()
        let events = await CalendarAggregator.upcomingEvents(daysAhead: lookaheadDays)
        let candidates = events.filter { ev in
            guard !ev.is_all_day else { return false }
            guard let loc = ev.location, !loc.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            // "Time to leave" is only for places you physically travel to — not
            // a match/show whose "location" is a TV channel or live stream.
            guard !isBroadcastLocation(loc) else { return false }
            guard let start = MeetingsCard.parseIso(ev.start_at) else { return false }
            return start > now.addingTimeInterval(10 * 60) // ignore things basically now
        }.prefix(maxMeetings)

        lastRun = now

        for ev in candidates {
            guard let start = MeetingsCard.parseIso(ev.start_at),
                  let address = ev.location else { continue }

            guard let travel = await travelTime(from: origin, toAddress: address) else { continue }
            let fire = start.addingTimeInterval(-(travel + bufferSeconds))
            guard fire > now else { continue } // already past the leave-by moment

            let minutes = max(1, Int((travel / 60).rounded()))
            let content = UNMutableNotificationContent()
            content.title = tr("זמן לצאת — \(ev.title)", "Time to leave — \(ev.title)")
            content.body = tr("כדי להגיע ב-\(timeString(start)) כדאי לצאת עכשיו. נסיעה של ~\(minutes) דק' ל\(shortAddress(address)).", "To arrive by \(timeString(start)) you should leave now. About a \(minutes) min drive to \(shortAddress(address)).")
            content.sound = .limorChosen

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "\(prefix)\(ev.event_id)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// True when an event's "location" is really a TV channel / broadcast /
    /// stream (e.g. a World Cup match on כאן 11) rather than a place to drive
    /// to. These should never get a "time to leave" alert.
    private static func isBroadcastLocation(_ location: String) -> Bool {
        let l = location.lowercased()
        let keys = [
            "כאן 11", "כאן11", "כאן 12", "כאן 13", "כאן ספורט", "כאן",
            "ערוץ", "שידור", "צפייה", "טלוויז", "שידור חי", "בשידור",
            "ספורט 1", "ספורט 2", "ספורט 3", "ספורט 4", "ספורט 5", "כאן ספורט",
            "broadcast", "live stream", "livestream", "streaming",
            "espn", "sport 1", "sport 2", "youtube", "twitch",
        ]
        return keys.contains { l.contains($0) }
    }

    // MARK: - Travel time

    private static func travelTime(from origin: CLLocationCoordinate2D, toAddress address: String) async -> TimeInterval? {
        guard let dest = await geocode(address) else { return nil }
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        req.transportType = .automobile
        do {
            let eta = try await MKDirections(request: req).calculateETA()
            return eta.expectedTravelTime
        } catch {
            return nil
        }
    }

    private static func geocode(_ address: String) async -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(address)
            return placemarks.first?.location?.coordinate
        } catch {
            return nil
        }
    }

    // MARK: - Formatting

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Trim a long address to its first component so the push body stays short.
    private static func shortAddress(_ address: String) -> String {
        let first = address.split(separator: ",").first.map(String.init) ?? address
        return first.trimmingCharacters(in: .whitespaces)
    }
}
