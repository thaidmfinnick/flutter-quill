import 'package:flutter/foundation.dart' show immutable;

@immutable
class HistoryChanged {
  const HistoryChanged(
    this.changed,
    this.len,
    this.position
  );

  final bool changed;
  final int? len;
  final int position;
}
