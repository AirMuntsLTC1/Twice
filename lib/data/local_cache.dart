import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Durable per-device cache. Cached data is account-scoped so one account
/// cannot accidentally display another account's private feed after logout.
class LocalCache {
  LocalCache._();
  static final LocalCache instance = LocalCache._();
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final base = await getDatabasesPath();
    _database = await openDatabase(
      p.join(base, 'twice_local_cache.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE cache (cache_key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)');
        await db.execute('CREATE TABLE outbox (id TEXT PRIMARY KEY, account_id TEXT NOT NULL, operation TEXT NOT NULL, payload TEXT NOT NULL, created_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT)');
        await db.execute('CREATE INDEX outbox_account_created ON outbox(account_id, created_at)');
      },
    );
    return _database!;
  }

  /// Opens the database in the background so queries execute immediately.
  Future<void> prewarm() async {
    try {
      await database;
    } catch (_) {}
  }

  String _key(String account, String type, [String id = '']) => '$account:$type:$id';

  Future<void> put(String account, String type, dynamic value, {String id = ''}) async {
    final db = await database;
    await db.insert('cache', {
      'cache_key': _key(account, type, id),
      'value': jsonEncode(value),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<dynamic> get(String account, String type, {String id = ''}) async {
    final db = await database;
    final rows = await db.query('cache', where: 'cache_key = ?', whereArgs: [_key(account, type, id)], limit: 1);
    if (rows.isEmpty) return null;
    try { return jsonDecode(rows.first['value']! as String); } catch (_) { return null; }
  }

  Future<void> enqueue(String account, String operation, Map<String, dynamic> payload) async {
    final db = await database;
    final id = operation == 'set_like'
        ? 'set_like:$account:${payload['post_id']}'
        : operation == 'set_saved'
            ? 'set_saved:$account:${payload['post_id']}'
            : '${DateTime.now().microsecondsSinceEpoch}_${payload['id'] ?? ''}';
    await db.transaction((txn) async {
      if (operation == 'set_like' || operation == 'set_saved') {
        await txn.delete(
          'outbox',
          where: 'account_id = ? AND operation = ? AND id = ?',
          whereArgs: [account, operation, id],
        );
      }
      await txn.insert(
        'outbox',
        {
          'id': id,
          'account_id': account,
          'operation': operation,
          'payload': jsonEncode(payload),
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<Map<String, dynamic>>> pending(String account) async {
    final db = await database;
    final rows = await db.query('outbox', where: 'account_id = ?', whereArgs: [account], orderBy: 'created_at ASC');
    return rows.map((r) => {...r, 'payload': jsonDecode(r['payload']! as String) as Map<String, dynamic>}).toList();
  }

  Future<void> removePending(String id) async => (await database).delete('outbox', where: 'id = ?', whereArgs: [id]);
  Future<void> markFailed(String id, Object error) async => (await database).rawUpdate('UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE id = ?', [error.toString(), id]);

  /// Purges old cache entries beyond maxAge to prevent unbounded disk growth.
  Future<void> pruneOldCacheEntries({Duration maxAge = const Duration(days: 30)}) async {
    try {
      final db = await database;
      final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
      await db.delete('cache', where: 'updated_at < ?', whereArgs: [cutoff]);
    } catch (_) {}
  }

  /// Purge user-scoped cache on logout to avoid cross-account data leakage.
  Future<void> clearAccount(String account) async {
    final db = await database;
    await db.delete('cache', where: 'cache_key LIKE ?', whereArgs: ['$account:%']);
    await db.delete('outbox', where: 'account_id = ?', whereArgs: [account]);
  }
}
