/// Zero-setup Flutter app driver using VM Service evaluate().
///
/// Drives any Flutter app without app-side dependencies, custom bindings,
/// or ValueKeys. Finds widgets by type, text, tooltip — like a test finder.
/// Interacts via pointer event dispatch through evaluate().
library;

export 'src/app_driver.dart';
export 'src/app_launcher.dart';
export 'src/widget_handle.dart';
