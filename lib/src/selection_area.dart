import 'dart:async';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

const Set<PointerDeviceKind> _kLongPressSelectionDevices = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

const double _kSelectableVerticalComparingThreshold = 3;

class CustomSelectableRegion extends StatefulWidget {
  const CustomSelectableRegion({
    required this.focusNode, required this.selectionControls, required this.isRightTap, required this.child, required this.onFocusChange, super.key,
    this.contextMenuBuilder,
    this.magnifierConfiguration = TextMagnifierConfiguration.disabled,
    this.onSelectionChanged,
    this.onRightTap
  });

  final TextMagnifierConfiguration magnifierConfiguration;

  final FocusNode focusNode;

  final Widget child;

  final SelectableRegionContextMenuBuilder? contextMenuBuilder;

  final TextSelectionControls selectionControls;

  final bool isRightTap;

  final ValueChanged<SelectedContent?>? onSelectionChanged;

  final Function(bool, CustomSelectableRegionState) onFocusChange;

  final ValueChanged<bool>? onRightTap;

  static List<ContextMenuButtonItem> getSelectableButtonItems({
    required final SelectionGeometry selectionGeometry,
    required final VoidCallback onCopy,
    required final VoidCallback onSelectAll,
    required final VoidCallback? onShare,
  }) {
    final canCopy = selectionGeometry.status == SelectionStatus.uncollapsed;
    final canSelectAll = selectionGeometry.hasContent;
    final platformCanShare = switch (defaultTargetPlatform) {
      TargetPlatform.android => selectionGeometry.status == SelectionStatus.uncollapsed,
      TargetPlatform.macOS ||
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.windows => false,
      TargetPlatform.iOS => false,
    };
    final canShare = onShare != null && platformCanShare;

    final showShareBeforeSelectAll = defaultTargetPlatform == TargetPlatform.android;

    return <ContextMenuButtonItem>[
      if (canCopy) ContextMenuButtonItem(onPressed: onCopy, type: ContextMenuButtonType.copy),
      if (canShare && showShareBeforeSelectAll)
        ContextMenuButtonItem(onPressed: onShare, type: ContextMenuButtonType.share),
      if (canSelectAll)
        ContextMenuButtonItem(onPressed: onSelectAll, type: ContextMenuButtonType.selectAll),
      if (canShare && !showShareBeforeSelectAll)
        ContextMenuButtonItem(onPressed: onShare, type: ContextMenuButtonType.share),
    ];
  }

  @override
  State<StatefulWidget> createState() => CustomSelectableRegionState();
}

class CustomSelectableRegionState extends State<CustomSelectableRegion> with TextSelectionDelegate, WidgetsBindingObserver  implements SelectionRegistrar {
  late final Map<Type, Action<Intent>> _actions = <Type, Action<Intent>>{
    SelectAllTextIntent: _makeOverridable(_SelectAllAction(this)),
    CopySelectionTextIntent: _makeOverridable(_CopySelectionAction(this)),
    ExtendSelectionToNextWordBoundaryOrCaretLocationIntent: _makeOverridable(
      _GranularlyExtendSelectionAction<ExtendSelectionToNextWordBoundaryOrCaretLocationIntent>(
        this,
        granularity: TextGranularity.word,
      ),
    ),
    ExpandSelectionToDocumentBoundaryIntent: _makeOverridable(
      _GranularlyExtendSelectionAction<ExpandSelectionToDocumentBoundaryIntent>(
        this,
        granularity: TextGranularity.document,
      ),
    ),
    ExpandSelectionToLineBreakIntent: _makeOverridable(
      _GranularlyExtendSelectionAction<ExpandSelectionToLineBreakIntent>(
        this,
        granularity: TextGranularity.line,
      ),
    ),
    ExtendSelectionByCharacterIntent: _makeOverridable(
      _GranularlyExtendCaretSelectionAction<ExtendSelectionByCharacterIntent>(
        this,
        granularity: TextGranularity.character,
      ),
    ),
    ExtendSelectionToNextWordBoundaryIntent: _makeOverridable(
      _GranularlyExtendCaretSelectionAction<ExtendSelectionToNextWordBoundaryIntent>(
        this,
        granularity: TextGranularity.word,
      ),
    ),
    ExtendSelectionToLineBreakIntent: _makeOverridable(
      _GranularlyExtendCaretSelectionAction<ExtendSelectionToLineBreakIntent>(
        this,
        granularity: TextGranularity.line,
      ),
    ),
    ExtendSelectionVerticallyToAdjacentLineIntent: _makeOverridable(
      _DirectionallyExtendCaretSelectionAction<ExtendSelectionVerticallyToAdjacentLineIntent>(this),
    ),
    ExtendSelectionToDocumentBoundaryIntent: _makeOverridable(
      _GranularlyExtendCaretSelectionAction<ExtendSelectionToDocumentBoundaryIntent>(
        this,
        granularity: TextGranularity.document,
      ),
    ),
  };

  final Map<Type, GestureRecognizerFactory> _gestureRecognizers =
      <Type, GestureRecognizerFactory>{};
  SelectionOverlay? _selectionOverlay;
  final LayerLink _startHandleLayerLink = LayerLink();
  final LayerLink _endHandleLayerLink = LayerLink();
  final LayerLink _toolbarLayerLink = LayerLink();
  final StaticSelectionContainerDelegate _selectionDelegate = StaticSelectionContainerDelegate();
  // there should only ever be one selectable, which is the SelectionContainer.
  Selectable? _selectable;

  bool get _hasSelectionOverlayGeometry =>
      _selectionDelegate.value.startSelectionPoint != null ||
      _selectionDelegate.value.endSelectionPoint != null;

  Orientation? _lastOrientation;
  SelectedContent? _lastSelectedContent;

  @visibleForTesting
  SelectionOverlay? get selectionOverlay => _selectionOverlay;

  final ProcessTextService _processTextService = DefaultProcessTextService();

  final List<ProcessTextAction> _processTextActions = <ProcessTextAction>[];

  FocusNode get _focusNode => widget.focusNode;

  final _SelectableRegionSelectionStatusNotifier _selectionStatusNotifier =
      _SelectableRegionSelectionStatusNotifier._();

