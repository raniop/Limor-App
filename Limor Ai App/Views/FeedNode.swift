import SwiftUI

/// A node in the topic-browser tree shown in the feed editor. Either a
/// category (`children` populated, no `topic`) the user can drill into, or
/// a leaf (`topic` populated) the user can pick.
struct FeedNode: Identifiable, Hashable {
    let id: String
    let label: String
    let icon: String
    let tint: Color
    let subtitle: String?
    let children: [FeedNode]
    let topic: FeedTopic?

    var isLeaf: Bool { topic != nil }

    init(
        id: String,
        label: String,
        icon: String,
        tint: Color,
        subtitle: String? = nil,
        children: [FeedNode] = [],
        topic: FeedTopic? = nil
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.tint = tint
        self.subtitle = subtitle
        self.children = children
        self.topic = topic
    }

    /// Convenience for leaves — the topic id matches the node id, so the
    /// "selected" state in the editor stays stable across reads.
    static func leaf(id: String, label: String, query: String, icon: String, tint: Color) -> FeedNode {
        FeedNode(
            id: id, label: label, icon: icon, tint: tint,
            topic: FeedTopic(id: id, label: label, query: query)
        )
    }
}

extension FeedNode {
    static let root: [FeedNode] = [sports, news, tech, finance, culture]

    // MARK: - Sports

    static let sports = FeedNode(
        id: "sports",
        label: "ספורט",
        icon: "figure.soccer",
        tint: .green,
        subtitle: "כדורגל, כדורסל, F1 ועוד",
        children: [
            footballRoot,
            basketballRoot,
            FeedNode(id: "sports.tennis", label: "טניס", icon: "tennis.racket", tint: .yellow,
                     children: [
                        .leaf(id: "sports.tennis.atp", label: "טור ATP", query: "ATP tennis tour latest news", icon: "tennis.racket", tint: .yellow),
                        .leaf(id: "sports.tennis.grand_slams", label: "גרנד סלאם", query: "tennis grand slam latest news", icon: "trophy.fill", tint: .yellow),
                     ]),
            .leaf(id: "sports.f1", label: "פורמולה 1", query: "Formula 1 latest news race results", icon: "flag.checkered", tint: .red),
            .leaf(id: "sports.nfl", label: "NFL", query: "NFL latest news", icon: "football.fill", tint: .brown),
            .leaf(id: "sports.boxing", label: "אגרוף ו-MMA", query: "boxing and UFC latest news", icon: "figure.boxing", tint: .orange),
        ]
    )

    static let footballRoot = FeedNode(
        id: "sports.football",
        label: "כדורגל",
        icon: "soccerball",
        tint: .green,
        children: [
            FeedNode(id: "sports.football.il", label: "ישראל", icon: "star.fill", tint: .blue,
                children: [
                    .leaf(id: "sports.football.il.hapoel_ta", label: "הפועל תל אביב", query: "Hapoel Tel Aviv FC football latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.il.maccabi_ta", label: "מכבי תל אביב", query: "Maccabi Tel Aviv FC latest news", icon: "tshirt.fill", tint: .yellow),
                    .leaf(id: "sports.football.il.beitar", label: "ביתר ירושלים", query: "Beitar Jerusalem FC latest news", icon: "tshirt.fill", tint: .yellow),
                    .leaf(id: "sports.football.il.beer_sheva", label: "הפועל באר שבע", query: "Hapoel Beer Sheva FC latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.il.maccabi_haifa", label: "מכבי חיפה", query: "Maccabi Haifa FC latest news", icon: "tshirt.fill", tint: .green),
                    .leaf(id: "sports.football.il.league", label: "ליגת העל (כללי)", query: "Israeli Premier League football latest news", icon: "list.bullet", tint: .blue),
                ]),
            FeedNode(id: "sports.football.es", label: "ספרד (לה ליגה)", icon: "star.fill", tint: .red,
                children: [
                    .leaf(id: "sports.football.es.barca", label: "ברצלונה", query: "FC Barcelona latest news", icon: "tshirt.fill", tint: Color(red: 0.65, green: 0.10, blue: 0.30)),
                    .leaf(id: "sports.football.es.real", label: "ריאל מדריד", query: "Real Madrid latest news", icon: "tshirt.fill", tint: .white),
                    .leaf(id: "sports.football.es.atletico", label: "אתלטיקו מדריד", query: "Atletico Madrid latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.es.league", label: "לה ליגה (כללי)", query: "La Liga latest news standings", icon: "list.bullet", tint: .red),
                ]),
            FeedNode(id: "sports.football.en", label: "אנגליה (פרמייר)", icon: "star.fill", tint: .purple,
                children: [
                    .leaf(id: "sports.football.en.arsenal", label: "ארסנל", query: "Arsenal FC latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.en.liverpool", label: "ליברפול", query: "Liverpool FC latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.en.man_united", label: "מנצ'סטר יונייטד", query: "Manchester United FC latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.en.man_city", label: "מנצ'סטר סיטי", query: "Manchester City FC latest news", icon: "tshirt.fill", tint: .blue),
                    .leaf(id: "sports.football.en.chelsea", label: "צ'לסי", query: "Chelsea FC latest news", icon: "tshirt.fill", tint: .blue),
                    .leaf(id: "sports.football.en.tottenham", label: "טוטנהאם", query: "Tottenham FC latest news", icon: "tshirt.fill", tint: .white),
                    .leaf(id: "sports.football.en.league", label: "פרמייר ליג (כללי)", query: "Premier League football latest news standings", icon: "list.bullet", tint: .purple),
                ]),
            .leaf(id: "sports.football.ucl", label: "ליגת האלופות", query: "UEFA Champions League latest news fixtures", icon: "trophy.fill", tint: .blue),
            .leaf(id: "sports.football.world_cup", label: "מונדיאל / יורו", query: "World Cup or Euro football latest news", icon: "globe", tint: .green),
        ]
    )

