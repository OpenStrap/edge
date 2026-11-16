# Guide capture tools

These widget-driver scripts produce review images or timing measurements. They are outside `test/` so CI runs behaviour checks without running capture jobs.

Run them through the project Boat runner, in a separate run directory for each shard. For example, from the owner machine:

```sh
/home/mini/Documents/repos/edge.research/bin/boat-run --sandbox SANDBOX_ID --name guide-capture WORKTREE -- bash -lc 'flutter pub get && flutter gen-l10n && GUIDE_SHOTS_DIR=/tmp/guide-shots flutter test --no-pub tool/guides/capture_activity.dart'
```

`capture_activity.dart` walks the eight main-screen guides with real pointer actions. `capture_markers.dart`, `capture_chrome.dart`, `capture_hand.dart` and `capture_phone.dart` use `GUIDE_RERENDER_DIR` instead. `profile_frames.dart` prints debug frame timings and needs no output directory. The captures are review artifacts, not golden baselines.

Run `python3 tool/guides/build_media.py OUTPUT_DIRECTORY` with ImageMagick available to turn the eight capture manifests into contact sheets and GIFs.
