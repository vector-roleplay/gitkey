import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class CustomShrinkWrappingViewport extends CustomViewport {
  CustomShrinkWrappingViewport({
    Key? key,
    AxisDirection axisDirection = AxisDirection.down,
    AxisDirection? crossAxisDirection,
    double anchor = 0.0,
    required ViewportOffset offset,
    List<RenderSliver>? children,
    Key? center,
    double? cacheExtent,
    List<Widget> slivers = const <Widget>[],
  })  : _anchor = anchor,
        super(
            key: key,
            axisDirection: axisDirection,
            crossAxisDirection: crossAxisDirection,
            offset: offset,
            center: center,
            cacheExtent: cacheExtent,
            slivers: slivers);

  final double _anchor;

  @override
  double get anchor => _anchor;

  @override
  CustomRenderShrinkWrappingViewport createRenderObject(BuildContext context) {
    return CustomRenderShrinkWrappingViewport(
      axisDirection: axisDirection,
      crossAxisDirection: crossAxisDirection ??
          Viewport.getDefaultCrossAxisDirection(context, axisDirection),
      offset: offset,
      anchor: anchor,
      cacheExtent: cacheExtent,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, CustomRenderShrinkWrappingViewport renderObject) {
    renderObject
      ..axisDirection = axisDirection
      ..crossAxisDirection = crossAxisDirection ??
          Viewport.getDefaultCrossAxisDirection(context, axisDirection)
      ..anchor = anchor
      ..offset = offset
      ..cacheExtent = cacheExtent
      ..cacheExtentStyle = cacheExtentStyle
      ..clipBehavior = clipBehavior;
  }
}

class CustomRenderShrinkWrappingViewport extends CustomRenderViewport {
  CustomRenderShrinkWrappingViewport({
    AxisDirection axisDirection = AxisDirection.down,
    required AxisDirection crossAxisDirection,
    required ViewportOffset offset,
    double anchor = 0.0,
    List<RenderSliver>? children,
    RenderSliver? center,
    double? cacheExtent,
  })  : _anchor = anchor,
        super(
          axisDirection: axisDirection,
          crossAxisDirection: crossAxisDirection,
          offset: offset,
          center: center,
          cacheExtent: cacheExtent,
          children: children,
        );

  double _anchor;

  @override
  double get anchor => _anchor;

  @override
  bool get sizedByParent => false;

  double lastMainAxisExtent = -1;

  @override
  set anchor(double value) {
    if (value == _anchor) return;
    _anchor = value;
    markNeedsLayout();
  }

  late double _shrinkWrapExtent;
  double? _calculatedCacheExtent;
  final double _maxMainAxisExtent = double.maxFinite;

  @override
  void performLayout() {
    if (center == null) {
      assert(firstChild == null);
      _minScrollExtent = 0.0;
      _maxScrollExtent = 0.0;
      _hasVisualOverflow = false;
      offset.applyContentDimensions(0.0, 0.0);
      return;
    }

    assert(center!.parent == this);

    final BoxConstraints constraints = this.constraints;
    if (firstChild == null) {
      switch (axis) {
        case Axis.vertical:
          assert(constraints.hasBoundedWidth);
          size = Size(constraints.maxWidth, constraints.minHeight);
          break;
        case Axis.horizontal:
          assert(constraints.hasBoundedHeight);
          size = Size(constraints.minWidth, constraints.maxHeight);
          break;
      }
      offset.applyViewportDimension(0.0);
      _maxScrollExtent = 0.0;
      _shrinkWrapExtent = 0.0;
      _hasVisualOverflow = false;
      offset.applyContentDimensions(0.0, 0.0);
      return;
    }

    double mainAxisExtent;
    final double crossAxisExtent;
    switch (axis) {
      case Axis.vertical:
        assert(constraints.hasBoundedWidth);
        mainAxisExtent = constraints.maxHeight;
        crossAxisExtent = constraints.maxWidth;
        break;
      case Axis.horizontal:
        assert(constraints.hasBoundedHeight);
        mainAxisExtent = constraints.maxWidth;
        crossAxisExtent = constraints.maxHeight;
        break;
    }

    if (mainAxisExtent.isInfinite) {
      mainAxisExtent = _maxMainAxisExtent;
    }

    final centerOffsetAdjustment = center!.centerOffsetAdjustment;

    double correction;
    double effectiveExtent = 0;
    do {
      correction = _attemptLayout(mainAxisExtent, crossAxisExtent,
          offset.pixels + centerOffsetAdjustment);
      if (correction != 0.0) {
        offset.correctBy(correction);
      } else {
        switch (axis) {
          case Axis.vertical:
            effectiveExtent = constraints.constrainHeight(_shrinkWrapExtent);
            break;
          case Axis.horizontal:
            effectiveExtent = constraints.constrainWidth(_shrinkWrapExtent);
            break;
        }
        final top = _minScrollExtent + mainAxisExtent * anchor;
        final bottom = _maxScrollExtent - mainAxisExtent * (1.0 - anchor);

        final maxScrollOffset = math.max(math.min(0.0, top), bottom);
        final minScrollOffset = math.min(top, maxScrollOffset);

        final bool didAcceptViewportDimension =
            offset.applyViewportDimension(effectiveExtent);
        final bool didAcceptContentDimension =
            offset.applyContentDimensions(minScrollOffset, maxScrollOffset);
        if (didAcceptViewportDimension && didAcceptContentDimension) {
          break;
        }
      }
    } while (true);
    switch (axis) {
      case Axis.vertical:
        size =
            constraints.constrainDimensions(crossAxisExtent, effectiveExtent);
        break;
      case Axis.horizontal:
        size =
            constraints.constrainDimensions(effectiveExtent, crossAxisExtent);
        break;
    }
  }

  double _attemptLayout(
      double mainAxisExtent, double crossAxisExtent, double correctedOffset) {
    assert(!mainAxisExtent.isNaN);
    assert(mainAxisExtent >= 0.0);
    assert(crossAxisExtent.isFinite);
    assert(crossAxisExtent >= 0.0);
    assert(correctedOffset.isFinite);
    _minScrollExtent = 0.0;
    _maxScrollExtent = 0.0;
    _hasVisualOverflow = false;
    _shrinkWrapExtent = 0.0;

    final centerOffset = mainAxisExtent * anchor - correctedOffset;
    final reverseDirectionRemainingPaintExtent =
        centerOffset.clamp(0.0, mainAxisExtent);
    final forwardDirectionRemainingPaintExtent =
        (mainAxisExtent - centerOffset).clamp(0.0, mainAxisExtent);

    switch (cacheExtentStyle) {
      case CacheExtentStyle.pixel:
        _calculatedCacheExtent = cacheExtent;
        break;
      case CacheExtentStyle.viewport:
        _calculatedCacheExtent = mainAxisExtent * cacheExtent!;
        break;
    }

    final fullCacheExtent = mainAxisExtent + 2 * _calculatedCacheExtent!;
    final centerCacheOffset = centerOffset + _calculatedCacheExtent!;
    final reverseDirectionRemainingCacheExtent =
        centerCacheOffset.clamp(0.0, fullCacheExtent);
    final forwardDirectionRemainingCacheExtent =
        (fullCacheExtent - centerCacheOffset).clamp(0.0, fullCacheExtent);

    final leadingNegativeChild = childBefore(center!);

    if (leadingNegativeChild != null) {
      final result = layoutChildSequence(
        child: leadingNegativeChild,
        scrollOffset: math.max(mainAxisExtent, centerOffset) - mainAxisExtent,
        overlap: 0.0,
        layoutOffset: forwardDirectionRemainingPaintExtent,
        remainingPaintExtent: reverseDirectionRemainingPaintExtent,
        mainAxisExtent: mainAxisExtent,
        crossAxisExtent: crossAxisExtent,
        growthDirection: GrowthDirection.reverse,
        advance: childBefore,
        remainingCacheExtent: reverseDirectionRemainingCacheExtent,
        cacheOrigin: (mainAxisExtent - centerOffset)
            .clamp(-_calculatedCacheExtent!, 0.0),
      );
      if (result != 0.0) return -result;
    }

    return layoutChildSequence(
      child: center,
      scrollOffset: math.max(0.0, -centerOffset),
      overlap:
          leadingNegativeChild == null ? math.min(0.0, -centerOffset) : 0.0,
      layoutOffset: centerOffset >= mainAxisExtent
          ? centerOffset
          : reverseDirectionRemainingPaintExtent,
      remainingPaintExtent: forwardDirectionRemainingPaintExtent,
      mainAxisExtent: mainAxisExtent,
      crossAxisExtent: crossAxisExtent,
      growthDirection: GrowthDirection.forward,
      advance: childAfter,
      remainingCacheExtent: forwardDirectionRemainingCacheExtent,
      cacheOrigin: centerOffset.clamp(-_calculatedCacheExtent!, 0.0),
    );
  }

  @override
  bool get hasVisualOverflow => _hasVisualOverflow;

  @override
  void updateOutOfBandData(
      GrowthDirection growthDirection, SliverGeometry childLayoutGeometry) {
    switch (growthDirection) {
      case GrowthDirection.forward:
        _maxScrollExtent += childLayoutGeometry.scrollExtent;
        break;
      case GrowthDirection.reverse:
        _minScrollExtent -= childLayoutGeometry.scrollExtent;
        break;
    }
    if (childLayoutGeometry.hasVisualOverflow) _hasVisualOverflow = true;
    _shrinkWrapExtent += childLayoutGeometry.maxPaintExtent;
    growSize = _shrinkWrapExtent;
  }

  @override
  String labelForChild(int index) => 'child $index';
}

abstract class CustomViewport extends MultiChildRenderObjectWidget {
  CustomViewport({
    Key? key,
    this.axisDirection = AxisDirection.down,
    this.crossAxisDirection,
    this.anchor = 0.0,
    required this.offset,
    this.center,
    this.cacheExtent,
    this.cacheExtentStyle = CacheExtentStyle.pixel,
    this.clipBehavior = Clip.hardEdge,
    List<Widget> slivers = const <Widget>[],
  }) : super(key: key, children: slivers);

  final AxisDirection axisDirection;
  final AxisDirection? crossAxisDirection;
  final double anchor;
  final ViewportOffset offset;
  final Key? center;
  final double? cacheExtent;
  final CacheExtentStyle cacheExtentStyle;
  final Clip clipBehavior;

  @override
  CustomRenderViewport createRenderObject(BuildContext context);

  @override
  _ViewportElement createElement() => _ViewportElement(this);
}

class _ViewportElement extends MultiChildRenderObjectElement {
  _ViewportElement(CustomViewport widget) : super(widget);

  @override
  CustomViewport get widget => super.widget as CustomViewport;

  @override
  CustomRenderViewport get renderObject =>
      super.renderObject as CustomRenderViewport;

  @override
  void mount(Element? parent, dynamic newSlot) {
    super.mount(parent, newSlot);
    _updateCenter();
  }

  @override
  void update(MultiChildRenderObjectWidget newWidget) {
    super.update(newWidget);
    _updateCenter();
  }

  void _updateCenter() {
    if (widget.center != null) {
      renderObject.center = children
          .singleWhere((Element element) => element.widget.key == widget.center)
          .renderObject as RenderSliver?;
    } else if (children.isNotEmpty) {
      renderObject.center = children.first.renderObject as RenderSliver?;
    } else {
      renderObject.center = null;
    }
  }
}

class CustomSliverPhysicalContainerParentData
    extends SliverPhysicalContainerParentData {
  double? layoutOffset;
  GrowthDirection? growthDirection;
}

abstract class CustomRenderViewport
    extends RenderViewportBase<CustomSliverPhysicalContainerParentData> {
  CustomRenderViewport({
    AxisDirection axisDirection = AxisDirection.down,
    required AxisDirection crossAxisDirection,
    required ViewportOffset offset,
    double anchor = 0.0,
    List<RenderSliver>? children,
    RenderSliver? center,
    double? cacheExtent,
    CacheExtentStyle cacheExtentStyle = CacheExtentStyle.pixel,
    Clip clipBehavior = Clip.hardEdge,
  })  : _center = center,
        super(
          axisDirection: axisDirection,
          crossAxisDirection: crossAxisDirection,
          offset: offset,
          cacheExtent: cacheExtent,
          cacheExtentStyle: cacheExtentStyle,
          clipBehavior: clipBehavior,
        ) {
    addAll(children);
    if (center == null && firstChild != null) _center = firstChild;
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! CustomSliverPhysicalContainerParentData)
      child.parentData = CustomSliverPhysicalContainerParentData();
  }

  double get anchor;
  set anchor(double value);

  RenderSliver? get center => _center;
  RenderSliver? _center;

  set center(RenderSliver? value) {
    if (value == _center) return;
    _center = value;
    markNeedsLayout();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    return constraints.biggest;
  }

  late double _minScrollExtent;
  late double _maxScrollExtent;
  bool _hasVisualOverflow = false;

  double growSize = 0;

  @override
  bool get hasVisualOverflow => _hasVisualOverflow;

  @override
  void updateOutOfBandData(
      GrowthDirection growthDirection, SliverGeometry childLayoutGeometry) {
    switch (growthDirection) {
      case GrowthDirection.forward:
        _maxScrollExtent += childLayoutGeometry.scrollExtent;
        break;
      case GrowthDirection.reverse:
        _minScrollExtent -= childLayoutGeometry.scrollExtent;
        break;
    }
    if (childLayoutGeometry.hasVisualOverflow) _hasVisualOverflow = true;
  }

  @override
  void updateChildLayoutOffset(RenderSliver child, double layoutOffset,
      GrowthDirection growthDirection) {
    final CustomSliverPhysicalContainerParentData childParentData =
        child.parentData! as CustomSliverPhysicalContainerParentData;
    childParentData.layoutOffset = layoutOffset;
    childParentData.growthDirection = growthDirection;
  }

  @override
  Offset paintOffsetOf(RenderSliver child) {
    final CustomSliverPhysicalContainerParentData childParentData =
        child.parentData! as CustomSliverPhysicalContainerParentData;
    return computeAbsolutePaintOffset(
        child, childParentData.layoutOffset!, childParentData.growthDirection!);
  }

  @override
  double scrollOffsetOf(RenderSliver child, double scrollOffsetWithinChild) {
    assert(child.parent == this);
    final GrowthDirection growthDirection = child.constraints.growthDirection;
    switch (growthDirection) {
      case GrowthDirection.forward:
        double scrollOffsetToChild = 0.0;
        RenderSliver? current = center;
        while (current != child) {
          scrollOffsetToChild += current!.geometry!.scrollExtent;
          current = childAfter(current);
        }
        return scrollOffsetToChild + scrollOffsetWithinChild;
      case GrowthDirection.reverse:
        double scrollOffsetToChild = 0.0;
        RenderSliver? current = childBefore(center!);
        while (current != child) {
          scrollOffsetToChild -= current!.geometry!.scrollExtent;
          current = childBefore(current);
        }
        return scrollOffsetToChild - scrollOffsetWithinChild;
    }
  }

  @override
  double maxScrollObstructionExtentBefore(RenderSliver child) {
    assert(child.parent == this);
    final GrowthDirection growthDirection = child.constraints.growthDirection;
    switch (growthDirection) {
      case GrowthDirection.forward:
        double pinnedExtent = 0.0;
        RenderSliver? current = center;
        while (current != child) {
          pinnedExtent += current!.geometry!.maxScrollObstructionExtent;
          current = childAfter(current);
        }
        return pinnedExtent;
      case GrowthDirection.reverse:
        double pinnedExtent = 0.0;
        RenderSliver? current = childBefore(center!);
        while (current != child) {
          pinnedExtent += current!.geometry!.maxScrollObstructionExtent;
          current = childBefore(current);
        }
        return pinnedExtent;
    }
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    final Offset offset = paintOffsetOf(child as RenderSliver);
    transform.translate(offset.dx, offset.dy);
  }

  @override
  double computeChildMainAxisPosition(
      RenderSliver child, double parentMainAxisPosition) {
    final CustomSliverPhysicalContainerParentData childParentData =
        child.parentData! as CustomSliverPhysicalContainerParentData;
    switch (applyGrowthDirectionToAxisDirection(
        child.constraints.axisDirection, child.constraints.growthDirection)) {
      case AxisDirection.down:
      case AxisDirection.right:
        return parentMainAxisPosition - childParentData.layoutOffset!;
      case AxisDirection.up:
        return (size.height - parentMainAxisPosition) -
            childParentData.layoutOffset!;
      case AxisDirection.left:
        return (size.width - parentMainAxisPosition) -
            childParentData.layoutOffset!;
    }
  }

  @override
  int get indexOfFirstChild {
    assert(center != null);
    assert(center!.parent == this);
    assert(firstChild != null);
    int count = 0;
    RenderSliver? child = center;
    while (child != firstChild) {
      count -= 1;
      child = childBefore(child!);
    }
    return count;
  }

  @override
  String labelForChild(int index) {
    if (index == 0) return 'center child';
    return 'child $index';
  }

  @override
  Iterable<RenderSliver> get childrenInPaintOrder sync* {
    if (firstChild == null) return;
    RenderSliver? child = firstChild;
    while (child != center) {
      yield child!;
      child = childAfter(child);
    }
    child = lastChild;
    while (true) {
      yield child!;
      if (child == center) return;
      child = childBefore(child);
    }
  }

  @override
  Iterable<RenderSliver> get childrenInHitTestOrder sync* {
    if (firstChild == null) return;
    RenderSliver? child = center;
    while (child != null) {
      yield child;
      child = childAfter(child);
    }
    child = childBefore(center!);
    while (child != null) {
      yield child;
      child = childBefore(child);
    }
  }
}