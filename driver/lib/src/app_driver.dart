import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'app_launcher.dart';
import 'widget_handle.dart';

/// Drives a running Flutter app via VM Service evaluate().
///
/// Zero app-side setup required. Works on any Flutter debug app.
///
/// ```dart
/// final driver = await AppDriver.launch('/path/to/app');
/// final button = await driver.findByType('FloatingActionButton');
/// await driver.tap(button);
/// final text = await driver.readText(await driver.findByText('0'));
/// await driver.dispose();
/// ```
final class AppDriver {
  AppDriver._({
    required VmService service,
    required String isolateId,
    required String rootLibId,
    required String gestureLibId,
    AppLauncher? launcher,
  })  : _service = service,
        _isolateId = isolateId,
        _rootLibId = rootLibId,
        _gestureLibId = gestureLibId,
        _launcher = launcher;

  final VmService _service;
  final String _isolateId;
  final String _rootLibId;
  final String _gestureLibId;
  final AppLauncher? _launcher;
  int _nextPointerId = 1;
  bool _connected = true;

  /// Whether the driver is connected to a running app.
  bool get isConnected => _connected;

  // ── Factory constructors ──────────────────────────────────────────────────

  /// Launch a Flutter app and connect to it.
  static Future<AppDriver> launch(
    String packagePath, {
    String device = 'macos',
    String? target,
    String flutterCommand = 'puro',
  }) async {
    final launcher = await AppLauncher.launch(
      packagePath,
      device: device,
      target: target,
      flutterCommand: flutterCommand,
    );
    final driver = await connect(launcher.vmServiceUri, launcher: launcher);
    return driver;
  }

  /// Connect to an already-running Flutter app via VM Service URI.
  static Future<AppDriver> connect(
    String vmServiceUri, {
    AppLauncher? launcher,
  }) async {
    final wsUri = _toWebSocketUri(vmServiceUri);
    final service = await vmServiceConnectUri(wsUri);
    final isolateId = await _findMainIsolate(service);
    final isolate = await service.getIsolate(isolateId);
    final rootLibId = isolate.rootLib!.id!;
    final gestureLibId = await _findGestureLib(service, isolateId);

    final driver = AppDriver._(
      service: service,
      isolateId: isolateId,
      rootLibId: rootLibId,
      gestureLibId: gestureLibId,
      launcher: launcher,
    );

    await driver._waitForReady();
    return driver;
  }

  // ── Finders ───────────────────────────────────────────────────────────────

  /// Find a widget by its runtimeType name.
  Future<WidgetHandle> findByType(String typeName) async {
    final result = await _eval(
      _rootLibId,
      '(() { String? r; '
      'void v(Element e) { '
      'if (r != null) return; '
      'if (e.widget.runtimeType.toString() == \'$typeName\') { '
      'final box = e.renderObject! as RenderBox; '
      'final c = box.localToGlobal(box.size.center(Offset.zero)); '
      'r = \'\${c.dx},\${c.dy}\'; return; } '
      'e.visitChildren(v); } '
      'v(WidgetsBinding.instance.rootElement!); '
      'return r ?? \'NOT_FOUND\'; })()',
    );
    return _parseHandle(result, typeName);
  }

  /// Find a widget by its exact text content.
  Future<WidgetHandle> findByText(String text) async {
    final escaped = _escape(text);
    final result = await _eval(
      _rootLibId,
      '(() { String? r; '
      'void v(Element e) { '
      'if (r != null) return; '
      'if (e.widget is Text && (e.widget as Text).data == \'$escaped\') { '
      'final box = e.renderObject! as RenderBox; '
      'final c = box.localToGlobal(box.size.center(Offset.zero)); '
      'r = \'\${c.dx},\${c.dy}\'; return; } '
      'e.visitChildren(v); } '
      'v(WidgetsBinding.instance.rootElement!); '
      'return r ?? \'NOT_FOUND\'; })()',
    );
    return _parseHandle(result, 'Text', text: text);
  }

