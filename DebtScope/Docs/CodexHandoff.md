Continue pricingStratigyPlan implementation. The prior recommendation to remove diagnostics was wrong: the plan depends on local debug diagnostics to measure paywall discovery, purchase intent, cancellations, product-load failures, and source attribution.

Current committed state:
- Paywall copy/value messaging is updated.
- PaywallSource exists.
- PaywallView now requires explicit PaywallSource.
- Existing active PaywallView call sites pass concrete sources.
- PurchaseManager still has no-op recording hooks:
  - recordPaywallImpression(source:)
  - recordPurchaseButtonTap(source:)
  - private recordPurchaseOutcome(_:)
  - private recordProductLoadOutcome(_:)
- Local counters were reverted/removed; no partial diagnostics changes remain in PurchaseManager.swift.
- Settings has an existing #if DEBUG Developer section with premium override and free import reset.

Next implementation:
Add debug-only local conversion diagnostics, not remote analytics and not customer-facing normal Settings UI.

Recommended implementation shape:
1. Add a #if DEBUG value type near PurchaseManager:
   PurchaseConversionDiagnostics: Codable, Equatable
   - paywallImpressionsTotal
   - paywallImpressionsBySource: [PaywallSource: Int]
   - purchaseButtonTaps
   - successfulPurchases
   - cancelledPurchases
   - productLoadFailures

2. In PurchaseManager under #if DEBUG:
   - @Published private(set) var conversionDiagnostics
   - load/save diagnostics from UserDefaults
   - updateConversionDiagnostics helper
   - resetConversionDiagnosticsForDebug()

3. Wire existing hooks:
   - recordPaywallImpression(source:) increments total and source count in DEBUG; remains no-op in release.
   - recordPurchaseButtonTap(source:) increments taps in DEBUG; source can be ignored unless adding per-source taps.
   - recordPurchaseOutcome(.success) increments successfulPurchases.
   - recordPurchaseOutcome(.cancelled) increments cancelledPurchases.
   - recordProductLoadOutcome(.empty/.error) increments productLoadFailures.
   - Do not count product-load success as a failure.

4. Surface only in SettingsView #if DEBUG Developer section:
   - Paywall Impressions
   - impressions by source, preferably only non-zero sources
   - Purchase Button Taps
   - Successful Purchases
   - Cancelled Purchases
   - Product Load Failures
   - Reset Conversion Diagnostics button

5. Add focused tests if time:
   - diagnostic counter model increments source impressions correctly
   - purchase taps/success/cancel/failure counters increment correctly
   - reset returns zero state
   If target access is hard, keep tests for the pure value type only.

6. Validate:
   - XcodeRefreshCodeIssuesInFile for PurchaseManager.swift and SettingsView.swift
   - BuildProject
   - Smoke test: DEBUG Settings developer section appears, paywall impression increments after opening paywall, purchase tap increments after tapping purchase, reset clears counters.

Important constraints:
- Do not add remote analytics.
- Do not expose conversion diagnostics in non-debug builds.
- Do not change product ID, price, entitlement rules, StoreKit config, restore behavior, or free import allowance.
- Backup/restore remains free with soft premium messaging only.
