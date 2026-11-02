import '../catalog/jurisdictions.dart';
import '../jurisdiction_option.dart';
import '../strings.dart';

final _marks = RegExp(r'[̀-ͯ]');

String _folded(String value) => value.toLowerCase().replaceAll(_marks, '');

/// The picker's options: every country, and each subdivision named as `{country} ({subdivision})`, sorted by name.
/// [localNames] are the countries' names in the player's language; a country without one keeps its English name.
List<JurisdictionOption> localizeJurisdictions(KidStrings strings, {Map<String, String> localNames = const {}}) {
  final countryNames = {for (final c in countries) c.code: localNames[c.code] ?? c.name};
  final options = [
    for (final c in countries) JurisdictionOption(code: c.code, name: countryNames[c.code]!),
    for (final MapEntry(key: code, value: subdivision) in strings.subdivisions.entries)
      JurisdictionOption(
        code: code,
        name: format(strings.jurisdiction.subdivisionName, {
          'country': countryNames[code.substring(0, 2)] ?? code.substring(0, 2),
          'subdivision': subdivision,
        }),
      ),
  ];
  return options..sort((a, b) => _folded(a.name).compareTo(_folded(b.name)));
}

/// The options whose name or code contains [query], ignoring case.
List<JurisdictionOption> matchingJurisdictions(List<JurisdictionOption> options, String query) {
  final q = _folded(query.trim());
  if (q.isEmpty) return options;
  return [
    for (final o in options)
      if (_folded(o.name).contains(q) || o.code.toLowerCase().contains(q)) o,
  ];
}
