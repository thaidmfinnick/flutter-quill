import '../../../quill_delta.dart';
import '../structs/doc_change.dart';
import '../structs/history_changed.dart';
import 'document.dart';

class History {
  History({
    this.ignoreChange = false,
    this.interval = 500,
    this.maxStack = 100,
    this.userOnly = false,
    this.lastRecorded = 0,
  });

  final HistoryStack stack = HistoryStack.empty();

  bool get hasUndo => stack.undo.isNotEmpty;

  bool get hasRedo => stack.redo.isNotEmpty;

  /// used for disable redo or undo function
  bool ignoreChange;

  int lastRecorded;

  /// Collaborative editing's conditions should be true
  final bool userOnly;

  ///max operation count for undo
  final int maxStack;

  ///record delay
  final int interval;

  void handleDocChange(DocChange docChange) {
    if (ignoreChange) return;
    if (!userOnly || docChange.source == ChangeSource.local) {
      record(docChange.change, docChange.before, docChange.position);
    } else {
      transform(docChange.change, docChange.position);
    }
  }

  void clear() {
    stack.clear();
  }

  void record(Delta change, Delta before, int pos) {
    if (change.isEmpty) return;
    stack.redo.clear();
    var undoDelta = change.invert(before);
    final timeStamp = DateTime.now().millisecondsSinceEpoch;

    if (lastRecorded + interval > timeStamp && stack.undo.isNotEmpty) {
      final lastDelta = stack.undo.removeLast();
      undoDelta = undoDelta.compose(lastDelta.delta);
    } else {
      lastRecorded = timeStamp;
    }

    if (undoDelta.isEmpty) return;
    stack.undo.add(StackDelta(undoDelta, pos));

    if (stack.undo.length > maxStack) {
      stack.undo.removeAt(0);
    }
  }

  ///
  ///It will override pre local undo delta,replaced by remote change
  ///
  void transform(Delta delta, int position) {
    final stackDelta = StackDelta(delta, position);
    transformStack(stack.undo, stackDelta);
    transformStack(stack.redo, stackDelta);
  }

  void transformStack(List<StackDelta> stack, StackDelta stackDelta) {
    for (var i = stack.length - 1; i >= 0; i -= 1) {
      final oldDelta = stack[i].delta;
      stack[i].delta = stackDelta.delta.transform(oldDelta, true);
      stackDelta.delta = oldDelta.transform(stackDelta.delta, false);
      if (stack[i].delta.length == 0) {
        stack.removeAt(i);
      }
    }
  }

  HistoryChanged _change(Document doc, List<StackDelta> source, List<StackDelta> dest, Function(int) func) {
    if (source.isEmpty) {
      return const HistoryChanged(false, 0, 0);
    }
    final stackDelta = source.removeLast();
    final delta = stackDelta.delta;
    // look for insert or delete
    int? len = 0;
    final ops = delta.toList();
    for (var i = 0; i < ops.length; i++) {
      if (ops[i].key == Operation.insertKey) {
        len = ops[i].length;
      } else if (ops[i].key == Operation.deleteKey) {
        len = ops[i].length! * -1;
      }
    }
    final base = Delta.from(doc.toDelta());
    final inverseDelta = delta.invert(base);
    dest.add(StackDelta(inverseDelta, stackDelta.position));
    lastRecorded = 0;
    ignoreChange = true;
    doc.compose(delta, ChangeSource.local, triggerHistory: true, func: func);
    ignoreChange = false;
    return HistoryChanged(true, len, stackDelta.position);
  }

  HistoryChanged undo(Document doc, Function(int) func) {
    return _change(doc, stack.undo, stack.redo, func);
  }

  HistoryChanged redo(Document doc, Function(int) func) {
    return _change(doc, stack.redo, stack.undo, func);
  }
}

class HistoryStack {
  HistoryStack.empty()
      : undo = [],
        redo = [];

  final List<StackDelta> undo;
  final List<StackDelta> redo;

  void clear() {
    undo.clear();
    redo.clear();
  }
}

class StackDelta {
  const StackDelta(
    this.delta,
    this.position
  );

  final Delta delta;
  final int position;

  set delta(newdDelta) {
    delta = newdDelta;
  }
}
