# WHOOP freeze goldens

Byte-identical pins of everything the band path stores for three synthetic
days (gen4 and gen5, full profile, 14 seeded baseline days), one file per
family and timezone. Written by `test/whoop_freeze_golden_test.dart`; see its
header for how to run each zone and which branches (zone sources, saved-session
HR ceiling, a confirmed nap, review suggestions) it forces. CI runs all three
zones (`.github/workflows/test.yml`).

Regenerate (`GENERATE_GOLDEN=1`) only with owner approval. A failing golden
means a WHOOP number moved. Fix the change, not the golden.
