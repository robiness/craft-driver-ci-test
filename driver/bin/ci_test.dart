/// CI regression test — runs against a real Flutter app.
///
/// Exit codes: 0 = pass, 1 = fail, 2 = launch error
///
/// macOS:  dart run bin/ci_test.dart ../app
/// Linux:  xvfb-run dart run bin/ci_test.dart ../app
import 'dart:io';

import 'package:craft_driver_ci/craft_driver.dart';

int _passed = 0;
int _failed = 0;
final _failures = <String>[];

void main(List<String> args) async {
  final packagePath = args.isNotEmpty ? args.first : '../app';
  final device = args.length > 1 ? args[1] : _defaultDevice();
  final stopwatch = Stopwatch()..start();

  stderr.writeln('CI Test: launching $packagePath on $device ...');
  final AppDriver driver;
  try {
    driver = await AppDriver.launch(
      packagePath,
      device: device,
      flutterCommand: _flutterCommand(),
    );
  } catch (e) {
    stderr.writeln('FATAL: $e');
    exit(2);
  }
  stderr.writeln('CI Test: connected in ${stopwatch.elapsedMilliseconds}ms\n');

  // ── Tests ─────────────────────────────────────────────────────────────

  await _test('Home screen has buttons', () async {
    await driver.findByText('Open Form');
    await driver.findByText('Open List');
  });

  await _test('Navigate to Form', () async {
    await driver.tapText('Open Form');
    await driver.findByText('Submit');
  });

  await _test('Type name', () async {
    await driver.typeText('name_field', 'CI User');
  });

  await _test('Type email', () async {
    await driver.typeText('email_field', 'ci@test.dev');
  });

  await _test('Submit and verify result', () async {
    await driver.tapText('Submit');
    final result = await driver.readFirstTextWhere(contains: 'Name:');
    _assert(result != null, 'Result not found');
    _assert(result!.contains('CI User'), 'Name missing: $result');
    _assert(result.contains('ci@test.dev'), 'Email missing: $result');
  });

  await _test('Navigate back', () async {
    final back = await driver.findByTooltip('Back');
    await driver.tap(back);
    await driver.findByText('Open Form');
  });

  await _test('Navigate to List', () async {
    await driver.tapText('Open List');
    await driver.findByTextContaining('Item 1');
  });

  await _test('Scroll list', () async {
    await driver.scroll(dy: -400);
  });

  await _test('Navigate back from List', () async {
    final back = await driver.findByTooltip('Back');
    await driver.tap(back);
    await driver.findByText('Open Form');
  });

  // ── Report ────────────────────────────────────────────────────────────

  stopwatch.stop();
  stderr.writeln('\n${'=' * 40}');
  stderr.writeln('Passed: $_passed  Failed: $_failed  Time: ${stopwatch.elapsedMilliseconds}ms');

  if (_failures.isNotEmpty) {
    stderr.writeln('Failures:');
    for (final f in _failures) {
      stderr.writeln('  ✗ $f');
    }
  }

  stderr.writeln('${'=' * 40}');

  await driver.dispose();
  exit(_failed > 0 ? 1 : 0);
}

String _defaultDevice() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isWindows) return 'windows';
  return 'macos';
}

String _flutterCommand() {
  // Use puro if available, else flutter directly
  final puroResult = Process.runSync('which', ['puro']);
  return puroResult.exitCode == 0 ? 'puro' : 'flutter';
}

Future<void> _test(String name, Future<void> Function() body) async {
  try {
    await body();
    _passed++;
    stderr.writeln('  ✓ $name');
  } catch (e) {
    _failed++;
    _failures.add('$name: $e');
    stderr.writeln('  ✗ $name: $e');
  }
}

void _assert(bool condition, String message) {
  if (!condition) throw StateError(message);
}
