// Check of a vendor help URL against the entry's pinned official host.

/// Null when [url] is acceptable for an entry whose reviewed host is
/// [pinnedHost]; otherwise a short reason. Acceptable: https, parseable, host
/// equal to [pinnedHost] (case-insensitive), no userinfo.
String? resetUrlProblem(String url, {required String pinnedHost}) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme) return 'not a URL';
  if (u.scheme != 'https') return 'not https';
  if (u.host.isEmpty) return 'no host';
  if (u.userInfo.isNotEmpty) return 'has userinfo';
  if (u.host.toLowerCase() != pinnedHost.toLowerCase()) {
    return 'host ${u.host} is not the pinned $pinnedHost';
  }
  return null;
}
