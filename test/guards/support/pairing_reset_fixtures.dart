// Fixtures for the reset-steps guard. Taken from the research, not from the
// registry: edge.research/design/pairing-ux-research/vendor-urls.md (checked
// 2026-11-05). Changing a value here is a reviewed edit.

/// The reviewed official host per registry entry id (the host of the URL in
/// vendor-urls.md). An entry's resetSteps.officialUrl must have exactly this
/// host. Entries absent here have no reviewed host: they are either in the NONE
/// set below or a research gap (see [kResearchGapIds]).
const Map<String, String> kPinnedOfficialHost = <String, String>{
  'gen4': 'support.whoop.com', // WHOOP 4.0 row
  'gen5': 'www.community.whoop.com', // WHOOP 5.0 / MG row
  'polar_pmd': 'support.polar.com', // OH1 / Verity Sense (the H-series is not this entry)
  'oura': 'support.ouraring.com',
  'ultrahuman': 'www.ultrahuman.com',
  'coros': 'support.coros.com',
  'miband234': 'www.mi.com',
  'pebble': 'help.repebble.com',
  'colmi': 'www.colmi.com',
  'garmin': 'support.garmin.com',
  'miscale_bc': 'www.mi.com', // Mi Body Composition Scale row
  'miscale2': 'www.mi.com', // Mi Smart Scale 2 row
};

/// Exact reviewed URLs where a wrong page was found in review.
/// The host pin above cannot tell a right page from a wrong one on the same host.
const Map<String, String> kPinnedOfficialUrl = <String, String>{
  // OH1 / Verity Sense reset page. The old page was the H9/H10 one (battery
  // removal), and this entry excludes the H-series.
  'polar_pmd': 'https://support.polar.com/en/how-can-i-reset-my-sensor',
  // Xiaomi's general official support page. The old link was the S400 FAQ, a
  // different product with model-specific reset-button steps.
  'miscale_bc': 'https://www.mi.com/global/support/',
};

/// The 13 devices vendor-urls.md marks NONE (no official site), by research
/// name, with the registry id where this registry has one (null: the device is
/// not a registry entry on this branch).
const Map<String, String?> kResearchNoneDevices = <String, String?>{
  'Smart ring R11M/R10M': null,
  'Lefun-protocol bands': null,
  'DaFit / MOYOUNG watches': null,
  'WearFit bands': null,
  'Jyou bands': null,
  'HPlus HR band': null,
  'ID115': null,
  'Makibes HR3': null,
  'TLW64 / NO1 F1': null,
  'Watch9': null,
  'XWatch': null,
  'DT78 / DT92 / DT66': null,
  'Generic "Bluetooth thermometer"': 'thermometer',
};

/// Registry ids vendor-urls.md has no row for. Not invented here; a human
/// decides (pinned host, or noOfficialSite with a reason, and the NONE set).
const Set<String> kResearchGapIds = <String>{'ble_hrs'};

/// Registry entries whose reset help is NOT device-specific (unverified or
/// noOfficialSite) and so need a human to source steps. SHRINK-ONLY: it is a
/// registered ratchet (test/guards/support/ratchets.dart, id
/// pairing_reset_followup, snapshot test/guards/ratchet_counts.json). Zero is
/// allowed and is the goal. Exact membership is checked against the registry.
const Set<String> kPairingFollowUp = <String>{
  'gen4',
  'ble_hrs',
  'oura',
  'polar_pmd',
  'coros',
  'ultrahuman',
  'miband234',
  'pebble',
  'colmi',
  'garmin',
  'thermometer',
  'miscale_bc',
  'miscale2',
};
