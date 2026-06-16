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
        label: tr("ספורט", "Sports"),
        icon: "figure.soccer",
        tint: .green,
        subtitle: tr("כדורגל, כדורסל, F1 ועוד", "Soccer, basketball, F1 and more"),
        children: [
            .leaf(id: "sports.general", label: tr("ספורט (כללי)", "Sports (general)"), query: "general sports news today highlights", icon: "list.bullet", tint: .green),
            footballRoot,
            basketballRoot,
            FeedNode(id: "sports.tennis", label: tr("טניס", "Tennis"), icon: "tennis.racket", tint: .yellow,
                     children: [
                        .leaf(id: "sports.tennis.general", label: tr("טניס (כללי)", "Tennis (general)"), query: "tennis news latest results", icon: "list.bullet", tint: .yellow),
                        .leaf(id: "sports.tennis.atp", label: tr("טור ATP", "ATP Tour"), query: "ATP tennis tour latest news", icon: "tennis.racket", tint: .yellow),
                        .leaf(id: "sports.tennis.grand_slams", label: tr("גרנד סלאם", "Grand Slam"), query: "tennis grand slam latest news", icon: "trophy.fill", tint: .yellow),
                     ]),
            .leaf(id: "sports.f1", label: tr("פורמולה 1", "Formula 1"), query: "Formula 1 latest news race results", icon: "flag.checkered", tint: .red),
            .leaf(id: "sports.nfl", label: "NFL", query: "NFL latest news", icon: "football.fill", tint: .brown),
            .leaf(id: "sports.boxing", label: tr("אגרוף ו-MMA", "Boxing & MMA"), query: "boxing and UFC latest news", icon: "figure.boxing", tint: .orange),
        ]
    )

    static let footballRoot = FeedNode(
        id: "sports.football",
        label: tr("כדורגל", "Football"),
        icon: "soccerball",
        tint: .green,
        children: [
            .leaf(id: "sports.football.general", label: tr("כדורגל (כללי)", "Football (general)"), query: "world football soccer news today", icon: "list.bullet", tint: .green),
            FeedNode(id: "sports.football.il", label: tr("ישראל", "Israel"), icon: "star.fill", tint: .blue,
                children: [
                    .leaf(id: "sports.football.il.hapoel_ta", label: tr("הפועל תל אביב", "Hapoel Tel Aviv"), query: "Hapoel Tel Aviv FC football latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.il.maccabi_ta", label: tr("מכבי תל אביב", "Maccabi Tel Aviv"), query: "Maccabi Tel Aviv FC latest news", icon: "tshirt.fill", tint: .yellow),
                    .leaf(id: "sports.football.il.beitar", label: tr("ביתר ירושלים", "Beitar Jerusalem"), query: "Beitar Jerusalem FC latest news", icon: "tshirt.fill", tint: .yellow),
                    .leaf(id: "sports.football.il.beer_sheva", label: tr("הפועל באר שבע", "Hapoel Be'er Sheva"), query: "Hapoel Beer Sheva FC latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.il.maccabi_haifa", label: tr("מכבי חיפה", "Maccabi Haifa"), query: "Maccabi Haifa FC latest news", icon: "tshirt.fill", tint: .green),
                    .leaf(id: "sports.football.il.league", label: tr("ליגת העל (כללי)", "Premier League (general)"), query: "Israeli Premier League football latest news", icon: "list.bullet", tint: .blue),
                ]),
            FeedNode(id: "sports.football.es", label: tr("ספרד (לה ליגה)", "Spain (La Liga)"), icon: "star.fill", tint: .red,
                children: [
                    .leaf(id: "sports.football.es.barca", label: tr("ברצלונה", "Barcelona"), query: "FC Barcelona latest news", icon: "tshirt.fill", tint: Color(red: 0.65, green: 0.10, blue: 0.30)),
                    .leaf(id: "sports.football.es.real", label: tr("ריאל מדריד", "Real Madrid"), query: "Real Madrid latest news", icon: "tshirt.fill", tint: .white),
                    .leaf(id: "sports.football.es.atletico", label: tr("אתלטיקו מדריד", "Atletico Madrid"), query: "Atletico Madrid latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.es.league", label: tr("לה ליגה (כללי)", "La Liga (general)"), query: "La Liga latest news standings", icon: "list.bullet", tint: .red),
                ]),
            FeedNode(id: "sports.football.en", label: tr("אנגליה (פרמייר)", "England (Premier)"), icon: "star.fill", tint: .purple,
                children: [
                    .leaf(id: "sports.football.en.arsenal", label: tr("ארסנל", "Arsenal"), query: "Arsenal FC latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.en.liverpool", label: tr("ליברפול", "Liverpool"), query: "Liverpool FC latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.en.man_united", label: tr("מנצ'סטר יונייטד", "Manchester United"), query: "Manchester United FC latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.football.en.man_city", label: tr("מנצ'סטר סיטי", "Manchester City"), query: "Manchester City FC latest news", icon: "tshirt.fill", tint: .blue),
                    .leaf(id: "sports.football.en.chelsea", label: tr("צ'לסי", "Chelsea"), query: "Chelsea FC latest news", icon: "tshirt.fill", tint: .blue),
                    .leaf(id: "sports.football.en.tottenham", label: tr("טוטנהאם", "Tottenham"), query: "Tottenham FC latest news", icon: "tshirt.fill", tint: .white),
                    .leaf(id: "sports.football.en.league", label: tr("פרמייר ליג (כללי)", "Premier League (general)"), query: "Premier League football latest news standings", icon: "list.bullet", tint: .purple),
                ]),
            .leaf(id: "sports.football.ucl", label: tr("ליגת האלופות", "Champions League"), query: "UEFA Champions League latest news fixtures", icon: "trophy.fill", tint: .blue),
            .leaf(id: "sports.football.world_cup", label: tr("מונדיאל / יורו", "World Cup / Euro"), query: "World Cup or Euro football latest news", icon: "globe", tint: .green),
        ]
    )

    static let basketballRoot = FeedNode(
        id: "sports.basketball",
        label: tr("כדורסל", "Basketball"),
        icon: "basketball.fill",
        tint: .orange,
        children: [
            .leaf(id: "sports.basketball.general", label: tr("כדורסל (כללי)", "Basketball (general)"), query: "basketball news today scores", icon: "list.bullet", tint: .orange),
            FeedNode(id: "sports.bball.il", label: tr("ישראל", "Israel"), icon: "star.fill", tint: .blue,
                children: [
                    .leaf(id: "sports.bball.il.maccabi_ta", label: tr("מכבי תל אביב", "Maccabi Tel Aviv"), query: "Maccabi Tel Aviv basketball latest news", icon: "tshirt.fill", tint: .yellow),
                    .leaf(id: "sports.bball.il.hapoel_ta", label: tr("הפועל תל אביב", "Hapoel Tel Aviv"), query: "Hapoel Tel Aviv basketball latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.bball.il.hapoel_jerusalem", label: tr("הפועל ירושלים", "Hapoel Jerusalem"), query: "Hapoel Jerusalem basketball latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.bball.il.league", label: tr("ליגת העל (כללי)", "Premier League (general)"), query: "Israeli basketball Premier League latest news", icon: "list.bullet", tint: .blue),
                ]),
            FeedNode(id: "sports.bball.nba", label: "NBA", icon: "basketball.fill", tint: .orange,
                children: [
                    .leaf(id: "sports.bball.nba.lakers", label: tr("לייקרס", "Lakers"), query: "Los Angeles Lakers latest news", icon: "tshirt.fill", tint: .purple),
                    .leaf(id: "sports.bball.nba.warriors", label: tr("ווריורס", "Warriors"), query: "Golden State Warriors latest news", icon: "tshirt.fill", tint: .blue),
                    .leaf(id: "sports.bball.nba.celtics", label: tr("סלטיקס", "Celtics"), query: "Boston Celtics latest news", icon: "tshirt.fill", tint: .green),
                    .leaf(id: "sports.bball.nba.bucks", label: tr("באקס", "Bucks"), query: "Milwaukee Bucks latest news", icon: "tshirt.fill", tint: .green),
                    .leaf(id: "sports.bball.nba.heat", label: tr("מיאמי היט", "Miami Heat"), query: "Miami Heat latest news", icon: "tshirt.fill", tint: .red),
                    .leaf(id: "sports.bball.nba.league", label: tr("NBA (כללי)", "NBA (general)"), query: "NBA latest news scores standings", icon: "list.bullet", tint: .orange),
                ]),
            .leaf(id: "sports.bball.euroleague", label: tr("יורוליג", "EuroLeague"), query: "Euroleague basketball latest news", icon: "trophy.fill", tint: .blue),
        ]
    )

    // MARK: - News

    static let news = FeedNode(
        id: "news",
        label: tr("חדשות", "News"),
        icon: "newspaper.fill",
        tint: .indigo,
        subtitle: tr("ישראל, מזרח תיכון, עולם", "Israel, Middle East, world"),
        children: [
            .leaf(id: "news.general", label: tr("חדשות (כללי)", "News (general)"), query: "top news stories today", icon: "list.bullet", tint: .indigo),
            .leaf(id: "news.il", label: tr("ישראל", "Israel"), query: "Israel news today", icon: "star.fill", tint: .blue),
            FeedNode(id: "news.wars", label: tr("מלחמות וסכסוכים", "Wars & Conflicts"), icon: "shield.fill", tint: .red,
                children: [
                    .leaf(id: "news.wars.general", label: tr("מלחמות (כללי)", "Wars (general)"), query: "wars and conflicts latest news today", icon: "list.bullet", tint: .red),
                    .leaf(id: "news.wars.gaza", label: tr("המלחמה בעזה", "The Gaza War"), query: "Gaza war latest news", icon: "exclamationmark.triangle.fill", tint: .red),
                    .leaf(id: "news.wars.lebanon", label: tr("צפון / לבנון", "North / Lebanon"), query: "Lebanon Israel border conflict latest news", icon: "exclamationmark.triangle.fill", tint: .orange),
                    .leaf(id: "news.wars.iran", label: tr("איראן", "Iran"), query: "Iran Israel conflict latest news", icon: "exclamationmark.triangle.fill", tint: .red),
                    .leaf(id: "news.wars.ukraine", label: tr("אוקראינה", "Ukraine"), query: "Ukraine Russia war latest news", icon: "exclamationmark.triangle.fill", tint: .blue),
                ]),
            .leaf(id: "news.middle_east", label: tr("מזרח תיכון", "Middle East"), query: "Middle East news today", icon: "globe", tint: .orange),
            .leaf(id: "news.world", label: tr("חדשות עולם", "World News"), query: "world news today", icon: "globe", tint: .blue),
            .leaf(id: "news.us_politics", label: tr("פוליטיקה אמריקאית", "US Politics"), query: "US politics news today", icon: "building.columns.fill", tint: .red),
            .leaf(id: "news.europe", label: tr("אירופה", "Europe"), query: "Europe news today", icon: "globe.europe.africa.fill", tint: .blue),
        ]
    )

    // MARK: - Tech

    static let tech = FeedNode(
        id: "tech",
        label: tr("טק", "Tech"),
        icon: "cpu.fill",
        tint: .purple,
        subtitle: tr("AI, אפל, סטארטאפים", "AI, Apple, startups"),
        children: [
            .leaf(id: "tech.general", label: tr("טק (כללי)", "Tech (general)"), query: "tech industry news today", icon: "list.bullet", tint: .purple),
            .leaf(id: "tech.ai", label: tr("AI ו-LLM", "AI & LLM"), query: "AI and LLM news this week", icon: "brain.head.profile", tint: .purple),
            .leaf(id: "tech.apple", label: tr("אפל", "Apple"), query: "Apple latest news products", icon: "apple.logo", tint: .gray),
            .leaf(id: "tech.tesla", label: tr("טסלה / מאסק", "Tesla / Musk"), query: "Tesla and Elon Musk news", icon: "car.fill", tint: .red),
            .leaf(id: "tech.startups_il", label: tr("סטארטאפים ישראליים", "Israeli Startups"), query: "Israeli startups news", icon: "lightbulb.fill", tint: .yellow),
            .leaf(id: "tech.cyber", label: tr("סייבר", "Cyber"), query: "cybersecurity news today", icon: "lock.shield.fill", tint: .blue),
            .leaf(id: "tech.gaming", label: tr("גיימינג", "Gaming"), query: "gaming news this week", icon: "gamecontroller.fill", tint: .indigo),
        ]
    )

    // MARK: - Finance

    static let finance = FeedNode(
        id: "finance",
        label: tr("פיננסי", "Finance"),
        icon: "chart.line.uptrend.xyaxis",
        tint: .mint,
        subtitle: tr("שווקים, קריפטו, מניות", "Markets, crypto, stocks"),
        children: [
            .leaf(id: "finance.general", label: tr("פיננסי (כללי)", "Finance (general)"), query: "financial markets economy news today", icon: "list.bullet", tint: .mint),
            .leaf(id: "finance.us_markets", label: tr("שווקים אמריקאים", "US Markets"), query: "US stock market today nasdaq sp500", icon: "chart.line.uptrend.xyaxis", tint: .green),
            .leaf(id: "finance.il_markets", label: tr("שווקים ישראליים", "Israeli Markets"), query: "Tel Aviv stock exchange TA125 latest", icon: "chart.line.uptrend.xyaxis", tint: .blue),
            FeedNode(id: "finance.crypto", label: tr("קריפטו", "Crypto"), icon: "bitcoinsign.circle.fill", tint: .orange,
                children: [
                    .leaf(id: "finance.crypto.btc", label: tr("ביטקוין", "Bitcoin"), query: "Bitcoin price news today", icon: "bitcoinsign.circle.fill", tint: .orange),
                    .leaf(id: "finance.crypto.eth", label: tr("את'ריום", "Ethereum"), query: "Ethereum price news today", icon: "diamond.fill", tint: .blue),
                    .leaf(id: "finance.crypto.general", label: tr("קריפטו (כללי)", "Crypto (general)"), query: "cryptocurrency market news today", icon: "list.bullet", tint: .orange),
                ]),
        ]
    )

    // MARK: - Culture

    static let culture = FeedNode(
        id: "culture",
        label: tr("תרבות", "Culture"),
        icon: "music.note",
        tint: .pink,
        subtitle: tr("סדרות, סרטים, מוזיקה", "Shows, movies, music"),
        children: [
            .leaf(id: "culture.general", label: tr("תרבות (כללי)", "Culture (general)"), query: "culture entertainment news this week", icon: "list.bullet", tint: .pink),
            .leaf(id: "culture.tv", label: tr("סדרות וסרטים", "Shows & Movies"), query: "new TV shows movies releases this week", icon: "tv.fill", tint: .pink),
            .leaf(id: "culture.music", label: tr("מוזיקה", "Music"), query: "music news new releases this week", icon: "music.note", tint: .purple),
            .leaf(id: "culture.books", label: tr("ספרים", "Books"), query: "new book releases reviews", icon: "book.fill", tint: .brown),
            .leaf(id: "culture.theater", label: tr("תיאטרון", "Theater"), query: "theater news Tel Aviv Broadway latest", icon: "theatermasks.fill", tint: .orange),
        ]
    )
}