  @protected
  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
    _initMouseGestureRecognizer();
    _initTouchGestureRecognizer();
    WidgetsBinding.instance.addObserver(this);
    _gestureRecognizers[TapGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(debugOwner: this),
          (TapGestureRecognizer instance) {
            instance.onSecondaryTapDown = widget.isRightTap
              ? _handleRightClickDown
              : (v) {
                widget.focusNode.requestFocus();
                final data = _selectable?.getSelectedContent();
                final content = data?.plainText ?? '';
                widget.onRightTap?.call(content.isNotEmpty);
              };
          },
        );
    _initProcessTextActions();
  }

  /// Query the engine to initialize the list of text processing actions to show
  /// in the text selection toolbar.
  Future<void> _initProcessTextActions() async {
    _processTextActions.clear();
    _processTextActions.addAll(await _processTextService.queryTextActions());
  }

  @protected
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        break;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return;
    }

    // Hide the text selection toolbar on mobile when orientation changes.
    final Orientation orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation == null) {
      _lastOrientation = orientation;
      return;
    }
    if (orientation != _lastOrientation) {
      _lastOrientation = orientation;
      hideToolbar(defaultTargetPlatform == TargetPlatform.android);
    }
  }

  @protected
  @override
  void didUpdateWidget(CustomSelectableRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode.addListener(_handleFocusChanged);
      if (_focusNode.hasFocus != oldWidget.focusNode.hasFocus) {
        _handleFocusChanged();
      }
    }
  }

  Action<T> _makeOverridable<T extends Intent>(Action<T> defaultAction) {
    return Action<T>.overridable(context: context, defaultAction: defaultAction);
  }

  void _handleFocusChanged() {
    if (!widget.focusNode.hasFocus && WidgetsBinding.instance.lifecycleState != AppLifecycleState.inactive) {
      clearSelection();
    }
  }

  void _updateSelectionStatus() {
    final SelectionGeometry geometry = _selectionDelegate.value;
    final TextSelection selection = switch (geometry.status) {
      SelectionStatus.uncollapsed ||
      SelectionStatus.collapsed => const TextSelection(baseOffset: 0, extentOffset: 1),
      SelectionStatus.none => const TextSelection.collapsed(offset: 1),
    };
    textEditingValue = TextEditingValue(text: '__', selection: selection);
    if (_hasSelectionOverlayGeometry) {
      _updateSelectionOverlay();
    } else {
      _selectionOverlay?.dispose();
      _selectionOverlay = null;
    }
  }

  bool _isShiftPressed = false;

  Offset? _lastSecondaryTapDownPosition;

  PointerDeviceKind? _lastPointerDeviceKind;

  static bool _isPrecisePointerDevice(PointerDeviceKind pointerDeviceKind) {
    switch (pointerDeviceKind) {
      case PointerDeviceKind.mouse:
        return true;
      case PointerDeviceKind.trackpad:
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.invertedStylus:
      case PointerDeviceKind.touch:
      case PointerDeviceKind.unknown:
        return false;
    }
  }

  void _finalizeSelectableRegionStatus() {
    if (_selectionStatusNotifier.value != SelectableRegionSelectionStatus.changing) {
      return;
    }
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.finalized;
  }

  int _getEffectiveConsecutiveTapCount(int rawCount) {
    int maxConsecutiveTap = 3;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        if (_lastPointerDeviceKind != null && _lastPointerDeviceKind != PointerDeviceKind.mouse) {
          maxConsecutiveTap = 2;
        }

        return rawCount <= maxConsecutiveTap
            ? rawCount
            : (rawCount % maxConsecutiveTap == 0
                ? maxConsecutiveTap
                : rawCount % maxConsecutiveTap);
      case TargetPlatform.linux:
        return rawCount <= maxConsecutiveTap
            ? rawCount
            : (rawCount % maxConsecutiveTap == 0
                ? maxConsecutiveTap
                : rawCount % maxConsecutiveTap);
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return min(rawCount, maxConsecutiveTap);
    }
  }

  void _initMouseGestureRecognizer() {
    _gestureRecognizers[TapAndPanGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<TapAndPanGestureRecognizer>(
          () => TapAndPanGestureRecognizer(
            debugOwner: this,
            supportedDevices: <PointerDeviceKind>{PointerDeviceKind.mouse},
          ),
          (TapAndPanGestureRecognizer instance) {
            instance
              ..onTapTrackStart = _onTapTrackStart
              ..onTapTrackReset = _onTapTrackReset
              ..onTapDown = _startNewMouseSelectionGesture
              ..onTapUp = _handleMouseTapUp
              ..onDragStart = _handleMouseDragStart
              ..onDragUpdate = _handleMouseDragUpdate
              ..onDragEnd = _handleMouseDragEnd
              ..onCancel = clearSelection
              ..dragStartBehavior = DragStartBehavior.down;
          },
        );
  }

  void _onTapTrackStart() {
    _isShiftPressed =
        HardwareKeyboard.instance.logicalKeysPressed.intersection(<LogicalKeyboardKey>{
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight,
        }).isNotEmpty;
  }

  void _onTapTrackReset() {
    _isShiftPressed = false;
  }

  void _initTouchGestureRecognizer() {
    _gestureRecognizers[TapAndHorizontalDragGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<TapAndHorizontalDragGestureRecognizer>(
          () => TapAndHorizontalDragGestureRecognizer(
            debugOwner: this,
            supportedDevices:
                PointerDeviceKind.values.where((PointerDeviceKind device) {
                  return device != PointerDeviceKind.mouse;
                }).toSet(),
          ),
          (TapAndHorizontalDragGestureRecognizer instance) {
            instance
              ..eagerVictoryOnDrag = defaultTargetPlatform != TargetPlatform.iOS
              ..onTapDown = _startNewMouseSelectionGesture
              ..onTapUp = _handleMouseTapUp
              ..onDragStart = _handleMouseDragStart
              ..onDragUpdate = _handleMouseDragUpdate
              ..onDragEnd = _handleMouseDragEnd
              ..onCancel = clearSelection
              ..dragStartBehavior = DragStartBehavior.down;
          },
        );
    _gestureRecognizers[LongPressGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(
            debugOwner: this,
            supportedDevices: _kLongPressSelectionDevices,
          ),
          (LongPressGestureRecognizer instance) {
            instance
              ..onLongPressStart = _handleTouchLongPressStart
              ..onLongPressMoveUpdate = _handleTouchLongPressMoveUpdate
              ..onLongPressEnd = _handleTouchLongPressEnd;
          },
        );
  }

  Offset? _doubleTapOffset;
  void _startNewMouseSelectionGesture(TapDragDownDetails details) {
    _lastPointerDeviceKind = details.kind;
    switch (_getEffectiveConsecutiveTapCount(details.consecutiveTapCount)) {
      case 1:
        _focusNode.requestFocus();
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
          case TargetPlatform.iOS:
            break;
          case TargetPlatform.macOS:
          case TargetPlatform.linux:
          case TargetPlatform.windows:
            hideToolbar();
            final bool isShiftPressedValid =
                _isShiftPressed && _selectionDelegate.value.startSelectionPoint != null;
            if (isShiftPressedValid) {
              _selectEndTo(offset: details.globalPosition);
              _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
              break;
            }
            clearSelection();
            _collapseSelectionAt(offset: details.globalPosition);
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
        }
      case 2:
        switch (defaultTargetPlatform) {
          case TargetPlatform.iOS:
            if (kIsWeb && details.kind != null && !_isPrecisePointerDevice(details.kind!)) {
              // Double tap on iOS web triggers when a drag begins after the double tap.
              _doubleTapOffset = details.globalPosition;
              break;
            }
            _selectWordAt(offset: details.globalPosition);
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
            if (details.kind != null && !_isPrecisePointerDevice(details.kind!)) {
              _showHandles();
            }
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
          case TargetPlatform.macOS:
          case TargetPlatform.linux:
          case TargetPlatform.windows:
            _selectWordAt(offset: details.globalPosition);
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
        }
      case 3:
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
          case TargetPlatform.iOS:
            if (details.kind != null && _isPrecisePointerDevice(details.kind!)) {
              // Triple tap on static text is only supported on mobile
              // platforms using a precise pointer device.
              _selectParagraphAt(offset: details.globalPosition);
              _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
            }
          case TargetPlatform.macOS:
          case TargetPlatform.linux:
          case TargetPlatform.windows:
            _selectParagraphAt(offset: details.globalPosition);
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
        }
    }
    _updateSelectedContentIfNeeded();
  }

  void _handleMouseDragStart(TapDragStartDetails details) {
    switch (_getEffectiveConsecutiveTapCount(details.consecutiveTapCount)) {
      case 1:
        if (details.kind != null && !_isPrecisePointerDevice(details.kind!)) {
          // Drag to select is only enabled with a precise pointer device.
          return;
        }
        _selectStartTo(offset: details.globalPosition);
        _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
    }
    _updateSelectedContentIfNeeded();
  }

  void _handleMouseDragUpdate(TapDragUpdateDetails details) {
    switch (_getEffectiveConsecutiveTapCount(details.consecutiveTapCount)) {
      case 1:
        if (details.kind != null && !_isPrecisePointerDevice(details.kind!)) {
          // Drag to select is only enabled with a precise pointer device.
          return;
        }
        _selectEndTo(offset: details.globalPosition, continuous: true);
        _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
      case 2:
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
            // Double tap + drag is only supported on Android when using a precise
            // pointer device or when not on the web.
            if (!kIsWeb || details.kind != null && _isPrecisePointerDevice(details.kind!)) {
              _selectEndTo(
                offset: details.globalPosition,
                continuous: true,
                textGranularity: TextGranularity.word,
              );
              _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
            }
          case TargetPlatform.iOS:
            if (kIsWeb &&
                details.kind != null &&
                !_isPrecisePointerDevice(details.kind!) &&
                _doubleTapOffset != null) {
              // On iOS web a double tap does not select the word at the position,
              // until the drag has begun.
              _selectWordAt(offset: _doubleTapOffset!);
              _doubleTapOffset = null;
            }
            _selectEndTo(
              offset: details.globalPosition,
              continuous: true,
              textGranularity: TextGranularity.word,
            );
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
            if (details.kind != null && !_isPrecisePointerDevice(details.kind!)) {
              _showHandles();
            }
          case TargetPlatform.macOS:
          case TargetPlatform.linux:
          case TargetPlatform.windows:
            _selectEndTo(
              offset: details.globalPosition,
              continuous: true,
              textGranularity: TextGranularity.word,
            );
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
        }
      case 3:
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
          case TargetPlatform.iOS:
            // Triple tap + drag is only supported on mobile devices when using
            // a precise pointer device.
            if (details.kind != null && _isPrecisePointerDevice(details.kind!)) {
              _selectEndTo(
                offset: details.globalPosition,
                continuous: true,
                textGranularity: TextGranularity.paragraph,
              );
              _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
            }
          case TargetPlatform.macOS:
          case TargetPlatform.linux:
          case TargetPlatform.windows:
            _selectEndTo(
              offset: details.globalPosition,
              continuous: true,
              textGranularity: TextGranularity.paragraph,
            );
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
        }
    }
    _updateSelectedContentIfNeeded();
  }

  void _handleMouseDragEnd(TapDragEndDetails details) {
    assert(_lastPointerDeviceKind != null);
    final bool isPointerPrecise = _isPrecisePointerDevice(_lastPointerDeviceKind!);
    // On mobile platforms like android, fuchsia, and iOS, a drag gesture will
    // only show the selection overlay when the drag has finished and the pointer
    // device kind is not precise, for example at the end of a double tap + drag
    // to select on native iOS.
    final bool shouldShowSelectionOverlayOnMobile = !isPointerPrecise;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        if (shouldShowSelectionOverlayOnMobile) {
          _showHandles();
          _showToolbar();
        }
      case TargetPlatform.iOS:
        if (shouldShowSelectionOverlayOnMobile) {
          _showToolbar();
        }
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        // The selection overlay is not shown on desktop platforms after a drag.
        break;
    }
    _finalizeSelection();
    _updateSelectedContentIfNeeded();
    _finalizeSelectableRegionStatus();
  }

  void _handleMouseTapUp(TapDragUpDetails details) {
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        _positionIsOnActiveSelection(globalPosition: details.globalPosition)) {
      // On iOS when the tap occurs on the previous selection, instead of
      // moving the selection, the context menu will be toggled.
      final bool toolbarIsVisible = _selectionOverlay?.toolbarIsVisible ?? false;
      if (toolbarIsVisible) {
        hideToolbar(false);
      } else {
        _showToolbar();
      }
      return;
    }
    switch (_getEffectiveConsecutiveTapCount(details.consecutiveTapCount)) {
      case 1:
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
          case TargetPlatform.iOS:
            hideToolbar();
            _collapseSelectionAt(offset: details.globalPosition);
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
          case TargetPlatform.macOS:
          case TargetPlatform.linux:
          case TargetPlatform.windows:
          // On desktop platforms the selection is set on tap down.
        }
      case 2:
        final bool isPointerPrecise = _isPrecisePointerDevice(details.kind);
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
            if (!isPointerPrecise) {
              // On Android, a double tap will only show the selection overlay after
              // the following tap up when the pointer device kind is not precise.
              _showHandles();
              _showToolbar();
            }
          case TargetPlatform.iOS:
            if (!isPointerPrecise) {
              if (kIsWeb) {
                // Double tap on iOS web only triggers when a drag begins after the double tap.
                break;
              }
              // On iOS, a double tap will only show the selection toolbar after
              // the following tap up when the pointer device kind is not precise.
              _showToolbar();
            }
          case TargetPlatform.macOS:
          case TargetPlatform.linux:
          case TargetPlatform.windows:
            // The selection overlay is not shown on desktop platforms
            // on a double click.
            break;
        }
    }
    _finalizeSelectableRegionStatus();
    _updateSelectedContentIfNeeded();
  }

  void _updateSelectedContentIfNeeded() {
    if (widget.onSelectionChanged == null) {
      return;
    }
    final SelectedContent? content = _selectable?.getSelectedContent();
    if (_lastSelectedContent?.plainText != content?.plainText) {
      _lastSelectedContent = content;
      widget.onSelectionChanged!.call(_lastSelectedContent);
    }
  }

  void _handleTouchLongPressStart(LongPressStartDetails details) {
    HapticFeedback.selectionClick();
    _focusNode.requestFocus();
    _selectWordAt(offset: details.globalPosition);
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
    // Platforms besides Android will show the text selection handles when
    // the long press is initiated. Android shows the text selection handles when
    // the long press has ended, usually after a pointer up event is received.
    if (defaultTargetPlatform != TargetPlatform.android) {
      _showHandles();
    }
    _updateSelectedContentIfNeeded();
  }

  void _handleTouchLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    _selectEndTo(offset: details.globalPosition, textGranularity: TextGranularity.word);
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
    _updateSelectedContentIfNeeded();
  }

  void _handleTouchLongPressEnd(LongPressEndDetails details) {
    _finalizeSelection();
    _updateSelectedContentIfNeeded();
    _finalizeSelectableRegionStatus();
    _showToolbar();
    if (defaultTargetPlatform == TargetPlatform.android) {
      _showHandles();
    }
  }

  bool _positionIsOnActiveSelection({required Offset globalPosition}) {
    for (final Rect selectionRect in _selectionDelegate.value.selectionRects) {
      final Matrix4 transform = _selectable!.getTransformTo(null);
      final Rect globalRect = MatrixUtils.transformRect(transform, selectionRect);
      if (globalRect.contains(globalPosition)) {
        return true;
      }
    }
    return false;
  }

  void _handleRightClickDown(TapDownDetails details) {
    final Offset? previousSecondaryTapDownPosition = _lastSecondaryTapDownPosition;
    final bool toolbarIsVisible = _selectionOverlay?.toolbarIsVisible ?? false;
    _lastSecondaryTapDownPosition = details.globalPosition;
    _focusNode.requestFocus();
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.windows:
        // If _lastSecondaryTapDownPosition is within the current selection then
        // keep the current selection, if not then collapse it.
        final bool lastSecondaryTapDownPositionWasOnActiveSelection = _positionIsOnActiveSelection(
          globalPosition: details.globalPosition,
        );
        if (lastSecondaryTapDownPositionWasOnActiveSelection) {
          // Restore _lastSecondaryTapDownPosition since it may be cleared if a user
          // accesses contextMenuAnchors.
          _lastSecondaryTapDownPosition = details.globalPosition;
          _showHandles();
          _showToolbar(location: _lastSecondaryTapDownPosition);
          _updateSelectedContentIfNeeded();
          return;
        }
        _collapseSelectionAt(offset: _lastSecondaryTapDownPosition!);
      case TargetPlatform.iOS:
        _selectWordAt(offset: _lastSecondaryTapDownPosition!);
      case TargetPlatform.macOS:
        if (previousSecondaryTapDownPosition == _lastSecondaryTapDownPosition && toolbarIsVisible) {
          hideToolbar();
          return;
        }
        _selectWordAt(offset: _lastSecondaryTapDownPosition!);
      case TargetPlatform.linux:
        if (toolbarIsVisible) {
          hideToolbar();
          return;
        }
        // If _lastSecondaryTapDownPosition is within the current selection then
        // keep the current selection, if not then collapse it.
        final bool lastSecondaryTapDownPositionWasOnActiveSelection = _positionIsOnActiveSelection(
          globalPosition: details.globalPosition,
        );
        if (!lastSecondaryTapDownPositionWasOnActiveSelection) {
          _collapseSelectionAt(offset: _lastSecondaryTapDownPosition!);
        }
    }
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
    _finalizeSelectableRegionStatus();
    // Restore _lastSecondaryTapDownPosition since it may be cleared if a user
    // accesses contextMenuAnchors.
    _lastSecondaryTapDownPosition = details.globalPosition;
    _showHandles();
    _showToolbar(location: _lastSecondaryTapDownPosition);
    _updateSelectedContentIfNeeded();
  }

  Offset? _selectionEndPosition;
  bool get _userDraggingSelectionEnd => _selectionEndPosition != null;
  bool _scheduledSelectionEndEdgeUpdate = false;

  void _triggerSelectionEndEdgeUpdate({TextGranularity? textGranularity}) {
    if (_scheduledSelectionEndEdgeUpdate || !_userDraggingSelectionEnd) {
      return;
    }
    if (_selectable?.dispatchSelectionEvent(
          SelectionEdgeUpdateEvent.forEnd(
            globalPosition: _selectionEndPosition!,
            granularity: textGranularity,
          ),
        ) ==
        SelectionResult.pending) {
      _scheduledSelectionEndEdgeUpdate = true;
      SchedulerBinding.instance.addPostFrameCallback((Duration timeStamp) {
        if (!_scheduledSelectionEndEdgeUpdate) {
          return;
        }
        _scheduledSelectionEndEdgeUpdate = false;
        _triggerSelectionEndEdgeUpdate(textGranularity: textGranularity);
      }, debugLabel: 'SelectableRegion.endEdgeUpdate');
      return;
    }
  }

  void _onAnyDragEnd(DragEndDetails details) {
    if (widget.selectionControls is! TextSelectionHandleControls) {
      _selectionOverlay!.hideMagnifier();
      _selectionOverlay!.showToolbar();
    } else {
      _selectionOverlay!.hideMagnifier();
      _selectionOverlay!.showToolbar(
        context: context,
        contextMenuBuilder: (BuildContext context) {
          return widget.contextMenuBuilder!(context, this);
        },
      );
    }
    _finalizeSelection();
    _updateSelectedContentIfNeeded();
    _finalizeSelectableRegionStatus();
  }

  void _stopSelectionEndEdgeUpdate() {
    _scheduledSelectionEndEdgeUpdate = false;
    _selectionEndPosition = null;
  }

  Offset? _selectionStartPosition;
  bool get _userDraggingSelectionStart => _selectionStartPosition != null;
  bool _scheduledSelectionStartEdgeUpdate = false;

  void _triggerSelectionStartEdgeUpdate({TextGranularity? textGranularity}) {
    if (_scheduledSelectionStartEdgeUpdate || !_userDraggingSelectionStart) {
      return;
    }
    if (_selectable?.dispatchSelectionEvent(
          SelectionEdgeUpdateEvent.forStart(
            globalPosition: _selectionStartPosition!,
            granularity: textGranularity,
          ),
        ) ==
        SelectionResult.pending) {
      _scheduledSelectionStartEdgeUpdate = true;
      SchedulerBinding.instance.addPostFrameCallback((Duration timeStamp) {
        if (!_scheduledSelectionStartEdgeUpdate) {
          return;
        }
        _scheduledSelectionStartEdgeUpdate = false;
        _triggerSelectionStartEdgeUpdate(textGranularity: textGranularity);
      }, debugLabel: 'SelectableRegion.startEdgeUpdate');
      return;
    }
  }

  void _stopSelectionStartEdgeUpdate() {
    _scheduledSelectionStartEdgeUpdate = false;
    _selectionEndPosition = null;
  }

  late Offset _selectionStartHandleDragPosition;
  late Offset _selectionEndHandleDragPosition;

  void _handleSelectionStartHandleDragStart(DragStartDetails details) {
    assert(_selectionDelegate.value.startSelectionPoint != null);

    final Offset localPosition = _selectionDelegate.value.startSelectionPoint!.localPosition;
    final Matrix4 globalTransform = _selectable!.getTransformTo(null);
    _selectionStartHandleDragPosition = MatrixUtils.transformPoint(globalTransform, localPosition);

    _selectionOverlay!.showMagnifier(
      _buildInfoForMagnifier(details.globalPosition, _selectionDelegate.value.startSelectionPoint!),
    );
    _updateSelectedContentIfNeeded();
  }

  void _handleSelectionStartHandleDragUpdate(DragUpdateDetails details) {
    _selectionStartHandleDragPosition = _selectionStartHandleDragPosition + details.delta;
    _selectionStartPosition =
        _selectionStartHandleDragPosition -
        Offset(0, _selectionDelegate.value.startSelectionPoint!.lineHeight / 2);
    _triggerSelectionStartEdgeUpdate();

    _selectionOverlay!.updateMagnifier(
      _buildInfoForMagnifier(details.globalPosition, _selectionDelegate.value.startSelectionPoint!),
    );
    _updateSelectedContentIfNeeded();
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
  }

  void _handleSelectionEndHandleDragStart(DragStartDetails details) {
    assert(_selectionDelegate.value.endSelectionPoint != null);
    final Offset localPosition = _selectionDelegate.value.endSelectionPoint!.localPosition;
    final Matrix4 globalTransform = _selectable!.getTransformTo(null);
    _selectionEndHandleDragPosition = MatrixUtils.transformPoint(globalTransform, localPosition);

    _selectionOverlay!.showMagnifier(
      _buildInfoForMagnifier(details.globalPosition, _selectionDelegate.value.endSelectionPoint!),
    );
    _updateSelectedContentIfNeeded();
  }

  void _handleSelectionEndHandleDragUpdate(DragUpdateDetails details) {
    _selectionEndHandleDragPosition = _selectionEndHandleDragPosition + details.delta;
    _selectionEndPosition =
        _selectionEndHandleDragPosition -
        Offset(0, _selectionDelegate.value.endSelectionPoint!.lineHeight / 2);
    _triggerSelectionEndEdgeUpdate();

    _selectionOverlay!.updateMagnifier(
      _buildInfoForMagnifier(details.globalPosition, _selectionDelegate.value.endSelectionPoint!),
    );
    _updateSelectedContentIfNeeded();
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
  }

  MagnifierInfo _buildInfoForMagnifier(
    Offset globalGesturePosition,
    SelectionPoint selectionPoint,
  ) {
    final Vector3 globalTransform = _selectable!.getTransformTo(null).getTranslation();
    final Offset globalTransformAsOffset = Offset(globalTransform.x, globalTransform.y);
    final Offset globalSelectionPointPosition =
        selectionPoint.localPosition + globalTransformAsOffset;
    final Rect caretRect = Rect.fromLTWH(
      globalSelectionPointPosition.dx,
      globalSelectionPointPosition.dy - selectionPoint.lineHeight,
      0,
      selectionPoint.lineHeight,
    );

    return MagnifierInfo(
      globalGesturePosition: globalGesturePosition,
      caretRect: caretRect,
      fieldBounds: globalTransformAsOffset & _selectable!.size,
      currentLineBoundaries: globalTransformAsOffset & _selectable!.size,
    );
  }

  void _createSelectionOverlay() {
    assert(_hasSelectionOverlayGeometry);
    if (_selectionOverlay != null) {
      return;
    }
    final SelectionPoint? start = _selectionDelegate.value.startSelectionPoint;
    final SelectionPoint? end = _selectionDelegate.value.endSelectionPoint;
    _selectionOverlay = SelectionOverlay(
      context: context,
      debugRequiredFor: widget,
      startHandleType: start?.handleType ?? TextSelectionHandleType.collapsed,
      lineHeightAtStart: start?.lineHeight ?? end!.lineHeight,
      onStartHandleDragStart: _handleSelectionStartHandleDragStart,
      onStartHandleDragUpdate: _handleSelectionStartHandleDragUpdate,
      onStartHandleDragEnd: _onAnyDragEnd,
      endHandleType: end?.handleType ?? TextSelectionHandleType.collapsed,
      lineHeightAtEnd: end?.lineHeight ?? start!.lineHeight,
      onEndHandleDragStart: _handleSelectionEndHandleDragStart,
      onEndHandleDragUpdate: _handleSelectionEndHandleDragUpdate,
      onEndHandleDragEnd: _onAnyDragEnd,
      selectionEndpoints: selectionEndpoints,
      selectionControls: widget.selectionControls,
      selectionDelegate: this,
      clipboardStatus: null,
      startHandleLayerLink: _startHandleLayerLink,
      endHandleLayerLink: _endHandleLayerLink,
      toolbarLayerLink: _toolbarLayerLink,
      magnifierConfiguration: widget.magnifierConfiguration,
    );
  }

  void _updateSelectionOverlay() {
    if (_selectionOverlay == null) {
      return;
    }
    assert(_hasSelectionOverlayGeometry);
    final SelectionPoint? start = _selectionDelegate.value.startSelectionPoint;
    final SelectionPoint? end = _selectionDelegate.value.endSelectionPoint;
    _selectionOverlay!
      ..startHandleType = start?.handleType ?? TextSelectionHandleType.left
      ..lineHeightAtStart = start?.lineHeight ?? end!.lineHeight
      ..endHandleType = end?.handleType ?? TextSelectionHandleType.right
      ..lineHeightAtEnd = end?.lineHeight ?? start!.lineHeight
      ..selectionEndpoints = selectionEndpoints;
  }

  /// Shows the selection handles.
  ///
  /// Returns true if the handles are shown, false if the handles can't be
  /// shown.
  bool _showHandles() {
    if (_selectionOverlay != null) {
      _selectionOverlay!.showHandles();
      return true;
    }

    if (!_hasSelectionOverlayGeometry) {
      return false;
    }

    _createSelectionOverlay();
    _selectionOverlay!.showHandles();
    return true;
  }

  bool _showToolbar({Offset? location}) {
    if (!_hasSelectionOverlayGeometry && _selectionOverlay == null) {
      return false;
    }

    if (kIsWeb && BrowserContextMenu.enabled) {
      return false;
    }

    if (_selectionOverlay == null) {
      _createSelectionOverlay();
    }

    _selectionOverlay!.toolbarLocation = location;
    if (widget.selectionControls is! TextSelectionHandleControls) {
      _selectionOverlay!.showToolbar();
      return true;
    }

    _selectionOverlay!.hideToolbar();

    _selectionOverlay!.showToolbar(
      context: context,
      contextMenuBuilder: (BuildContext context) {
        return widget.contextMenuBuilder!(context, this);
      },
    );
    return true;
  }

  void _selectEndTo({
    required Offset offset,
    bool continuous = false,
    TextGranularity? textGranularity,
  }) {
    if (!continuous) {
      _selectable?.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forEnd(globalPosition: offset, granularity: textGranularity),
      );
      return;
    }
    if (_selectionEndPosition != offset) {
      _selectionEndPosition = offset;
      _triggerSelectionEndEdgeUpdate(textGranularity: textGranularity);
    }
  }

  void _selectStartTo({
    required Offset offset,
    bool continuous = false,
    TextGranularity? textGranularity,
  }) {
    if (!continuous) {
      _selectable?.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forStart(globalPosition: offset, granularity: textGranularity),
      );
      return;
    }
    if (_selectionStartPosition != offset) {
      _selectionStartPosition = offset;
      _triggerSelectionStartEdgeUpdate(textGranularity: textGranularity);
    }
  }

  void _collapseSelectionAt({required Offset offset}) {
    _finalizeSelection();
    _selectStartTo(offset: offset);
    _selectEndTo(offset: offset);
  }

  void _selectWordAt({required Offset offset}) {
    _finalizeSelection();
    _selectable?.dispatchSelectionEvent(SelectWordSelectionEvent(globalPosition: offset));
  }

  void _selectParagraphAt({required Offset offset}) {
    _finalizeSelection();
    _selectable?.dispatchSelectionEvent(SelectParagraphSelectionEvent(globalPosition: offset));
  }

  void _finalizeSelection() {
    _stopSelectionEndEdgeUpdate();
    _stopSelectionStartEdgeUpdate();
  }

  void clearSelection() {
    _finalizeSelection();
    _directionalHorizontalBaseline = null;
    _adjustingSelectionEnd = null;
    _selectable?.dispatchSelectionEvent(const ClearSelectionEvent());
    _updateSelectedContentIfNeeded();
  }

  Future<void> _copy() async {
    final SelectedContent? data = _selectable?.getSelectedContent();
    if (data == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: data.plainText));
  }

  Future<void> _share() async {
    final SelectedContent? data = _selectable?.getSelectedContent();
    if (data == null) {
      return;
    }
    await SystemChannels.platform.invokeMethod('Share.invoke', data.plainText);
  }

  TextSelectionToolbarAnchors get contextMenuAnchors {
    if (_lastSecondaryTapDownPosition != null) {
      final TextSelectionToolbarAnchors anchors = TextSelectionToolbarAnchors(
        primaryAnchor: _lastSecondaryTapDownPosition!,
      );
      _lastSecondaryTapDownPosition = null;
      return anchors;
    }
    final RenderBox renderBox = context.findRenderObject()! as RenderBox;
    return TextSelectionToolbarAnchors.fromSelection(
      renderBox: renderBox,
      startGlyphHeight: startGlyphHeight,
      endGlyphHeight: endGlyphHeight,
      selectionEndpoints: selectionEndpoints,
    );
  }

  bool? _adjustingSelectionEnd;
  bool _determineIsAdjustingSelectionEnd(bool forward) {
    if (_adjustingSelectionEnd != null) {
      return _adjustingSelectionEnd!;
    }
    final bool isReversed;
    final SelectionPoint start = _selectionDelegate.value.startSelectionPoint!;
    final SelectionPoint end = _selectionDelegate.value.endSelectionPoint!;
    if (start.localPosition.dy > end.localPosition.dy) {
      isReversed = true;
    } else if (start.localPosition.dy < end.localPosition.dy) {
      isReversed = false;
    } else {
      isReversed = start.localPosition.dx > end.localPosition.dx;
    }
    // Always move the selection edge that increases the selection range.
    return _adjustingSelectionEnd = forward != isReversed;
  }

  void _granularlyExtendSelection(TextGranularity granularity, bool forward) {
    _directionalHorizontalBaseline = null;
    if (!_selectionDelegate.value.hasSelection) {
      return;
    }
    _selectable?.dispatchSelectionEvent(
      GranularlyExtendSelectionEvent(
        forward: forward,
        isEnd: _determineIsAdjustingSelectionEnd(forward),
        granularity: granularity,
      ),
    );
    _updateSelectedContentIfNeeded();
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
    _finalizeSelectableRegionStatus();
  }

  double? _directionalHorizontalBaseline;

  void _directionallyExtendSelection(bool forward) {
    if (!_selectionDelegate.value.hasSelection) {
      return;
    }
    final bool adjustingSelectionExtend = _determineIsAdjustingSelectionEnd(forward);
    final SelectionPoint baseLinePoint =
        adjustingSelectionExtend
            ? _selectionDelegate.value.endSelectionPoint!
            : _selectionDelegate.value.startSelectionPoint!;
    _directionalHorizontalBaseline ??= baseLinePoint.localPosition.dx;
    final Offset globalSelectionPointOffset = MatrixUtils.transformPoint(
      context.findRenderObject()!.getTransformTo(null),
      Offset(_directionalHorizontalBaseline!, 0),
    );
    _selectable?.dispatchSelectionEvent(
      DirectionallyExtendSelectionEvent(
        isEnd: _adjustingSelectionEnd!,
        direction:
            forward ? SelectionExtendDirection.nextLine : SelectionExtendDirection.previousLine,
        dx: globalSelectionPointOffset.dx,
      ),
    );
    _updateSelectedContentIfNeeded();
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
    _finalizeSelectableRegionStatus();
  }

  List<ContextMenuButtonItem> get contextMenuButtonItems {
    return SelectableRegion.getSelectableButtonItems(
      selectionGeometry: _selectionDelegate.value,
      onCopy: () {
        _copy();

        // On Android copy should clear the selection.
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
            clearSelection();
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
            _finalizeSelectableRegionStatus();
          case TargetPlatform.iOS:
            hideToolbar(false);
          case TargetPlatform.linux:
          case TargetPlatform.macOS:
          case TargetPlatform.windows:
            hideToolbar();
        }
      },
      onSelectAll: () {
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
          case TargetPlatform.iOS:
          case TargetPlatform.fuchsia:
            selectAll(SelectionChangedCause.toolbar);
          case TargetPlatform.linux:
          case TargetPlatform.macOS:
          case TargetPlatform.windows:
            selectAll();
            hideToolbar();
        }
      },
      onShare: () {
        _share();

        // On Android, share should clear the selection.
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
            clearSelection();
            _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
            _finalizeSelectableRegionStatus();
          case TargetPlatform.iOS:
            hideToolbar(false);
          case TargetPlatform.linux:
          case TargetPlatform.macOS:
          case TargetPlatform.windows:
            hideToolbar();
        }
      },
    )..addAll(_textProcessingActionButtonItems);
  }

  List<ContextMenuButtonItem> get _textProcessingActionButtonItems {
    final List<ContextMenuButtonItem> buttonItems = <ContextMenuButtonItem>[];
    final SelectedContent? data = _selectable?.getSelectedContent();
    if (data == null) {
      return buttonItems;
    }

    for (final ProcessTextAction action in _processTextActions) {
      buttonItems.add(
        ContextMenuButtonItem(
          label: action.label,
          onPressed: () async {
            final String selectedText = data.plainText;
            if (selectedText.isNotEmpty) {
              await _processTextService.processTextAction(action.id, selectedText, true);
              hideToolbar();
            }
          },
        ),
      );
    }
    return buttonItems;
  }

  /// The line height at the start of the current selection.
  double get startGlyphHeight {
    return _selectionDelegate.value.startSelectionPoint!.lineHeight;
  }

  /// The line height at the end of the current selection.
  double get endGlyphHeight {
    return _selectionDelegate.value.endSelectionPoint!.lineHeight;
  }

  /// Returns the local coordinates of the endpoints of the current selection.
  List<TextSelectionPoint> get selectionEndpoints {
    final SelectionPoint? start = _selectionDelegate.value.startSelectionPoint;
    final SelectionPoint? end = _selectionDelegate.value.endSelectionPoint;
    late List<TextSelectionPoint> points;
    final Offset startLocalPosition = start?.localPosition ?? end!.localPosition;
    final Offset endLocalPosition = end?.localPosition ?? start!.localPosition;
    if (startLocalPosition.dy > endLocalPosition.dy) {
      points = <TextSelectionPoint>[
        TextSelectionPoint(endLocalPosition, TextDirection.ltr),
        TextSelectionPoint(startLocalPosition, TextDirection.ltr),
      ];
    } else {
      points = <TextSelectionPoint>[
        TextSelectionPoint(startLocalPosition, TextDirection.ltr),
        TextSelectionPoint(endLocalPosition, TextDirection.ltr),
      ];
    }
    return points;
  }

  @Deprecated(
    'Use `contextMenuBuilder` instead. '
    'This feature was deprecated after v3.3.0-0.5.pre.',
  )
  @override
  bool get cutEnabled => false;

  @Deprecated(
    'Use `contextMenuBuilder` instead. '
    'This feature was deprecated after v3.3.0-0.5.pre.',
  )
  @override
  bool get pasteEnabled => false;

  @override
  void hideToolbar([bool hideHandles = true]) {
    _selectionOverlay?.hideToolbar();
    if (hideHandles) {
      _selectionOverlay?.hideHandles();
    }
  }

  @override
  void selectAll([SelectionChangedCause? cause]) {
    clearSelection();
    _selectable?.dispatchSelectionEvent(const SelectAllSelectionEvent());
    if (cause == SelectionChangedCause.toolbar) {
      _showToolbar();
      _showHandles();
    }
    _updateSelectedContentIfNeeded();
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
    _finalizeSelectableRegionStatus();
  }

  @Deprecated(
    'Use `contextMenuBuilder` instead. '
    'This feature was deprecated after v3.3.0-0.5.pre.',
  )
  @override
  void copySelection(SelectionChangedCause cause) {
    _copy();
    clearSelection();
    _selectionStatusNotifier.value = SelectableRegionSelectionStatus.changing;
    _finalizeSelectableRegionStatus();
  }

  @Deprecated(
    'Use `contextMenuBuilder` instead. '
    'This feature was deprecated after v3.3.0-0.5.pre.',
  )
  @override
  TextEditingValue textEditingValue = const TextEditingValue(text: '_');

  @Deprecated(
    'Use `contextMenuBuilder` instead. '
    'This feature was deprecated after v3.3.0-0.5.pre.',
  )
  @override
  void bringIntoView(TextPosition position) {
    /* SelectableRegion must be in view at this point. */
  }

  @Deprecated(
    'Use `contextMenuBuilder` instead. '
    'This feature was deprecated after v3.3.0-0.5.pre.',
  )
  @override
  void cutSelection(SelectionChangedCause cause) {
    assert(false);
  }

  @Deprecated(
    'Use `contextMenuBuilder` instead. '
    'This feature was deprecated after v3.3.0-0.5.pre.',
  )
  @override
  void userUpdateTextEditingValue(TextEditingValue value, SelectionChangedCause cause) {
    /* SelectableRegion maintains its own state */
  }

  @Deprecated(
    'Use `contextMenuBuilder` instead. '
    'This feature was deprecated after v3.3.0-0.5.pre.',
  )
  @override
  Future<void> pasteText(SelectionChangedCause cause) async {
    assert(false);
  }


  @override
  void add(Selectable selectable) {
    assert(_selectable == null);
    _selectable = selectable;
    _selectable!.addListener(_updateSelectionStatus);
    _selectable!.pushHandleLayers(_startHandleLayerLink, _endHandleLayerLink);
  }

  @override
  void remove(Selectable selectable) {
    assert(_selectable == selectable);
    _selectable!.removeListener(_updateSelectionStatus);
    _selectable!.pushHandleLayers(null, null);
    _selectable = null;
  }

  @protected
  @override
  void dispose() {
    _selectable?.removeListener(_updateSelectionStatus);
    _selectable?.pushHandleLayers(null, null);
    WidgetsBinding.instance.removeObserver(this);
    _selectionDelegate.dispose();
    _selectionStatusNotifier.dispose();
    _selectionOverlay?.hideMagnifier();
    _selectionOverlay?.dispose();
    _selectionOverlay = null;
    widget.focusNode.removeListener(_handleFocusChanged);
    super.dispose();
  }

  @protected
  @override
  Widget build(BuildContext context) {
    assert(debugCheckHasOverlay(context));
    Widget result = SelectableRegionSelectionStatusScope._(
      selectionStatusNotifier: _selectionStatusNotifier,
      child: SelectionContainer(registrar: this, delegate: _selectionDelegate, child: widget.child),
    );
    if (kIsWeb) {
      result = PlatformSelectableRegionContextMenu(child: result);
    }
    return CompositedTransformTarget(
      link: _toolbarLayerLink,
      child: RawGestureDetector(
        gestures: _gestureRecognizers,
        behavior: HitTestBehavior.translucent,
        excludeFromSemantics: true,
        child: Actions(
          actions: _actions,
          child: Focus.withExternalFocusNode(
            includeSemantics: false,
            focusNode: _focusNode,
            onFocusChange: (value) {
              widget.onFocusChange(value, this);
            },
            child: result,
          ),
        ),
      ),
    );
  }
}

