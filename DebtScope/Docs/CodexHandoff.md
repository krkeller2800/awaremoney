# Codex Handoff

## Current Focus
- Phase 1, Phase 2, Phase 3, and Phase 4 of `DebtScope/DebtScope/Docs/Assistant-Future-Enhancements-Implementation-Plan.md` are implemented, smoke tested, and committed per user note.
- Phase 5 has begun with privacy-preserving App Intents for navigation-only system shortcuts.
- The Debt Payoff Plan shortcut now has a dedicated read-only in-app destination instead of opening the liability account setup list.
- The old "Debt Payoff" setup/list destination has been renamed to "Liability Accounts" in the QuickStart UI and detail/editor title to distinguish it from the read-only Payoff Plan screen.
- QuickStart tile cleanup also renamed the "Money Flow" heading to "Cash Flow" and the former "Cash Flow" tile under it to "Asset Accounts".
- Assistant remains privacy-first and read-only. Do not expose balances, transactions, import filenames, payoff amounts, or payoff dates in Siri, Shortcuts, Spotlight, or other system surfaces without a separate privacy review.

## Completed This Checkpoint
- Added `DebtScope/DebtScope/Assistant/DebtScopeAppIntents.swift`.
- Added `DebtScopeAppSection` AppEnum with non-sensitive section targets:
  - Debt Summary
  - Upcoming Bills
  - Assistant
  - Debt Payoff Plan
- Added `OpenDebtScopeSectionIntent`, which opens the app and stores only a section identifier.
- Added `DebtScopeAppShortcuts` phrases for the four section-opening shortcuts.
- Added `DebtScopeAppSectionRequestStore` for live notification delivery and cold-launch pending-section handoff through `UserDefaults`.
- Added `DebtScope/DebtScope/Debt/DebtPayoffPlanView.swift` as a read-only saved payoff plan destination.
- The payoff plan screen uses `DebtScopeAssistantService.payoffPlanSummary(startDate:)` and `debtSummary()` so it reuses existing `PayoffPlanProvider` calculation paths and missing-data notes.
- Wired `QuickStartView` to route App Intent requests into existing screens:
  - Debt Summary -> Compare Strategies / debt summary screen
  - Upcoming Bills -> Income & Bills screen
  - Assistant -> Assistant screen when enabled, otherwise Debt Payoff
  - Debt Payoff Plan -> new Payoff Plan screen
- Added Payoff Plan as a first-class QuickStart Debt topic, alongside Debt Payoff and Compare Strategies.
- Renamed the setup/list topic from Debt Payoff to Liability Accounts.
- Updated the per-account payoff editor navigation title to Liability Account.
- Updated payoff-plan and assistant cleanup guidance to point users to Liability Accounts when they need to fix APR or minimum-payment inputs.
- Renamed the QuickStart Money Flow group to Cash Flow.
- Renamed the QuickStart cash-flow account tile to Asset Accounts and suppress the compact navigation title for that route to avoid a truncated duplicate of the in-page heading.

## Latest Validation
- User reported the original four App Shortcuts smoke test was successful, with the note that Payoff Plan should open a dedicated saved-plan screen.
- Xcode live diagnostics found no issues in:
  - `DebtScope/Assistant/DebtScopeAppIntents.swift`
  - `DebtScope/Assistant/DebtScopeAssistantService.swift`
  - `DebtScope/Assistant/DebtScopeAssistantViewModel.swift`
  - `DebtScope/Debt/DebtPayoffDetailView.swift`
  - `DebtScope/Debt/DebtPayoffPlanView.swift`
  - `DebtScope/Debt/DebtPayoffView.swift`
  - `DebtScope/View/QuickStartView.swift`
- Full Xcode project build succeeded after the dedicated Payoff Plan screen, Liability Accounts rename, and QuickStart Cash Flow tile cleanup changes.
- SwiftUI preview rendering for `DebtPayoffPlanView` timed out after 120 seconds; no preview result was captured.

## Known Constraints / Risks
- App Shortcuts are navigation-only and intentionally return no financial data.
- The Assistant shortcut falls back to Debt Payoff if the assistant feature flag is disabled.
- No Spotlight or App Entity indexing has been added yet.
- The Payoff Plan screen is read-only and includes a Manage Liability Accounts button for fixing debt inputs in the existing liability account workflow.
- Device-level Siri/Shortcuts should be manually rechecked after the Payoff Plan reroute.

## Recommended Next Step
- Manually smoke test the `Open debt payoff plan in DebtScope` shortcut again and confirm it opens the new Payoff Plan screen.
- Confirm the Debt section shows Payoff Plan, Liability Accounts, and Compare Strategies with clear distinction between plan viewing and liability setup.
- Confirm the Cash Flow section shows Asset Accounts and Income & Bills with the expected destinations.
- Confirm Siri/Shortcuts only launches DebtScope and does not show or speak financial values, import filenames, transaction details, or payoff details in the system result UI. It is expected that the opened DebtScope app screen displays the user’s in-app financial data.
- If validation passes, commit this Phase 5 checkpoint.
- Suggested commit message: `Add navigation-only DebtScope app shortcuts`
