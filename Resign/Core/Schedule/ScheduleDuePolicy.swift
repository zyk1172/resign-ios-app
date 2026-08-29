import Foundation

/// Scheduling due rule. A project is due when it has never been successfully
/// installed, or when `intervalDays` local calendar days have passed since the
/// last successful install — regardless of whether that success came from the
/// GUI or the scheduled worker.
enum ScheduleDuePolicy {
    static func isDue(
        lastSuccessfulInstallDate: Date?,
        intervalDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let days = min(max(intervalDays, 1), 7)
        guard let lastSuccessfulInstallDate else { return true }

        let startOfToday = calendar.startOfDay(for: now)
        guard let dueDay = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: lastSuccessfulInstallDate)) else {
            return true
        }
        return startOfToday >= dueDay
    }
}
