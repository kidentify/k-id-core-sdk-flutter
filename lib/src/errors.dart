/// The closed set of error codes the SDK surfaces, grouped by what the developer does about it.
enum KidErrorCode { invalidRequest, unauthorized, notFound, rateLimited, unavailable }

/// A failure from the k-ID API, or one the SDK caught before a call. [message] is safe to display, never raw server
/// text; [rawCode] is k-ID's own code.
class KidError implements Exception {
  const KidError({required this.status, required this.code, required this.message, this.rawCode, this.retryAfter});

  final int status;
  final KidErrorCode code;
  final String message;
  final String? rawCode;

  /// With [KidErrorCode.rateLimited], the whole seconds k-ID asked the caller to wait before trying again, when it
  /// said, or, when k-ID rate limited the client token a call needed, the seconds left before the SDK asks for one
  /// again.
  final int? retryAfter;

  @override
  String toString() => 'KidError(status=$status, code=${code.name}, rawCode=$rawCode, message=$message)';
}

/// The outcome of a user-recoverable call such as `submit`, `change` or `upgrade`.
class KidResult {
  const KidResult.ok()
      : ok = true,
        error = null;
  const KidResult.failed(KidError this.error) : ok = false;

  final bool ok;
  final KidError? error;
}

// The API returns almost every error as HTTP 400, so map on the JSON `error` code, not the status.
const _rawErrorToCode = {
  'NOT_FOUND': KidErrorCode.notFound,
  'UNAUTHORIZED': KidErrorCode.unauthorized,
  'TOO_MANY_REQUESTS': KidErrorCode.rateLimited,
  'INVALID_INPUT': KidErrorCode.invalidRequest,
  'INVALID_EMAIL': KidErrorCode.invalidRequest,
  'AGE_CONFLICT': KidErrorCode.invalidRequest,
  'CLIENT_TOKEN_INVALID': KidErrorCode.unauthorized,
  'FEATURE_DISABLED': KidErrorCode.unavailable,
  'CANNOT_RESOLVE_JURISDICTION': KidErrorCode.unavailable,
  'INTERNAL_ERROR': KidErrorCode.unavailable,
  'UNKNOWN': KidErrorCode.unavailable,
};

KidErrorCode toKidErrorCode(String? rawCode, int status) {
  final mapped = _rawErrorToCode[rawCode];
  if (mapped != null) return mapped;
  if (status == 429) return KidErrorCode.rateLimited;
  if (status == 401 || status == 403) return KidErrorCode.unauthorized;
  if (status == 404) return KidErrorCode.notFound;
  if (status >= 400 && status < 500) return KidErrorCode.invalidRequest;
  return KidErrorCode.unavailable;
}

enum ErrorMessage {
  invalidRequest('The request was invalid.'),
  invalidAgeSignal('Provide a valid date of birth or age.'),
  invalidJurisdiction('Unknown or invalid jurisdiction code.'),
  ageConflict('The platform age signal conflicts with the provided age.'),
  challengeIdRequired('A challenge id is required.'),
  challengeResolved('This challenge is already resolved; no email can be sent.'),
  emailMismatch("The email address doesn't match this challenge's approver, or is required."),
  permissionNotChangeable("That permission can't be changed here."),
  unauthorizedKey('Invalid or unrecognized publishable key.'),
  unauthorizedOrigin("This origin isn't allowed for your publishable key."),
  unauthorizedApp("This app isn't allowed to use your publishable key."),
  sessionNotFound('Session not found.'),
  challengeNotFound('Challenge not found.'),
  rateLimited('Too many requests. Please wait and try again.'),
  serverError('Something went wrong on our side. Please try again.'),
  featureDisabled("This feature isn't enabled for this product.");

  const ErrorMessage(this.text);
  final String text;
}

final _invalidInputSubcases = [
  (RegExp('invalid jurisdiction', caseSensitive: false), ErrorMessage.invalidJurisdiction),
  (RegExp('dateofbirth|date of birth', caseSensitive: false), ErrorMessage.invalidAgeSignal),
  (RegExp('challenge id must be provided', caseSensitive: false), ErrorMessage.challengeIdRequired),
  (RegExp('completed challenge', caseSensitive: false), ErrorMessage.challengeResolved),
];

String resolveErrorMessage(
  String? rawCode,
  String? rawMessage,
  int status, {
  required ErrorMessage forbidden,
  ErrorMessage notFound = ErrorMessage.sessionNotFound,
  ErrorMessage invalid = ErrorMessage.invalidRequest,
}) {
  switch (rawCode) {
    case 'AGE_CONFLICT':
      return ErrorMessage.ageConflict.text;
    case 'INVALID_EMAIL':
      return ErrorMessage.emailMismatch.text;
    case 'FEATURE_DISABLED':
      return ErrorMessage.featureDisabled.text;
    case 'TOO_MANY_REQUESTS':
      return ErrorMessage.rateLimited.text;
    case 'UNAUTHORIZED':
      return status == 403 ? forbidden.text : ErrorMessage.unauthorizedKey.text;
    case 'INTERNAL_ERROR':
      return ErrorMessage.serverError.text;
    case 'NOT_FOUND':
      return notFound.text;
  }
  if (status == 429) return ErrorMessage.rateLimited.text;
  if (status == 401) return ErrorMessage.unauthorizedKey.text;
  if (status == 403) return forbidden.text;
  if (status >= 500 || status == 0) return ErrorMessage.serverError.text;
  if (rawMessage != null) {
    for (final (test, message) in _invalidInputSubcases) {
      if (test.hasMatch(rawMessage)) return message.text;
    }
  }
  return invalid.text;
}

/// The error a failure the SDK catches before any call carries, such as a submit before a challenge exists.
KidError localKidError([String? message]) => KidError(
      status: 0,
      code: KidErrorCode.invalidRequest,
      message: message ?? ErrorMessage.invalidRequest.text,
    );

/// Anything that is not already a [KidError], such as a dropped connection, becomes a transport error.
KidError toKidError(Object? e) =>
    e is KidError ? e : KidError(status: 0, code: KidErrorCode.unavailable, message: ErrorMessage.serverError.text);
