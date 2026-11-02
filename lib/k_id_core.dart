/// The k-ID SDK for Flutter apps: an age gate with parental consent, adult age verification, and a settings menu where
/// players manage their permissions.
library;

export 'src/catalog/jurisdictions.dart' show JurisdictionCode;
export 'src/catalog/permissions.dart' show PermissionName;
export 'src/client.dart' show DeclareField, KidDeclare;
export 'src/core/settings.dart' show SettingsChallengeState, SettingsChallengeStatus;
export 'src/core/types.dart' show ChallengeKind, KidStatus, RawChallengeStatus;
export 'src/core/verify_age.dart' show VerifyAgeStep;
export 'src/errors.dart' show KidError, KidErrorCode, KidResult;
export 'src/jurisdiction_option.dart' show JurisdictionOption;
export 'src/localization.dart'
    show
        KidAgeLocalization,
        KidEmailLocalization,
        KidJurisdictionLocalization,
        KidLocalization,
        KidPermissionLocalization,
        KidSettingsLocalization,
        defaultStrings,
        getKidLocalization,
        kidLocales;
export 'src/models.dart' show AgeSignal, AgeVerification, Challenge, ManagedBy, Permission, Requirements, Session;
export 'src/strings.dart'
    show KidAgeStrings, KidEmailStrings, KidJurisdictionStrings, KidPermissionStrings, KidSettingsStrings, KidStrings;
export 'src/version.dart' show kidSdkVersion;
export 'src/widgets/appearance.dart' show KidAppearance, KidAppearanceVariables, KidElementName, KidElementStyle;
export 'src/widgets/components.dart'
    show
        KidAgeGate,
        KidAgeMethod,
        KidAskAnAdult,
        KidCollectAge,
        KidPermission,
        KidPermissionSettings,
        KidSelectJurisdiction,
        KidSessionVerifyAge,
        KidSettings,
        KidVerifyAge;
export 'src/widgets/providers.dart'
    show
        KidAgeGateController,
        KidCoreContext,
        KidCoreProvider,
        KidSessionProvider,
        KidSettingsController,
        KidSettingsProvider,
        UseKidAgeGate,
        UseKidChallenge,
        UseKidPermission,
        UseKidPermissionSettings,
        UseKidSession,
        UseKidSessionVerifyAge;
