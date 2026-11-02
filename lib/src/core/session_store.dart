import '../models.dart';

/// The latest copy of each session, shared by every controller on one client, so a permission changed through
/// settings reaches the permission gate on the same session.
class SessionStore {
  final _latest = <String, Session>{};
  final _listeners = <void Function(Session session)>{};

  void publish(Session session) {
    if (identical(_latest[session.sessionId], session)) return;
    _latest[session.sessionId] = session;
    for (final l in [..._listeners]) {
      l(session);
    }
  }

  Session? current(String sessionId) => _latest[sessionId];

  void Function() subscribe(void Function(Session session) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}