  /// Find a widget whose text contains [substring].
  Future<WidgetHandle> findByTextContaining(String substring) async {
    final escaped = _escape(substring);
    final result = await _eval(
      _rootLibId,
      '(() { String? r; String? t; '
      'void v(Element e) { '
      'if (r != null) return; '
      'if (e.widget is Text && (e.widget as Text).data != null '
      '&& (e.widget as Text).data!.contains(\'$escaped\')) { '
      'final box = e.renderObject! as RenderBox; '
      'final c = box.localToGlobal(box.size.center(Offset.zero)); '
      'r = \'\${c.dx},\${c.dy}\'; t = (e.widget as Text).data; return; } '
      'e.visitChildren(v); } '
      'v(WidgetsBinding.instance.rootElement!); '
      'return r ?? \'NOT_FOUND\'; })()',
    );
    return _parseHandle(result, 'Text', text: substring);
  }

  /// Find a widget by its tooltip message.
  Future<WidgetHandle> findByTooltip(String message) async {
    final escaped = _escape(message);
    final result = await _eval(
      _rootLibId,
      '(() { String? r; '
      'void v(Element e) { '
      'if (r != null) return; '
      'if (e.widget is Tooltip && (e.widget as Tooltip).message == \'$escaped\') { '
      'final box = e.renderObject! as RenderBox; '
      'final c = box.localToGlobal(box.size.center(Offset.zero)); '
      'r = \'\${c.dx},\${c.dy}\'; return; } '
      'e.visitChildren(v); } '
      'v(WidgetsBinding.instance.rootElement!); '
      'return r ?? \'NOT_FOUND\'; })()',
    );
    return _parseHandle(result, 'Tooltip', tooltip: message);
  }

