import ClewDomain
import Foundation

/// A time field whose minutes move in quarter hours (user, 2026-11-18): the hour or the
/// minutes are selected, and the arrow keys (or the stepper) change that part; the
/// minutes step :00 → :15 → :30 → :45 and wrap within the hour, as the field's own
/// minutes do. A typed minute is kept while typing and becomes the nearest quarter when
/// the field is left.
public enum QuarterTime {
    public static let step = 15

    /// The field proposes `new` after `old`. A one-minute step (an arrow key or the
    /// stepper on the minutes; the field carries into the hour, 8:00 ↓ is 7:59) becomes
    /// a quarter-hour step in the same direction; anything else (the hour, typed
    /// digits) is kept as proposed.
    public static func stepped(from old: TimeOfDay, to new: TimeOfDay) -> TimeOfDay {
        let day = 24 * 60
        let from = old.hour * 60 + old.minute
        let to = new.hour * 60 + new.minute
        let total: Int
        switch (to - from + day) % day {
        case 1: total = (from / step + 1) * step % day                                  // up
        case day - 1: total = ((from + step - 1) / step - 1 + day / step) % (day / step) * step   // down
        default: return new
        }
        return TimeOfDay(hour: total / 60, minute: total % 60) ?? new
    }

    /// The nearest quarter hour (half past rounds up), wrapping past midnight.
    public static func nearest(_ time: TimeOfDay) -> TimeOfDay {
        let total = time.hour * 60 + time.minute
        let rounded = (total + step / 2) / step * step % (24 * 60)
        return TimeOfDay(hour: rounded / 60, minute: rounded % 60) ?? time
    }
}
