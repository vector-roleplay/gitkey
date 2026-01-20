// Copyright 2019 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';

import 'item_positions_listener.dart';
import 'item_positions_notifier.dart';
import 'positioned_list.dart';
import 'post_mount_callback.dart';
import 'scroll_offset_notifier.dart';
import 'scroll_offset_listener.dart';

const int _screenScrollCount = 2;

class ScrollablePositionedList extends StatefulWidget {
  const ScrollablePositionedList.builder({
    required this.itemCount,
    required this.itemBuilder,
    Key? key,
    this.itemScrollController,
    this.shrinkWrap = false,
    ItemPositionsListener? itemPositionsListener,
    this.scrollOffsetController,
    ScrollOffsetListener? scrollOffsetListener,
    this.initialScrollIndex = 0,
    this.initialAlignment = 0,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.physics,
    this.semanticChildCount,
    this.padding,
    this.addSemanticIndexes = true,
    this.addAutomaticKeepAlives = true,
    this.addRepaintBoundaries = true,
    this.minCacheExtent,
  })  : assert(itemCount != null),
        assert(itemBuilder != null),
        itemPositionsNotifier = itemPositionsListener as ItemPositionsNotifier?,
        scrollOffsetNotifier = scrollOffsetListener as ScrollOffsetNotifier?,
        separatorBuilder = null,
        super(key: key);

  const ScrollablePositionedList.separated({
    required this.itemCount,
    required this.itemBuilder,
    required this.separatorBuilder,
    Key? key,
    this.shrinkWrap = false,
    this.itemScrollController,
    ItemPositionsListener? itemPositionsListener,
    this.scrollOffsetController,
    ScrollOffsetListener? scrollOffsetListener,
    this.initialScrollIndex = 0,
    this.initialAlignment = 0,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.physics,
    this.semanticChildCount,
    this.padding,
    this.addSemanticIndexes = true,
    this.addAutomaticKeepAlives = true,
    this.addRepaintBoundaries = true,
    this.minCacheExtent,
  })  : assert(itemCount != null),
        assert(itemBuilder != null),
        assert(separatorBuilder != null),
        itemPositionsNotifier = itemPositionsListener as ItemPositionsNotifier?,
        scrollOffsetNotifier = scrollOffsetListener as ScrollOffsetNotifier?,
        super(key: key);

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;
  final ItemScrollController? itemScrollController;
  final ItemPositionsNotifier? itemPositionsNotifier;
  final ScrollOffsetController? scrollOffsetController;
  final ScrollOffsetNotifier? scrollOffsetNotifier;
  final int initialScrollIndex;
  final double initialAlignment;
  final Axis scrollDirection;
  final bool reverse;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final int? semanticChildCount;
  final EdgeInsets? padding;
  final bool addSemanticIndexes;
  final bool addAutomaticKeepAlives;
  final bool addRepaintBoundaries;
  final double? minCacheExtent;

  @override
  State<StatefulWidget> createState() => _ScrollablePositionedListState();
}

class ItemScrollController {
  bool get isAttached => _scrollableListState != null;

  _ScrollablePositionedListState? _scrollableListState;

  void jumpTo({required int index, double alignment = 0}) {
    _scrollableListState!._jumpTo(index: index, alignment: alignment);
  }

  Future<void> scrollTo({
    required int index,
    double alignment = 0,
    required Duration duration,
    Curve curve = Curves.linear,
    List<double> opacityAnimationWeights = const [40, 20, 40],
  }) {
    assert(_scrollableListState != null);
    assert(opacityAnimationWeights.length == 3);
    assert(duration > Duration.zero);
    return _scrollableListState!._scrollTo(
      index: index,
      alignment: alignment,
      duration: duration,
      curve: curve,
      opacityAnimationWeights: opacityAnimationWeights,
    );
  }