  /// Find a widget by its ValueKey<String>.
  Future<WidgetHandle> findByKey(String key) async {
    final result = await _eval(
      _rootLibId,
      '(() { String? r; String? typeName; '
      'void v(Element e) { '
      'if (r != null) return; '
      'if (e.widget.key == const ValueKey(\'$key\')) { '
      'final box = e.renderObject! as RenderBox; '
      'final c = box.localToGlobal(box.size.center(Offset.zero)); '
      'typeName = e.widget.runtimeType.toString(); '
      'r = \'\${c.dx},\${c.dy}\'; return; } '
      'e.visitChildren(v); } '
      'v(WidgetsBinding.instance.rootElement!); '
      'return r != null ? \'\$typeName|\$r\' : \'NOT_FOUND\'; })()',
    );
    if (result == 'NOT_FOUND') {
      throw WidgetNotFoundError('No widget with key "$key"');
    }
    final parts = result.split('|');
    final coords = parts[1].split(',');
    return WidgetHandle(
      type: parts[0],
      x: double.parse(coords[0]),
      y: double.parse(coords[1]),
      key: key,
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /// Tap a widget at its center position.
  Future<void> tap(WidgetHandle handle) async {
    final id = _nextPointerId++;
    // Temporarily override FlutterError.onError during gesture dispatch.
    // Flutter's StackFrame parser cannot handle evaluate() stack frames,
    // so any error during dispatch would crash the parser rather than
    // reporting the actual error.
    await _eval(
      _gestureLibId,
      '(() { '
      'final prev = FlutterError.onError; '
      'FlutterError.onError = (d) {}; '
      'try { '
      'final b = GestureBinding.instance; '
      'final p = Offset(${handle.x}, ${handle.y}); '
      'b.handlePointerEvent('
      'PointerAddedEvent(pointer: $id, position: p)); '
      'b.handlePointerEvent('
      'PointerDownEvent(pointer: $id, position: p)); '
      'b.handlePointerEvent('
      'PointerUpEvent(pointer: $id, position: p)); '
      'b.handlePointerEvent('
      'PointerRemovedEvent(pointer: $id, position: p)); '
      '} finally { FlutterError.onError = prev; } '
      'return \'ok\'; })()',
    );
    await waitForIdle();
  }

  /// Tap a widget found by type. Convenience for `tap(await findByType(...))`.
  Future<void> tapType(String typeName) async =>
      tap(await findByType(typeName));

  /// Tap a widget found by text. Convenience for `tap(await findByText(...))`.
  Future<void> tapText(String text) async => tap(await findByText(text));

  /// Type text into a TextField found by its ValueKey.
  Future<void> typeText(String key, String value) async {
    final escaped = _escape(value);
    // Setting controller.text triggers ChangeNotifier which may cause
    // Flutter's StackFrame parser to crash on Eval stack frames.
    // The text IS set regardless — so we catch and ignore the eval error.
    try {
      await _eval(
        _rootLibId,
        '(() { '
        'bool done = false; '
        'void v(Element e) { '
        'if (done) return; '
        'if (e.widget.key == const ValueKey(\'$key\') && e.widget is TextField) { '
        '(e.widget as TextField).controller?.text = \'$escaped\'; '
        'done = true; return; } '
        'e.visitChildren(v); } '
        'v(WidgetsBinding.instance.rootElement!); '
        'return done; })()',
      );
    } on DriverEvalError catch (e) {
      // Ignore StackFrame parser errors — the operation succeeded.
      if (!e.message.contains('stack_frame.dart')) rethrow;
    }
    await waitForIdle();
  }

  /// Scroll by dragging from center of screen in the given direction.
  ///
  /// [dx] and [dy] are the drag distances in logical pixels.
  /// Negative [dy] scrolls down (content moves up), positive scrolls up.
  /// [steps] controls how many intermediate move events are sent.
  Future<void> scroll({double dx = 0, double dy = -300, int steps = 20}) async {
    final id = _nextPointerId++;
    // Get screen center for the drag start point.
    final centerStr = await _eval(
      _rootLibId,
      '(() { '
      'final view = WidgetsBinding.instance.platformDispatcher.views.first; '
      'final size = view.physicalSize / view.devicePixelRatio; '
      'return \'\${size.width / 2},\${size.height / 2}\'; '
      '})()',
    );
    final parts = centerStr.split(',');
    final cx = double.parse(parts[0]);
    final cy = double.parse(parts[1]);

    final sw = Stopwatch()..start();

    // Pointer down
    await _pointerEvent(id, 'PointerAddedEvent', cx, cy,
        timestampMs: sw.elapsedMilliseconds);
    await _pointerEvent(id, 'PointerDownEvent', cx, cy,
        timestampMs: sw.elapsedMilliseconds);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Move in separate evaluate calls with real delays between them.
    for (var i = 1; i <= steps; i++) {
      final moveX = cx + dx * i / steps;
      final moveY = cy + dy * i / steps;
      await _pointerEvent(id, 'PointerMoveEvent', moveX, moveY,
          timestampMs: sw.elapsedMilliseconds);
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    // Pointer up
    await _pointerEvent(id, 'PointerUpEvent', cx + dx, cy + dy,
        timestampMs: sw.elapsedMilliseconds);
    await _pointerEvent(id, 'PointerRemovedEvent', cx + dx, cy + dy,
        timestampMs: sw.elapsedMilliseconds);
    await waitForIdle();
  }

  /// Dispatch a single pointer event with timestamp.
  Future<void> _pointerEvent(
    int pointerId,
    String eventType,
    double x,
    double y, {
    int timestampMs = 0,
  }) async {
    try {
      await _eval(
        _gestureLibId,
        '(() { '
        'final prev = FlutterError.onError; '
        'FlutterError.onError = (d) {}; '
        'try { '
        'GestureBinding.instance.handlePointerEvent('
        '$eventType(pointer: $pointerId, position: Offset($x, $y), '
        'timeStamp: Duration(milliseconds: $timestampMs))); '
        '} finally { FlutterError.onError = prev; } '
        'return \'ok\'; })()',
      );
    } on DriverEvalError catch (e) {
      if (!e.message.contains('stack_frame.dart')) rethrow;
    }
  }

  // ── Reading ───────────────────────────────────────────────────────────────

  /// Read the text content of a Text widget by finding it with a matcher.
  ///
  /// [matcher] is an evaluate expression fragment that returns true/false
  /// for a given Element `e`. Example: finding numeric text.
  Future<String?> readText(WidgetHandle handle) async {
    // Re-find the widget at the handle's position and read its text.
    final result = await _eval(
      _rootLibId,
      '(() { String? r; '
      'void v(Element e) { '
      'if (r != null) return; '
      'if (e.widget is Text) { '
      'final box = e.renderObject as RenderBox?; '
      'if (box != null) { '
      'final c = box.localToGlobal(box.size.center(Offset.zero)); '
      'if ((c.dx - ${handle.x}).abs() < 1 && (c.dy - ${handle.y}).abs() < 1) { '
      'r = (e.widget as Text).data; return; } } } '
      'e.visitChildren(v); } '
      'v(WidgetsBinding.instance.rootElement!); '
      'return r ?? \'NOT_FOUND\'; })()',
    );
    return result == 'NOT_FOUND' ? null : result;
  }

  /// Read the text of the first Text widget matching a predicate.
  Future<String?> readFirstTextWhere({
    bool numericOnly = false,
    String? contains,
  }) async {
    String condition;
    if (numericOnly) {
      condition = 'int.tryParse(t) != null';
    } else if (contains != null) {
      condition = 't.contains(\'${_escape(contains)}\')';
    } else {
      condition = 'true';
    }

    final result = await _eval(
      _rootLibId,
      '(() { String? r; '
      'void v(Element e) { '
      'if (r != null) return; '
      'if (e.widget is Text) { '
      'final t = (e.widget as Text).data; '
      'if (t != null && ($condition)) { r = t; return; } } '
      'e.visitChildren(v); } '
      'v(WidgetsBinding.instance.rootElement!); '
      'return r ?? \'NOT_FOUND\'; })()',
    );
    return result == 'NOT_FOUND' ? null : result;
  }

  // ── Screenshots ───────────────────────────────────────────────────────────

  /// Take a screenshot of the running app using the widget tree dump.
  ///
  /// Saves to [outputPath] (defaults to a temp file) and returns the path.
  Future<String?> screenshot({String? outputPath}) async {
    try {
      // Use ext.flutter.debugDumpApp for a text snapshot of the widget tree.
      // For a visual PNG, we use the inspector's screenshot extension.
      final result = await _service.callServiceExtension(
        'ext.flutter.inspector.screenshot',
        isolateId: _isolateId,
        args: {
          'id': await _getRootWidgetId(),
          'width': '800.0',
          'height': '600.0',
          'margin': '0.0',
          'maxPixelRatio': '2.0',
          'debugPaint': 'false',
        },
      );
      final imageData = result.json?['screenshot'] as String?;
      if (imageData == null) return null;

      final path = outputPath ??
          '${Directory.systemTemp.path}/craft_screenshot_'
              '${DateTime.now().millisecondsSinceEpoch}.png';

      // imageData is base64-encoded PNG
      final bytes = base64Decode(imageData);
      await File(path).writeAsBytes(bytes);
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<String> _getRootWidgetId() async {
    try {
      final result = await _service.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetSummaryTree',
        isolateId: _isolateId,
        args: {'groupName': 'craft_driver'},
      );
      return result.json?['valueId'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  // ── Hot Reload ────────────────────────────────────────────────────────────

  /// Trigger hot reload on the running app.
  Future<bool> hotReload() async {
    try {
      final isolate = await _service.getIsolate(_isolateId);
      final extensions = isolate.extensionRPCs ?? [];
      if (extensions.contains('ext.flutter.reassemble')) {
        await _service.callServiceExtension(
          'ext.flutter.reassemble',
          isolateId: _isolateId,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Disconnect from the app and kill the process if launched by this driver.
  Future<void> dispose() async {
    _connected = false;
    await _service.dispose();
    _launcher?.kill();
  }

  // ── MCP-compatible methods ─────────────────────────────────────────────

  /// Health check — returns status info about the connection.
  Future<Map<String, dynamic>> health() async {
    try {
      final hasRoot = await _eval(
        _rootLibId,
        'WidgetsBinding.instance.rootElement != null',
      );
      return {
        'status': 'ok',
        'driver': 'evaluate',
        'rootElementExists': hasRoot == 'true',
      };
    } catch (e) {
      return {'status': 'error', 'message': '$e'};
    }
  }

  /// Tap by text, key, or coordinates — MCP-compatible interface.
  ///
  /// Returns a result map with tapped status.
  Future<Map<String, dynamic>> tapMcp({
    String? text,
    String? key,
    double? x,
    double? y,
  }) async {
    try {
      WidgetHandle handle;
      if (text != null) {
        handle = await findByText(text);
      } else if (key != null) {
        handle = await findByKey(key);
      } else if (x != null && y != null) {
        handle = WidgetHandle(type: 'coordinate', x: x, y: y);
      } else {
        return {'tapped': false, 'error': 'Provide text, key, or x/y'};
      }
      await tap(handle);
      return {'tapped': true, 'position': '${handle.x}, ${handle.y}'};
    } catch (e) {
      return {'tapped': false, 'error': '$e'};
    }
  }

  /// List all interactive elements — MCP-compatible interface.
  ///
  /// Uses a universal approach: detects interactivity by checking for
  /// GestureDetector/InkWell with non-null callbacks, type-name heuristics,
  /// and hit-test validation. Works with any widget framework (Material,
  /// Cupertino, fluent_ui, custom).
  Future<Map<String, dynamic>> getInteractiveElements() async {
    final result = await _eval(
      _rootLibId,
      '(() { '
      'final els = <String>[]; '
      'final seen = <String>{}; '  // Deduplicate by position.
      // Interactivity check: callback-based + type-name heuristic.
      'bool isInteractive(Widget w) { '
      'if (w is GestureDetector && (w.onTap != null || w.onLongPress != null || w.onDoubleTap != null)) return true; '
      'final t = w.runtimeType.toString(); '
      // Skip private/internal framework widgets.
      'if (t.startsWith(\'_\') || t == \'RawGestureDetector\' || '
      't == \'Listener\') return false; '
      // Type name heuristics — catches Material, Cupertino, fluent_ui, custom.
      'if (t.endsWith(\'Button\') || t.endsWith(\'Field\') || '
      't.endsWith(\'Checkbox\') || t.endsWith(\'Switch\') || '
      't.endsWith(\'Slider\') || t.endsWith(\'Radio\') || '
      't.endsWith(\'Toggle\') || t == \'ListTile\' || '
      't.contains(\'TextField\') || t.contains(\'DropdownButton\') || '
      't.contains(\'PopupMenu\') || t.contains(\'NavigationDestination\')) return true; '
      'return false; '
      '} '
      'void v(Element e) { '
      'if (els.length >= 50) return; '
      'final w = e.widget; '
      'if (isInteractive(w)) { '
      'final box = e.renderObject as RenderBox?; '
      'if (box != null && box.hasSize && box.attached) { '
      'try { '
      'final pos = box.localToGlobal(Offset.zero); '
      'final size = box.size; '
      // Deduplicate by rounded position.
      'final posKey = \'\${pos.dx.round()},\${pos.dy.round()}\'; '
      'if (seen.contains(posKey)) { e.visitChildren(v); return; } '
      'seen.add(posKey); '
      // Extract text from subtree.
      'String? text; String? key; '
      'if (w.key is ValueKey) key = (w.key as ValueKey).value?.toString(); '
      'void ft(Element c) { if (text != null) return; '
      'if (c.widget is Text) { text = (c.widget as Text).data; return; } '
      'c.visitChildren(ft); } '
      'e.visitChildren(ft); '
      'final t = w.runtimeType.toString(); '
      // Compact format: truncate text to 20 chars to avoid valueAsString limit.
      'final tx = (text ?? \'\').length > 20 ? text!.substring(0, 20) : (text ?? \'\'); '
      'els.add(\'\$t|\$tx|\${key ?? ""}|'
      '\${pos.dx.toInt()}|\${pos.dy.toInt()}|'
      '\${size.width.toInt()}|\${size.height.toInt()}\'); '
      '} catch (_) {} '
      '} } '
      'e.visitChildren(v); } '
      'v(WidgetsBinding.instance.rootElement!); '
      'return els.join(\'\\n\'); '
      '})()',
    );

    final elements = <Map<String, dynamic>>[];
    if (result.isNotEmpty) {
      for (final line in result.split('\n')) {
        final parts = line.split('|');
        if (parts.length >= 7) {
          elements.add({
            'type': parts[0],
            'text': parts[1].isEmpty ? null : parts[1],
            'key': parts[2].isEmpty ? null : parts[2],
            'x': double.tryParse(parts[3]) ?? 0,
            'y': double.tryParse(parts[4]) ?? 0,
            'width': double.tryParse(parts[5]) ?? 0,
            'height': double.tryParse(parts[6]) ?? 0,
          });
        }
      }
    }

    return {'elements': elements, 'count': elements.length};
  }

  /// Evaluate an arbitrary Dart expression in the app's root library scope.
  ///
  /// Returns the string result. Useful for debugging and custom queries.
  Future<String> debugEval(String expression) => _eval(_rootLibId, expression);

  /// Wait until the framework has no more scheduled frames.
  Future<void> waitForIdle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        final busy = await _eval(
          _rootLibId,
          'WidgetsBinding.instance.hasScheduledFrame',
        );
        if (busy == 'false') return;
      } catch (_) {
        // Framework still busy — wait and retry.
      }
    }
  }

  // ── Private ───────────────────────────────────────────────────────────────

  Future<String> _eval(String libId, String expr) async {
    final result = await _service.evaluate(_isolateId, libId, expr);
    if (result is InstanceRef) {
      // valueAsString is truncated at 128 chars. Fetch full value if needed.
      final short = result.valueAsString;
      if (short != null &&
          result.valueAsStringIsTruncated == true &&
          result.id != null) {
        final full = await _service.getObject(_isolateId, result.id!);
        if (full is Instance) {
          return full.valueAsString ?? short;
        }
      }
      return short ?? result.classRef?.name ?? 'null';
    }
    if (result is ErrorRef) {
      throw DriverEvalError(result.message ?? 'Unknown evaluate error');
    }
    return result.toString();
  }

  Future<void> _waitForReady() async {
    for (var i = 0; i < 60; i++) {
      try {
        final r = await _service.callServiceExtension(
          'ext.flutter.didSendFirstFrameRasterizedEvent',
          isolateId: _isolateId,
        );
        if (r.json?['enabled'] == true || r.json?['enabled'] == 'true') {
          return;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  WidgetHandle _parseHandle(
    String result,
    String typeName, {
    String? text,
    String? tooltip,
    String? key,
  }) {
    if (result == 'NOT_FOUND') {
      throw WidgetNotFoundError(
        'No widget found: type=$typeName'
        '${text != null ? ', text="$text"' : ''}'
        '${tooltip != null ? ', tooltip="$tooltip"' : ''}'
        '${key != null ? ', key="$key"' : ''}',
      );
    }
    final coords = result.split(',');
    return WidgetHandle(
      type: typeName,
      x: double.parse(coords[0]),
      y: double.parse(coords[1]),
      text: text,
      tooltip: tooltip,
      key: key,
    );
  }

  static String _escape(String s) => s.replaceAll("'", "\\'");

  static String _toWebSocketUri(String uri) {
    var w = uri;
    if (w.startsWith('http://')) w = 'ws://${w.substring(7)}';
    if (w.startsWith('https://')) w = 'wss://${w.substring(8)}';
    if (!w.endsWith('/ws')) w = w.endsWith('/') ? '${w}ws' : '$w/ws';
    return w;
  }

  static Future<String> _findMainIsolate(VmService service) async {
    final vm = await service.getVM();
    for (final ref in vm.isolates ?? <IsolateRef>[]) {
      final iso = await service.getIsolate(ref.id!);
      if ((iso.extensionRPCs ?? []).contains('ext.flutter.reassemble')) {
        return ref.id!;
      }
    }
    return vm.isolates!.first.id!;
  }

  static Future<String> _findGestureLib(
    VmService service,
    String isolateId,
  ) async {
    final iso = await service.getIsolate(isolateId);
    for (final lib in iso.libraries ?? <LibraryRef>[]) {
      if (lib.uri == 'package:flutter/src/gestures/binding.dart') {
        return lib.id!;
      }
    }
    for (final lib in iso.libraries ?? <LibraryRef>[]) {
      if (lib.uri == 'package:flutter/src/widgets/binding.dart') {
        return lib.id!;
      }
    }
    return iso.rootLib!.id!;
  }
}

/// Thrown when a widget cannot be found in the element tree.
final class WidgetNotFoundError implements Exception {
  const WidgetNotFoundError(this.message);
  final String message;

  @override
  String toString() => 'WidgetNotFoundError: $message';
}

/// Thrown when an evaluate() expression fails to compile or execute.
final class DriverEvalError implements Exception {
  const DriverEvalError(this.message);
  final String message;

  @override
  String toString() => 'DriverEvalError: $message';
}
