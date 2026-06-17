Continue pricingStratigyPlan implementation.

Current committed state:
- Last commit: 1e14f42 Add debug purchase conversion diagnostics.
- Working tree was clean after the commit.
- Paywall copy/value messaging has been updated.
- PaywallSource exists and PaywallView requires an explicit PaywallSource.
- Active PaywallView call sites pass concrete sources.
- PurchaseManager now has DEBUG-only local conversion diagnostics:
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
- Focused PurchaseConversionDiagnosticsTests were added and passed.
- Validation completed before commit: live diagnostics clean, full Xcode build passed, focused tests passed, manual smoke test passed.

Important context:
- The plan document has older text that says not to store/expose local conversion counters. That guidance is obsolete for the current implementation; the accepted direction is DEBUG-only local diagnostics in SettingsView's Developer section.
- Do not add remote analytics.
- Do not expose conversion diagnostics in release builds or customer-facing normal Settings UI.
- Do not change product ID, price, entitlement rules, StoreKit config, restore behavior, or free import allowance.
- Backup/restore remains free with soft premium messaging only.

Next suggested step:
- Continue the pricing strategy pass by verifying StoreKit reliability from the plan checklist: product ID/App Store Connect status, agreements/tax/banking, product loading outside local debug/test assumptions, empty-product handling, and restore behavior.
- If implementation work is preferred instead, inspect pricingStratigyPlan for the next incomplete coding item after diagnostics and proceed narrowly.
