# Codex Handoff

## Current Focus
- Pricing strategy implementation is in progress.
- Recent work focused on making the lifetime paywall clearer, preserving free backup/restore access, and tightening Settings/About upgrade entry points.
- Local debug conversion counters and visible Settings conversion diagnostics were removed after review; `PaywallSource` and no-op recording hooks remain so future remote analytics can be added without re-threading source attribution.

## Completed / Verified Context
- Added `PaywallSource` modeling and wired known paywall sources for import limit, external import, Settings, About, QuickStart trial banner, and Backup & Restore.
- Updated `PaywallView` with lifetime messaging, concise value bullets, source-specific context messages, `Unlock Lifetime - {price}` CTA, and large-only presentation detent.
- Removed local conversion counter storage and the Settings `Conversion Diagnostics` display.
- Kept analytics-ready hook methods for paywall impressions, purchase taps, purchase outcomes, and product load outcomes, but they intentionally do nothing for now.
- Added Backup & Restore soft Premium value messaging while preserving free backup export, sharing, and restore access.
- Updated trial/import allowance wording away from quota-only copy.
- Updated Settings purchase row to `Lifetime Premium` with supporting text: `Unlimited imports, backup/restore, payoff insights, and private local tools.`
- Updated About upgrade CTA to `Unlock Lifetime Premium` with supporting text: `Unlimited local planning with no subscription.`
- Fixed Settings list button handling so canceling restore purchases does not cause the next Lifetime Premium tap to re-present restore confirmation.
- Focused Xcode diagnostics and full Xcode builds passed after the recent changes.
- User smoke tested the Settings restore/paywall interaction fix and committed it.

## Important Product Decisions
- Backup and restore remain available to all users for now.
- Backup & Restore remains a soft Premium value message, not a blocker.
- Do not add remote analytics in this pass. Future remote analytics require explicit privacy/App Store messaging review first.
- Keep current lifetime product ID, free import allowance, entitlement behavior, StoreKit configuration, restore flow, and price behavior unchanged unless explicitly requested.
- Keep the current low lifetime price during this conversion-improvement pass.

## Strong Next Steps
1. Audit remaining paywall entry points against `PaywallSource`.
   - Confirm external import, payoff result, assistant, and any default `.unknown` presentations either have a concrete source or are intentionally unknown.
   - Search for `PaywallView(` and check every call site.
   - Goal: no accidental `.unknown` source paths for normal user flows.

2. Smoke test source-specific paywall copy from real user paths.
   - Fifth import/exhausted trial flow.
   - External file import flow.
   - Backup & Restore soft upgrade section.
   - Settings and About upgrade rows.
   - Assistant/payoff result paywall paths if those gates are currently reachable.
   - Goal: each entry point opens the paywall at large height, has correct context copy, and does not block free flows incorrectly.

3. Review `pricingStratigyPlan.md` for completed/stale items.
   - Mark or rewrite the `PurchaseManager` diagnostics section to match the current no-local-counters decision.
   - Identify the next actual implementation item instead of carrying old diagnostics tasks forward.
   - Goal: plan reflects product decisions and current code, not earlier exploratory ideas.

4. Tighten purchase/paywall error surfaces if needed.
   - Review `iapDiagnosticSummary` visibility in `PaywallView`; it is still user-visible when StoreKit product loading fails.
   - Decide whether that text should remain diagnostic-style or become friendlier release copy.
   - Goal: StoreKit failure state is understandable to a normal user without exposing unnecessary technical details.

5. Consider final pricing-pass polish only after the above.
   - Ensure lifetime value copy is consistent across paywall, Settings, About, Backup & Restore, and exhausted import gates.
   - Avoid changing entitlement rules, import allowance, product ID, restore behavior, or price.

## Notes / Risks
- Some source-specific messages exist but may not have been exercised recently from their real flows: external import, payoff result, and assistant.
- `.unknown` should be treated as acceptable only for truly generic/manual presentations; normal app entry points should prefer a concrete `PaywallSource`.
- Any future remote analytics would require privacy/App Store messaging review before implementation.
