# Pricing Strategy Plan

## Goal

Improve Premium conversion before changing the price. Current evidence suggests price is not the only blocker: users are not buying at a low lifetime price, so the app needs to create clearer value, show that value earlier, and ask for purchase at a better moment.

## Current Model

- One lifetime Premium purchase.
- Four free imports before import workflows are gated.
- Paywall currently frames Premium mostly as continued importing.
- New value has expanded beyond imports: debt payoff planning, payment-change simulations, cash-flow and reserve context, net worth, local search, Spotlight, backups, and optional on-device assistant.

## Recommended Pricing Position

Keep the current low lifetime price during the next conversion pass. Do not raise the price until there is evidence that users understand the value and some users are buying.

Position the current price as an early-supporter lifetime unlock:

- One-time purchase.
- No subscription.
- No ads.
- No bank login required.
- Private, local-first finance planning.

Future pricing can be revisited after conversion improves. A higher lifetime price or a separate subscription should only be considered when the app has proven demand or adds recurring-cost features such as bank sync, hosted sync, cloud backup, or server-side AI.

## Product Changes To Improve Conversion

### 1. Reframe Premium Around Outcomes

Replace import-only messaging with broader value messaging.

Suggested paywall headline:

> Unlock unlimited local finance planning

Suggested subheadline:

> Continue importing statements, comparing payoff strategies, backing up your data, and using private on-device insights.

Suggested value bullets:

- Unlimited statement imports and review history.
- Debt payoff plans with avalanche, snowball, and minimum-payment strategies.
- Extra-payment impact simulations.
- Cash-flow, bills, reserves, and net worth in one place.
- Backup and restore for your local data.
- Local search, Spotlight support, and optional on-device assistant.
- No ads, no bank login, no server financial database.

### 2. Move Purchase Prompts To Value Moments

Avoid asking users to buy before they have seen a useful result. Better trigger points:

- After a successful import review shows clean accounts or transactions.
- After DebtScope calculates a debt-free date.
- After a strategy comparison shows avalanche vs. snowball differences.
- After an extra-payment simulation shows time or interest savings.
- When the user attempts a fifth import.
- When the user tries backup/restore after building meaningful data.

The fifth-import gate can stay, but it should not be the only conversion moment.

### 3. Make The Free Experience Demonstrate The Plan

The free tier should help users reach an aha moment before purchase.

Keep free:

- Manual account setup.
- Basic debt payoff plan creation.
- Viewing imported data from free imports.
- Basic net worth and cash-flow summaries.
- Local assistant availability/settings where supported.

Gate or upsell:

- Additional imports after the free allowance.
- Batch or external-file import continuation.
- Advanced import memory and saved mapping convenience.
- Backup export/restore after meaningful use.
- Full assistant analysis after a small number of prompts, if needed later.

Do not gate basic payoff visibility too early. The payoff result is what helps sell the unlock.

### 4. Improve Trial Language

Current language should move away from sounding like a hard import quota.

Replace:

> 4 free imports remaining

With variants like:

> Trial active: 4 statement imports included

or:

> Try DebtScope with 4 statement imports, then unlock unlimited local planning.

When imports are used:

> Your trial imports are used. Unlock lifetime Premium to keep importing and preserve your full planning workflow.

### 5. Add Purchase Context In Settings/About

The Settings and About upgrade entry should communicate the offer before opening the paywall.

Suggested row text:

> Lifetime Premium: unlimited imports, backup/restore, payoff insights, and private local tools.

This is more useful than a generic `Upgrade to Premium` button.

### 6. Add Lightweight Conversion Diagnostics

Add local debug counters first; only add analytics later if privacy policy and App Store messaging are ready.

Track locally in debug builds:

- Paywall impressions.
- Paywall source: fifth import, Settings, About, backup, assistant, payoff result, external import.
- Purchase button taps.
- Successful purchases.
- Cancelled purchases.
- Product load failures.

This answers whether the problem is paywall discovery, paywall copy, StoreKit reliability, or purchase intent.

### 7. Verify StoreKit Reliability

Before changing price, confirm users can actually buy.

Checklist:

- Product ID matches App Store Connect exactly.
- Product is approved or available for the current build state.
- Paid Apps agreement, tax, and banking are complete.
- App Store product loads outside debug/test environments.
- Paywall handles empty product responses clearly.
- Restore works for purchased Apple IDs.

If product loading is failing, conversion will look like a pricing problem when it is actually a purchase pipeline problem.

## Coding Changes

### Paywall Model

Add a lightweight paywall source model so the app can explain why Premium is being shown and so debug diagnostics can group impressions.

Suggested type:

```swift
enum PaywallSource: String, Codable, CaseIterable {
    case fifthImport
    case externalImport
    case settings
    case about
    case backupRestore
    case payoffResult
    case assistant
    case unknown
}
```

Use this source when presenting `PaywallView` from import, Settings, About, QuickStart, backup, and future assistant/payoff prompts.

### PurchaseManager.swift

Update `PurchaseManager` responsibilities:

- Keep the current lifetime product ID and free import allowance unchanged.
- Keep `PaywallSource` threaded through paywall presentations so future analytics can attribute entry points.
- Keep lightweight recording hook methods for paywall impressions, purchase button taps, purchase outcomes, and product loading outcomes.
- Do not store local conversion counters or expose conversion diagnostics in Settings.

