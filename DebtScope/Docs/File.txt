# Reserve Processing – Developer Notes

These notes document how the reserve processing feature works so that contributors can confidently maintain and extend it.

This feature automatically accumulates money in a "reserve" for non-monthly bills so that, by the due date, enough has been set aside to pay the bill.

## Data Model Fields

The following fields on `CashFlowItem` are used by reserve processing:

- `reserveBalance: Decimal`
  - The current accumulated reserve dollars for the item. This increases with monthly contributions and initial seeding, and decreases on settlement (when the bill is due and paid from reserves).
- `reserveCycleStart: Date?`
  - The start date of the current reserve cycle. A cycle spans the period from one due date to the next for a non-monthly bill. For example, a quarterly bill has a ~3-month cycle.
  - On settlement (the due date), this advances to the due date that just occurred.
- `reserveLastSeededCycleStart: Date?`
  - A marker to ensure the "seed" contribution is applied **once per cycle**. When the cycle advances, this marker is cleared so the next cycle can be seeded once.
- `reserveAutoEnabled: Bool`
  - When `true`, the updater includes this item in reserve processing. Only non-monthly items should be auto-enabled.

Other related settings:

- `SettingsStore.useReserveProcessingForBills: Bool`
  - Global feature flag to enable/disable the updater across the app.
- `SettingsStore.lastReserveUpdateMonth: DateComponents?` (or equivalent month token)
  - Tracks the last calendar month when the updater ran successfully. Used to guarantee idempotence within a month (i.e., multiple runs in the same month do not double-apply monthly contributions/seed).

## Updater Overview and Schedule

`ReserveUpdateService.updateReserves(asOf:)` is invoked with an "as of" date and performs these steps for each eligible `CashFlowItem`:

1. Skip if `SettingsStore.useReserveProcessingForBills` is `false` or `reserveAutoEnabled` is `false`, or the item is monthly (monthly bills don't need reserves).
2. Determine the current cycle based on `frequency`, `dueDay`, and `reserveCycleStart`.
3. Idempotence by calendar month:
   - If the updater already ran in the same calendar month as `asOf`, do not apply monthly contributions or seeding again.
4. Seed (once per cycle):
   - Compute how many full months have elapsed in the current cycle before the current month, multiply by the monthly contribution, and add that as a one-time seed if `reserveLastSeededCycleStart != reserveCycleStart`.
   - Mark `reserveLastSeededCycleStart = reserveCycleStart` after applying the seed.
5. Monthly contribution (once per month):
   - Add the monthly contribution for the current month.
6. Settlement on due date:
   - If `asOf` is on the due date for the item, deduct the bill `amount` from `reserveBalance` and advance `reserveCycleStart` to this due date. Clear `reserveLastSeededCycleStart` (so the new cycle can seed once).
7. Persist updates and record `SettingsStore.lastReserveUpdateMonth` for idempotence.

### Idempotence Guarantees

- Running the updater multiple times within the same calendar month will not change `reserveBalance` after the first run.
- Seeding is done at most once per cycle: the `reserveLastSeededCycleStart` marker ensures this.
- Settlement on a due date is idempotent: re-running on the same date does not double-deduct or re-advance the cycle.

These behaviors are covered by tests such as:
- Idempotence within a month (contributions apply once).
- Seed applied once per cycle; monthly applies once per month.
- Settlement deducts on the due date and advances the cycle.

## Planner Formulas

Let:
- `A` = bill amount (e.g., $1200 yearly)
- `m` = months per cycle based on `frequency` (yearly=12, semiannual=6, quarterly=3)
- `monthlyContribution = A / m`

Then, for an `asOf` in month `M` within the current cycle:

- Seed (one-time per cycle): `seed = monthlyContribution * monthsElapsedBeforeCurrentMonth`
  - Example: quarterly $300, created at cycle start in October, as of December 1 → two months elapsed (Oct, Nov), seed = 2 * 100 = 200.
- Monthly: add `monthlyContribution` once per calendar month when the updater runs.
- Settlement: on the due date, deduct `A` and advance the cycle start to the due date.

Notes:
- Seeding ensures that if the feature is enabled mid-cycle, the reserve "catches up" to where it should be as if contributions had been made monthly from the cycle start.
- Monthly contributions and seeding are both suppressed if the updater already ran earlier in the same month.

## Rebase a Cycle After Edits

When editing a bill (changing frequency, due day, enabling auto-reserve, or adjusting created/due dates), you may need to rebase the cycle so it remains consistent.

Recommended steps when significant edits occur:

1. Set or recompute `reserveCycleStart` so it aligns with the start of the current cycle.
   - A common approach is to set `reserveCycleStart` to the most recent due date at or before `asOf`.
2. Clear `reserveLastSeededCycleStart` so the next updater run can apply the seed for the newly-defined cycle.
3. Keep `reserveBalance` as-is unless you intend to reset or adjust it. If you reset it, document the reason in a migration or change log.
4. Ensure `reserveAutoEnabled` matches intent (non-monthly only).
5. Optionally clear `SettingsStore.lastReserveUpdateMonth` to ensure the next run can apply contributions if the edit crosses a month boundary.

Example: Changing a bill from monthly to quarterly on the 15th
- Update `frequency` to quarterly, `dueDay = 15`.
- Set `reserveCycleStart` to the latest 15th that is ≤ `asOf`.
- Clear `reserveLastSeededCycleStart`.
- Next run will seed two months if you are two months into the new quarter, and then add the monthly contribution for the current month.

## Settings and Feature Flags

- `useReserveProcessingForBills`: master switch. If off, the updater is a no-op.
- `lastReserveUpdateMonth`: month token for idempotence. Resetting this enables contributions in the next run even within the same app session.
- Per-item: `reserveAutoEnabled` controls inclusion in the updater. Turn this on for eligible non-monthly bills only.

## Operational Guidance

- Call `updateReserves(asOf:)` at app launch and when the calendar month changes (e.g., on first app foreground in a new month). You can also run it on-demand when the user edits a bill.
- Ensure tests cover:
  - Month-level idempotence (re-running in the same month does nothing).
  - Seeding once per cycle.
  - Settlement on due date (deduct and advance cycle) and its idempotence.
- Prefer deterministic `asOf` dates in tests to avoid flakiness.

## Future Enhancements (Ideas)

- Support for semiannual or custom cycle lengths beyond quarterly/yearly.
- UI affordances to show pending seed and monthly contributions.
- Admin tools to rebase or reset reserves for a selected item.
- Audit trails for reserve changes to aid debugging and user trust.

