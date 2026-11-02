# Changelog

## 1.0.0

First public release, with the same surface and behaviour as the web, iOS and Android SDKs 1.0.0.

- Age gate with parent consent: `KidAgeGate` collects the player's age and jurisdiction, and asks a parent for consent when the player needs it.
- Adults-only age verification: `KidVerifyAge` verifies that the player is an adult on a product that only allows adults, and `KidSessionVerifyAge` checks it later on any product.
- Permissions and settings: `KidSettings` lets the player manage their permissions and ask a grownup to turn on more.
- Verify age for age-threshold features: a feature with a minimum age turns on only after the player verifies their age. `KidSettings` sends them the check, and `upgrade()` does it from your own UI.
- Error codes: every failure is a `KidError` with a fixed set of codes, including `rateLimited` with `retryAfter`, the seconds to wait before trying again.
- Runs on iOS, Android and the web, with App Attest, Key Attestation or reCAPTCHA on a live key, and Apple's Declared Age Range or Google Play Age Signals where the platform offers them.
