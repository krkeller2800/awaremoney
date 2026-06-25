Current state:
- Modified `QAccountsListView` to ensure tapping a row only selects the account (allowing the PDF toolbar button to function correctly in one-column views).
- Moved the "Edit" action exclusively into the ellipsis menu and swipe actions, decoupling it from row taps.
- Made `onEdit` an optional parameter in `QAccountsListView` and removed it from the two-column layout (`columnsView`) in `DebtPayoffDetailView`, eliminating the redundant Edit option from the ellipsis menu when the detail panel is already visible.
- Fixed a SwiftUI state/navigation conflict where tapping "Payment Impact" from the ellipsis menu in one-column mode silently failed. Replaced `.navigationDestination` with a robust `.sheet` wrapper.
- Standardized sheet sizing by applying `.applyFormSheetSizing()` to both the Edit sheet and the Payment Impact sheet so they open at identical half-height detents.

Validation status:
- Verified syntax for all changed views.
- Verified expected behavior aligns with user testing across one-column and two-column layouts.

Recommended next step:
- Commit changes and proceed with further app refinements.

-- Antigravity
