import 'dart:async';

typedef SetTimer = Object Function(void Function() fn, int ms);
typedef ClearTimer = void Function(Object handle);

Object defaultSetTimer(void Function() fn, int ms) => Timer(Duration(milliseconds: ms), fn);

void defaultClearTimer(Object handle) => (handle as Timer).cancel();

int defaultNow() => DateTime.now().millisecondsSinceEpoch;

int? parseTime(String? iso) => iso == null ? null : DateTime.tryParse(iso)?.millisecondsSinceEpoch;

/// The listeners of a controller's state.
class Listeners {
  final _listeners = <void Function()>{};

  void Function() add(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void emit() {
    for (final l in [..._listeners]) {
      l();
    }
  }
}
