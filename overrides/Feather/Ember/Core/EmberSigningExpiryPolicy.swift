import Foundation

/// The app's embedded provisioning profile can expire long before its
/// certificate. Use the earlier deadline for any automatic renewal decision.
enum EmberSigningExpiryPolicy {
    static func effectiveExpiry(profile: Date?, certificate: Date?) -> Date? {
        [profile, certificate].compactMap { $0 }.min()
    }

    static func needsRefresh(profile: Date?, certificate: Date?,
                             now: Date = Date(), thresholdDays: Int) -> Bool {
        guard let expiry = effectiveExpiry(profile: profile, certificate: certificate) else {
            // An unknown expiry cannot safely be assumed to be in the future.
            return true
        }
        return expiry <= now.addingTimeInterval(TimeInterval(max(1, thresholdDays)) * 86_400)
    }
}
