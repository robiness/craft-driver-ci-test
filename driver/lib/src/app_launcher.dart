import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Launches a Flutter app and extracts the VM Service URI.
final class AppLauncher {
  AppLauncher._({
    required this.vmServiceUri,
    required this.process,
  });

  /// The VM Service WebSocket URI for connecting.
  final String vmServiceUri;

  /// The running Flutter app process.
  final Process process;

  /// Launch a Flutter app with `flutter run --machine` and wait for the
  /// VM Service URI.
  ///
  /// [packagePath] is the root directory of the Flutter project.
  /// [device] defaults to `macos`.
  /// [target] is the entry point file, defaults to `lib/main.dart`.
  /// [flutterCommand] defaults to `puro` (Craft convention).
  static Future<AppLauncher> launch(
    String packagePath, {
    String device = 'macos',
    String? target,
    String flutterCommand = 'puro',
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final args = [
      if (flutterCommand == 'puro') 'flutter',
      'run',
      '-d', device,
      if (target != null) ...['--target', target],
      '--machine',
    ];

    final process = await Process.start(
      flutterCommand,
      args,
      workingDirectory: packagePath,
    );

    final vmServiceUri = await _parseVmServiceUri(process, timeout);
    return AppLauncher._(vmServiceUri: vmServiceUri, process: process);
  }

  /// Kill the running app.
  void kill() => process.kill();

  static Future<String> _parseVmServiceUri(
    Process process,
    Duration timeout,
  ) {
    final completer = Completer<String>();
    final wsUriPattern = RegExp(r'"wsUri"\s*:\s*"([^"]+)"');

    process.stdout.transform(utf8.decoder).listen((data) {
      for (final line in data.split('\n')) {
        if (completer.isCompleted) return;
        final m = wsUriPattern.firstMatch(line);
        if (m != null) {
          completer.complete(m.group(1)!);
          return;
        }
      }
    });

    // Consume stderr to prevent blocking.
    process.stderr.transform(utf8.decoder).listen((_) {});

    return completer.future.timeout(timeout, onTimeout: () {
      process.kill();
      throw TimeoutException(
        'No VM Service URI found after ${timeout.inSeconds}s',
      );
    });
  }
}
