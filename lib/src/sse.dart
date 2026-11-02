/// One server-sent event.
typedef SseEvent = ({String event, String data});

/// A server-sent events parser (the WHATWG event-stream format), fed decoded text as it arrives.
class SseParser {
  SseParser(this._onEvent);

  final void Function(SseEvent event) _onEvent;
  String _buffer = '';
  String _event = '';
  List<String> _data = [];

  /// The server's last `retry:` hint, in ms.
  int? retryMs;

  void push(String chunk) {
    _buffer += chunk;
    var start = 0;
    for (var i = 0; i < _buffer.length; i++) {
      final c = _buffer[i];
      if (c != '\n' && c != '\r') continue;
      // A trailing CR may be the first half of a CRLF split across chunks.
      if (c == '\r' && i == _buffer.length - 1) break;
      _line(_buffer.substring(start, i));
      if (c == '\r' && i + 1 < _buffer.length && _buffer[i + 1] == '\n') i++;
      start = i + 1;
    }
    _buffer = _buffer.substring(start);
  }

  void _line(String text) {
    if (text.isEmpty) {
      if (_data.isNotEmpty) _onEvent((event: _event.isEmpty ? 'message' : _event, data: _data.join('\n')));
      _event = '';
      _data = [];
      return;
    }
    if (text.startsWith(':')) return;
    final colon = text.indexOf(':');
    final field = colon < 0 ? text : text.substring(0, colon);
    var value = colon < 0 ? '' : text.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      _event = value;
    } else if (field == 'data') {
      _data.add(value);
    } else if (field == 'retry' && RegExp(r'^\d+$').hasMatch(value)) {
      retryMs = int.parse(value);
    }
  }
}
