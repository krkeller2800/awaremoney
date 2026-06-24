Continue from the sample-data / first-look preparation work.

Current state:
- The "First Look" implementation plan has been fully realized in `QuickStartView.swift`.
- The `firstLookIntro` UI exactly mirrors the provided mockup with a custom timeline stepper card ("How DebtScope Works"), matched typography (`.title2.weight(.bold)` for the intro, `.subheadline.weight(.semibold)` for the steps), and perfectly spaced, uniform-width primary and secondary action buttons below the card.
- Empty states in `IncomeAndBillsView`, `QuickStartView` (Assets), and `DebtSummaryView` have been properly configured using `ContentUnavailableView` to smoothly guide users toward adding data.
- The routing hint text ("After import, DebtScope routes you...") has been correctly moved out of the intro section to just above the `DEBT` heading in the sidebar.
- All layout spacings and paddings were tightened up, completely removing double-padding scenarios (e.g., between the 'Viewing Sample Data' banner and the intro content).
- The `Keep for Spending` strategy-switch behavior has been completely resolved. The UI flags were removed in favor of a cleaner state property, correctly handling Minimums vs Snowball strategies without state persistence errors.
- The app compiles cleanly on the iOS Simulator without errors.

Validation status:
- All layout elements compile and visually align to the design mockups.
- `QuickStartView` effectively orchestrates the onboarding experience.
- Xcode build completed successfully.

Recommended next step:
- Check for any final review items on the First Look implementation or determine the next major feature/bug fix to begin work on.
