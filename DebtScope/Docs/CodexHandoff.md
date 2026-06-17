# Codex Handoff

## Current Focus
- Pricing strategy implementation is in progress.
- Recent Settings/About lifetime upgrade context work and Settings restore/paywall tap handling fix were smoke tested and committed.

## Completed / Verified Context
- Added `PaywallSource` modeling and wired known paywall sources for import limit, external import, Settings, About, QuickStart trial banner, and Backup & Restore.
- Updated `PaywallView` lifetime messaging, source-specific context, large-only presentation detent, and DEBUG-only local conversion diagnostics.
- Added DEBUG-only local conversion counters in `PurchaseManager`, backed by `UserDefaults`.
- Settings Developer section exposes `Conversion Diagnostics`.
- Added Backup & Restore soft Premium value messaging while preserving free backup export, sharing, and restore access.
- Updated trial/import allowance wording away from quota-only copy.
- Updated Settings purchase row to `Lifetime Premium` with supporting text: `Unlimited imports, backup/restore, payoff insights, and private local tools.`
- Updated About upgrade CTA to `Unlock Lifetime Premium` with supporting text: `Unlimited local planning with no subscription.`
- Fixed Settings list button handling so canceling restore purchases does not cause the next Lifetime Premium tap to re-present restore confirmation.
- Focused Xcode diagnostics and full Xcode builds passed after the recent changes.
- User smoke tested the recent Settings restore/paywall interaction fix and committed it.

## Important Product Decisions
- Backup and restore remain available to all users for now.
- Backup & Restore remains a soft Premium value message, not a blocker.
- Conversion diagnostics remain local-only and DEBUG-only unless privacy/App Store messaging is explicitly updated later.
- Keep current lifetime product ID, free import allowance, entitlement behavior, StoreKit configuration, restore flow, and price behavior unchanged unless explicitly requested.
- Keep the current low lifetime price during this conversion-improvement pass.

## Suggested Next Step
- Continue `pricingStratigyPlan.md` with the next unimplemented pricing strategy item.
- Likely next area: exercise or refine remaining source-specific paywall entry points that have not all been smoke tested recently, especially external import, payoff result, and assistant.
- Avoid entitlement, StoreKit product, free allowance, restore flow, and price behavior changes unless the user asks for them.

## Notes / Risks
- The debug summary previously showed one `unknown` paywall impression/tap from a default-source path. This is acceptable for diagnostics, but can be cleaned up later by assigning a concrete `PaywallSource` where appropriate.
- Any future remote analytics would require explicit privacy/App Store messaging review first.
