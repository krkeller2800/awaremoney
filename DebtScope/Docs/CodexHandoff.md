Current state:
- Sample liability fixtures were cleaned up at the PDF/sample-loader level, not by changing real-statement import logic.
- `003-creditCard.pdf` is intentionally excluded from `SampleStatementResource`; comment added in `QuickStartView.swift` because it duplicated the Crescent liability sample.
- Active sample statements now total 10: credit cards are Summit, Pinecrest, Northstar, Harborview; loans are Summit, Crescent, Pinecrest.
- Several sample PDFs were regenerated from FakePDFGen output so issuers/types are distinct and loans use parser-friendly `Monthly Payment` wording.
- `FakeStatementPDFRenderer.swift` now emits `Monthly Payment` for loan summaries.
- Sample data version is `2026-06-25.remove-crescent-card-sample` so existing sample mode reloads and drops the removed Crescent card.
- Compare Strategies toolbar now keeps Schedule/Chart icon-only in phone portrait, and uses icon+text buttons outside portrait.

Files changed:
- `DebtScope/Debt/DebtSummaryView.swift`
- `DebtScope/View/QuickStartView.swift`
- `DebtScope/Resources/SampleData/001-genericLoan.pdf`
- `DebtScope/Resources/SampleData/003-creditCard.pdf`
- `DebtScope/Resources/SampleData/007-creditCard.pdf`
- `DebtScope/Resources/SampleData/010-genericLoan.pdf`
- `DebtScope/Resources/SampleData/011-genericLoan.pdf`
- `Tools/FakePDFGen/Sources/FakePDFGen/FakeStatementPDFRenderer.swift`
- `DebtScope/Docs/CodexHandoff.md`

Validation status:
- Active sample resource snippet confirmed `003-creditCard.pdf` is no longer imported and active count is 10.
- Fixture intake snippets confirmed corrected PDF identities/types/payments for changed files.
- Visual PDF raster checks confirmed regenerated PDFs are upright/readable after the earlier bad direct PDF attempt was replaced by FakePDFGen output.
- Live Xcode diagnostics were clean for `QuickStartView.swift` and `DebtSummaryView.swift` after the latest edits.
- Full Xcode builds passed after the sample fixture changes and after the Compare Strategies toolbar change.

Recommended next step:
- In sample mode, reopen Liability Accounts and Compare Strategies to confirm the Crescent credit card is gone and landscape toolbar buttons show icon+text.
- Commit the current changes once the UI verification looks right.
