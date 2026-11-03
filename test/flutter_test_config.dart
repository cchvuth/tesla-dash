// flutter test runs this around every test file in this folder: each one
// gets the real fonts before its first test.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUpAll(_loadRealFont);
  await testMain();
}

/// Tests default to Ahem, which draws every glyph as a filled square and
/// makes the renders useless for judging layout. Load a real face instead.
Future<void> _loadRealFont() async {
  // The icon font too, from the Flutter SDK the test runs on: tests otherwise
  // draw every icon as a box. (The app ships its own copy in the APK.)
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path &&
      !Directory('${dir.path}/material_fonts').existsSync()) {
    dir = dir.parent;
  }
  final icons = File('${dir.path}/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync()))))
        .load();
  }
  for (final path in [
    '/System/Library/Fonts/Supplemental/Arial.ttf',
    '/System/Library/Fonts/Supplemental/Helvetica.ttf',
    '/System/Library/Fonts/Supplemental/Verdana.ttf',
  ]) {
    final f = File(path);
    if (!f.existsSync()) continue;
    final bytes = ByteData.sublistView(f.readAsBytesSync());
    // 'Ahem' too: CustomPainter text does not read the theme, so overriding
    // the test default is the only way to see painted labels realistically.
    await (FontLoader('Roboto')..addFont(Future.value(bytes))).load();
    return;
  }
}
