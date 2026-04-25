# Teller API Integration Design for awaremoney

## Objective
Integrate the [Teller API](https://teller.io) into `awaremoney` to allow users to directly connect their bank accounts for real-time, synchronous fetching of balances and transactions. This will complement the existing manual statement import flow.

## 1. Architecture & Components

### A. Authentication & Link Creation (Frontend)
- **Teller Connect UI:** Implement a SwiftUI view (`TellerConnectView`) using `UIViewRepresentable` wrapping a `WKWebView` (or use the official Teller iOS SDK if available). This view will load the Teller Connect drop-in UI.
- **Environment & Keys:** Store the Teller `application_id` in a `.env` file or Xcode build configuration.
- **Token Management:** Upon successful linking, Teller returns an `accessToken` and an `enrollment_id`. These must be stored securely in the iOS **Keychain** (do not use `UserDefaults` or `SwiftData` for raw tokens).

### B. Data Synchronization (Backend/Service Layer)
Create a new `TellerSyncService` to handle API communication.
- **Endpoints Used:**
  - `GET /accounts` (Fetch all accounts under an enrollment)
  - `GET /accounts/{id}/balances` (Fetch real-time balances)
  - `GET /accounts/{id}/transactions` (Fetch transaction history)
- **Sync Trigger:** Sync can be triggered manually via a "Pull to Refresh" on the Accounts list, or automatically on app foregrounding (using `scenePhase` in `awaremoneyApp`).

## 2. Data Mapping Strategy

### Accounts
Map the Teller Account object to `awaremoney`'s `Account` SwiftData model:
- `id`: Generate a new `UUID`.
- `name`: Map from Teller's `name` or `institution.name`.
- `institutionName`: Map from Teller's `institution.name`.
- `typeRaw`: Map Teller's `type` and `subtype` (e.g., `depository/checking` -> `checking`, `credit/credit_card` -> `creditCard`).
- `currencyCode`: Map from Teller's `currency_code` (default "USD").
- `last4`: Map from Teller's `account_number` (last 4 digits).

### Transactions
Map the Teller Transaction object to `awaremoney`'s `Transaction` SwiftData model:
- `id`: Generate a new `UUID`.
- `datePosted`: Parse from Teller's `date`.
- `amount`: Map from Teller's `amount`. Note: Teller amounts for debits are positive; we need to align this with `awaremoney`'s internal sign convention (usually expenses are negative, or handled via `Transaction.Kind`).
- `payee`: Map from Teller's `description`.
- `externalId`: Store Teller's unique transaction `id`. **Crucial for deduplication** to prevent duplicate entries on subsequent syncs.
- `hashKey`: Generate a composite hash `Hash(date + amount + payee)` to help de-dupe against previously *manually imported* transactions.

## 3. UI/UX Updates

1. **Import Flow Update:** Add a "Connect Bank Account" button alongside the existing PDF/CSV import options in `ImportFlowView` and `AccountsListView`.
2. **Linked Accounts Management:** Create a new `LinkedInstitutionsView` (accessible from Settings or Accounts) to show active Teller enrollments, last sync times, and provide an option to "Disconnect" (which removes the Keychain token and stops syncing).
3. **Sync Feedback:** Add an inline loading indicator during active syncs to provide visibility into the background fetching process.

## 4. Security & Privacy
- `awaremoney` will only fetch data; no money movement capabilities (like Zelle) will be requested or implemented.
- Access tokens will never be logged or sent to any server other than Teller's API.
- All network requests to Teller will be made directly from the iOS client (client-side integration).

## 5. Phased Implementation Steps
1. **Phase 1: Setup & Connect:** Implement `TellerConnectView`, Keychain storage, and the "Connect" button UI.
2. **Phase 2: Account Sync:** Implement `TellerSyncService.fetchAccounts()` and map them to `Account` models in SwiftData.
3. **Phase 3: Transaction Sync:** Implement transaction fetching, deduplication logic, and map to `Transaction` models.
4. **Phase 4: Polish:** Add loading states, error handling (e.g., re-authentication if a token expires), and the Linked Accounts management screen.