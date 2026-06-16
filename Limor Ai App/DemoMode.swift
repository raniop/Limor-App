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
        // Shared so the hotel's matched_flight_id lines up with the flight's id.
        let flightDepIso = iso(13 * 24 * 3600)
        return InsightsBundle(
            flights: [
                FlightInsight(airline: "Blue Bird Airways", flight_number: "BZ706",
                              departure_date_iso: flightDepIso,
                              departure_airport: "ATH", arrival_airport: "TLV",
                              passenger_name: "Rani Ophir", booking_reference: "Q2K9PL",
                              source_email_id: nil),
            ],
            hotels: [
                HotelInsight(hotel_name: "Athens Plaza Hotel", city: "אתונה",
                             address: "Syntagma Square, Athens",
                             check_in_date_iso: iso(10 * 24 * 3600),
                             check_out_date_iso: iso(13 * 24 * 3600),
                             guest_name: "Rani Ophir", booking_reference: "Q2K9PL",
                             source_email_id: nil,
                             matched_flight_id: "Blue Bird Airways-BZ706-\(flightDepIso)"),
            ],
            receipts: [
                ReceiptInsight(vendor: "שופרסל אונליין", amount: 486.30, currency: "ILS", amount_ils: nil,
                               category: "groceries", transaction_date_iso: iso(-2 * 24 * 3600),
                               description: "משלוח שבועי", source_email_id: nil),
                ReceiptInsight(vendor: "Netflix", amount: 54.90, currency: "ILS", amount_ils: nil,
                               category: "subscriptions", transaction_date_iso: iso(-4 * 24 * 3600),
                               description: "מנוי חודשי", source_email_id: nil),
                ReceiptInsight(vendor: "Wolt", amount: 128.00, currency: "ILS", amount_ils: nil,
                               category: "dining", transaction_date_iso: iso(-5 * 24 * 3600),
                               description: "ארוחת ערב", source_email_id: nil),
                ReceiptInsight(vendor: "פז Yellow", amount: 312.50, currency: "ILS", amount_ils: nil,
                               category: "transport", transaction_date_iso: iso(-8 * 24 * 3600),
                               description: "תדלוק", source_email_id: nil),
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

    static var worldCup: WorldCupBundle {
        WorldCupBundle(
            matches: [
                WorldCupMatch(id: "mexico-poland-demo", stage: "שלב הבתים", group: "A",
                              home_team: "מקסיקו", away_team: "פולין",
                              home_flag: "🇲🇽", away_flag: "🇵🇱",
                              kickoff_iso: iso(-2 * 3600), venue: "אצטדיון אצטקה, מקסיקו סיטי",
                              status: "live", home_score: 1, away_score: 0),
                WorldCupMatch(id: "usa-wales-demo", stage: "שלב הבתים", group: "B",
                              home_team: "ארה״ב", away_team: "ויילס",
                              home_flag: "🇺🇸", away_flag: "🏴",
                              kickoff_iso: iso(5 * 3600), venue: "SoFi Stadium, לוס אנג'לס",
                              status: "scheduled", home_score: nil, away_score: nil),
                WorldCupMatch(id: "argentina-nigeria-demo", stage: "שלב הבתים", group: "C",
                              home_team: "ארגנטינה", away_team: "ניגריה",
                              home_flag: "🇦🇷", away_flag: "🇳🇬",
                              kickoff_iso: iso(26 * 3600), venue: "MetLife Stadium, ניו יורק",
                              status: "scheduled", home_score: nil, away_score: nil),
                WorldCupMatch(id: "france-norway-demo", stage: "שלב הבתים", group: "D",
                              home_team: "צרפת", away_team: "נורווגיה",
                              home_flag: "🇫🇷", away_flag: "🇳🇴",
                              kickoff_iso: iso(-20 * 3600), venue: "BMO Field, טורונטו",
                              status: "finished", home_score: 3, away_score: 1),
            ],
            generated_at: iso()
        )
    }

    static var briefing: CeoBriefing {
        let html = """
        <div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif; font-size:15px; line-height:1.6; color:#1a1a1a; max-width:680px;">
        <p>Dear Investors,</p>
        <p>I wanted to share a brief update on the company's progress over the last two weeks.</p>
        <hr style="border:none; border-top:1px solid #e3e3e3; margin:20px 0;">
        <h2 style="font-size:18px; margin:24px 0 8px; color:#111;">Executive Summary</h2>
        <p>We shipped rapidly across our product portfolio this period, with several TestFlight releases and an active support cycle. Momentum is strong on execution; commercial traction remains early-stage.</p>
        <h2 style="font-size:18px; margin:24px 0 8px; color:#111;">Product &amp; Technology Updates</h2>
        <ul style="margin:6px 0 6px 18px; padding:0;">
        <li style="margin:4px 0;"><strong>Rapid release cadence</strong> — multiple builds shipped to TestFlight, demonstrating a tight iteration loop.</li>
        <li style="margin:4px 0;"><strong>AI cost optimization</strong> — identified up to 51% potential savings via prompt caching.</li>
        </ul>
        <h2 style="font-size:18px; margin:24px 0 8px; color:#111;">Risks &amp; Challenges</h2>
        <ul style="margin:6px 0 6px 18px; padding:0;">
        <li style="margin:4px 0;"><strong>Unit economics</strong> — current per-user AI cost is high; mitigation in progress (BYOK + caching).</li>
        </ul>
        <p>Best regards,<br><strong>Rani Ophir</strong><br>CEO</p>
        </div>
        """
        return CeoBriefing(
            subject: "Executive Business Update — Last 14 Days",
            html_body: html, lang: "en",
            timeframe_days: 14, email_count: 49,
            generated_at: iso(-1800), status: "ready"
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