abstract class _NonOverrideAction<T extends Intent> extends ContextAction<T> {
  Object? invokeAction(T intent, [BuildContext? context]);

  @override
  Object? invoke(T intent, [BuildContext? context]) {
    if (callingAction != null) {
      return callingAction!.invoke(intent);
    }
    return invokeAction(intent, context);
  }
}

class _SelectAllAction extends _NonOverrideAction<SelectAllTextIntent> {
  _SelectAllAction(this.state);

  final CustomSelectableRegionState state;

  @override
  void invokeAction(SelectAllTextIntent intent, [BuildContext? context]) {
    state.selectAll(SelectionChangedCause.keyboard);
  }
}

class _CopySelectionAction extends _NonOverrideAction<CopySelectionTextIntent> {
  _CopySelectionAction(this.state);

  final CustomSelectableRegionState state;

  @override
  void invokeAction(CopySelectionTextIntent intent, [BuildContext? context]) {
    state._copy();
  }
}

class _GranularlyExtendSelectionAction<T extends DirectionalTextEditingIntent>
    extends _NonOverrideAction<T> {
  _GranularlyExtendSelectionAction(this.state, {required this.granularity});

  final CustomSelectableRegionState state;
  final TextGranularity granularity;

  @override
  void invokeAction(T intent, [BuildContext? context]) {
    state._granularlyExtendSelection(granularity, intent.forward);
  }
}

