// Revision DDL executes here so schema creation stays additive and cheap.
part of 'db.dart';

Future<void> _ldbCreateInputRev(Database db) async {
  await db.execute(
    'CREATE TABLE IF NOT EXISTS input_rev ('
    'bucket INTEGER PRIMARY KEY, rev INTEGER NOT NULL)',
  );
  if ((await db.rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'decoded_onehz'",
  )).isNotEmpty) {
    await db.execute('''CREATE TRIGGER IF NOT EXISTS decoded_onehz_rev_ai
      AFTER INSERT ON decoded_onehz WHEN NEW.rec_ts IS NOT NULL AND NEW.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT NEW.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = NEW.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = NEW.rec_ts / 900;
      END''');
    await db.execute('''CREATE TRIGGER IF NOT EXISTS decoded_onehz_rev_au
      AFTER UPDATE ON decoded_onehz WHEN NEW.rec_ts IS NOT NULL AND NEW.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT NEW.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = NEW.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = NEW.rec_ts / 900;
      END''');
    await db.execute('''CREATE TRIGGER IF NOT EXISTS decoded_onehz_rev_au_old
      AFTER UPDATE ON decoded_onehz WHEN OLD.rec_ts IS NOT NULL AND OLD.rec_ts > 0 AND (NEW.rec_ts IS NULL OR NEW.rec_ts <= 0 OR NEW.rec_ts / 900 != OLD.rec_ts / 900)
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT OLD.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = OLD.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = OLD.rec_ts / 900;
      END''');
    await db.execute('''CREATE TRIGGER IF NOT EXISTS decoded_onehz_rev_ad
      AFTER DELETE ON decoded_onehz WHEN OLD.rec_ts IS NOT NULL AND OLD.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT OLD.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = OLD.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = OLD.rec_ts / 900;
      END''');
  }
  if ((await db.rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'decoded_rr'",
  )).isNotEmpty) {
    await db.execute('''CREATE TRIGGER IF NOT EXISTS decoded_rr_rev_ai
      AFTER INSERT ON decoded_rr WHEN NEW.rec_ts IS NOT NULL AND NEW.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT NEW.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = NEW.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = NEW.rec_ts / 900;
      END''');
    await db.execute('''CREATE TRIGGER IF NOT EXISTS decoded_rr_rev_au
      AFTER UPDATE ON decoded_rr WHEN NEW.rec_ts IS NOT NULL AND NEW.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT NEW.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = NEW.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = NEW.rec_ts / 900;
      END''');
    await db.execute('''CREATE TRIGGER IF NOT EXISTS decoded_rr_rev_au_old
      AFTER UPDATE ON decoded_rr WHEN OLD.rec_ts IS NOT NULL AND OLD.rec_ts > 0 AND (NEW.rec_ts IS NULL OR NEW.rec_ts <= 0 OR NEW.rec_ts / 900 != OLD.rec_ts / 900)
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT OLD.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = OLD.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = OLD.rec_ts / 900;
      END''');
    await db.execute('''CREATE TRIGGER IF NOT EXISTS decoded_rr_rev_ad
      AFTER DELETE ON decoded_rr WHEN OLD.rec_ts IS NOT NULL AND OLD.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT OLD.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = OLD.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = OLD.rec_ts / 900;
      END''');
  }
}
