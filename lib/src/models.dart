import 'catalog/permissions.dart';

typedef Json = Map<String, dynamic>;

/// The player's age, given instead of collecting it in the gate.
sealed class AgeSignal {
  const AgeSignal();

  /// `YYYY-MM-DD`.
  const factory AgeSignal.dateOfBirth(String dateOfBirth) = DateOfBirthSignal;
  const factory AgeSignal.age(int age) = AgeNumberSignal;

  Json toJson();
}

final class DateOfBirthSignal extends AgeSignal {
  const DateOfBirthSignal(this.dateOfBirth);
  final String dateOfBirth;

  @override
  Json toJson() => {'dateOfBirth': dateOfBirth};

  @override
  bool operator ==(Object other) => other is DateOfBirthSignal && other.dateOfBirth == dateOfBirth;

  @override
  int get hashCode => dateOfBirth.hashCode;
}

final class AgeNumberSignal extends AgeSignal {
  const AgeNumberSignal(this.age);
  final int age;

  @override
  Json toJson() => {'age': age};

  @override
  bool operator ==(Object other) => other is AgeNumberSignal && other.age == age;

  @override
  int get hashCode => age.hashCode;
}

/// Who controls a permission.
enum ManagedBy {
  player,
  guardian,
  prohibited;

  static ManagedBy? fromWire(Object? value) => switch (value) {
        'PLAYER' => ManagedBy.player,
        'GUARDIAN' => ManagedBy.guardian,
        'PROHIBITED' => ManagedBy.prohibited,
        _ => null,
      };
}

class Permission {
  const Permission({required this.name, required this.enabled, this.managedBy, this.verifiedAgeThreshold});

  factory Permission.fromJson(Json json) => Permission(
        name: json['name'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? false,
        managedBy: ManagedBy.fromWire(json['managedBy']),
        verifiedAgeThreshold: (json['verifiedAgeThreshold'] as num?)?.toInt(),
      );

  final String name;
  final bool enabled;
  final ManagedBy? managedBy;

  /// The age the player must verify before this permission can be enabled; null when no age check applies.
  final int? verifiedAgeThreshold;

  PermissionName get permissionName => PermissionName(name);
}

class AgeVerification {
  const AgeVerification({required this.verifiedAge, required this.verifiedAt});

  factory AgeVerification.fromJson(Json json) => AgeVerification(
        verifiedAge: (json['verifiedAge'] as num?)?.toInt() ?? 0,
        verifiedAt: json['verifiedAt'] as String? ?? '',
      );

  /// The proven age as of now, counting birthdays since [verifiedAt].
  final int verifiedAge;
  final String verifiedAt;
}

class Session {
  const Session({
    required this.sessionId,
    required this.ageStatus,
    required this.permissions,
    this.jurisdiction,
    this.etag,
    this.hasApproverEmail,
    this.ageVerification,
  });

  factory Session.fromJson(Json json) {
    final verification = json['ageVerification'];
    return Session(
      sessionId: json['sessionId'] as String? ?? '',
      ageStatus: json['ageStatus'] as String? ?? '',
      jurisdiction: json['jurisdiction'] as String?,
      etag: json['etag'] as String?,
      hasApproverEmail: json['hasApproverEmail'] as bool?,
      permissions: [
        for (final p in json['permissions'] as List? ?? const [])
          Permission.fromJson((p as Map).cast<String, dynamic>()),
      ],
      ageVerification: verification is Map ? AgeVerification.fromJson(verification.cast<String, dynamic>()) : null,
    );
  }

  final String sessionId;
  final String ageStatus;
  final String? jurisdiction;
  final String? etag;

  /// Whether a grownup is linked to approve upgrades. When false, pass the grownup's email to `upgrade`.
  final bool? hasApproverEmail;
  final List<Permission> permissions;
  final AgeVerification? ageVerification;
}

class Requirements {
  const Requirements({
    required this.shouldDisplay,
    required this.approvedAgeCollectionMethods,
    this.digitalConsentAge,
    this.civilAge,
    this.minimumAge,
    this.accessAge,
  });

  factory Requirements.fromJson(Json json) => Requirements(
        shouldDisplay: json['shouldDisplay'] as bool? ?? false,
        approvedAgeCollectionMethods: [for (final m in json['approvedAgeCollectionMethods'] as List? ?? const []) '$m'],
        digitalConsentAge: (json['digitalConsentAge'] as num?)?.toInt(),
        civilAge: (json['civilAge'] as num?)?.toInt(),
        minimumAge: (json['minimumAge'] as num?)?.toInt(),
        accessAge: (json['accessAge'] as num?)?.toInt(),
      );

  final bool shouldDisplay;
  final List<String> approvedAgeCollectionMethods;
  final int? digitalConsentAge;

  /// The age at which a player is a legal adult; compare the session's `ageVerification.verifiedAge` to it.
  final int? civilAge;
  final int? minimumAge;
  final int? accessAge;
}

class Challenge {
  const Challenge({required this.challengeId, this.type});

  factory Challenge.fromJson(Json json) =>
      Challenge(challengeId: json['challengeId'] as String? ?? '', type: json['type'] as String?);

  final String challengeId;
  final String? type;
}

class ChallengeStatus {
  const ChallengeStatus({required this.status, this.type, this.sessionId, this.expiresAt, this.permissions});

  factory ChallengeStatus.fromJson(Json json) => ChallengeStatus(
        status: json['status'] as String? ?? '',
        type: json['type'] as String?,
        sessionId: json['sessionId'] as String?,
        expiresAt: json['expiresAt'] as String?,
        permissions:
            json['permissions'] is List ? [for (final p in json['permissions'] as List) PermissionName('$p')] : null,
      );

  final String status;
  final String? type;
  final String? sessionId;
  final String? expiresAt;
  final List<PermissionName>? permissions;
}

class AgeResult {
  const AgeResult({required this.status, this.session, this.challenge, this.claimToken});

  factory AgeResult.fromJson(Json json) => AgeResult(
        status: json['status'] as String? ?? '',
        session: json['session'] is Map ? Session.fromJson((json['session'] as Map).cast<String, dynamic>()) : null,
        challenge:
            json['challenge'] is Map ? Challenge.fromJson((json['challenge'] as Map).cast<String, dynamic>()) : null,
        claimToken: json['claimToken'] as String?,
      );

  final String status;
  final Session? session;
  final Challenge? challenge;
  final String? claimToken;
}

/// The player's age range as the platform shared it.
class PlatformAgeSignal {
  const PlatformAgeSignal({required this.name, required this.ageLow, required this.ageHigh, this.declarationType});

  factory PlatformAgeSignal.fromJson(Json json) => PlatformAgeSignal(
        name: json['name'] as String? ?? '',
        ageLow: (json['ageLow'] as num?)?.toInt() ?? 0,
        ageHigh: (json['ageHigh'] as num?)?.toInt() ?? -1,
        declarationType: json['declarationType'] as String?,
      );

  final String name;
  final int ageLow;

  /// -1 when the range has no upper bound.
  final int ageHigh;
  final String? declarationType;

  Json toJson() => {
        'name': name,
        'ageLow': ageLow,
        'ageHigh': ageHigh,
        if (declarationType != null) 'declarationType': declarationType,
      };
}
