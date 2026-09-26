# Notice

Edge is an independent, open-source project (MIT License — see `LICENSE`). It
is not affiliated with, sponsored by, or endorsed by WHOOP, Inc. or any of its
trademarks.

No WHOOP source code, binaries, firmware, or copyrighted assets are included
in this repository. The Bluetooth protocol support in this project was
independently developed by observing the band's own Bluetooth communications;
see [the protocol repo's README](https://github.com/OpenStrap/protocol) for
methodology notes.

## wger exercise data

The generated exercise catalogue in
`lib/ui2/activity/wger_exercises.g.dart` contains selected fields from the
[wger](https://wger.de) exercise database. wger licenses the base exercise and
each translation separately. Each generated row therefore retains its source
UUID and every distinct author/license pair used by its base metadata, labels,
or aliases. Entries are individually available under CC BY-SA 3.0, CC BY-SA
4.0, or CC0; the applicable credits are recorded on that row. The picker links
each imported exercise to its exact public wger record, where the source,
license, and any author information supplied by wger can be inspected.

Edge adapts the source by selecting fields, normalizing whitespace, sorting
records, and omitting descriptions, notes, images, and videos. No exercise
content is fetched while the app is running.

The generated dataset is separate from Edge's MIT-licensed application code.
Refresh it with `dart run tool/update_wger_exercises.dart`; the importer rejects
an unfamiliar license rather than silently shipping it.