Avoid adding remote analytics in this pass. Future remote analytics require explicit privacy and App Store messaging review.

### PaywallView.swift

Replace the current import-centered paywall with outcome-centered copy:

- Title: `Unlock Lifetime Premium`
- Subtitle: `Unlimited local finance planning with no subscription, ads, or bank login.`
- Add concise value bullets using `Label` rows.
- Keep the StoreKit price in the purchase button.
- Change the button title to `Unlock Lifetime - {price}`.
- Accept an optional `PaywallSource` and show a short source-specific message when useful.
- Call `PurchaseManager` diagnostic recording on appear and purchase tap.

Suggested source-specific messages:

- Fifth import: `Your trial imports are used. Unlock Premium to keep importing statements and building your plan.`
- External import: `Unlock Premium to import this file and continue your local financial history.`
- Backup/restore: `Unlock Premium to protect and move your local DebtScope data.`
- Settings/About: no extra warning; show the general value proposition.

### TrialBanner.swift

Change the banner from a quota-only message to trial language.

Suggested active copy:

```text
Trial active: {remaining} statement imports included
```

Suggested exhausted copy for places that need it:

```text
Trial imports used. Unlock Lifetime Premium for unlimited local planning.
```

Keep the banner compact, but make it feel like a trial instead of a warning.

### SettingsView.swift

Replace the generic `Upgrade to Premium` row with a richer purchase entry.

Suggested visible row:

```text
Lifetime Premium
Unlimited imports, backup/restore, payoff insights, and private local tools.
```

Keep `Restore Purchases` nearby. In debug builds, add the conversion diagnostics summary below the existing purchase/debug status fields.

### AboutView.swift

Update the upgrade button or surrounding text so About does not just repeat `Upgrade to Premium`.

Suggested button:

```text
Unlock Lifetime Premium
```

Suggested short supporting text:

```text
Unlimited local planning with no subscription.
```

### ImportFlowView.swift and ReviewImportView.swift

Pass a meaningful `PaywallSource` when presenting the paywall:

- Use `.fifthImport` when the free import allowance is exhausted during normal import.
- Use `.externalImport` when opening a document from Files/share sheet is blocked.
- Preserve current import safety checks and free allowance behavior.

Do not change parser behavior, approval behavior, or the number of free imports in this pass.

### QuickStartView.swift

When showing the paywall from the sidebar trial banner, pass a source that reflects the user's context. Use `.unknown` if no better source is available, or add a `.trialBanner` case if the code needs more specific diagnostics.

If future payoff-result upsells are added, trigger them only after useful results are visible. Do not block the basic payoff plan before the user sees value.

### Backup Views

If backup/restore is currently free, leave it alone unless the product decision is to gate it. If gated later, present the paywall with `.backupRestore` and explain data portability/protection rather than imports.

### DebugSettingsView.swift

Add a debug-only purchase conversion section:

- Paywall impressions total.
- Paywall impressions by source.
- Purchase button taps.
- Successful purchases.
- Cancelled purchases.
- Product load failures.
- Button to reset conversion diagnostics.

This should be visible only in debug/developer tooling.

### Tests And Validation

Add focused tests where practical:

- `PurchaseManager` diagnostic counters increment correctly.
- Free import allowance behavior is unchanged.
- Paywall source copy returns expected text.
- Trial banner text handles 1 remaining, multiple remaining, and exhausted states.

Manual validation:

- Product loads and price displays.
- Paywall appears from Settings, About, trial banner, normal import gate, and external import gate.
- Purchase cancellation records a cancelled outcome but does not unlock Premium.
- Successful sandbox/TestFlight purchase unlocks Premium.
- Restore purchases still works.

## Suggested Implementation Order

1. Add `PaywallSource` and local debug conversion diagnostics.
2. Update paywall copy, value bullets, and source-specific messaging.
3. Update trial banner language.
4. Pass paywall sources from ImportFlow, ReviewImport, Settings, About, and QuickStart.
5. Add better upgrade text in Settings and About.
6. Surface debug diagnostics and reset control in developer settings.
7. Add focused tests for diagnostics, copy helpers, and unchanged import allowance behavior.
8. Keep price unchanged for one release and observe behavior.
9. Re-evaluate price only after there are paywall impressions and at least some purchase-button taps.

## Copy Drafts

### Paywall Title

Unlock Lifetime Premium

### Paywall Subtitle

Unlimited local finance planning with no subscription, ads, or bank login.

### Purchase Button

Unlock Lifetime - {price}

### Footer

Includes unlimited statement imports, payoff planning, backup/restore, local search, Spotlight support, and optional on-device assistant features. Purchases are tied to your Apple ID and can be restored on new devices.

### Fifth Import Message

Your trial imports are used. Unlock Lifetime Premium to keep importing statements and continue building your private financial plan.

## Success Criteria

- More users reach a clear payoff, cash-flow, or import-review result before seeing a purchase ask.
- Paywall copy explains the full product value, not just import access.
- Debug diagnostics show where users drop off.
- Product loading failures are not confused with price resistance.
- Pricing remains stable until conversion behavior is understood.
