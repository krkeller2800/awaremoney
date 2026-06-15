# Codex Handoff

## Current Focus
- Fuzzy matching inside DebtScope in-app search is implemented and smoke tested.
- The Assistant UX/Settings/QuickStart cleanup checkpoint remains complete, verified on device, and committed.
- The assistant remains read-only, privacy-first, and on-device only. There is no off-device AI fallback.

## Completed In Current Increment
- Added `DebtScopeFuzzySearch` in `DebtScope/Utils/DebtScopeFuzzySearch.swift`.
- Search matching now normalizes case, diacritics, punctuation, and whitespace.
- Search still supports exact/substring matches, including compact punctuation-insensitive matches such as formatted amounts.
- Added typo-tolerant token matching using bounded Levenshtein distance.
- Added subsequence matching for longer tokens, supporting abbreviated queries like `chse crd` for `Chase Credit Card`.
- Very short unrelated queries are guarded from broad fuzzy matches.
- Updated `AccountSearchView` in `QuickStartView` so account, transaction, and balance result groups all use the shared fuzzy matcher.
- Added `DebtScopeFuzzySearchTests` covering exact matching, typo matching, multi-token matching, and short-query rejection.

## Latest Validation
- User smoke tested fuzzy search and reported it works well.
- Live diagnostics were clean for:
  - `DebtScope/Utils/DebtScopeFuzzySearch.swift`
  - `DebtScope/View/QuickStartView.swift`
  - `DebtScope/Testing/DebtScopeFuzzySearchTests.swift`
- Focused fuzzy search tests passed: 4 passed, 0 failed.
- Full Xcode project build passed.

## Privacy / Scope Rules
- In-app search can search local financial details because it runs inside DebtScope's normal authenticated UI.
- Spotlight privacy rules still apply separately: default Spotlight behavior remains generic app-section results only unless the master financial-details toggle is enabled.
- Financial Spotlight results must expose labels only.
- Do not add amounts, balances, dates, memos, notes, account numbers, import filenames, hashes, or raw database identifiers to Spotlight result text.
- Do not add write-capable AI/App Intent workflows without a confirmed normal app UI workflow and audit trail.
- Keep transaction-level assistant work aggregated by default and gated by `assistantIncludeTransactions` plus an explicit user request.
- Assistant copy should continue to state that AI use is on-device only and that unavailable Apple Intelligence means the assistant stays unavailable.

## Known Notes / Risks
- Fuzzy search currently applies only to the in-app `AccountSearchView` search sheet in `QuickStartView`.
- The matcher is intentionally lightweight and local; it does not rank results yet, it only decides inclusion.
- Large transaction histories still run the same in-memory filtering path as before; fuzzy matching adds per-value token work but is bounded and covered by smoke testing.

## Recommended Next Step
- Commit the fuzzy search increment.
- Next product increment options:
  - Add result ranking/highlighting for in-app search.
  - Extend fuzzy matching to other local search/filter surfaces if new ones are added.
  - Continue with the next privacy-scoped assistant/App Intent improvement.
