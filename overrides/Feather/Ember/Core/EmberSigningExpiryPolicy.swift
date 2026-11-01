import Foundation

/// Feather's CertificatePair.expiration is read from the imported mobileprovision,
/// not the X.509 signing certificate. Use the earlier of that stored expiry and
/// the Apple developer portal's current profile expiry for renewal decisions.
enum EmberSigningExpiryPolicy {
    static func effectiveExpiry(inventoryProfile: Date?, storedProfile: Date?) -> Date? {
        [inventoryProfile, storedProfile].compactMap { $0 }.min()
    }

    static func needsRefresh(inventoryProfile: Date?, storedProfile: Date?,
                             now: Date = Date(), thresholdDays: Int) -> Bool {
        guard let expiry = effectiveExpiry(inventoryProfile: inventoryProfile, storedProfile: storedProfile) else {
            // An unknown expiry cannot safely be assumed to be in the future.
            return true
        }
        return expiry <= now.addingTimeInterval(TimeInterval(max(1, thresholdDays)) * 86_400)
    }
}