    static let basketballRoot = FeedNode(
        id: "sports.basketball",
        label: "כדורסל",
        icon: "basketball.fill",
        tint: .orange,
        children: [
            FeedNode(id: "sports.bball.il", label: "ישראל", icon: "star.fill", tint: .blue,
                children: [
                    .leaf(id: "sports.bball.il.maccabi_ta", label: "מכבי תל אביב", query: "Maccabi Tel Aviv basketball latest news", icon: "tshirt.fill", tint: .yellow),
                    .leaf(id: "sports.bball.il.hapoel_ta", label: "הפועל תל אביב", query: "Hapoel Tel Aviv basketball latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.bball.il.hapoel_jerusalem", label: "הפועל ירושלים", query: "Hapoel Jerusalem basketball latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.bball.il.league", label: "ליגת העל (כללי)", query: "Israeli basketball Premier League latest news", icon: "list.bullet", tint: .blue),
                ]),
            FeedNode(id: "sports.bball.nba", label: "NBA", icon: "basketball.fill", tint: .orange,
                children: [
                    .leaf(id: "sports.bball.nba.lakers", label: "לייקרס", query: "Los Angeles Lakers latest news", icon: "tshirt.fill", tint: .purple),
                    .leaf(id: "sports.bball.nba.warriors", label: "ווריורס", query: "Golden State Warriors latest news", icon: "tshirt.fill", tint: .blue),
                    .leaf(id: "sports.bball.nba.celtics", label: "סלטיקס", query: "Boston Celtics latest news", icon: "tshirt.fill", tint: .green),
                    .leaf(id: "sports.bball.nba.bucks", label: "באקס", query: "Milwaukee Bucks latest news", icon: "tshirt.fill", tint: .green),
                    .leaf(id: "sports.bball.nba.heat", label: "מיאמי היט", query: "Miami Heat latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.bball.nba.league", label: "NBA (כללי)", query: "NBA latest news scores standings", icon: "list.bullet", tint: .orange),
                ]),
            .leaf(id: "sports.bball.euroleague", label: "יורוליג", query: "Euroleague basketball latest news", icon: "trophy.fill", tint: .blue),
        ]
    )

    // MARK: - News

