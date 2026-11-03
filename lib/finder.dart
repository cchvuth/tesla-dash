import 'dart:math';

import 'panda.dart';

/// Ways a tyre pressure is packed: raw * kPa per count + offset = kPa gauge.
/// Tesla's own is 0.025 bar a count; the rest are what tyre sensors use.
/// Few on purpose: every extra one lets random bytes look like tyres.
const kPressureCodes = <(String, double, double)>[
  ('0.025 bar', 2.5, 0),
  ('1 kPa', 1, 0),
  ('1 psi', 6.89476, 0),
  ('0.1 psi', 0.689476, 0),
  ('0.025 bar absolute', 2.5, -101.325),
];

/// One frame and field layout where the pressure turned up: per payload,
/// the start bits (Intel order, as the DBCs count) and the psi each read.
class PressureHit {
  PressureHit(this.id, this.bus, this.code, this.len, this.surprise);
  final int id, bus, len;
  final String code;

  /// How unlikely one field is to fit by chance: ln(2^len / raw values that
  /// fit). A loose encoding (21 of 512 raw values) earns less per match
  /// than a tight one (5 of 256).
  final double surprise;
  final byPage = <String, Map<int, double>>{};

  /// The strongest evidence, as (where, how much): fields side by side in
  /// one payload at a fixed stride, the way four wheels sit ('run
  /// start/stride'), or one field reading differently across payloads, a
  /// page per sensor ('field start'). Overlapping windows over random bytes
  /// make no run, and a constant byte that happens to fit is one reading.
  late final (String, int) evidence = () {
    var run = ('', 0);
    for (final starts in byPage.values) {
      for (final s0 in starts.keys) {
        for (final stride in {len, (len + 7) ~/ 8 * 8}) {
          var n = 0;
          while (starts.containsKey(s0 + n * stride)) {
            n++;
          }
          if (n > run.$2) run = ('run $s0/$stride', n);
        }
      }
    }
    final seen = <int, Set<int>>{};
    for (final starts in byPage.values) {
      for (final e in starts.entries) {
        (seen[e.key] ??= {}).add((e.value * 10).round());
      }
    }
    var field = ('', 0);
    for (final e in seen.entries) {
      if (e.value.length > field.$2) field = ('field ${e.key}', e.value.length);
    }
    return run.$2 >= field.$2 ? run : field;
  }();

  int get strength => evidence.$2;

  /// A run on byte boundaries and Tesla's own scale break ties: both are
  /// what the car's tyre frames use.
  double get score {
    final at = RegExp(r'run (\d+)/(\d+)').firstMatch(evidence.$1);
    final aligned = at != null && int.parse(at[1]!) % 8 == 0 && int.parse(at[2]!) % 8 == 0;
    return strength * 3 * surprise + (aligned ? 2 : 0) + (code == '0.025 bar' ? 1 : 0);
  }

  @override
  String toString() {
    final best = byPage.entries.reduce((a, b) => b.value.length > a.value.length ? b : a);
    final at = (best.value.keys.toList()..sort())
        .map((s) => '$s|$len ${best.value[s]!.toStringAsFixed(1)}')
        .join(', ');
    return '0x${id.toRadixString(16).toUpperCase().padLeft(3, '0')} bus $bus, $code: '
        '$at psi in ${best.key} (${evidence.$1} x$strength)';
  }
}

/// Every field, at every start bit and 8 to 10 bits long, in every recent
/// payload of every frame, that reads [lo]..[hi] psi in one of
/// [kPressureCodes]. Best candidates first.
List<PressureHit> findPressure(Map<int, Frame> frames, double lo, double hi) {
  final hits = <String, PressureHit>{};
  for (final e in frames.entries) {
    final f = e.value;
    for (final data in f.recent.isEmpty ? [f.data] : f.recent) {
      var word = 0;
      for (var i = 0; i < data.length && i < 8; i++) {
        word |= data[i] << (8 * i);
      }
      final bits = min(data.length, 8) * 8;
      for (final len in const [8, 9, 10]) {
        final mask = (1 << len) - 1;
        double surprise(double kpa, double offset) {
          final n = ((hi * 6.89476 - offset) / kpa).floor() -
              ((lo * 6.89476 - offset) / kpa).ceil() + 1;
          return log((mask + 1) / max(n, 1));
        }
        for (var start = 0; start + len <= bits; start++) {
          final raw = (word >>> start) & mask;
          if (raw == 0 || raw == mask) continue; // empty, or not available
          for (final (code, kpa, offset) in kPressureCodes) {
            final psi = (raw * kpa + offset) / 6.89476;
            if (psi < lo || psi > hi) continue;
            hits
                .putIfAbsent('${e.key}/$code/$len',
                    () => PressureHit(e.key, f.bus, code, len, surprise(kpa, offset)))
                .byPage
                .putIfAbsent(hexOf(data), () => {})[start] = psi;
          }
        }
      }
    }
  }
  return hits.values.toList()..sort((a, b) => b.score.compareTo(a.score));
}

/// [findPressure] run again and again while frames come in: a real tyre
/// frame keeps showing the same evidence in the same place, a payload that
/// fit by chance soon stops.
class PressureSearch {
  PressureSearch(this.lo, this.hi);
  final double lo, hi;
  int scans = 0;
  final _seen = <String, int>{};
  final _best = <String, PressureHit>{};

  void scan(Map<int, Frame> frames) {
    scans++;
    for (final h in findPressure(frames, lo, hi)) {
      if (h.strength < 2) continue; // a lone match is noise
      final k = '${h.id}/${h.code}/${h.len}/${h.evidence.$1}';
      _seen[k] = (_seen[k] ?? 0) + 1;
      if ((_best[k]?.score ?? -1) <= h.score) _best[k] = h;
    }
  }

