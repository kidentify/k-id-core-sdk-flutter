class KidJurisdictionStrings {
  const KidJurisdictionStrings({
    required this.label,
    required this.placeholder,
    required this.submit,
    required this.subdivisionName,
  });

  final String label;
  final String placeholder;
  final String submit;

  /// `{country}` is the localized country, `{subdivision}` the region.
  final String subdivisionName;
}

class KidAgeStrings {
  const KidAgeStrings({required this.dateOfBirthLabel, required this.ageLabel, required this.submit});

  final String dateOfBirthLabel;

  /// `{age}` is the selected age.
  final String ageLabel;
  final String submit;
}

class KidEmailStrings {
  const KidEmailStrings({
    required this.title,
    required this.description,
    required this.emailPlaceholder,
    required this.submit,
    required this.submitting,
    required this.error,
    required this.invalidEmail,
  });

  final String title;
  final String description;
  final String emailPlaceholder;
  final String submit;
  final String submitting;
  final String error;
  final String invalidEmail;
}

class KidSettingsStrings {
  const KidSettingsStrings({
    required this.title,
    required this.enabledLabel,
    required this.on,
    required this.off,
    required this.ask,
    required this.added,
    required this.granted,
    required this.askGrownup,
    required this.asking,
    required this.waiting,
    required this.verifying,
    required this.error,
  });

  final String title;

  /// `{permission}` is the permission name.
  final String enabledLabel;
  final String on;
  final String off;
  final String ask;
  final String added;
  final String granted;
  final String askGrownup;
  final String asking;
  final String waiting;

  /// Shown in place of [waiting] while the player's own age check is out.
  final String verifying;
  final String error;
}

class KidPermissionStrings {
  const KidPermissionStrings({required this.name});

  final String name;
}

/// The copy every k-ID widget renders.
class KidStrings {
  const KidStrings({
    required this.jurisdiction,
    required this.age,
    required this.askAnAdult,
    required this.verifyAge,
    required this.settings,
    required this.subdivisions,
    required this.permissions,
  });

  final KidJurisdictionStrings jurisdiction;
  final KidAgeStrings age;
  final KidEmailStrings askAnAdult;
  final KidEmailStrings verifyAge;
  final KidSettingsStrings settings;

  /// Subdivision names keyed by ISO 3166-2 code, without the country.
  final Map<String, String> subdivisions;

  /// Permission copy keyed by permission name.
  final Map<String, KidPermissionStrings> permissions;
}

final _token = RegExp(r'\{(\w+)\}');

/// Fills `{token}` placeholders from [vars]; an absent token is left verbatim.
String format(String template, Map<String, Object> vars) =>
    template.replaceAllMapped(_token, (m) => vars.containsKey(m[1]) ? '${vars[m[1]]}' : m[0]!);
