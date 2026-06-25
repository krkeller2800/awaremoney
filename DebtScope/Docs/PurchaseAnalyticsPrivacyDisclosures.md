# Purchase Analytics Privacy Disclosures

## Scope

This document captures the privacy policy and App Store Connect disclosure decisions for DebtScope purchase analytics.

Purchase analytics is enabled by default in distributed TestFlight and production builds after backend and privacy release gates are complete. Users can turn it off in Settings > Data & Privacy > Share purchase analytics.

## Privacy Policy Copy For komakode.com

Add or update a DebtScope analytics section with this substance:

DebtScope may collect limited purchase analytics unless the user turns off Share purchase analytics in Settings. The analytics are used to understand whether the paywall is shown, whether purchase or restore actions are attempted, whether StoreKit returns successful, cancelled, pending, unverified, failed, restored, or none-found results, and whether StoreKit product loading succeeds, returns empty results, or fails.

DebtScope purchase analytics may include:

- A random app-generated install ID, hashed on the server before storage.
- App version and build number.
- Platform and operating system major/minor version.
- Purchase funnel event name.
- Paywall source.
- StoreKit product load state or result.
- Purchase or restore result.
- Storefront country only when needed for StoreKit reliability debugging.
- A coarse channel such as debug, TestFlight, sandbox, or production.
- Server-generated received timestamp.

DebtScope purchase analytics does not include:

- Financial account names.
- Payees.
- Transaction amounts.
- Balances.
- Imported document names.
- User-entered financial text.
- Apple ID, email, name, or other direct identity.
- Assistant prompts or assistant responses.
- Raw database records or backup contents.

Analytics are sent to DebtScope infrastructure at `komakode.com` and stored in Cloudflare D1. Reporting endpoints are private and are used only for product reliability and purchase funnel measurement. Purchase analytics is not used for third-party advertising or tracking across apps or websites.

## App Store Connect Privacy Answers

Recommended App Privacy response for this analytics rollout:

- Data collected: Yes, when Share purchase analytics is enabled in the distributed build. Users can turn it off in Settings.
- Data type: Usage Data > Product Interaction.
- Purpose: Analytics and App Functionality/Product Reliability, if App Store Connect presents the current purpose options that match these terms.
- Linked to user: No. The app sends a random install ID; the server stores a peppered hash of that ID and does not store Apple ID, email, name, account data, or financial content.
- Used for tracking: No. The data is not used to track users across apps or websites owned by other companies.
- Third-party advertising: No.
- Developer advertising or marketing: No.

If App Store Connect requires more granular classification for StoreKit failure diagnostics, include only the narrow data type that best matches product interaction or diagnostic reliability information. Do not add financial information, contact information, identifiers tied to identity, purchases, search history, browsing history, location, contacts, user content, or sensitive information unless the app's actual collection changes.

## Release Gate

Before enabling analytics in TestFlight or production:

- Publish the updated privacy policy on `komakode.com`.
- Publish the matching App Store Connect App Privacy answers.
- Confirm the distributed app defaults Share purchase analytics to on only after backend ingestion, privacy policy, and App Store Connect privacy answers are live.
- Confirm Settings includes the user-facing disclosure and toggle.
- Reconfirm payloads contain only fields listed in this document.
