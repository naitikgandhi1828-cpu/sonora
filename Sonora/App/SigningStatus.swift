import Foundation
import UserNotifications

/// Knows when this sideloaded copy of the app was last installed from the laptop and when it stops
/// working (both come from the signing profile), tells you when it has been updated, and warns you
/// before it expires. Works the same whichever tool signed it.
enum SigningStatus {
    private static let seenKey = "signingExpirySeen"
    private static let warningIDs = ["sign-expiry-2d", "sign-expiry-1d", "sign-expiry-3h"]

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App"
    }

    /// The signing profile the app was installed with (nil when not sideloaded).
    private static let profile: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }
        let xml = Data(text[start.lowerBound..<end.upperBound].utf8)
        return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
    }()

    /// When the app stops working.
    static let expiry: Date? = profile?["ExpirationDate"] as? Date

    /// When the laptop last signed and installed the app. A fresh profile is made each time, so its
    /// creation date is the moment of the update.
    static let updatedAt: Date? = profile?["CreationDate"] as? Date

    /// "today at 12:10 PM", "yesterday at 9:05 AM" or "on Fri 2 Oct at 12:10 PM".
    static func whenPhrase(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
        return "on \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) at \(time)"
    }

    static var daysLeft: Int? {
        guard let expiry else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day
    }

    static func formatted(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// Asks once for permission to show these notifications.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Run whenever the app comes to the foreground.
    static func check() {
        guard let expiry else { return }
        let defaults = UserDefaults.standard
        let seen = defaults.object(forKey: seenKey) as? Date
        guard seen != expiry else { return }

        // A later expiry than last time means the app was just re-signed.
        if let seen, expiry > seen.addingTimeInterval(3600) {
            let when = updatedAt.map { "Updated \(whenPhrase($0)). " } ?? ""
            post(id: "sign-refreshed-\(Int(expiry.timeIntervalSince1970))",
                 title: "✅ \(appName) updated",
                 body: "\(when)Works until \(formatted(expiry)).",
                 at: nil)
        }
        defaults.set(expiry, forKey: seenKey)
        scheduleWarnings(for: expiry)
    }

    /// Reminders before expiry. They're scheduled ahead, so they arrive even if the app isn't opened.
    private static func scheduleWarnings(for expiry: Date) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: warningIDs)
        let slots: [(String, TimeInterval, String)] = [
            (warningIDs[0], 2 * 86_400, "in 2 days"),
            (warningIDs[1], 86_400, "tomorrow"),
            (warningIDs[2], 3 * 3_600, "in 3 hours")
        ]
        for (id, before, when) in slots {
            let fire = expiry.addingTimeInterval(-before)
            guard fire > Date() else { continue }
            post(id: id,
                 title: "⚠️ \(appName) stops working \(when)",
                 body: "Connect your iPhone to the laptop with the cable to update it (expires \(formatted(expiry))).",
                 at: fire)
        }
    }

    private static func post(id: String, title: String, body: String, at date: Date?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger: UNNotificationTrigger? = date.map {
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0),
                repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

/// Shows the app's own notifications as banners even while it is open.
final class ForegroundNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotifications()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