  /// Best first: the same evidence in the most scans, then the strongest.
  List<(PressureHit, int)> get ranked {
    final r = [for (final k in _best.keys) (_best[k]!, _seen[k]!)];
    r.sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : b.$1.score.compareTo(a.$1.score));
    return r;
  }
}

/// Ways a route's distance and time to go may be packed: unit, km or
/// minutes per count.
const kDistanceCodes = <(String, double)>[
  ('m', 0.001), ('10 m', 0.01), ('0.1 km', 0.1), ('0.01 mi', 0.0160934),
  ('0.1 mi', 0.160934), ('ft', 0.0003048),
];
const kTimeCodes = <(String, double)>[('min', 1), ('0.1 min', 0.1), ('s', 1 / 60), ('10 s', 1 / 6)];

/// A field that read the route's start value, and what it read since.
class RouteField {
  RouteField(this.id, this.bus, this.page, this.start, this.len, this.kind, this.code, this.per);
  final int id, bus, page, start, len;
  final String kind, code; // 'distance' (km) or 'time' (min)
  final double per;
  double? first;
  final history = <double>[];
  int fits = 0, misses = 0;
  double err = 0; // summed |read - expected| / tolerance: how closely it tracked

  int get score => fits - 3 * misses;

  @override
  String toString() =>
      '0x${id.toRadixString(16).toUpperCase().padLeft(3, '0')} bus $bus page $page, '
      '$start|$len in $code: ${history.map((v) => v.toStringAsFixed(kind == 'time' ? 1 : 2)).join(' > ')} '
      '${kind == 'time' ? 'min' : 'km'} ($fits fit, $misses off)';
}

/// Finds where the car puts the route by watching it count down: at the
/// start, every field that reads the route's distance or time to go in a
/// common encoding is noted; as the car drives, each is read again and
/// kept only while it falls as the drive says it should. A constant or a
/// random field soon misses; the route's own fields keep fitting. Also
/// looks for the destination's name as text.
class RouteSearch {
  RouteSearch({required this.km, required this.minutes, required this.name});
  final double km, minutes;
  final String name;
  final fields = <String, RouteField>{};
  final names = <String>{}; // where pieces of the name turned up
  bool _started = false;

  static int _page(List<int> d) => d.isEmpty ? 0 : d[0] & 7;

  /// [kmDriven] and [minutesGone] since the search started.
  void scan(Map<int, Frame> frames, double kmDriven, double minutesGone) {
    final expectKm = km - kmDriven, expectMin = minutes - minutesGone;
    final grams = {
      for (final w in name.toLowerCase().split(RegExp(r'\s+')))
        for (var i = 0; i + 4 <= w.length; i++) w.substring(i, i + 4),
    };
    for (final e in frames.entries) {
      final f = e.value;
      final seenPages = <int>{};
      for (final data in (f.recent.isEmpty ? [f.data] : f.recent).reversed) {
        final text = String.fromCharCodes(data.map((b) => b >= 0x20 && b < 0x7f ? b : 0x2e)).toLowerCase();
        for (final g in grams) {
          if (text.contains(g)) {
            names.add('0x${e.key.toRadixString(16).toUpperCase()} bus ${f.bus}: "$text" ($g)');
          }
        }
        final page = _page(data);
        if (!seenPages.add(page)) continue; // newest payload of each page only
        var word = 0;
        for (var i = 0; i < data.length && i < 8; i++) {
          word |= data[i] << (8 * i);
        }
        final bits = min(data.length, 8) * 8;
        for (var len = 8; len <= 16; len++) {
          final mask = (1 << len) - 1;
          for (var start = 0; start + len <= bits; start++) {
            final raw = (word >>> start) & mask;
            if (raw == 0 || raw == mask) continue;
            for (final (kind, codes, want, tol) in [
              ('distance', kDistanceCodes, expectKm, max(0.12 * km, 0.25)),
              ('time', kTimeCodes, expectMin, 1.2),
            ]) {
              for (final (code, per) in codes) {
                final v = raw * per;
                final key = '${e.key}/$page/$start/$len/$code';
                final off = (v - want).abs() / tol;
                if (!_started) {
                  if (off <= 1) {
                    fields[key] = RouteField(e.key, f.bus, page, start, len, kind, code, per)
                      ..first = v
                      ..history.add(v)
                      ..fits = 1
                      ..err = off;
                  }
                } else if (fields[key] case final rf?) {
                  if (rf.history.last != v) rf.history.add(v);
                  off <= 1 ? rf.fits++ : rf.misses++;
                  rf.err += min(off, 3.0);
                }
              }
            }
          }
        }
      }
    }
    _started = true;
  }

  /// Where the route is, best first: one entry per frame, page and kind,
  /// each the reading of it that changed, missed least and tracked the
  /// countdown most closely. (The same bits read through another encoding
  /// or a wider window are that same source.)
  List<RouteField> get ranked {
    final best = <String, RouteField>{};
    for (final f in fields.values) {
      if (f.history.length < 2 || f.fits <= f.misses * 3) continue;
      final k = '${f.id}/${f.page}/${f.kind}';
      final b = best[k];
      if (b == null ||
          f.score > b.score ||
          (f.score == b.score && (f.err < b.err || (f.err == b.err && f.len < b.len)))) {
        best[k] = f;
      }
    }
    return best.values.toList()
      ..sort((a, b) => a.score != b.score ? b.score.compareTo(a.score) : a.err.compareTo(b.err));
  }
}
