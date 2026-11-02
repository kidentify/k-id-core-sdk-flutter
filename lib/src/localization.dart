import 'catalog/permissions.dart';
import 'localization/locales.dart';
import 'strings.dart';

class KidJurisdictionLocalization {
  const KidJurisdictionLocalization({this.label, this.placeholder, this.submit, this.subdivisionName});

  final String? label;
  final String? placeholder;
  final String? submit;

  /// `{country}` is the localized country, `{subdivision}` the region.
  final String? subdivisionName;
}

class KidAgeLocalization {
  const KidAgeLocalization({this.dateOfBirthLabel, this.ageLabel, this.submit});

  final String? dateOfBirthLabel;

  /// `{age}` is the selected age.
  final String? ageLabel;
  final String? submit;
}

class KidEmailLocalization {
  const KidEmailLocalization({
    this.title,
    this.description,
    this.emailPlaceholder,
    this.submit,
    this.submitting,
    this.error,
    this.invalidEmail,
  });

  final String? title;
  final String? description;
  final String? emailPlaceholder;
  final String? submit;
  final String? submitting;
  final String? error;
  final String? invalidEmail;
}

class KidSettingsLocalization {
  const KidSettingsLocalization({
    this.title,
    this.enabledLabel,
    this.on,
    this.off,
    this.ask,
    this.added,
    this.granted,
    this.askGrownup,
    this.asking,
    this.waiting,
    this.verifying,
    this.error,
  });

  final String? title;

  /// `{permission}` is the permission name.
  final String? enabledLabel;
  final String? on;
  final String? off;
  final String? ask;
  final String? added;
  final String? granted;
  final String? askGrownup;
  final String? asking;
  final String? waiting;

  /// Shown in place of [waiting] while the player's own age check is out.
  final String? verifying;
  final String? error;
}

class KidPermissionLocalization {
  const KidPermissionLocalization({this.name});

  final String? name;
}

/// Copy overrides for the widgets, merged field by field over the English defaults: a locale, or your own wording.
/// [locale] also names the countries in the jurisdiction picker and lays the widgets out right to left for Arabic.
class KidLocalization {
  const KidLocalization({
    this.jurisdiction,
    this.age,
    this.askAnAdult,
    this.verifyAge,
    this.settings,
    this.subdivisions,
    this.permissions,
    this.locale,
  });

  final KidJurisdictionLocalization? jurisdiction;
  final KidAgeLocalization? age;
  final KidEmailLocalization? askAnAdult;
  final KidEmailLocalization? verifyAge;
  final KidSettingsLocalization? settings;

  /// Subdivision names keyed by ISO 3166-2 code, without the country.
  final Map<String, String>? subdivisions;
  final Map<PermissionName, KidPermissionLocalization>? permissions;
  final String? locale;

  /// A copy with the given fields replaced, e.g. `KidLocalization.frFR.copyWith(settings: ...)`. A section passed
  /// here replaces that whole section.
  KidLocalization copyWith({
    KidJurisdictionLocalization? jurisdiction,
    KidAgeLocalization? age,
    KidEmailLocalization? askAnAdult,
    KidEmailLocalization? verifyAge,
    KidSettingsLocalization? settings,
    Map<String, String>? subdivisions,
    Map<PermissionName, KidPermissionLocalization>? permissions,
    String? locale,
  }) =>
      KidLocalization(
        jurisdiction: jurisdiction ?? this.jurisdiction,
        age: age ?? this.age,
        askAnAdult: askAnAdult ?? this.askAnAdult,
        verifyAge: verifyAge ?? this.verifyAge,
        settings: settings ?? this.settings,
        subdivisions: subdivisions ?? this.subdivisions,
        permissions: permissions ?? this.permissions,
        locale: locale ?? this.locale,
      );

  static const arSA = localizationAr;
  static const deDE = localizationDe;
  static const enGB = localizationEnGB;
  static const esES = localizationEs;
  static const esMX = localizationEsMX;
  static const frFR = localizationFr;
  static const frCA = localizationFrCA;
  static const hiIN = localizationHi;
  static const idID = localizationId;
  static const itIT = localizationIt;
  static const jaJP = localizationJa;
  static const koKR = localizationKo;
  static const msMY = localizationMs;
  static const nlNL = localizationNl;
  static const ptPT = localizationPt;
  static const ptBR = localizationPtBR;
  static const ruRU = localizationRu;
  static const thTH = localizationTh;
  static const trTR = localizationTr;
  static const zhCN = localizationZh;
  static const zhTW = localizationZhHant;
}

/// The English copy the widgets render without a localization.
const defaultStrings = englishStrings;

/// The locales the SDK ships, by language tag.
const kidLocales = [
  'ar',
  'de',
  'en',
  'en-GB',
  'es',
  'es-MX',
  'fr',
  'fr-CA',
  'hi',
  'id',
  'it',
  'ja',
  'ko',
  'ms',
  'nl',
  'pt',
  'pt-BR',
  'ru',
  'th',
  'tr',
  'zh',
  'zh-Hant',
];

