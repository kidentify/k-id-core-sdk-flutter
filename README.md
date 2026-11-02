# k-ID Core SDK (Flutter)

The k-ID SDK for Flutter apps. It adds an age gate with parental consent, adult age verification, and a settings menu
where players manage their permissions, as drop-in widgets, composable pieces, or controllers for your own UI. The web
(`@k-id/core-react`), iOS and Android SDKs share its surface, names, and behavior.

## Requirements

Flutter 3.24 or later (Dart 3.5). iOS 15 or later, Android 12 (API 31) or later, and the web. macOS, Windows and Linux
are not supported.

## Install

```sh
flutter pub add k_id_core
```

On Android, raise your app's minimum SDK to 31 in `android/app/build.gradle.kts`, since Flutter's default is lower:

```kotlin
android {
    defaultConfig {
        minSdk = 31
    }
}
```

## Test and live keys

Each product in Kai has a test key (`kgp_test_...`) and a live key (`kgp_live_...`). k-ID answers only the apps listed
on the key in Kai, and the SDK names the app on each platform:

- **iOS:** the SDK sends the bundle id as `Kid-App-Id`. Register it on the test key; for a live key, register it with
  your Apple Team ID.
- **Android:** the SDK sends the package name as `Kid-App-Id`. Register it on the test key; for a live key, register it
  with the SHA-256 of the certificate that signs the app you ship.
- **Web:** the page's origin, which the browser sends: scheme, host and port together, such as `https://yourgame.com` or
  `http://localhost:8080`.

