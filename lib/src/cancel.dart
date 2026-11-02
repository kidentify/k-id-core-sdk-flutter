import 'dart:async';

/// Cancels a stream request, like an AbortSignal.
class Cancel {
  final _done = Completer<void>();

  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}
