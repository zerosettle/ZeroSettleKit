/// Tracks which impression keys have already been reported this session, so the
/// banner fires at most once per (session, variant). MainActor-isolated: only
/// touched from ZSOfferManager (which is @MainActor).
@MainActor
final class ImpressionDedupe {
    private var seen = Set<String>()

    /// Returns true the first time `key` is seen, false on every later call.
    func shouldReport(_ key: String) -> Bool {
        seen.insert(key).inserted
    }
}
