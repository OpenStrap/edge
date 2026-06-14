// AppStatus — the payload of GET /app/status: an optional OTA update pointer and
// an optional admin-pushed home-screen alert banner. Parsed defensively; any
// missing field collapses to null so a partial/blank config never crashes.

class UpdateInfo {
  final String? latestVersion; // "0.3.0" (display only)
  final int latestBuild;       // monotonic build number; compared to ours
  final String? apkUrl;        // signed-APK download URL
  final String? notes;         // what's new
  final int minBuild;          // clients below this MUST update

  const UpdateInfo({
    this.latestVersion,
    required this.latestBuild,
    this.apkUrl,
    this.notes,
    this.minBuild = 0,
  });

  static UpdateInfo? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final build = (j['latest_build'] as num?)?.toInt();
    if (build == null) return null; // no version published → no update info
    return UpdateInfo(
      latestVersion: j['latest_version'] as String?,
      latestBuild: build,
      apkUrl: j['apk_url'] as String?,
      notes: j['notes'] as String?,
      minBuild: (j['min_build'] as num?)?.toInt() ?? 0,
    );
  }
}

enum BannerLevel { info, warn, critical }

BannerLevel _level(String? s) {
  switch (s) {
    case 'critical':
      return BannerLevel.critical;
    case 'warn':
      return BannerLevel.warn;
    default:
      return BannerLevel.info;
  }
}

class BannerInfo {
  final String id;        // stable key so a dismissed banner stays dismissed
  final String? title;
  final String text;
  final BannerLevel level; // critical → not dismissible
  final String? actionUrl; // optional tap-through link

  const BannerInfo({
    required this.id,
    this.title,
    required this.text,
    this.level = BannerLevel.info,
    this.actionUrl,
  });

  bool get dismissible => level != BannerLevel.critical;

  static BannerInfo? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final text = (j['text'] as String?)?.trim() ?? '';
    if (text.isEmpty && (j['title'] as String?)?.trim().isEmpty != false) return null;
    return BannerInfo(
      id: (j['id'] ?? '').toString(),
      title: j['title'] as String?,
      text: text,
      level: _level(j['level'] as String?),
      actionUrl: j['action_url'] as String?,
    );
  }
}

class AppStatus {
  final UpdateInfo? update;
  final BannerInfo? banner;
  const AppStatus({this.update, this.banner});

  static AppStatus fromJson(Map<String, dynamic> j) => AppStatus(
        update: UpdateInfo.fromJson((j['update'] as Map?)?.cast<String, dynamic>()),
        banner: BannerInfo.fromJson((j['banner'] as Map?)?.cast<String, dynamic>()),
      );
}