class _GranularlyExtendCaretSelectionAction<T extends DirectionalCaretMovementIntent>
    extends _NonOverrideAction<T> {
  _GranularlyExtendCaretSelectionAction(this.state, {required this.granularity});

  final CustomSelectableRegionState state;
  final TextGranularity granularity;

  @override
  void invokeAction(T intent, [BuildContext? context]) {
    if (intent.collapseSelection) {
      // Selectable region never collapses selection.
      return;
    }
    state._granularlyExtendSelection(granularity, intent.forward);
  }
}

class _DirectionallyExtendCaretSelectionAction<T extends DirectionalCaretMovementIntent>
    extends _NonOverrideAction<T> {
  _DirectionallyExtendCaretSelectionAction(this.state);

  final CustomSelectableRegionState state;

  @override
  void invokeAction(T intent, [BuildContext? context]) {
    if (intent.collapseSelection) {
      // Selectable region never collapses selection.
      return;
    }
    state._directionallyExtendSelection(intent.forward);
  }
}

class StaticSelectionContainerDelegate extends MultiSelectableSelectionContainerDelegate {
  final Set<Selectable> _hasReceivedStartEvent = <Selectable>{};

  final Set<Selectable> _hasReceivedEndEvent = <Selectable>{};

  Offset? _lastStartEdgeUpdateGlobalPosition;

