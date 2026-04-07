/// A reference to a widget found in the running app's element tree.
///
/// Holds the position needed for interaction. Obtained via [AppDriver] finders.
final class WidgetHandle {
  const WidgetHandle({
    required this.type,
    required this.x,
    required this.y,
    this.text,
    this.key,
    this.tooltip,
  });

  /// Widget runtimeType name.
  final String type;

  /// Center position in global coordinates.
  final double x;
  final double y;

  /// Text content if available (for Text widgets or buttons with labels).
  final String? text;

  /// ValueKey string if available.
  final String? key;

  /// Tooltip message if available.
  final String? tooltip;

  @override
  String toString() => 'WidgetHandle($type at ($x, $y)'
      '${text != null ? ', text: "$text"' : ''}'
      '${key != null ? ', key: "$key"' : ''})';
}
