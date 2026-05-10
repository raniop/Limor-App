import ActivityKit
import Foundation

/// Live Activity attributes for an upcoming reminder. Static `attributes` describe
/// the activity when started (reminder identity + label); the dynamic `ContentState`
/// is what the system can update over time.
struct LimorReminderAttributes: ActivityAttributes {
    public typealias ReminderState = ContentState

    public struct ContentState: Codable, Hashable {
        /// ISO-8601 due time. Updates when the user snoozes.
        public var dueAt: Date

        public init(dueAt: Date) {
            self.dueAt = dueAt
        }
    }

    public var reminderId: String
    public var task: String

    public init(reminderId: String, task: String) {
        self.reminderId = reminderId
        self.task = task
    }
}