  Offset? _lastEndEdgeUpdateGlobalPosition;

  @protected
  void didReceiveSelectionEventFor({required Selectable selectable, bool? forEnd}) {
    switch (forEnd) {
      case true:
        _hasReceivedEndEvent.add(selectable);
      case false:
        _hasReceivedStartEvent.add(selectable);
      case null:
        _hasReceivedStartEvent.add(selectable);
        _hasReceivedEndEvent.add(selectable);
    }
  }

  @protected
  void didReceiveSelectionBoundaryEvents() {
    if (currentSelectionStartIndex == -1 || currentSelectionEndIndex == -1) {
      return;
    }
    final int start = min(currentSelectionStartIndex, currentSelectionEndIndex);
    final int end = max(currentSelectionStartIndex, currentSelectionEndIndex);
    for (int index = start; index <= end; index += 1) {
      didReceiveSelectionEventFor(selectable: selectables[index]);
    }
    _updateLastSelectionEdgeLocationsFromGeometries();
  }

  @protected
  void updateLastSelectionEdgeLocation({
    required Offset globalSelectionEdgeLocation,
    required bool forEnd,
  }) {
    if (forEnd) {
      _lastEndEdgeUpdateGlobalPosition = globalSelectionEdgeLocation;
    } else {
      _lastStartEdgeUpdateGlobalPosition = globalSelectionEdgeLocation;
    }
  }

  void _updateLastSelectionEdgeLocationsFromGeometries() {
    if (currentSelectionStartIndex != -1 &&
        selectables[currentSelectionStartIndex].value.hasSelection) {
      final Selectable start = selectables[currentSelectionStartIndex];
      final Offset localStartEdge =
          start.value.startSelectionPoint!.localPosition +
          Offset(0, -start.value.startSelectionPoint!.lineHeight / 2);
      updateLastSelectionEdgeLocation(
        globalSelectionEdgeLocation: MatrixUtils.transformPoint(
          start.getTransformTo(null),
          localStartEdge,
        ),
        forEnd: false,
      );
    }
    if (currentSelectionEndIndex != -1 &&
        selectables[currentSelectionEndIndex].value.hasSelection) {
      final Selectable end = selectables[currentSelectionEndIndex];
      final Offset localEndEdge =
          end.value.endSelectionPoint!.localPosition +
          Offset(0, -end.value.endSelectionPoint!.lineHeight / 2);
      updateLastSelectionEdgeLocation(
        globalSelectionEdgeLocation: MatrixUtils.transformPoint(
          end.getTransformTo(null),
          localEndEdge,
        ),
        forEnd: true,
      );
    }
  }

  @protected
  void clearInternalSelectionState() {
    selectables.forEach(clearInternalSelectionStateForSelectable);
    _lastStartEdgeUpdateGlobalPosition = null;
    _lastEndEdgeUpdateGlobalPosition = null;
  }

  @protected
  void clearInternalSelectionStateForSelectable(Selectable selectable) {
    _hasReceivedStartEvent.remove(selectable);
    _hasReceivedEndEvent.remove(selectable);
  }

  @override
  void remove(Selectable selectable) {
    clearInternalSelectionStateForSelectable(selectable);
    super.remove(selectable);
  }

  @override
  SelectionResult handleSelectAll(SelectAllSelectionEvent event) {
    final SelectionResult result = super.handleSelectAll(event);
    didReceiveSelectionBoundaryEvents();
    return result;
  }

  @override
  SelectionResult handleSelectWord(SelectWordSelectionEvent event) {
    final SelectionResult result = super.handleSelectWord(event);
    didReceiveSelectionBoundaryEvents();
    return result;
  }

  @override
  SelectionResult handleSelectParagraph(SelectParagraphSelectionEvent event) {
    final SelectionResult result = super.handleSelectParagraph(event);
    didReceiveSelectionBoundaryEvents();
    return result;
  }

  @override
  SelectionResult handleClearSelection(ClearSelectionEvent event) {
    final SelectionResult result = super.handleClearSelection(event);
    clearInternalSelectionState();
    return result;
  }

  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    updateLastSelectionEdgeLocation(
      globalSelectionEdgeLocation: event.globalPosition,
      forEnd: event.type == SelectionEventType.endEdgeUpdate,
    );
    return super.handleSelectionEdgeUpdate(event);
  }

  @override
  void dispose() {
    clearInternalSelectionState();
    super.dispose();
  }

  @override
  SelectionResult dispatchSelectionEventToChild(Selectable selectable, SelectionEvent event) {
    switch (event.type) {
      case SelectionEventType.startEdgeUpdate:
        didReceiveSelectionEventFor(selectable: selectable, forEnd: false);
        ensureChildUpdated(selectable);
      case SelectionEventType.endEdgeUpdate:
        didReceiveSelectionEventFor(selectable: selectable, forEnd: true);
        ensureChildUpdated(selectable);
      case SelectionEventType.clear:
        clearInternalSelectionStateForSelectable(selectable);
      case SelectionEventType.selectAll:
      case SelectionEventType.selectWord:
      case SelectionEventType.selectParagraph:
        break;
      case SelectionEventType.granularlyExtendSelection:
      case SelectionEventType.directionallyExtendSelection:
        didReceiveSelectionEventFor(selectable: selectable);
        ensureChildUpdated(selectable);
    }
    return super.dispatchSelectionEventToChild(selectable, event);
  }

  @override
  void ensureChildUpdated(Selectable selectable) {
    if (_lastEndEdgeUpdateGlobalPosition != null && _hasReceivedEndEvent.add(selectable)) {
      final SelectionEdgeUpdateEvent synthesizedEvent = SelectionEdgeUpdateEvent.forEnd(
        globalPosition: _lastEndEdgeUpdateGlobalPosition!,
      );
      if (currentSelectionEndIndex == -1) {
        handleSelectionEdgeUpdate(synthesizedEvent);
      }
      selectable.dispatchSelectionEvent(synthesizedEvent);
    }
    if (_lastStartEdgeUpdateGlobalPosition != null && _hasReceivedStartEvent.add(selectable)) {
      final SelectionEdgeUpdateEvent synthesizedEvent = SelectionEdgeUpdateEvent.forStart(
        globalPosition: _lastStartEdgeUpdateGlobalPosition!,
      );
      if (currentSelectionStartIndex == -1) {
        handleSelectionEdgeUpdate(synthesizedEvent);
      }
      selectable.dispatchSelectionEvent(synthesizedEvent);
    }
  }

  @override
  void didChangeSelectables() {
    if (_lastEndEdgeUpdateGlobalPosition != null) {
      handleSelectionEdgeUpdate(
        SelectionEdgeUpdateEvent.forEnd(globalPosition: _lastEndEdgeUpdateGlobalPosition!),
      );
    }
    if (_lastStartEdgeUpdateGlobalPosition != null) {
      handleSelectionEdgeUpdate(
        SelectionEdgeUpdateEvent.forStart(globalPosition: _lastStartEdgeUpdateGlobalPosition!),
      );
    }
    final Set<Selectable> selectableSet = selectables.toSet();
    _hasReceivedEndEvent.removeWhere(
      (Selectable selectable) => !selectableSet.contains(selectable),
    );
    _hasReceivedStartEvent.removeWhere(
      (Selectable selectable) => !selectableSet.contains(selectable),
    );
    super.didChangeSelectables();
  }
}

