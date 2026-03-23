import StoreKit
import Foundation

/// Manages StoreKit 2 purchases for the Pro unlock.
@MainActor
@Observable
final class PaywallManager {
    static let shared = PaywallManager()

    /// The product ID configured in App Store Connect (and in PocketREPL.storekit for sandbox)
    static let productId = "com.bontecou.PocketREPL.pro"

    // MARK: - State

    /// The StoreKit product, loaded from App Store Connect
    var product: Product?

    /// True while a purchase or restore is in-flight
    var isPurchasing = false

    /// A human-readable error to show in the UI
    var purchaseError: String?

    private let tracker = UsageTracker.shared

    // MARK: - Lifecycle

    /// Load the product from the App Store / StoreKit sandbox.
    /// Call once on app launch or when the paywall becomes visible.
    func loadProducts() async {
        do {
            let products = try await Product.products(for: [Self.productId])
            product = products.first
        } catch {
            print("[PaywallManager] Failed to load products: \(error)")
        }
    }

    /// Check existing entitlements (e.g. after app launch) and unlock if already purchased.
    func checkExistingEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, tx.productID == Self.productId {
                tracker.unlock()
            }
        }
    }

    // MARK: - Purchase

    /// Initiate a new purchase of the Pro unlock.
    func purchase() async {
        guard let product else {
            purchaseError = "Product not available. Please check your connection and try again."
            return
        }

        isPurchasing = true
        purchaseError = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    tracker.unlock()
                    await transaction.finish()
                case .unverified(_, let error):
                    purchaseError = "Purchase verification failed: \(error.localizedDescription)"
                }
            case .userCancelled:
                break // User tapped Cancel — no error to show
            case .pending:
                purchaseError = "Purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }

        isPurchasing = false
    }

    // MARK: - Restore

    /// Restore previously-made purchases.
    func restorePurchases() async {
        isPurchasing = true
        purchaseError = nil
        do {
            try await AppStore.sync()
            await checkExistingEntitlements()
            if !tracker.isPurchased {
                purchaseError = "No previous purchase found for this Apple ID."
            }
        } catch {
            purchaseError = error.localizedDescription
        }
        isPurchasing = false
    }

    // MARK: - Helpers

    /// Formatted price string, e.g. "$2.99", or nil while loading
    var priceString: String? {
        product?.displayPrice
    }
}
