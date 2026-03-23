import Foundation

/// Tracks how many free messages the user has consumed and whether they've unlocked the app.
/// Persisted in UserDefaults so it survives app restarts.
@Observable
final class UsageTracker {
    static let shared = UsageTracker()

    /// Number of free messages before paywall triggers
    static let freeMessageLimit = 5

    private let defaults = UserDefaults.standard
    private let messagesUsedKey = "com.bontecou.PocketREPL.messagesUsed"
    private let isPurchasedKey  = "com.bontecou.PocketREPL.isPurchased"

    // MARK: - Computed State

    /// How many messages the user has sent so far
    var messagesUsed: Int {
        get { defaults.integer(forKey: messagesUsedKey) }
        set { defaults.set(newValue, forKey: messagesUsedKey) }
    }

    /// Whether the user has unlocked the full app
    var isPurchased: Bool {
        get { defaults.bool(forKey: isPurchasedKey) }
        set { defaults.set(newValue, forKey: isPurchasedKey) }
    }

    /// Returns true when the free tier is exhausted and no purchase has been made
    var isOverLimit: Bool {
        !isPurchased && messagesUsed >= Self.freeMessageLimit
    }

    /// How many free messages remain (0 when exhausted)
    var remainingFreeMessages: Int {
        max(0, Self.freeMessageLimit - messagesUsed)
    }

    /// Whether the free-tier warning badge should be visible
    var showFreeTrialWarning: Bool {
        !isPurchased && remainingFreeMessages <= 2
    }

    // MARK: - Actions

    /// Call this each time the user successfully sends a message
    func recordMessageSent() {
        guard !isPurchased else { return }
        messagesUsed += 1
    }

    /// Mark the app as fully unlocked (called after successful purchase/restore)
    func unlock() {
        isPurchased = true
    }
}