abstract class MultiSelectableSelectionContainerDelegate extends SelectionContainerDelegate
    with ChangeNotifier {
  MultiSelectableSelectionContainerDelegate() {
    if (kFlutterMemoryAllocationsEnabled) {
      ChangeNotifier.maybeDispatchObjectCreation(this);
    }
  }

  List<Selectable> selectables = <Selectable>[];

  static const double _kSelectionHandleDrawableAreaPadding = 5.0;

  @protected
  int currentSelectionEndIndex = -1;

  @protected
  int currentSelectionStartIndex = -1;

  LayerLink? _startHandleLayer;
  Selectable? _startHandleLayerOwner;
  LayerLink? _endHandleLayer;
  Selectable? _endHandleLayerOwner;

  bool _isHandlingSelectionEvent = false;
  bool _scheduledSelectableUpdate = false;
  bool _selectionInProgress = false;
  Set<Selectable> _additions = <Selectable>{};

  bool _extendSelectionInProgress = false;

  @override
  void add(Selectable selectable) {
    assert(!selectables.contains(selectable));
    _additions.add(selectable);
    _scheduleSelectableUpdate();
  }

  @override
  void remove(Selectable selectable) {
    if (_additions.remove(selectable)) {
      return;
    }
    _removeSelectable(selectable);
    _scheduleSelectableUpdate();
  }

  void layoutDidChange() {
    _updateSelectionGeometry();
  }

  void _scheduleSelectableUpdate() {
    if (!_scheduledSelectableUpdate) {
      _scheduledSelectableUpdate = true;
      void runScheduledTask([Duration? duration]) {
        if (!_scheduledSelectableUpdate) {
          return;
        }
        _scheduledSelectableUpdate = false;
        _updateSelectables();
      }

      if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.postFrameCallbacks) {
        scheduleMicrotask(runScheduledTask);
      } else {
        SchedulerBinding.instance.addPostFrameCallback(
          runScheduledTask,
          debugLabel: 'SelectionContainer.runScheduledTask',
        );
      }
    }
  }

  void _updateSelectables() {
    if (_additions.isNotEmpty) {
      _flushAdditions();
    }
    didChangeSelectables();
  }

  void _flushAdditions() {
    final List<Selectable> mergingSelectables = _additions.toList()..sort(compareOrder);
    final List<Selectable> existingSelectables = selectables;
    selectables = <Selectable>[];
    int mergingIndex = 0;
    int existingIndex = 0;
    int selectionStartIndex = currentSelectionStartIndex;
    int selectionEndIndex = currentSelectionEndIndex;
    while (mergingIndex < mergingSelectables.length || existingIndex < existingSelectables.length) {
      if (mergingIndex >= mergingSelectables.length ||
          (existingIndex < existingSelectables.length &&
              compareOrder(existingSelectables[existingIndex], mergingSelectables[mergingIndex]) <
                  0)) {
        if (existingIndex == currentSelectionStartIndex) {
          selectionStartIndex = selectables.length;
        }
        if (existingIndex == currentSelectionEndIndex) {
          selectionEndIndex = selectables.length;
        }
        selectables.add(existingSelectables[existingIndex]);
        existingIndex += 1;
        continue;
      }

      final Selectable mergingSelectable = mergingSelectables[mergingIndex];
      if (existingIndex < max(currentSelectionStartIndex, currentSelectionEndIndex) &&
          existingIndex > min(currentSelectionStartIndex, currentSelectionEndIndex)) {
        ensureChildUpdated(mergingSelectable);
      }
      mergingSelectable.addListener(_handleSelectableGeometryChange);
      selectables.add(mergingSelectable);
      mergingIndex += 1;
    }
    assert(
      mergingIndex == mergingSelectables.length &&
          existingIndex == existingSelectables.length &&
          selectables.length == existingIndex + mergingIndex,
    );
    assert(selectionStartIndex >= -1 || selectionStartIndex < selectables.length);
    assert(selectionEndIndex >= -1 || selectionEndIndex < selectables.length);
    assert((currentSelectionStartIndex == -1) == (selectionStartIndex == -1));
    assert((currentSelectionEndIndex == -1) == (selectionEndIndex == -1));
    currentSelectionEndIndex = selectionEndIndex;
    currentSelectionStartIndex = selectionStartIndex;
    _additions = <Selectable>{};
  }

  void _removeSelectable(Selectable selectable) {
    assert(selectables.contains(selectable), 'The selectable is not in this registrar.');
    final int index = selectables.indexOf(selectable);
    selectables.removeAt(index);
    if (index <= currentSelectionEndIndex) {
      currentSelectionEndIndex -= 1;
    }
    if (index <= currentSelectionStartIndex) {
      currentSelectionStartIndex -= 1;
    }
    selectable.removeListener(_handleSelectableGeometryChange);
  }

  @protected
  @mustCallSuper
  void didChangeSelectables() {
    _updateSelectionGeometry();
  }

  @override
  SelectionGeometry get value => _selectionGeometry;
  SelectionGeometry _selectionGeometry = const SelectionGeometry(
    hasContent: false,
    status: SelectionStatus.none,
  );

  void _updateSelectionGeometry() {
    final SelectionGeometry newValue = getSelectionGeometry();
    if (_selectionGeometry != newValue) {
      _selectionGeometry = newValue;
      notifyListeners();
    }
    _updateHandleLayersAndOwners();
  }

  static Rect _getBoundingBox(Selectable selectable) {
    Rect result = selectable.boundingBoxes.first;
    for (int index = 1; index < selectable.boundingBoxes.length; index += 1) {
      result = result.expandToInclude(selectable.boundingBoxes[index]);
    }
    return result;
  }

  @protected
  Comparator<Selectable> get compareOrder => _compareScreenOrder;

  static int _compareScreenOrder(Selectable a, Selectable b) {
    final Rect rectA = MatrixUtils.transformRect(a.getTransformTo(null), _getBoundingBox(a));
    final Rect rectB = MatrixUtils.transformRect(b.getTransformTo(null), _getBoundingBox(b));
    final int result = _compareVertically(rectA, rectB);
    if (result != 0) {
      return result;
    }
    return _compareHorizontally(rectA, rectB);
  }

  static int _compareVertically(Rect a, Rect b) {
    if ((a.top - b.top < _kSelectableVerticalComparingThreshold &&
            a.bottom - b.bottom > -_kSelectableVerticalComparingThreshold) ||
        (b.top - a.top < _kSelectableVerticalComparingThreshold &&
            b.bottom - a.bottom > -_kSelectableVerticalComparingThreshold)) {
      return 0;
    }
    if ((a.top - b.top).abs() > _kSelectableVerticalComparingThreshold) {
      return a.top > b.top ? 1 : -1;
    }
    return a.bottom > b.bottom ? 1 : -1;
  }

  static int _compareHorizontally(Rect a, Rect b) {
    // a encloses b.
    if (a.left - b.left < precisionErrorTolerance && a.right - b.right > -precisionErrorTolerance) {
      return -1;
    }
    // b encloses a.
    if (b.left - a.left < precisionErrorTolerance && b.right - a.right > -precisionErrorTolerance) {
      return 1;
    }
    if ((a.left - b.left).abs() > precisionErrorTolerance) {
      return a.left > b.left ? 1 : -1;
    }
    return a.right > b.right ? 1 : -1;
  }

  void _handleSelectableGeometryChange() {
    if (_isHandlingSelectionEvent) {
      return;
    }
    _updateSelectionGeometry();
  }

  @protected
  SelectionGeometry getSelectionGeometry() {
    if (currentSelectionEndIndex == -1 || currentSelectionStartIndex == -1 || selectables.isEmpty) {
      return SelectionGeometry(status: SelectionStatus.none, hasContent: selectables.isNotEmpty);
    }

    if (!_extendSelectionInProgress) {
      currentSelectionStartIndex = _adjustSelectionIndexBasedOnSelectionGeometry(
        currentSelectionStartIndex,
        currentSelectionEndIndex,
      );
      currentSelectionEndIndex = _adjustSelectionIndexBasedOnSelectionGeometry(
        currentSelectionEndIndex,
        currentSelectionStartIndex,
      );
    }

    // Need to find the non-null start selection point.
    SelectionGeometry startGeometry = selectables[currentSelectionStartIndex].value;
    final bool forwardSelection = currentSelectionEndIndex >= currentSelectionStartIndex;
    int startIndexWalker = currentSelectionStartIndex;
    while (startIndexWalker != currentSelectionEndIndex &&
        startGeometry.startSelectionPoint == null) {
      startIndexWalker += forwardSelection ? 1 : -1;
      startGeometry = selectables[startIndexWalker].value;
    }

    SelectionPoint? startPoint;
    if (startGeometry.startSelectionPoint != null) {
      final Matrix4 startTransform = getTransformFrom(selectables[startIndexWalker]);
      final Offset start = MatrixUtils.transformPoint(
        startTransform,
        startGeometry.startSelectionPoint!.localPosition,
      );
      // It can be NaN if it is detached or off-screen.
      if (start.isFinite) {
        startPoint = SelectionPoint(
          localPosition: start,
          lineHeight: startGeometry.startSelectionPoint!.lineHeight,
          handleType: startGeometry.startSelectionPoint!.handleType,
        );
      }
    }

    // Need to find the non-null end selection point.
    SelectionGeometry endGeometry = selectables[currentSelectionEndIndex].value;
    int endIndexWalker = currentSelectionEndIndex;
    while (endIndexWalker != currentSelectionStartIndex && endGeometry.endSelectionPoint == null) {
      endIndexWalker += forwardSelection ? -1 : 1;
      endGeometry = selectables[endIndexWalker].value;
    }
    SelectionPoint? endPoint;
    if (endGeometry.endSelectionPoint != null) {
      final Matrix4 endTransform = getTransformFrom(selectables[endIndexWalker]);
      final Offset end = MatrixUtils.transformPoint(
        endTransform,
        endGeometry.endSelectionPoint!.localPosition,
      );
      // It can be NaN if it is detached or off-screen.
      if (end.isFinite) {
        endPoint = SelectionPoint(
          localPosition: end,
          lineHeight: endGeometry.endSelectionPoint!.lineHeight,
          handleType: endGeometry.endSelectionPoint!.handleType,
        );
      }
    }

    final List<Rect> selectionRects = <Rect>[];
    final Rect? drawableArea =
        hasSize ? Rect.fromLTWH(0, 0, containerSize.width, containerSize.height) : null;
    for (int index = currentSelectionStartIndex; index <= currentSelectionEndIndex; index++) {
      final List<Rect> currSelectableSelectionRects = selectables[index].value.selectionRects;
      final List<Rect> selectionRectsWithinDrawableArea =
          currSelectableSelectionRects
              .map((Rect selectionRect) {
                final Matrix4 transform = getTransformFrom(selectables[index]);
                final Rect localRect = MatrixUtils.transformRect(transform, selectionRect);
                return drawableArea?.intersect(localRect) ?? localRect;
              })
              .where((Rect selectionRect) {
                return selectionRect.isFinite && !selectionRect.isEmpty;
              })
              .toList();
      selectionRects.addAll(selectionRectsWithinDrawableArea);
    }

    return SelectionGeometry(
      startSelectionPoint: startPoint,
      endSelectionPoint: endPoint,
      selectionRects: selectionRects,
      status: startGeometry != endGeometry ? SelectionStatus.uncollapsed : startGeometry.status,
      // Would have at least one selectable child.
      hasContent: true,
    );
  }

  int _adjustSelectionIndexBasedOnSelectionGeometry(int currentIndex, int towardIndex) {
    final bool forward = towardIndex > currentIndex;
    while (currentIndex != towardIndex &&
        selectables[currentIndex].value.status != SelectionStatus.uncollapsed) {
      currentIndex += forward ? 1 : -1;
    }
    return currentIndex;
  }

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_startHandleLayer == startHandle && _endHandleLayer == endHandle) {
      return;
    }
    _startHandleLayer = startHandle;
    _endHandleLayer = endHandle;
    _updateHandleLayersAndOwners();
  }

  void _updateHandleLayersAndOwners() {
    LayerLink? effectiveStartHandle = _startHandleLayer;
    LayerLink? effectiveEndHandle = _endHandleLayer;
    if (effectiveStartHandle != null || effectiveEndHandle != null) {
      final Rect? drawableArea =
          hasSize
              ? Rect.fromLTWH(
                0,
                0,
                containerSize.width,
                containerSize.height,
              ).inflate(_kSelectionHandleDrawableAreaPadding)
              : null;
      final bool hideStartHandle =
          value.startSelectionPoint == null ||
          drawableArea == null ||
          !drawableArea.contains(value.startSelectionPoint!.localPosition);
      final bool hideEndHandle =
          value.endSelectionPoint == null ||
          drawableArea == null ||
          !drawableArea.contains(value.endSelectionPoint!.localPosition);
      effectiveStartHandle = hideStartHandle ? null : _startHandleLayer;
      effectiveEndHandle = hideEndHandle ? null : _endHandleLayer;
    }
    if (currentSelectionStartIndex == -1 || currentSelectionEndIndex == -1) {
      // No valid selection.
      if (_startHandleLayerOwner != null) {
        _startHandleLayerOwner!.pushHandleLayers(null, null);
        _startHandleLayerOwner = null;
      }
      if (_endHandleLayerOwner != null) {
        _endHandleLayerOwner!.pushHandleLayers(null, null);
        _endHandleLayerOwner = null;
      }
      return;
    }

    if (selectables[currentSelectionStartIndex] != _startHandleLayerOwner) {
      _startHandleLayerOwner?.pushHandleLayers(null, null);
    }
    if (selectables[currentSelectionEndIndex] != _endHandleLayerOwner) {
      _endHandleLayerOwner?.pushHandleLayers(null, null);
    }

    _startHandleLayerOwner = selectables[currentSelectionStartIndex];

    if (currentSelectionStartIndex == currentSelectionEndIndex) {
      // Selection edges is on the same selectable.
      _endHandleLayerOwner = _startHandleLayerOwner;
      _startHandleLayerOwner!.pushHandleLayers(effectiveStartHandle, effectiveEndHandle);
      return;
    }

    _startHandleLayerOwner!.pushHandleLayers(effectiveStartHandle, null);
    _endHandleLayerOwner = selectables[currentSelectionEndIndex];
    _endHandleLayerOwner!.pushHandleLayers(null, effectiveEndHandle);
  }

  /// Copies the selected contents of all [Selectable]s.
  @override
  SelectedContent? getSelectedContent() {
    final List<SelectedContent> selections = <SelectedContent>[
      for (final Selectable selectable in selectables)
        if (selectable.getSelectedContent() case final SelectedContent data) data,
    ];
    if (selections.isEmpty) {
      return null;
    }
    final StringBuffer buffer = StringBuffer();
    for (final SelectedContent selection in selections) {
      buffer.write(selection.plainText);
    }
    return SelectedContent(plainText: buffer.toString().replaceAll('\u202F', '\n'),);
  }

  @override
  int get contentLength =>
      selectables.fold<int>(0, (int sum, Selectable selectable) => sum + selectable.contentLength);

  SelectedContentRange? _calculateLocalRange(List<_SelectionInfo> selections) {
    if (currentSelectionStartIndex == -1 || currentSelectionEndIndex == -1) {
      return null;
    }
    int startOffset = 0;
    int endOffset = 0;
    bool foundStart = false;
    bool forwardSelection = currentSelectionEndIndex >= currentSelectionStartIndex;
    if (currentSelectionEndIndex == currentSelectionStartIndex) {
      final SelectedContentRange rangeAtSelectableInSelection =
          selectables[currentSelectionStartIndex].getSelection()!;
      forwardSelection =
          rangeAtSelectableInSelection.endOffset >= rangeAtSelectableInSelection.startOffset;
    }
    for (int index = 0; index < selections.length; index++) {
      final _SelectionInfo selection = selections[index];
      if (selection.range == null) {
        if (foundStart) {
          return SelectedContentRange(
            startOffset: forwardSelection ? startOffset : endOffset,
            endOffset: forwardSelection ? endOffset : startOffset,
          );
        }
        startOffset += selection.contentLength;
        endOffset = startOffset;
        continue;
      }
      final int selectionStartNormalized = min(
        selection.range!.startOffset,
        selection.range!.endOffset,
      );
      final int selectionEndNormalized = max(
        selection.range!.startOffset,
        selection.range!.endOffset,
      );
      if (!foundStart) {
        startOffset += selectionStartNormalized;
        endOffset = startOffset + (selectionEndNormalized - selectionStartNormalized).abs();
        foundStart = true;
      } else {
        endOffset += (selectionEndNormalized - selectionStartNormalized).abs();
      }
    }
    assert(
      foundStart,
      'The start of the selection has not been found despite this selection delegate having an existing currentSelectionStartIndex and currentSelectionEndIndex.',
    );
    return SelectedContentRange(
      startOffset: forwardSelection ? startOffset : endOffset,
      endOffset: forwardSelection ? endOffset : startOffset,
    );
  }

  @override
  SelectedContentRange? getSelection() {
    final List<_SelectionInfo> selections = <_SelectionInfo>[
      for (final Selectable selectable in selectables)
        (contentLength: selectable.contentLength, range: selectable.getSelection()),
    ];
    return _calculateLocalRange(selections);
  }

  void _flushInactiveSelections() {
    if (currentSelectionStartIndex == -1 && currentSelectionEndIndex == -1) {
      return;
    }
    if (currentSelectionStartIndex == -1 || currentSelectionEndIndex == -1) {
      final int skipIndex =
          currentSelectionStartIndex == -1 ? currentSelectionEndIndex : currentSelectionStartIndex;
      selectables
          .where((Selectable target) => target != selectables[skipIndex])
          .forEach(
            (Selectable target) =>
                dispatchSelectionEventToChild(target, const ClearSelectionEvent()),
          );
      return;
    }
    final int skipStart = min(currentSelectionStartIndex, currentSelectionEndIndex);
    final int skipEnd = max(currentSelectionStartIndex, currentSelectionEndIndex);
    for (int index = 0; index < selectables.length; index += 1) {
      if (index >= skipStart && index <= skipEnd) {
        continue;
      }
      dispatchSelectionEventToChild(selectables[index], const ClearSelectionEvent());
    }
  }

  /// Selects all contents of all [Selectable]s.
  @protected
  SelectionResult handleSelectAll(SelectAllSelectionEvent event) {
    for (final Selectable selectable in selectables) {
      dispatchSelectionEventToChild(selectable, event);
    }
    currentSelectionStartIndex = 0;
    currentSelectionEndIndex = selectables.length - 1;
    return SelectionResult.none;
  }

  SelectionResult _handleSelectBoundary(SelectionEvent event) {
    assert(
      event is SelectWordSelectionEvent || event is SelectParagraphSelectionEvent,
      'This method should only be given selection events that select text boundaries.',
    );
    late final Offset effectiveGlobalPosition;
    if (event.type == SelectionEventType.selectWord) {
      effectiveGlobalPosition = (event as SelectWordSelectionEvent).globalPosition;
    } else if (event.type == SelectionEventType.selectParagraph) {
      effectiveGlobalPosition = (event as SelectParagraphSelectionEvent).globalPosition;
    }
    SelectionResult? lastSelectionResult;
    for (int index = 0; index < selectables.length; index += 1) {
      bool globalRectsContainPosition = false;
      if (selectables[index].boundingBoxes.isNotEmpty) {
        for (final Rect rect in selectables[index].boundingBoxes) {
          final Rect globalRect = MatrixUtils.transformRect(
            selectables[index].getTransformTo(null),
            rect,
          );
          if (globalRect.contains(effectiveGlobalPosition)) {
            globalRectsContainPosition = true;
            break;
          }
        }
      }
      if (globalRectsContainPosition) {
        final SelectionGeometry existingGeometry = selectables[index].value;
        lastSelectionResult = dispatchSelectionEventToChild(selectables[index], event);
        if (index == selectables.length - 1 && lastSelectionResult == SelectionResult.next) {
          return SelectionResult.next;
        }
        if (lastSelectionResult == SelectionResult.next) {
          continue;
        }
        if (index == 0 && lastSelectionResult == SelectionResult.previous) {
          return SelectionResult.previous;
        }
        if (selectables[index].value != existingGeometry) {
          // Geometry has changed as a result of select word, need to clear the
          // selection of other selectables to keep selection in sync.
          selectables
              .where((Selectable target) => target != selectables[index])
              .forEach(
                (Selectable target) =>
                    dispatchSelectionEventToChild(target, const ClearSelectionEvent()),
              );
          currentSelectionStartIndex = currentSelectionEndIndex = index;
        }
        return SelectionResult.end;
      } else {
        if (lastSelectionResult == SelectionResult.next) {
          currentSelectionStartIndex = currentSelectionEndIndex = index - 1;
          return SelectionResult.end;
        }
      }
    }
    assert(lastSelectionResult == null);
    return SelectionResult.end;
  }

  /// Selects a word in a [Selectable] at the location
  /// [SelectWordSelectionEvent.globalPosition].
  @protected
  SelectionResult handleSelectWord(SelectWordSelectionEvent event) {
    return _handleSelectBoundary(event);
  }

  /// Selects a paragraph in a [Selectable] at the location
  /// [SelectParagraphSelectionEvent.globalPosition].
  @protected
  SelectionResult handleSelectParagraph(SelectParagraphSelectionEvent event) {
    return _handleSelectBoundary(event);
  }

  /// Removes the selection of all [Selectable]s this delegate manages.
  @protected
  SelectionResult handleClearSelection(ClearSelectionEvent event) {
    for (final Selectable selectable in selectables) {
      dispatchSelectionEventToChild(selectable, event);
    }
    currentSelectionEndIndex = -1;
    currentSelectionStartIndex = -1;
    return SelectionResult.none;
  }

  /// Extend current selection in a certain [TextGranularity].
  @protected
  SelectionResult handleGranularlyExtendSelection(GranularlyExtendSelectionEvent event) {
    assert((currentSelectionStartIndex == -1) == (currentSelectionEndIndex == -1));
    if (currentSelectionStartIndex == -1) {
      if (event.forward) {
        currentSelectionStartIndex = currentSelectionEndIndex = 0;
      } else {
        currentSelectionStartIndex = currentSelectionEndIndex = selectables.length;
      }
    }
    int targetIndex = event.isEnd ? currentSelectionEndIndex : currentSelectionStartIndex;
    SelectionResult result = dispatchSelectionEventToChild(selectables[targetIndex], event);
    if (event.forward) {
      assert(result != SelectionResult.previous);
      while (targetIndex < selectables.length - 1 && result == SelectionResult.next) {
        targetIndex += 1;
        result = dispatchSelectionEventToChild(selectables[targetIndex], event);
        assert(result != SelectionResult.previous);
      }
    } else {
      assert(result != SelectionResult.next);
      while (targetIndex > 0 && result == SelectionResult.previous) {
        targetIndex -= 1;
        result = dispatchSelectionEventToChild(selectables[targetIndex], event);
        assert(result != SelectionResult.next);
      }
    }
    if (event.isEnd) {
      currentSelectionEndIndex = targetIndex;
    } else {
      currentSelectionStartIndex = targetIndex;
    }
    return result;
  }

  /// Extend current selection in a certain [TextGranularity].
  @protected
  SelectionResult handleDirectionallyExtendSelection(DirectionallyExtendSelectionEvent event) {
    assert((currentSelectionStartIndex == -1) == (currentSelectionEndIndex == -1));
    if (currentSelectionStartIndex == -1) {
      currentSelectionStartIndex =
          currentSelectionEndIndex = switch (event.direction) {
            SelectionExtendDirection.previousLine ||
            SelectionExtendDirection.backward => selectables.length - 1,
            SelectionExtendDirection.nextLine || SelectionExtendDirection.forward => 0,
          };
    }
    int targetIndex = event.isEnd ? currentSelectionEndIndex : currentSelectionStartIndex;
    SelectionResult result = dispatchSelectionEventToChild(selectables[targetIndex], event);
    switch (event.direction) {
      case SelectionExtendDirection.previousLine:
        assert(result == SelectionResult.end || result == SelectionResult.previous);
        if (result == SelectionResult.previous) {
          if (targetIndex > 0) {
            targetIndex -= 1;
            result = dispatchSelectionEventToChild(
              selectables[targetIndex],
              event.copyWith(direction: SelectionExtendDirection.backward),
            );
            assert(result == SelectionResult.end);
          }
        }
      case SelectionExtendDirection.nextLine:
        assert(result == SelectionResult.end || result == SelectionResult.next);
        if (result == SelectionResult.next) {
          if (targetIndex < selectables.length - 1) {
            targetIndex += 1;
            result = dispatchSelectionEventToChild(
              selectables[targetIndex],
              event.copyWith(direction: SelectionExtendDirection.forward),
            );
            assert(result == SelectionResult.end);
          }
        }
      case SelectionExtendDirection.forward:
      case SelectionExtendDirection.backward:
        assert(result == SelectionResult.end);
    }
    if (event.isEnd) {
      currentSelectionEndIndex = targetIndex;
    } else {
      currentSelectionStartIndex = targetIndex;
    }
    return result;
  }

  /// Updates the selection edges.
  @protected
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    if (event.type == SelectionEventType.endEdgeUpdate) {
      return currentSelectionEndIndex == -1
          ? _initSelection(event, isEnd: true)
          : _adjustSelection(event, isEnd: true);
    }
    return currentSelectionStartIndex == -1
        ? _initSelection(event, isEnd: false)
        : _adjustSelection(event, isEnd: false);
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final bool selectionWillBeInProgress = event is! ClearSelectionEvent;
    if (!_selectionInProgress && selectionWillBeInProgress) {
      // Sort the selectable every time a selection start.
      selectables.sort(compareOrder);
    }
    _selectionInProgress = selectionWillBeInProgress;
    _isHandlingSelectionEvent = true;
    late SelectionResult result;
    switch (event.type) {
      case SelectionEventType.startEdgeUpdate:
      case SelectionEventType.endEdgeUpdate:
        _extendSelectionInProgress = false;
        result = handleSelectionEdgeUpdate(event as SelectionEdgeUpdateEvent);
      case SelectionEventType.clear:
        _extendSelectionInProgress = false;
        result = handleClearSelection(event as ClearSelectionEvent);
      case SelectionEventType.selectAll:
        _extendSelectionInProgress = false;
        result = handleSelectAll(event as SelectAllSelectionEvent);
      case SelectionEventType.selectWord:
        _extendSelectionInProgress = false;
        result = handleSelectWord(event as SelectWordSelectionEvent);
      case SelectionEventType.selectParagraph:
        _extendSelectionInProgress = false;
        result = handleSelectParagraph(event as SelectParagraphSelectionEvent);
      case SelectionEventType.granularlyExtendSelection:
        _extendSelectionInProgress = true;
        result = handleGranularlyExtendSelection(event as GranularlyExtendSelectionEvent);
      case SelectionEventType.directionallyExtendSelection:
        _extendSelectionInProgress = true;
        result = handleDirectionallyExtendSelection(event as DirectionallyExtendSelectionEvent);
    }
    _isHandlingSelectionEvent = false;
    _updateSelectionGeometry();
    return result;
  }

  @override
  void dispose() {
    for (final Selectable selectable in selectables) {
      selectable.removeListener(_handleSelectableGeometryChange);
    }
    selectables = const <Selectable>[];
    _scheduledSelectableUpdate = false;
    super.dispose();
  }

  @protected
  void ensureChildUpdated(Selectable selectable);

  @protected
  SelectionResult dispatchSelectionEventToChild(Selectable selectable, SelectionEvent event) {
    return selectable.dispatchSelectionEvent(event);
  }

  SelectionResult _initSelection(SelectionEdgeUpdateEvent event, {required bool isEnd}) {
    assert(
      (isEnd && currentSelectionEndIndex == -1) || (!isEnd && currentSelectionStartIndex == -1),
    );
    int newIndex = -1;
    bool hasFoundEdgeIndex = false;
    SelectionResult? result;
    for (int index = 0; index < selectables.length && !hasFoundEdgeIndex; index += 1) {
      final Selectable child = selectables[index];
      final SelectionResult childResult = dispatchSelectionEventToChild(child, event);
      switch (childResult) {
        case SelectionResult.next:
        case SelectionResult.none:
          newIndex = index;
        case SelectionResult.end:
          newIndex = index;
          result = SelectionResult.end;
          hasFoundEdgeIndex = true;
        case SelectionResult.previous:
          hasFoundEdgeIndex = true;
          if (index == 0) {
            newIndex = 0;
            result = SelectionResult.previous;
          }
          result ??= SelectionResult.end;
        case SelectionResult.pending:
          newIndex = index;
          result = SelectionResult.pending;
          hasFoundEdgeIndex = true;
      }
    }

    if (newIndex == -1) {
      assert(selectables.isEmpty);
      return SelectionResult.none;
    }
    if (isEnd) {
      currentSelectionEndIndex = newIndex;
    } else {
      currentSelectionStartIndex = newIndex;
    }
    _flushInactiveSelections();
    return result ?? SelectionResult.next;
  }

  SelectionResult _adjustSelection(SelectionEdgeUpdateEvent event, {required bool isEnd}) {
    assert(() {
      if (isEnd) {
        assert(currentSelectionEndIndex < selectables.length && currentSelectionEndIndex >= 0);
        return true;
      }
      assert(currentSelectionStartIndex < selectables.length && currentSelectionStartIndex >= 0);
      return true;
    }());
    SelectionResult? finalResult;
    final bool isCurrentEdgeWithinViewport =
        isEnd
            ? _selectionGeometry.endSelectionPoint != null
            : _selectionGeometry.startSelectionPoint != null;
    final bool isOppositeEdgeWithinViewport =
        isEnd
            ? _selectionGeometry.startSelectionPoint != null
            : _selectionGeometry.endSelectionPoint != null;
    int newIndex = switch ((isEnd, isCurrentEdgeWithinViewport, isOppositeEdgeWithinViewport)) {
      (true, true, true) => currentSelectionEndIndex,
      (true, true, false) => currentSelectionEndIndex,
      (true, false, true) => currentSelectionStartIndex,
      (true, false, false) => 0,
      (false, true, true) => currentSelectionStartIndex,
      (false, true, false) => currentSelectionStartIndex,
      (false, false, true) => currentSelectionEndIndex,
      (false, false, false) => 0,
    };
    bool? forward;
    late SelectionResult currentSelectableResult;
    while (newIndex < selectables.length && newIndex >= 0 && finalResult == null) {
      currentSelectableResult = dispatchSelectionEventToChild(selectables[newIndex], event);
      switch (currentSelectableResult) {
        case SelectionResult.end:
        case SelectionResult.pending:
        case SelectionResult.none:
          finalResult = currentSelectableResult;
        case SelectionResult.next:
          if (forward == false) {
            newIndex += 1;
            finalResult = SelectionResult.end;
          } else if (newIndex == selectables.length - 1) {
            finalResult = currentSelectableResult;
          } else {
            forward = true;
            newIndex += 1;
          }
        case SelectionResult.previous:
          if (forward ?? false) {
            newIndex -= 1;
            finalResult = SelectionResult.end;
          } else if (newIndex == 0) {
            finalResult = currentSelectableResult;
          } else {
            forward = false;
            newIndex -= 1;
          }
      }
    }
    if (isEnd) {
      currentSelectionEndIndex = newIndex;
    } else {
      currentSelectionStartIndex = newIndex;
    }
    _flushInactiveSelections();
    return finalResult!;
  }
}

