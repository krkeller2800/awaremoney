Continue pricingStratigyPlan implementation.

Current committed state:
- Last commit: 97cde39 Improve StoreKit product diagnostics for paywall reliability.
- Working tree was clean after the commit.
- Paywall copy/value messaging has been updated.
- PaywallSource exists and PaywallView requires an explicit PaywallSource.
- Active PaywallView call sites pass concrete sources.
- PurchaseManager has DEBUG-only local conversion diagnostics:
  - paywallImpressionsTotal
  - paywallImpressionsBySource
  - purchaseButtonTaps
  - successfulPurchases
  - cancelledPurchases
  - productLoadFailures
- Conversion diagnostics persist locally in UserDefaults only in DEBUG builds.
- Existing recording hooks are wired in DEBUG and remain non-customer-facing.
- SettingsView's DEBUG Developer section is the correct place for conversion diagnostics.
- DebugSettingsView is only for debug category/tool controls and should not be used for conversion diagnostics.
- StoreKit reliability pass is implemented:
  - PurchaseManager exposes explicit productLoadState: idle, loading, loaded, empty, failed.
  - Manual StoreKit product reload clears stale product state before refetching.
  - PaywallView uses productLoadState for loading, empty-product, and App Store error messaging.
  - SettingsView Developer section shows StoreKit Product status, IAP Diagnostic, and Reload StoreKit Product.
  - Product load failures are counted once per failed load cycle instead of once per retry.
- Focused PurchaseConversionDiagnosticsTests include diagnostics counter coverage and productLoadState display-value coverage.
- Validation completed before commit: full Xcode build passed, focused purchase diagnostics tests passed, manual smoke test passed.

Important context:
- The plan document has older text that says not to store/expose local conversion counters. That guidance is obsolete for the current implementation; the accepted direction is DEBUG-only local diagnostics in SettingsView's Developer section.
- Do not add remote analytics.
- Do not expose conversion diagnostics in release builds or customer-facing normal Settings UI.
- Do not change product ID, price, entitlement rules, StoreKit config, restore behavior, or free import allowance.
- Backup/restore remains free with soft premium messaging only.
- Remaining StoreKit checklist items requiring App Store Connect/manual access: exact product ID match, product approval/availability for the current build state, Paid Apps agreement, tax, banking, and sandbox/TestFlight restore with purchased Apple IDs.

Next suggested step:
- Continue pricing strategy work from pricingStratigyPlan after the completed diagnostics/reliability pass. Likely options are manual App Store Connect/TestFlight verification or adding focused tests for paywall source copy and trial banner text if more implementation work is preferred.
