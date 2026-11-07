import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/places/coordinates.dart';

void main() {
  group('parseCoordinatePair', () {
    GeoPoint ok(String input) {
      final result = parseCoordinatePair(input);
      expect(result.error, isNull, reason: input);
      return result.point!;
    }

    CoordinatePasteError fails(String input) {
      final result = parseCoordinatePair(input);
      expect(result.point, isNull, reason: input);
      return result.error!;
    }

    test('reads Google Maps order: latitude first, longitude second', () {
      final p = ok('31.732600, 34.757743');
      expect(p.latitude, 31.7326);
      expect(p.longitude, 34.757743);
    });

    test('never swaps: a longitude-first pair is rejected, not corrected', () {
      // 34.75 is a valid latitude, so this pair is read as given...
      final p = ok('34.757743, 31.732600');
      expect(p.latitude, 34.757743);
      // ...and a pair that is only valid when swapped is refused.
      expect(fails('120.5, 45.1'), CoordinatePasteError.latitudeOutOfRange);
    });

    test('keeps full precision', () {
      final p = ok('31.73260012345678, 34.75774398765432');
      expect(p.latitude, 31.73260012345678);
      expect(p.longitude, 34.75774398765432);
    });

    test('negative coordinates and the exact boundaries', () {
      expect(ok('-33.8688, -151.2093').longitude, -151.2093);
      expect(ok('-90, -180').latitude, -90);
      expect(ok('90, 180').longitude, 180);
      expect(ok('0,0').latitude, 0);
      expect(ok('+31.5,+34.5').longitude, 34.5);
    });

    test('out of range values name the offending coordinate', () {
      expect(fails('90.000001, 34'), CoordinatePasteError.latitudeOutOfRange);
      expect(fails('-91, 34'), CoordinatePasteError.latitudeOutOfRange);
      expect(fails('31, 180.5'), CoordinatePasteError.longitudeOutOfRange);
      expect(fails('31, -181'), CoordinatePasteError.longitudeOutOfRange);
    });

    test('malformed input is rejected', () {
      for (final input in [
        '31.7326',
        '31.7326 34.7577',
        '31,7326, 34,7577',
        '31.7, 34.7, 5',
        'NaN, 34',
        'Infinity, 34',
        '31.7, -Infinity',
        '1e1, 34',
        '0x1F, 34',
        '31°43\'57"N, 34°45\'28"E',
        'abc, def',
        '31.7,',
        ', 34.7',
      ]) {
        expect(fails(input), CoordinatePasteError.malformed, reason: input);
      }
      expect(fails('   '), CoordinatePasteError.empty);
    });

    test('links are refused and never scanned for numbers', () {
      for (final input in [
        'https://www.google.com/maps/@31.7326,34.7577,17z',
        'https://maps.app.goo.gl/AbCdEf123',
        'maps.app.goo.gl/xyz',
        'google.com/maps/place/31.7326,34.7577',
        'geo:31.7326,34.7577',
        'www.example.com/31.7,34.7',
      ]) {
        expect(
          fails(input),
          CoordinatePasteError.unsupportedLink,
          reason: input,
        );
      }
    });

    test('bidi marks added by an RTL copy are ignored', () {
      final p = ok('\u200F\u206631.7326, 34.7577\u2069\u200E');
      expect(p.latitude, 31.7326);
      expect(p.longitude, 34.7577);
    });
  });

  group('parseCoordinate and editorText', () {
    test('editor text round-trips every double exactly', () {
      for (final value in [
        31.73260012345678,
        -0.0000001,
        1e-7,
        179.99999999999997,
        -89.123456789012,
        0.1 + 0.2,
      ]) {
        expect(parseCoordinate(editorText(value)), value, reason: '$value');
      }
    });

    test('rejects non-finite and malformed values', () {
      for (final input in ['', 'NaN', 'Infinity', '-Infinity', '1,5', 'x']) {
        expect(parseCoordinate(input), isNull, reason: input);
      }
    });
  });

  group('GeoPoint', () {
    test('validates range and finiteness', () {
      expect(GeoPoint.tryCreate(double.nan, 0), isNull);
      expect(GeoPoint.tryCreate(0, double.infinity), isNull);
      expect(GeoPoint.tryCreate(90.0000001, 0), isNull);
      expect(GeoPoint.tryCreate(0, -180.0000001), isNull);
      expect(GeoPoint.tryCreate(-90, 180), isNotNull);
    });
  });

  group('display', () {
    test('pairs and values are LTR-isolated and labelled in order', () {
      expect(displayPair(31.7326, -34.5), '\u206631.732600, -34.500000\u2069');
      expect(displayCoordinate(-0.5), '\u2066-0.500000\u2069');
      expect(displayPair(31.7326, 34.5, decimals: 5), contains('31.73260, '));
    });

    test('display rounding never reaches the editor value', () {
      const value = 31.73260012345678;
      expect(displayCoordinate(value), contains('31.732600'));
      expect(editorText(value), '31.73260012345678');
    });
  });

  group('previewRadii', () {
    test('defaults to 300 m outer and 80 m inner', () {
      final r = previewRadii();
      expect(r.outer, 300);
      expect(r.inner, 80);
    });

    test('uses the editor radius, then the saved radius', () {
      expect(previewRadii(editorRadius: 450, savedOuterRadius: 300).outer, 450);
      expect(previewRadii(savedOuterRadius: 500).outer, 500);
      expect(
        previewRadii(editorRadius: double.nan, savedOuterRadius: 500).outer,
        500,
      );
    });

    test('inner follows the saved place, capped at the outer radius', () {
      expect(previewRadii(savedInnerRadius: 80).inner, 80);
      final small = previewRadii(editorRadius: 60, savedInnerRadius: 80);
      expect(small.outer, 60);
      expect(small.inner, 60);
    });
  });

  group('initialMapPoint', () {
    final saved = GeoPoint.tryCreate(31.66, 34.78);

    test('prefers valid editor values, then the saved place', () {
      expect(
        initialMapPoint(latitudeText: '32.1', longitudeText: '34.9'),
        GeoPoint.tryCreate(32.1, 34.9),
      );
      expect(
        initialMapPoint(
          latitudeText: 'abc',
          longitudeText: '34.9',
          saved: saved,
        ),
        saved,
      );
      expect(
        initialMapPoint(latitudeText: '95', longitudeText: '34', saved: saved),
        saved,
      );
    });

    test('a new place without coordinates has no initial point', () {
      expect(initialMapPoint(latitudeText: '', longitudeText: ''), isNull);
    });
  });
}
