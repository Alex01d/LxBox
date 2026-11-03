import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class IosEdgeBackGesture extends StatefulWidget {
  const IosEdgeBackGesture({
    super.key,
    required this.observer,
    required this.child,
  });

  final NavigatorObserver observer;
  final Widget child;

  @override
  State<IosEdgeBackGesture> createState() => _IosEdgeBackGestureState();
}

class _IosEdgeBackGestureState extends State<IosEdgeBackGesture> {
  static const _edgeWidth = 20.0;
  static const _backDragDistance = 80.0;

  late final HorizontalDragGestureRecognizer _drag;
  double _dragged = 0;

  NavigatorState? get _navigator => widget.observer.navigator;

  @override
  void initState() {
    super.initState();
    _drag = HorizontalDragGestureRecognizer(debugOwner: this)
      ..onStart = ((_) => _dragged = 0)
      ..onUpdate = ((details) => _dragged += details.primaryDelta ?? 0)
      ..onEnd = ((_) => _goBackIfDraggedFarEnough());
  }

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _goBackIfDraggedFarEnough() {
    if (_dragged < _backDragDistance) return;
    unawaited(_navigator?.maybePop());
  }

  Route<dynamic>? _topRoute() {
    Route<dynamic>? top;
    _navigator?.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }

  bool _flutterSwipeIsOff() {
    final route = _topRoute();
    return route is PageRoute &&
        !route.isFirst &&
        route.popDisposition == RoutePopDisposition.doNotPop;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_flutterSwipeIsOff()) _drag.addPointer(event);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _edgeWidth,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _handlePointerDown,
          ),
        ),
      ],
    );
  }
}