  void scrollToStart() {
    if (_scrollableListState == null) return;
    
    final itemCount = _scrollableListState!.widget.itemCount;
    if (itemCount == 0) return;
    
    _scrollableListState!._jumpTo(index: 0, alignment: 0.0);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _scrollableListState?.primary.scrollController;
      if (controller != null && controller.hasClients) {
        controller.jumpTo(controller.position.minScrollExtent);
      }
    });
  }

  void scrollToEnd() {
    if (_scrollableListState == null) return;
    
    final itemCount = _scrollableListState!.widget.itemCount;
    if (itemCount == 0) return;
    
    _scrollableListState!._jumpTo(index: itemCount - 1, alignment: 0.0);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _scrollableListState?.primary.scrollController;
      if (controller != null && controller.hasClients) {
        controller.jumpTo(controller.position.maxScrollExtent);
      }
    });
  }

  void _attach(_ScrollablePositionedListState scrollableListState) {
    assert(_scrollableListState == null);
    _scrollableListState = scrollableListState;
  }

  void _detach() {
    _scrollableListState = null;
  }
}

class ScrollOffsetController {
  Future<void> animateScroll(
      {required double offset,
      required Duration duration,
      Curve curve = Curves.linear}) async {
    final currentPosition =
        _scrollableListState!.primary.scrollController.offset;
    final newPosition = currentPosition + offset;
    await _scrollableListState!.primary.scrollController.animateTo(
      newPosition,
      duration: duration,
      curve: curve,
    );
  }

  _ScrollablePositionedListState? _scrollableListState;

  void _attach(_ScrollablePositionedListState scrollableListState) {
    assert(_scrollableListState == null);
    _scrollableListState = scrollableListState;
  }

  void _detach() {
    _scrollableListState = null;
  }
}

