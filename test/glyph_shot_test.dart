// Renders the hand-drawn glyphs large and at button size. GLYPH_SHOT=<file>.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tesla_dash/glyphs.dart';

void main() {
  testWidgets('glyphs', (t) async {
    final key = GlobalKey();
    t.view.physicalSize = const Size(840, 600); // room for a row more as glyphs are added
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: Container(
          color: Colors.black,
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Wrap(spacing: 24, runSpacing: 20, children: [
              for (final g in Glyph.values) GlyphIcon(g, size: 96, color: Colors.white),
            ]),
            const SizedBox(height: 24),
            // At button size, off and lit.
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final lit in [false, true])
                for (final g in Glyph.values)
                  Container(
                    width: 52,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: lit ? const Color(0xFF9CD3FF) : null,
                      border: Border.all(
                          color: lit ? const Color(0xFF9CD3FF) : Colors.white70),
                    ),
                    child: GlyphIcon(g, size: 24, color: lit ? Colors.black : Colors.white),
                  ),
            ]),
          ]),
        ),
      ),
    ));
    final out = Platform.environment['GLYPH_SHOT'];
    if (out == null) return;
    await t.runAsync(() async {
      final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
          .toImage(pixelRatio: 1);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
