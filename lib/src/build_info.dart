final class BuildInfo {
  const BuildInfo({
    required this.version,
    required this.buildNumber,
    required this.commit,
    required this.buildType,
  });

  static const current = BuildInfo(
    version: String.fromEnvironment(
      'PINGPLACE_APP_VERSION',
      defaultValue: '1.0.0',
    ),
    buildNumber: String.fromEnvironment(
      'PINGPLACE_BUILD_NUMBER',
      defaultValue: '14',
    ),
    commit: String.fromEnvironment(
      'PINGPLACE_GIT_SHA',
      defaultValue: 'unknown',
    ),
    buildType: String.fromEnvironment(
      'PINGPLACE_BUILD_TYPE',
      defaultValue: 'debug',
    ),
  );

  final String version;
  final String buildNumber;
  final String commit;
  final String buildType;

  String get versionLabel => 'PingPlace $version (Build $buildNumber)';

  String get commitLabel => 'Commit: $commit';

  String get buildTypeLabel => 'Build type: $buildType';
}