    static let news = FeedNode(
        id: "news",
        label: "חדשות",
        icon: "newspaper.fill",
        tint: .indigo,
        subtitle: "ישראל, מזרח תיכון, עולם",
        children: [
            .leaf(id: "news.il", label: "ישראל", query: "Israel news today", icon: "star.fill", tint: .blue),
            FeedNode(id: "news.wars", label: "מלחמות וסכסוכים", icon: "shield.fill", tint: .red,
                children: [
                    .leaf(id: "news.wars.gaza", label: "המלחמה בעזה", query: "Gaza war latest news", icon: "exclamationmark.triangle.fill", tint: .red),
                    .leaf(id: "news.wars.lebanon", label: "צפון / לבנון", query: "Lebanon Israel border conflict latest news", icon: "exclamationmark.triangle.fill", tint: .orange),
                    .leaf(id: "news.wars.iran", label: "איראן", query: "Iran Israel conflict latest news", icon: "exclamationmark.triangle.fill", tint: .red),
                    .leaf(id: "news.wars.ukraine", label: "אוקראינה", query: "Ukraine Russia war latest news", icon: "exclamationmark.triangle.fill", tint: .blue),
                ]),
            .leaf(id: "news.middle_east", label: "מזרח תיכון", query: "Middle East news today", icon: "globe", tint: .orange),
            .leaf(id: "news.world", label: "חדשות עולם", query: "world news today", icon: "globe", tint: .blue),
            .leaf(id: "news.us_politics", label: "פוליטיקה אמריקאית", query: "US politics news today", icon: "building.columns.fill", tint: .red),
            .leaf(id: "news.europe", label: "אירופה", query: "Europe news today", icon: "globe.europe.africa.fill", tint: .blue),
        ]
    )

    // MARK: - Tech

    static let tech = FeedNode(
        id: "tech",
        label: "טק",
        icon: "cpu.fill",
        tint: .purple,
        subtitle: "AI, אפל, סטארטאפים",
        children: [
            .leaf(id: "tech.ai", label: "AI ו-LLM", query: "AI and LLM news this week", icon: "brain.head.profile", tint: .purple),
            .leaf(id: "tech.apple", label: "אפל", query: "Apple latest news products", icon: "apple.logo", tint: .gray),
            .leaf(id: "tech.tesla", label: "טסלה / מאסק", query: "Tesla and Elon Musk news", icon: "car.fill", tint: .red),
            .leaf(id: "tech.startups_il", label: "סטארטאפים ישראליים", query: "Israeli startups news", icon: "lightbulb.fill", tint: .yellow),
            .leaf(id: "tech.cyber", label: "סייבר", query: "cybersecurity news today", icon: "lock.shield.fill", tint: .blue),
            .leaf(id: "tech.gaming", label: "גיימינג", query: "gaming news this week", icon: "gamecontroller.fill", tint: .indigo),
        ]
    )

    // MARK: - Finance

    static let finance = FeedNode(
        id: "finance",
        label: "פיננסי",
        icon: "chart.line.uptrend.xyaxis",
        tint: .mint,
        subtitle: "שווקים, קריפטו, מניות",
        children: [
            .leaf(id: "finance.us_markets", label: "שווקים אמריקאים", query: "US stock market today nasdaq sp500", icon: "chart.line.uptrend.xyaxis", tint: .green),
            .leaf(id: "finance.il_markets", label: "שווקים ישראליים", query: "Tel Aviv stock exchange TA125 latest", icon: "chart.line.uptrend.xyaxis", tint: .blue),
            FeedNode(id: "finance.crypto", label: "קריפטו", icon: "bitcoinsign.circle.fill", tint: .orange,
                children: [
                    .leaf(id: "finance.crypto.btc", label: "ביטקוין", query: "Bitcoin price news today", icon: "bitcoinsign.circle.fill", tint: .orange),
                    .leaf(id: "finance.crypto.eth", label: "את'ריום", query: "Ethereum price news today", icon: "diamond.fill", tint: .blue),
                    .leaf(id: "finance.crypto.general", label: "קריפטו (כללי)", query: "cryptocurrency market news today", icon: "list.bullet", tint: .orange),
                ]),
        ]
    )

    // MARK: - Culture

    static let culture = FeedNode(
        id: "culture",
        label: "תרבות",
        icon: "music.note",
        tint: .pink,
        subtitle: "סדרות, סרטים, מוזיקה",
        children: [
            .leaf(id: "culture.tv", label: "סדרות וסרטים", query: "new TV shows movies releases this week", icon: "tv.fill", tint: .pink),
            .leaf(id: "culture.music", label: "מוזיקה", query: "music news new releases this week", icon: "music.note", tint: .purple),
            .leaf(id: "culture.books", label: "ספרים", query: "new book releases reviews", icon: "book.fill", tint: .brown),
            .leaf(id: "culture.theater", label: "תיאטרון", query: "theater news Tel Aviv Broadway latest", icon: "theatermasks.fill", tint: .orange),
        ]
    )
}