const _byTag = {
  'ar': KidLocalization.arSA,
  'de': KidLocalization.deDE,
  'en': KidLocalization(locale: 'en'),
  'en-GB': KidLocalization.enGB,
  'es': KidLocalization.esES,
  'es-MX': KidLocalization.esMX,
  'fr': KidLocalization.frFR,
  'fr-CA': KidLocalization.frCA,
  'hi': KidLocalization.hiIN,
  'id': KidLocalization.idID,
  'it': KidLocalization.itIT,
  'ja': KidLocalization.jaJP,
  'ko': KidLocalization.koKR,
  'ms': KidLocalization.msMY,
  'nl': KidLocalization.nlNL,
  'pt': KidLocalization.ptPT,
  'pt-BR': KidLocalization.ptBR,
  'ru': KidLocalization.ruRU,
  'th': KidLocalization.thTH,
  'tr': KidLocalization.trTR,
  'zh': KidLocalization.zhCN,
  'zh-Hant': KidLocalization.zhTW,
};

const _traditionalChineseSubtags = {'hant', 'tw', 'hk', 'mo'};

/// The localization for a player's language tag: the exact tag first, then Traditional Chinese for `zh-TW`, `zh-HK`,
/// `zh-MO` and `zh-Hant`, then the base language, then English. English is `KidLocalization(locale: 'en')`, which keeps
/// the built-in copy.
KidLocalization getKidLocalization(String locale) {
  final lower = locale.replaceAll('_', '-').toLowerCase();
  String? match(String tag) => kidLocales.where((l) => l.toLowerCase() == tag).firstOrNull;
  final exact = match(lower);
  if (exact != null) return _byTag[exact]!;
  final [language, ...subtags] = lower.split('-');
  if (language == 'zh' && subtags.any(_traditionalChineseSubtags.contains)) return KidLocalization.zhTW;
  return _byTag[match(language) ?? 'en']!;
}

/// The English defaults with [overrides] merged over them, field by field.
KidStrings mergeStrings(KidLocalization? overrides) {
  final d = defaultStrings;
  if (overrides == null) return d;
  KidEmailStrings email(KidEmailStrings base, KidEmailLocalization? o) => o == null
      ? base
      : KidEmailStrings(
          title: o.title ?? base.title,
          description: o.description ?? base.description,
          emailPlaceholder: o.emailPlaceholder ?? base.emailPlaceholder,
          submit: o.submit ?? base.submit,
          submitting: o.submitting ?? base.submitting,
          error: o.error ?? base.error,
          invalidEmail: o.invalidEmail ?? base.invalidEmail,
        );
  final j = overrides.jurisdiction;
  final a = overrides.age;
  final s = overrides.settings;
  return KidStrings(
    jurisdiction: j == null
        ? d.jurisdiction
        : KidJurisdictionStrings(
            label: j.label ?? d.jurisdiction.label,
            placeholder: j.placeholder ?? d.jurisdiction.placeholder,
            submit: j.submit ?? d.jurisdiction.submit,
            subdivisionName: j.subdivisionName ?? d.jurisdiction.subdivisionName,
          ),
    age: a == null
        ? d.age
        : KidAgeStrings(
            dateOfBirthLabel: a.dateOfBirthLabel ?? d.age.dateOfBirthLabel,
            ageLabel: a.ageLabel ?? d.age.ageLabel,
            submit: a.submit ?? d.age.submit,
          ),
    askAnAdult: email(d.askAnAdult, overrides.askAnAdult),
    verifyAge: email(d.verifyAge, overrides.verifyAge),
    settings: s == null
        ? d.settings
        : KidSettingsStrings(
            title: s.title ?? d.settings.title,
            enabledLabel: s.enabledLabel ?? d.settings.enabledLabel,
            on: s.on ?? d.settings.on,
            off: s.off ?? d.settings.off,
            ask: s.ask ?? d.settings.ask,
            added: s.added ?? d.settings.added,
            granted: s.granted ?? d.settings.granted,
            askGrownup: s.askGrownup ?? d.settings.askGrownup,
            asking: s.asking ?? d.settings.asking,
            waiting: s.waiting ?? d.settings.waiting,
            verifying: s.verifying ?? d.settings.verifying,
            error: s.error ?? d.settings.error,
          ),
    subdivisions: {...d.subdivisions, ...?overrides.subdivisions},
    permissions: {
      ...d.permissions,
      for (final MapEntry(key: name, value: copy) in (overrides.permissions ?? const {}).entries)
        name.value: KidPermissionStrings(name: copy.name ?? d.permissions[name.value]?.name ?? name.value),
    },
  );
}

const _rtlLanguages = {'ar', 'fa', 'he', 'ur'};

/// Whether [locale] reads right to left; null when there is no locale.
bool? isRightToLeft(String? locale) {
  if (locale == null || locale.isEmpty) return null;
  return _rtlLanguages.contains(locale.split(RegExp('[-_]')).first.toLowerCase());
}
