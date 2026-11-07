import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/places/coordinates.dart';

void main() {
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

    test('ignores bidi marks around a typed value', () {
      expect(parseCoordinate('\u200F\u206631.7326\u2069\u200E'), 31.7326);
      expect(parseCoordinate('\u2066-34.5\u2069'), -34.5);
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