Simulators, emulators and a local web server work on a test key. See [Live keys](#live-keys) for what a live key
checks.

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:k_id_core/k_id_core.dart';

class Root extends StatelessWidget {
  const Root({super.key});

  @override
  Widget build(BuildContext context) => KidCoreProvider(
        publishableKey: 'kgp_test_...',
        baseUrl: 'https://kai-api.test.k-id.com/fapi/v1',
        declare: const KidDeclare(permissions: [PermissionName.textChatPublic], supportEmail: 'help@example.com'),
        child: KidSessionProvider(
          jurisdiction: JurisdictionCode.auto,
          child: const KidAgeGate(pass: Game()),
        ),
      );
}
```

Later, on your options screen, a standing menu lets the player manage that session's permissions:

```dart
KidSettingsProvider(sessionId: sessionId, child: const KidSettings())
```

(`KidSettingsProvider` must sit inside a `KidCoreProvider`.)

The widgets use Material inputs; in an app without `MaterialApp` they fall back to the English Material
localizations.

## `KidCoreProvider` - app-level, wrap once

- `publishableKey` - required. Your k-ID publishable key; safe to ship in the app.
  The SDK binds its calls to the device: it creates a device key, mints a short-lived client token for it from k-ID,
  and signs every call with it. There is nothing to configure. On iOS the key is in the Secure Enclave, on Android in
  the Keystore, and on the web it is a non-extractable WebCrypto key in the browser's IndexedDB, so a relaunch or reload
  reuses it.
- `baseUrl` - required. The k-ID API URL Kai shows for your key: `https://kai-api.k-id.com/fapi/v1` for a live key,
  `https://kai-api.test.k-id.com/fapi/v1` for a test key. Calls must go straight to k-ID, not through a proxy, because
  each call carries a proof signed for the exact k-ID URL it is sent to.
- `declare` - optional `KidDeclare`, read once. See [Declare](#declare-test-keys).
- `appearance` - optional `KidAppearance`. See [Styling](#styling).
- `localization` - optional `KidLocalization`: a locale, or partial copy overrides merged over the English defaults.
  See [Localization](#localization).

`KidCoreProvider.of(context)` is the `KidCoreContext`: `strings` and `jurisdictions`.

## `KidSessionProvider` - wrap one age gate

- `jurisdiction` - a `JurisdictionCode`: an ISO 3166-1 alpha-2 country or ISO 3166-2 subdivision code (the supported
  ones are static members named as on iOS and Android, such as `JurisdictionCode.US_CA`;
  `JurisdictionCode('US-CA')` also works), or `JurisdictionCode.auto` to resolve it from the client IP (falls back to
  the picker). Omit to show the picker.
- `age` - `AgeSignal` (`AgeSignal.dateOfBirth('YYYY-MM-DD')` or `AgeSignal.age(n)`). Omit to show `KidCollectAge`.
- `email` - the grownup's email for consent, or the player's own email for adult age verification. Omit to show
  `KidAskAnAdult` / `KidVerifyAge`.
- `challengeId` / `sessionId` - resume. See [Resume after a restart](#resume-after-a-restart).
- `onChallenge` - fires once a challenge's email is sent.
- `onSession` - fires once the session is established.
- `onClaim` - fires once the age check has a result, passed or pending, with a one-time token for your backend.

Age and jurisdiction freeze once the check runs; later changes are ignored with a warning.

## `KidSettingsProvider` - wrap the settings menu

- `sessionId` - required; the session from the age gate's `onSession`.
- `challengeId` / `onChallenge` - resume an in-flight grownup ask. `onChallenge` fires once the ask's email is sent.

## Resume after a restart

The SDK keeps only its device key; it stores no session or challenge ids. Store the ids `onSession` and `onChallenge`
hand you, in whatever storage your app already uses, and pass them back as `sessionId` / `challengeId` on the next
launch. A returning player then skips the age gate, and a pending grownup ask picks up where it left off. The provider
reads them once, when it is first built.

## Integration tiers

Three levels of control, across both surfaces: the age gate (`KidSessionProvider`) and the settings menu
(`KidSettingsProvider`). Mix them freely. Every widget fills its container's width.

**Tier 1 - drop-in widgets.** `KidAgeGate` draws the capture itself while `running`. For the other states it shows the
widget you pass, `pending`, `pass`, `prohibited`, `fail` or `error`, and nothing for one you leave out, so pass at least
`pass`. There is no reset: recover from `error` by recreating `KidSessionProvider`, for example by giving it a new
`key`.

`KidSettings()` is the all-in-one permission menu inside `KidSettingsProvider`: player-managed permissions get an
on/off switch, guardian-managed ones are staged with a tap and asked for together in one request, and prohibited ones
are hidden.

`KidPermission(name: PermissionName.voiceChat, fallback: ..., child: ...)` shows its child when that permission is
enabled for the player, else `fallback` (default: nothing).

**Tier 2 - composable pieces.** Place these inside `KidSessionProvider`. Each shows only during its own step, and not
at all once you supply the matching provider input. The callbacks only observe; they never take over the flow.

- `KidSelectJurisdiction(onSelect: ...)` - the jurisdiction picker. `onSelect` gets the chosen code.
- `KidCollectAge(methods: ..., onSubmit: ...)` - `methods` is your preferred order of `KidAgeMethod.ageSlider` /
  `KidAgeMethod.dateOfBirth`, limited to what the jurisdiction approves; omit it for age slider, then date of birth.
  `onSubmit` gets the `AgeSignal`.
- `KidAskAnAdult(onSent: ...)` - the grownup's email with a built-in send. `onSent` gets the email once it has gone
  out.
- `KidVerifyAge(onSent: ...)` - for an adults-only product: emails the player a link to verify their age on k-ID.
  `onSent` gets the email once it has gone out.

On an established session, `KidSessionVerifyAge(pass: ...)` verifies the player is an adult. See
[Verifying age on a session](#verifying-age-on-a-session).

`KidPermissionSettings()` is `KidSettings` without its surrounding card, for your own settings screen.

**Tier 3 - headless.** Hold each value in your own state and pass it as the matching `KidSessionProvider` input; the
widgets fill in anything you omit. Read and drive the flow from the controller the provider holds; a widget that reads
it rebuilds as it changes. Each web hook is a getter:

| Web hook                                    | Flutter                                                               |
| ------------------------------------------- | --------------------------------------------------------------------- |
| `useKidAgeGate()`                           | `KidSessionProvider.of(context).ageGate`                              |
| `useKidSession()`                           | `KidSessionProvider.of(context).session`                              |
| `useKidChallenge()`                         | `KidSessionProvider.of(context).challenge`                            |
| `useKidPermission()`                        | `KidSessionProvider.of(context).permission`                           |
| `useKidPermissionSettings()`                | `KidSettingsProvider.of(context).permissionSettings`                  |
| `useKidStrings()` / `useKidJurisdictions()` | `KidCoreProvider.of(context).strings` / `.jurisdictions`              |

- `ageGate` - `status`, `challengeId`, `challengeKind`, `sessionId`, `error`, `requirements` (including the
  jurisdiction's `digitalConsentAge`, `civilAge`, `minimumAge` and `accessAge`), and `submit()`, which sends the
  challenge email once the check has produced a challenge and can be called again to re-send. `challengeKind` is
  `ChallengeKind.parentalConsent` when the email goes to a parent and `ChallengeKind.ageAssurance` when it goes to the
  player, or null before there is a challenge.
- `session` - `session`, `permissions` (a name to enabled map), `sessionId`, `isLoaded`, `ageVerification`
  (`verifiedAge`, counting birthdays since, and `verifiedAt` once the player has proven an age, else null),
  `verifyAge`, and `refresh()`, a cheap re-read. The player is a verified adult when
  `ageVerification.verifiedAge >= requirements.civilAge`.
- `session.verifyAge` - the headless form of `KidSessionVerifyAge`, sharing its flow: `start()` checks the session (a
  no-op until the gate passes; after a fail or error it starts over with a fresh check); `status` is `pass` once the
  session's `ageVerification.verifiedAge` meets the jurisdiction's civil age, `fail` when it does not, and `error` when
  k-ID cannot be reached. While `step` is `VerifyAgeStep.email`, collect the player's email and call `submit(email)`;
  while `status` is `pending`, call it again to re-send.
- `permission` - `can(PermissionName.voiceChat)` and `get(PermissionName.voiceChat)`, the full `Permission` including
  `managedBy`, so you can explain a guardian-managed feature rather than just hide it.
- `challenge` - `challengeId`, `status` and `expiresAt`, for a custom waiting screen. `expiresAt` is only set when the
  challenge has a deadline, like Indonesia's 24-hour consent window. Once it passes, the age gate moves to `fail`;
  recreate the provider to ask again.
- `permissionSettings` - branch each permission on `managedBy`: `ManagedBy.player` -> `change(name, enabled)`, except a
  player-managed permission with a `verifiedAgeThreshold` that is off: ask for it on its own with `upgrade([name])`,
  which turns it on when the player's verified age already covers it and otherwise returns `invalidRequest` because an
  age check is needed; call it again with the player's own email (never the grownup's),
  `upgrade([name], approverEmail: playerEmail)`, and k-ID emails the player a link to verify their age;
  `ManagedBy.guardian` -> collect a set and `upgrade(names)` (one request, emailed to the player's grownup);
  `ManagedBy.prohibited` -> hide it. One `upgrade` can't mix permissions that have a `verifiedAgeThreshold` with ones
  that don't: k-ID rejects it with `invalidRequest`. When `hasApproverEmail` is false, ask for the grownup's email and
  pass `upgrade(names, approverEmail: ...)`. `challenge` is the in-flight ask; its `challengeKind` is `parentalConsent`
  while it waits on the grownup and `ageAssurance` while it waits on the player's own age check, and null until known.
  `change` and `upgrade` return a `KidResult` (see [Errors](#errors)).

Two steps `KidCollectAge` and `KidAskAnAdult` handle for you, you drive yourself here:

- Age: `requirements.approvedAgeCollectionMethods` lists the inputs the jurisdiction allows (null until a jurisdiction
  is set). Collect one and pass it as the `age` input (`date-of-birth` -> `AgeSignal.dateOfBirth`, `age-slider` ->
  `AgeSignal.age`).
- Consent and adult verification: the `email` input alone does not send. Once a challenge exists, pass `email`, then
  call `submit()`.

A permission's name is a `PermissionName` (`PermissionName.voiceChat`); a session's `Permission` gives it as
`permissionName`. Client-side permissions gate what a player sees. Enforce the real capability server-side.

## Styling

`KidAppearance(variables: ..., elements: ...)`. `variables` is a `KidAppearanceVariables` with the same tokens as web,
iOS and Android (`colorPrimary`, `colorOnPrimary`, `colorText`, `colorTextMuted`, `colorSurface`, `colorSurfaceMuted`,
`colorBorder`, `colorDanger`, `fontFamily`, `radius`); pass only the ones you change. `elements` overrides one element,
keyed by `KidElementName` (`card`, `title`, `label`, `input`, `button`, `muted`, `danger`, `row`, `pill` (`pillAsk` /
`pillAdded`), `askForm`, `controlColumn`, `verifyAge`, and one per widget: `selectJurisdiction`, `collectAge`,
`askAnAdult`, `settings`) with a `KidElementStyle`. An override beats every default. The widgets don't read your app's
`ThemeData`.

```dart
KidCoreProvider(
  publishableKey: 'kgp_test_...',
  baseUrl: 'https://kai-api.test.k-id.com/fapi/v1',
  appearance: const KidAppearance(
    variables: KidAppearanceVariables(colorPrimary: Color(0xFF7C5CFF)),
    elements: {KidElementName.button: KidElementStyle(cornerRadius: 24)},
  ),
  child: ...,
)
```

## Localization

The widgets render in English. Pass a locale to translate them:

```dart
KidCoreProvider(
  publishableKey: 'kgp_test_...',
  baseUrl: 'https://kai-api.test.k-id.com/fapi/v1',
  localization: KidLocalization.jaJP,
  child: ...,
)
```

`getKidLocalization(Localizations.localeOf(context).toLanguageTag())` picks the locale for the player's language,
falling back to English. `kidLocales` lists the supported locales. An Arabic locale lays the widgets out right to left.

To change individual strings, pass a `KidLocalization` with only the fields you change; each field is merged over the
English defaults. To change a string in a locale, use `copyWith`: a section you pass replaces the locale's section,
and its fields you leave out fall back to English. Keep any `{token}` placeholders.

```dart
final ja = KidLocalization.jaJP;
ja.copyWith(
  age: KidAgeLocalization(dateOfBirthLabel: ja.age?.dateOfBirthLabel, ageLabel: ja.age?.ageLabel, submit: 'OK'),
)
```

The jurisdiction picker follows the locale, naming countries in the player's language; `KidCoreProvider.of(context)
.jurisdictions` is the same list for a custom picker. Permission names follow it too: `KidSettings` shows them, and a
custom settings UI reads `KidCoreProvider.of(context).strings.permissions[name.value]?.name`.

## Errors

`KidError` carries `status`, a closed `code` (`KidErrorCode`: `invalidRequest`, `unauthorized`, `notFound`,
`rateLimited`, `unavailable`), a display-safe `message`, k-ID's own `rawCode`, and with `rateLimited`, `retryAfter`:
the whole seconds k-ID asked you to wait, when it said, or, when k-ID rate limited the client token a call needed, the
seconds left before the SDK asks for one again. The SDK never retries a rate-limited call for you. Systemic failures
throw it, and `session.refresh()` throws nothing else; user-recoverable ones (`submit`, `change`, `upgrade`) return a
`KidResult` whose `error` is the `KidError` instead. The `error` of `ageGate`, `session.verifyAge` and
`permissionSettings` is the `KidError` behind `status == KidStatus.error` (or a failed settings load), or null: a k-ID
API error as is, and any other failure, such as a dropped connection, as `unavailable`. Full detail goes to the
developer log. `submit()` returns `invalidRequest` when called before a challenge exists or without an email.

The `error` widgets of `KidAgeGate` and `KidSessionVerifyAge` take no arguments: read the error inside them from
`KidSessionProvider.of(context).ageGate.error` or `.session.verifyAge.error`. When the settings list fails to load,
`permissionSettings.error` is set; call its `refresh()` to load it again.

## Live keys

A live key also proves to k-ID that it is really your app calling, the same way the iOS, Android and web SDKs do:

- **iOS:** App Attest. It works only in App Store and TestFlight builds; add the App Attest capability to your target
  in Xcode, with the production environment.
- **Android:** Key Attestation. It passes only for a build signed with a certificate you listed in Kai, on a device with
  a locked bootloader and verified boot.
- **Web:** reCAPTCHA Enterprise, run invisibly before the first call. If your page sets a Content Security Policy,
  allow:
  - `script-src`: `https://www.google.com/recaptcha/` `https://www.gstatic.com/recaptcha/`
  - `frame-src`: `https://www.google.com/recaptcha/` `https://recaptcha.google.com/recaptcha/`
  - `connect-src`: `https://www.google.com/recaptcha/`

Where the check can't pass, such as a debug build, the mint gets basic trust and the SDK logs why. Use a test key while
developing.

## Declared Age Range and Play Age Signals

The age gate first asks the platform for the player's age range, with the jurisdiction's minimum, access and civil ages
as the age gates. When the player shares it, the range stands in for the age step and the player never sees it. Without
a range, or when the player declines, the gate asks for their age as usual. It is asked only from an app the platform
has verified (a live key that passed App Attest or Key Attestation), or from any app on a test key, and never when you
pass `age`.

- **iOS 26 and later:** Apple's Declared Age Range. It needs the `com.apple.developer.declared-age-range` entitlement:
  enable the Declared Age Range capability on your target in Xcode.
- **Android:** Google Play Age Signals. Play answers with your app's own age ranges if you set them on the Age signals
  page in Play Console, or with its default ranges. It answers only for an app installed from Google Play, or sideloaded
  on a device signed in as a license tester, and only where Play offers age signals.
- **Web:** no platform gives an age range, so the gate asks for the age.

## Declare (test keys)

`declare` on `KidCoreProvider` is a one-time integration manifest: the capabilities the app uses (which become its
permission set), plus its legal links, icon and support email. What parents read about the app's data is worked out in
Kai, from these capabilities and a few questions Kai asks you there. It applies only while you use a test key; a live
key skips it. The age gate sends no request until it lands; a transient failure is retried a few times, and if declare
still fails the age gate shows `error`.

```dart
const KidDeclare(
  permissions: [PermissionName.textChatPublic, PermissionName.voiceChat],
  privacyPolicyUrl: DeclareField.set('https://example.com/privacy'),
  termsOfServiceUrl: DeclareField.set('https://example.com/terms'),
  iconUrl: DeclareField.set('assets/icon.png'),
  supportEmail: 'help@example.com',
)
```

`permissions` and `supportEmail` are required. Every other field is a `DeclareField`: leave it out (or
`DeclareField.keep()`) to keep what k-ID already has, `DeclareField.clear()` to clear it, or `DeclareField.set(value)`
to set it.

- `permissions` - required. Each is a `PermissionName`. An unknown name is rejected, and the call fails naming it.
- `privacyPolicyUrl` / `termsOfServiceUrl` - optional http(s) URLs. Clearing one resets it to k-ID's default link.
- `iconUrl` - optional app icon, a PNG or JPEG up to 5MB. A public https link is sent for k-ID to fetch; anything else
  the app can load (an asset in your pubspec, a file path, a dev server) is read by the SDK and sent inline. Clearing it
  removes it.
- `supportEmail` - required email address that k-ID's emails give players and parents to contact for help. A missing,
  empty or invalid address is rejected, and the call fails naming `supportEmail`. Getting a live key also needs your own
  privacy and terms links and an icon.

## Adult age verification (`KidVerifyAge`)

`KidVerifyAge` emails the player a link to verify their age on k-ID. The result comes through the SDK's status check,
the same as consent. Verification happens in the browser, through the link k-ID emails; the SDK opens no browser or web
view.

## Verifying age on a session

On any product, a player already through the gate can prove they are an adult (the civil age of their jurisdiction) on
their session with age assurance, for example to open an adults-only space. Like `KidAgeGate`, `KidSessionVerifyAge`
draws the email form itself and shows whatever you pass for each outcome, and nothing for one you leave out:

| State                                                                   | Shows                                                         |
| ----------------------------------------------------------------------- | ------------------------------------------------------------- |
| before the gate passes, and while it checks the session                 | nothing                                                       |
| the session is not yet a verified adult                                | the email form (`onSent` gets the email once the link is sent) |
| link sent, waiting for the player to verify                             | `pending`                                                     |
| the session is a verified adult (straight away when it already was one) | `pass`, and the session carries `ageVerification`             |
| the player could not prove they are an adult                            | `fail`                                                        |
| k-ID could not be reached or rate limited                               | `error`                                                       |

Showing `KidSessionVerifyAge` again after a fail or error tries again with a new email.

```dart
const KidSessionVerifyAge(
  pass: AdultsSpace(),
  pending: Text('Check your email to verify your age.'),
  fail: Text('We could not verify your age.'),
)
```

## Privacy

On iOS the SDK's privacy manifest declares the data it collects, linked to the player, not used for tracking, and only
for app functionality: Other Data Types (the player's age, date of birth or platform age signal), User ID (the session
id) and Coarse Location (the jurisdiction). The SDK also sends an approver's email (the parent for consent, or the player
for adult age verification) when a challenge asks for one, so add Email Address to your App Store privacy label if your
setup raises challenges.
