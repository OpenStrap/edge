part of 'db.dart';

Future<void> _ldbCreateSessionCeilingRev(Database db) async {
  await db.execute('CREATE TABLE IF NOT EXISTS session_ceiling_rev ('
      'id INTEGER PRIMARY KEY CHECK (id = 1), rev INTEGER NOT NULL)');
  // Sparse legacy schemas get their sessions table during onOpen repair.
  final present = await db.rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sessions'",
  );
  if (present.isEmpty) return;
  await db.execute('''CREATE TRIGGER IF NOT EXISTS sessions_ceiling_ai
    AFTER INSERT ON sessions BEGIN
      INSERT INTO session_ceiling_rev(id, rev) SELECT 1, 0
        WHERE NOT EXISTS (SELECT 1 FROM session_ceiling_rev WHERE id = 1);
      UPDATE session_ceiling_rev SET rev = rev + 1 WHERE id = 1;
    END''');
  await db.execute('''CREATE TRIGGER IF NOT EXISTS sessions_ceiling_au
    AFTER UPDATE OF id, type, status, start_ts, end_ts ON sessions BEGIN
      INSERT INTO session_ceiling_rev(id, rev) SELECT 1, 0
        WHERE NOT EXISTS (SELECT 1 FROM session_ceiling_rev WHERE id = 1);
      UPDATE session_ceiling_rev SET rev = rev + 1 WHERE id = 1;
    END''');
  await db.execute('''CREATE TRIGGER IF NOT EXISTS sessions_ceiling_ad
    AFTER DELETE ON sessions BEGIN
      INSERT INTO session_ceiling_rev(id, rev) SELECT 1, 0
        WHERE NOT EXISTS (SELECT 1 FROM session_ceiling_rev WHERE id = 1);
      UPDATE session_ceiling_rev SET rev = rev + 1 WHERE id = 1;
    END''');
}