typedef _SelectionInfo = ({int contentLength, SelectedContentRange? range});

typedef SelectableRegionContextMenuBuilder =
    Widget Function(BuildContext context, CustomSelectableRegionState selectableRegionState);

enum SelectableRegionSelectionStatus {
  changing,
  finalized,
}

final class _SelectableRegionSelectionStatusNotifier extends ChangeNotifier
    implements ValueListenable<SelectableRegionSelectionStatus> {
  _SelectableRegionSelectionStatusNotifier._();

  SelectableRegionSelectionStatus _selectableRegionSelectionStatus =
      SelectableRegionSelectionStatus.finalized;

  @override
  SelectableRegionSelectionStatus get value => _selectableRegionSelectionStatus;

  @protected
  set value(SelectableRegionSelectionStatus newStatus) {
    assert(
      newStatus == SelectableRegionSelectionStatus.finalized &&
              value == SelectableRegionSelectionStatus.changing ||
          newStatus == SelectableRegionSelectionStatus.changing,
      'Attempting to finalize the selection when it is already finalized.',
    );
    _selectableRegionSelectionStatus = newStatus;
    notifyListeners();
  }
}

final class SelectableRegionSelectionStatusScope extends InheritedWidget {
  const SelectableRegionSelectionStatusScope._({
    required this.selectionStatusNotifier,
    required super.child,
  });

