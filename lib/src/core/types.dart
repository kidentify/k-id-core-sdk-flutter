import '../errors.dart';
import '../models.dart';

/// The single status the whole surface reads. `running` is capturing or not started; `pending` is consent sent and
/// waiting; `pass`, `prohibited` and `fail` are terminal; `error` is an unrecoverable failure.
enum KidStatus { running, pending, pass, prohibited, fail, error }

/// The raw challenge status, for a custom waiting screen. `inProgress` is the adult opened the request but has not
/// finished.
enum RawChallengeStatus { pending, inProgress, pass, fail }

/// Whether a challenge's email goes to a parent or to the player.
enum ChallengeKind { parentalConsent, ageAssurance }

/// Which interactive step the capture flow is on while `running`; null once it leaves `running`.
enum AgeGateStep { jurisdiction, age, parentalConsent, ageAssurance, checking }

const Object unset = Object();

class AgeGateState {
  const AgeGateState({
    required this.status,
    required this.step,
    required this.challengeId,
    required this.challengeKind,
    required this.sessionId,
    required this.session,
    required this.claimToken,
    required this.rawChallengeStatus,
    required this.expiresAt,
    required this.requirements,
    required this.emailProvided,
    required this.error,
  });

  final KidStatus status;
  final AgeGateStep? step;
  final String? challengeId;
  final ChallengeKind? challengeKind;
  final String? sessionId;
  final Session? session;

  /// One-time claim token for this check; null until the check, after a prohibition, and on resume.
  final String? claimToken;
  final RawChallengeStatus? rawChallengeStatus;

  /// The challenge's deadline, or null when it has none. The flow moves to `fail` at this time.
  final String? expiresAt;
  final Requirements? requirements;

  /// True when the email arrived as a provider input, so the email forms stay hidden.
  final bool emailProvided;

  /// Why the gate ended in `error`: a k-ID API error as is, and any other failure as `unavailable`.
  final KidError? error;

  AgeGateState copyWith({
    KidStatus? status,
    Object? step = unset,
    Object? challengeId = unset,
    Object? challengeKind = unset,
    Object? sessionId = unset,
    Object? session = unset,
    Object? claimToken = unset,
    Object? rawChallengeStatus = unset,
    Object? expiresAt = unset,
    Object? requirements = unset,
    bool? emailProvided,
    Object? error = unset,
  }) =>
      AgeGateState(
        status: status ?? this.status,
        step: identical(step, unset) ? this.step : step as AgeGateStep?,
        challengeId: identical(challengeId, unset) ? this.challengeId : challengeId as String?,
        challengeKind: identical(challengeKind, unset) ? this.challengeKind : challengeKind as ChallengeKind?,
        sessionId: identical(sessionId, unset) ? this.sessionId : sessionId as String?,
        session: identical(session, unset) ? this.session : session as Session?,
        claimToken: identical(claimToken, unset) ? this.claimToken : claimToken as String?,
        rawChallengeStatus:
            identical(rawChallengeStatus, unset) ? this.rawChallengeStatus : rawChallengeStatus as RawChallengeStatus?,
        expiresAt: identical(expiresAt, unset) ? this.expiresAt : expiresAt as String?,
        requirements: identical(requirements, unset) ? this.requirements : requirements as Requirements?,
        emailProvided: emailProvided ?? this.emailProvided,
        error: identical(error, unset) ? this.error : error as KidError?,
      );
}
