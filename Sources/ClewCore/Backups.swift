import ClewDomain
import Foundation

/// Which daily backups to keep (ARCHITECTURE §7): every backup from the last
/// `daily` days, plus, from older backups, the newest one in each of the `weekly`
/// most recent ISO weeks that have one. At most 14 + 8 = 22 copies; the rest are
/// pruned.
public enum BackupRetention {
    public static let daily = 14
    public static let weekly = 8

    public static func keep(_ days: [LocalDay], today: LocalDay, daily: Int = daily, weekly: Int = weekly) -> Set<LocalDay> {
        let cutoff = today.adding(days: -daily)              // dailies are after this day
        let past = Set(days.filter { $0 <= today })
        var keep = past.filter { $0 > cutoff }
        let older = past.filter { $0 <= cutoff }
        let newestPerWeek = Dictionary(grouping: older, by: \.weekStart).compactMapValues { $0.max() }
        for week in newestPerWeek.keys.sorted(by: >).prefix(weekly) {
            if let newest = newestPerWeek[week] { keep.insert(newest) }
        }
        return keep
    }
}
