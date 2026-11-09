import ClewDomain
import Foundation

extension Clew {
    static let ratingsKey = "ratingDots"

    /// Rating dots after a tick (SPEC §4) are optional and off by default.
    public func ratingsEnabled() throws -> Bool {
        try storeForQueries.read { r in
            guard let json = try r.setting(Self.ratingsKey) else { return false }
            return try JSONDecoder().decode(Bool.self, from: Data(json.utf8))
        }
    }

    public func setRatingsEnabled(_ on: Bool) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { try $0.saveSetting(Self.ratingsKey, json: on ? "true" : "false", updatedAt: now) }
    }

    /// How a tick felt, 1–5: rough, meh, okay, good, great. Rating again replaces it
    /// (the latest `ratedAt` wins, ARCHITECTURE §8). A voided tick cannot be rated.
    public static let ratingScale = 1...5

    public func rate(checkInId: UUID, rating: Int) throws {
        guard Self.ratingScale.contains(rating) else { throw ClewError.notAllowed }
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard let checkIn = try w.checkIn(id: checkInId) else { throw ClewError.checkInNotFound }
            guard !checkIn.isVoided else { throw ClewError.notAllowed }
            try w.rateCheckIn(id: checkInId, rating: rating, at: now)
        }
    }
}
