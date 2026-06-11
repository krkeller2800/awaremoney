# Assistant TestFlight Validation Notes

## Rollout Scope

- Keep the DebtScope Assistant read-only for TestFlight validation.
- Keep `assistantEnabled` defaulting to `false`; users must turn it on from Settings before any Assistant entry point appears.
- Keep transaction details disabled by default. Do not add a transaction-pattern tool until privacy controls have been validated.
- Treat real-device Apple Intelligence behavior as authoritative. Simulator checks are useful for UI and fallback states, not final Foundation Models behavior.

## Feature Flag Checks

- Fresh install or cleared defaults:
  - Settings > Data & Privacy shows `DebtScope Assistant` off.
  - Assistant is absent from the main topic groups.
  - Assistant is absent from the utility menu.
- Turn `DebtScope Assistant` on:
  - Assistant appears in the Data topic group and opens the interactive assistant view.
  - Assistant remains absent from the utility menu.
  - `Allow transaction details` and `Keep assistant history` become editable, but remain off unless the user enables them.
- Turn `DebtScope Assistant` off:
  - If Assistant is selected, the current selection routes back to Debt Payoff.
  - Assistant is removed from compact navigation paths.
  - `Allow transaction details` and `Keep assistant history` reset to off.

## Real-Device Smoke Pass

Use representative DebtScope data on an Apple Intelligence-capable iPhone with Apple Intelligence enabled.

- Ask: `What is my current debt picture?`
  - Expected: Uses DebtScope debt data and avoids invented balances, APRs, payment amounts, or account counts.
- Ask: `Which debt should I focus on first and why?`
  - Expected: Explains the current payoff strategy and names missing APR/payment data if relevant.
- Ask: `How much would I save by using avalanche over snowball?`
  - Expected: Uses the strategy comparison result and reports avalanche interest savings when the fixture supports savings.
- Also ask: `How much interest do I save by using avalanche versus snowball?`
  - Expected: Uses the same strategy comparison result as the shorter avalanche-vs-snowball wording.
- Ask: `What bills are coming up soon?`
  - Expected: Uses upcoming bill summaries and handles an empty bill list plainly.
- Ask: `Can I afford to add $100 to monthly debt payments?`
  - Expected: Uses cash-flow/budget context and avoids presenting the answer as regulated financial advice.
- Ask with sparse or empty data:
  - Expected: Says what data is missing instead of inventing values.
- Ask for raw transactions or memos while transaction details are off:
  - Expected: Explains that transaction details are disabled or unavailable in the current assistant tools.

## Observed Real-Device Results

- Real-device smoke pass completed successfully with representative DebtScope data after adding deterministic direct responses for supported rollout prompts.
- Supported smoke prompts now answer immediately, with no visible spinner delay. This is expected for direct read-only service responses and differs from the earlier Foundation Models-only path.
- On the first pass, a couple of prompts did not return useful answers. Repeating the smoke pass produced reasonable answers for all prompts.
- Keep an eye on first-run behavior during TestFlight; repeated prompt success suggests the data path is valid, but first-run UX should be monitored.

## Logging And Privacy

- Confirm logs do not include sensitive balances, payees, memos, account numbers, persistent IDs, import hashes, or backup payloads.
- Confirm assistant responses do not expose raw SwiftData records or backup data.
- Confirm no write-capable AI tools are registered.