  final ValueListenable<SelectableRegionSelectionStatus> selectionStatusNotifier;

  static ValueListenable<SelectableRegionSelectionStatus>? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<SelectableRegionSelectionStatusScope>()
        ?.selectionStatusNotifier;
  }

  @override
  bool updateShouldNotify(SelectableRegionSelectionStatusScope oldWidget) {
    return selectionStatusNotifier != oldWidget.selectionStatusNotifier;
  }
}

class SelectionListener extends StatefulWidget {
  const SelectionListener({super.key, required this.selectionNotifier, required this.child});

  final SelectionListenerNotifier selectionNotifier;

  final Widget child;

  @override
  State<SelectionListener> createState() => _SelectionListenerState();
}

class _SelectionListenerState extends State<SelectionListener> {
  late final _SelectionListenerDelegate _selectionDelegate = _SelectionListenerDelegate(
    selectionNotifier: widget.selectionNotifier,
  );

  @override
  void didUpdateWidget(SelectionListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectionNotifier != widget.selectionNotifier) {
      _selectionDelegate._setNotifier(widget.selectionNotifier);
    }
  }

  @override
  void dispose() {
    _selectionDelegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SelectionContainer(delegate: _selectionDelegate, child: widget.child);
  }
}

final class _SelectionListenerDelegate extends StaticSelectionContainerDelegate
    implements SelectionDetails {
  _SelectionListenerDelegate({required SelectionListenerNotifier selectionNotifier})
    : _selectionNotifier = selectionNotifier {
    _selectionNotifier._registerSelectionListenerDelegate(this);
  }

  SelectionGeometry? _initialSelectionGeometry;

  SelectionListenerNotifier _selectionNotifier;
  void _setNotifier(SelectionListenerNotifier newNotifier) {
    _selectionNotifier._unregisterSelectionListenerDelegate();
    _selectionNotifier = newNotifier;
    _selectionNotifier._registerSelectionListenerDelegate(this);
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    // Skip initial notification if selection is not valid.
    if (_initialSelectionGeometry == null && !value.hasSelection) {
      _initialSelectionGeometry = value;
      return;
    }
    _selectionNotifier.notifyListeners();
  }

  @override
  void dispose() {
    _selectionNotifier._unregisterSelectionListenerDelegate();
    _initialSelectionGeometry = null;
    super.dispose();
  }

  @override
  SelectedContentRange? get range => getSelection();

  @override
  SelectionStatus get status => value.status;
}

abstract final class SelectionDetails {
  SelectedContentRange? get range;
  SelectionStatus get status;
}

final class SelectionListenerNotifier extends ChangeNotifier {
  _SelectionListenerDelegate? _selectionDelegate;

  SelectionDetails get selection =>
      _selectionDelegate ??
      (throw Exception('Selection client has not been registered to this notifier.'));

  bool get registered => _selectionDelegate != null;

  void _registerSelectionListenerDelegate(_SelectionListenerDelegate selectionDelegate) {
    assert(
      !registered,
      'This SelectionListenerNotifier is already registered to another SelectionListener. Try providing a new SelectionListenerNotifier.',
    );
    _selectionDelegate = selectionDelegate;
  }

  void _unregisterSelectionListenerDelegate() {
    _selectionDelegate = null;
  }

  @override
  void dispose() {
    _unregisterSelectionListenerDelegate();
    super.dispose();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
  }
}