import Foundation

/// Lightweight demo harness: launch the app with `--limor-demo` to bypass
/// sign-in and render the UI with sample data, so we can review the layout
/// (especially the iPad dashboard) without a real account. Pure visual aid —
/// no network calls fire in this mode.
enum DemoMode {
    static let isOn = ProcessInfo.processInfo.arguments.contains("--limor-demo")
}

/// Sample content for `DemoMode`.
enum DemoData {
    private static func iso(_ offset: TimeInterval = 0) -> String {
        ISO8601DateFormatter.limor.string(from: Date().addingTimeInterval(offset))
    }

    static var reminders: [Reminder] {
        [
            Reminder(id: "d1", task: "פאדל — פארק לאומי ר\"ג, מגרש 3", due_at: iso(3 * 3600),
                     status: .pending, created_at: iso(), completed_at: nil,
                     msUntilDue: 3 * 3600 * 1000, isOverdue: false),
            Reminder(id: "d2", task: "להתקשר לרופא שיניים ולקבוע תור", due_at: iso(26 * 3600),
                     status: .pending, created_at: iso(), completed_at: nil,
                     msUntilDue: 26 * 3600 * 1000, isOverdue: false),
            Reminder(id: "d3", task: "לשלם ארנונה", due_at: iso(50 * 3600),
                     status: .pending, created_at: iso(), completed_at: nil,
                     msUntilDue: 50 * 3600 * 1000, isOverdue: false),
        ]
    }

    static var snapshot: NowResponse {
        NowResponse(
            next_reminder: reminders.first,
            weather: Weather(temp_c: 28, feels_like_c: 29, condition: "בהיר",
                             icon: "sun.max.fill", high_c: 31, low_c: 22,
                             fetched_at: iso(), lat: 32.08, lng: 34.78),
            user: NowResponse.User(display_name: "רני אופיר"),
            updated_at: iso()
        )
    }

    static var insights: InsightsBundle {
        InsightsBundle(
            flights: [
                FlightInsight(airline: "Blue Bird Airways", flight_number: "BZ706",
                              departure_date_iso: iso(13 * 24 * 3600),
                              departure_airport: "ATH", arrival_airport: "TLV",
                              passenger_name: "Rani Ophir", booking_reference: "Q2K9PL",
                              source_email_id: nil),
            ],
            recommendations: [
                Recommendation(id: "rc1", kind: "movement", title: "בא לך סיבוב קצר?",
                               body: "2,000 צעדים עד עכשיו. 15 דקות הליכה אחרי הצהריים יעשו לך טוב.",
                               cta: "תזכירי לי ב-17:00", priority: 1, generated_at: iso()),
                Recommendation(id: "rc2", kind: "calendar", title: "צהריים עמוסים",
                               body: "3 פגישות רצופות בין 12:00 ל-15:00. עדיף לאכול לפני או אחרי.",
                               cta: nil, priority: 2, generated_at: iso()),
            ],
            generated_at: iso()
        )
    }

    static var feed: FeedBundle {
        FeedBundle(
            topics: [FeedTopic(id: "tt1", label: "טכנולוגיה", query: "tech")],
            items: [
                FeedItem(topic_id: "tt1", topic_label: "טכנולוגיה",
                         headline: "WWDC 2026 נפתח ביום שני — iOS 27 בדרך",
                         body: "אפל צפויה להציג עיצוב מחודש וסירי חכמה יותר.",
                         sources: [], generated_at: iso()),
                FeedItem(topic_id: "tt1", topic_label: "טכנולוגיה",
                         headline: "עדכון תוכנה מתפרס למיליוני מכשירים",
                         body: "הגרסה החדשה כוללת שיפורי ביצועים וסוללה.",
                         sources: [], generated_at: iso()),
            ],
            generated_at: iso()
        )
    }

    static var tasks: [LimorTask] {
        [
            LimorTask(id: "tk1", title: "לרשום ילדים לקייטנות קיץ", done: false,
                      tags: ["בית"], created_at: iso(), completed_at: nil),
            LimorTask(id: "tk2", title: "לשלוח חוזה חתום ללקוח", done: false,
                      tags: ["עבודה", "דחוף"], created_at: iso(), completed_at: nil),
            LimorTask(id: "tk3", title: "לקנות ליהלי ספרי קריאה", done: false,
                      tags: [], created_at: iso(), completed_at: nil),
        ]
    }
}