class _ScrollablePositionedListState extends State<ScrollablePositionedList>
    with TickerProviderStateMixin {
  var primary = _ListDisplayDetails(const ValueKey('Ping'));
  var secondary = _ListDisplayDetails(const ValueKey('Pong'));

  final opacity = ProxyAnimation(const AlwaysStoppedAnimation<double>(0));

  void Function() startAnimationCallback = () {};

  bool _isTransitioning = false;

  AnimationController? _animationController;

  double previousOffset = 0;

  @override
  void initState() {
    super.initState();
    ItemPosition? initialPosition = PageStorage.of(context).readState(context);
    primary.target = initialPosition?.index ?? widget.initialScrollIndex;
    primary.alignment =
        initialPosition?.itemLeadingEdge ?? widget.initialAlignment;
    if (widget.itemCount > 0 && primary.target > widget.itemCount - 1) {
      primary.target = widget.itemCount - 1;
    }
    widget.itemScrollController?._attach(this);
    widget.scrollOffsetController?._attach(this);
    primary.itemPositionsNotifier.itemPositions.addListener(_updatePositions);
    secondary.itemPositionsNotifier.itemPositions.addListener(_updatePositions);
    primary.scrollController.addListener(() {
      final currentOffset = primary.scrollController.offset;
      final offsetChange = currentOffset - previousOffset;
      previousOffset = currentOffset;
      if (!_isTransitioning ||
          (widget.scrollOffsetNotifier?.recordProgrammaticScrolls ?? false)) {
        widget.scrollOffsetNotifier?.changeController.add(offsetChange);
      }
    });
  }

  @override
  void activate() {
    super.activate();
    widget.itemScrollController?._attach(this);
    widget.scrollOffsetController?._attach(this);
  }

  @override
  void deactivate() {
    widget.itemScrollController?._detach();
    widget.scrollOffsetController?._detach();
    super.deactivate();
  }

  @override
  void dispose() {
    primary.itemPositionsNotifier.itemPositions
        .removeListener(_updatePositions);
    secondary.itemPositionsNotifier.itemPositions
        .removeListener(_updatePositions);
    _animationController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ScrollablePositionedList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemScrollController?._scrollableListState == this) {
      oldWidget.itemScrollController?._detach();
    }
    if (widget.itemScrollController?._scrollableListState != this) {
      widget.itemScrollController?._detach();
      widget.itemScrollController?._attach(this);
    }

    if (widget.itemCount == 0) {
      setState(() {
        primary.target = 0;
        secondary.target = 0;
      });
    } else {
      if (primary.target > widget.itemCount - 1) {
        setState(() {
          primary.target = widget.itemCount - 1;
        });
      }
      if (secondary.target > widget.itemCount - 1) {
        setState(() {
          secondary.target = widget.itemCount - 1;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cacheExtent = _cacheExtent(constraints);
        return Listener(
          onPointerDown: (_) => _stopScroll(canceled: true),
          child: Stack(
            children: <Widget>[
              PostMountCallback(
                key: primary.key,
                callback: startAnimationCallback,
                child: FadeTransition(
                  opacity: ReverseAnimation(opacity),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (_) => _isTransitioning,
                    child: PositionedList(
                      itemBuilder: widget.itemBuilder,
                      separatorBuilder: widget.separatorBuilder,
                      itemCount: widget.itemCount,
                      positionedIndex: primary.target,
                      controller: primary.scrollController,
                      itemPositionsNotifier: primary.itemPositionsNotifier,
                      scrollDirection: widget.scrollDirection,
                      reverse: widget.reverse,
                      cacheExtent: cacheExtent,
                      alignment: primary.alignment,
                      physics: widget.physics,
                      shrinkWrap: widget.shrinkWrap,
                      addSemanticIndexes: widget.addSemanticIndexes,
                      semanticChildCount: widget.semanticChildCount,
                      padding: widget.padding,
                      addAutomaticKeepAlives: widget.addAutomaticKeepAlives,
                      addRepaintBoundaries: widget.addRepaintBoundaries,
                    ),
                  ),
                ),
              ),
              if (_isTransitioning)
                PostMountCallback(
                  key: secondary.key,
                  callback: startAnimationCallback,
                  child: FadeTransition(
                    opacity: opacity,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (_) => false,
                      child: PositionedList(
                        itemBuilder: widget.itemBuilder,
                        separatorBuilder: widget.separatorBuilder,
                        itemCount: widget.itemCount,
                        itemPositionsNotifier: secondary.itemPositionsNotifier,
                        positionedIndex: secondary.target,
                        controller: secondary.scrollController,
                        scrollDirection: widget.scrollDirection,
                        reverse: widget.reverse,
                        cacheExtent: cacheExtent,
                        alignment: secondary.alignment,
                        physics: widget.physics,
                        shrinkWrap: widget.shrinkWrap,
                        addSemanticIndexes: widget.addSemanticIndexes,
                        semanticChildCount: widget.semanticChildCount,
                        padding: widget.padding,
                        addAutomaticKeepAlives: widget.addAutomaticKeepAlives,
                        addRepaintBoundaries: widget.addRepaintBoundaries,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  double _cacheExtent(BoxConstraints constraints) => max(
        (widget.scrollDirection == Axis.vertical
                ? constraints.maxHeight
                : constraints.maxWidth) *
            _screenScrollCount,
        widget.minCacheExtent ?? 0,
      );

  void _jumpTo({required int index, required double alignment}) {
    _stopScroll(canceled: true);
    if (index > widget.itemCount - 1) {
      index = widget.itemCount - 1;
    }
    setState(() {
      primary.scrollController.jumpTo(0);
      primary.target = index;
      primary.alignment = alignment;
    });
  }

  Future<void> _scrollTo({
    required int index,
    required double alignment,
    required Duration duration,
    Curve curve = Curves.linear,
    required List<double> opacityAnimationWeights,
  }) async {
    if (index > widget.itemCount - 1) {
      index = widget.itemCount - 1;
    }
    if (_isTransitioning) {
      final scrollCompleter = Completer<void>();
      _stopScroll(canceled: true);
      SchedulerBinding.instance.addPostFrameCallback((_) async {
        await _startScroll(
          index: index,
          alignment: alignment,
          duration: duration,
          curve: curve,
          opacityAnimationWeights: opacityAnimationWeights,
        );
        scrollCompleter.complete();
      });
      await scrollCompleter.future;
    } else {
      await _startScroll(
        index: index,
        alignment: alignment,
        duration: duration,
        curve: curve,
        opacityAnimationWeights: opacityAnimationWeights,
      );
    }
  }

  Future<void> _startScroll({
    required int index,
    required double alignment,
    required Duration duration,
    Curve curve = Curves.linear,
    required List<double> opacityAnimationWeights,
  }) async {
    final direction = index > primary.target ? 1 : -1;
    final itemPosition = primary.itemPositionsNotifier.itemPositions.value
        .firstWhereOrNull(
            (ItemPosition itemPosition) => itemPosition.index == index);
    if (itemPosition != null) {
      final localScrollAmount = itemPosition.itemLeadingEdge *
          primary.scrollController.position.viewportDimension;
      await primary.scrollController.animateTo(
          primary.scrollController.offset +
              localScrollAmount -
              alignment * primary.scrollController.position.viewportDimension,
          duration: duration,
          curve: curve);
    } else {
      final scrollAmount = _screenScrollCount *
          primary.scrollController.position.viewportDimension;
      final startCompleter = Completer<void>();
      final endCompleter = Completer<void>();
      startAnimationCallback = () {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          startAnimationCallback = () {};
          _animationController?.dispose();
          _animationController =
              AnimationController(vsync: this, duration: duration)..forward();
          opacity.parent = _opacityAnimation(opacityAnimationWeights)
              .animate(_animationController!);
          secondary.scrollController.jumpTo(-direction *
              (_screenScrollCount *
                      primary.scrollController.position.viewportDimension -
                  alignment *
                      secondary.scrollController.position.viewportDimension));

          startCompleter.complete(primary.scrollController.animateTo(
              primary.scrollController.offset + direction * scrollAmount,
              duration: duration,
              curve: curve));
          endCompleter.complete(secondary.scrollController
              .animateTo(0, duration: duration, curve: curve));
        });
      };
      setState(() {
        secondary.target = index;
        secondary.alignment = alignment;
        _isTransitioning = true;
      });
      await Future.wait<void>([startCompleter.future, endCompleter.future]);
      _stopScroll();
    }
  }

  void _stopScroll({bool canceled = false}) {
    if (!_isTransitioning) {
      return;
    }

    if (canceled) {
      if (primary.scrollController.hasClients) {
        primary.scrollController.jumpTo(primary.scrollController.offset);
      }
      if (secondary.scrollController.hasClients) {
        secondary.scrollController.jumpTo(secondary.scrollController.offset);
      }
    }

    if (mounted) {
      setState(() {
        if (opacity.value >= 0.5) {
          var temp = primary;
          primary = secondary;
          secondary = temp;
        }
        _isTransitioning = false;
        opacity.parent = const AlwaysStoppedAnimation<double>(0);
      });
    }
  }

  Animatable<double> _opacityAnimation(List<double> opacityAnimationWeights) {
    const startOpacity = 0.0;
    const endOpacity = 1.0;
    return TweenSequence<double>(<TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
          tween: ConstantTween<double>(startOpacity),
          weight: opacityAnimationWeights[0]),
      TweenSequenceItem<double>(
          tween: Tween<double>(begin: startOpacity, end: endOpacity),
          weight: opacityAnimationWeights[1]),
      TweenSequenceItem<double>(
          tween: ConstantTween<double>(endOpacity),
          weight: opacityAnimationWeights[2]),
    ]);
  }

  void _updatePositions() {
    final itemPositions = primary.itemPositionsNotifier.itemPositions.value
        .where((ItemPosition position) =>
            position.itemLeadingEdge < 1 && position.itemTrailingEdge > 0);
    if (itemPositions.isNotEmpty) {
      PageStorage.of(context).writeState(
          context,
          itemPositions.reduce((value, element) =>
              value.itemLeadingEdge < element.itemLeadingEdge
                  ? value
                  : element));
    }
    widget.itemPositionsNotifier?.itemPositions.value = itemPositions;
  }
}

class _ListDisplayDetails {
  _ListDisplayDetails(this.key);

  final itemPositionsNotifier = ItemPositionsNotifier();
  final scrollController = ScrollController(keepScrollOffset: false);

  int target = 0;
  double alignment = 0;

  final Key key;
}