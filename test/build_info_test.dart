import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/build_info.dart';

void main() {
  test('formats version and build information for the debug screen', () {
    const info = BuildInfo(
      version: '1.2.3',
      buildNumber: '42',
      commit: 'abc1234',
      buildType: 'release',
    );

    expect(info.versionLabel, 'PingPlace 1.2.3 (Build 42)');
    expect(info.commitLabel, 'Commit: abc1234');
    expect(info.buildTypeLabel, 'Build type: release');
  });

  test('uses the current package build number when no define is supplied', () {
    expect(BuildInfo.current.versionLabel, 'PingPlace 1.0.0 (Build 11)');
  });

  test('uses an explicit fallback when Git metadata is unavailable', () {
    const info = BuildInfo(
      version: '1.0.0',
      buildNumber: '11',
      commit: 'unknown',
      buildType: 'debug',
    );

    expect(info.commitLabel, 'Commit: unknown');
  });
}
