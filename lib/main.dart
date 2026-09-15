import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.instance.database;
  runApp(MyApp(repository: NotesRepository(db)));
}

class Note {
  final String id;
  final String title;
  final String content;
  final DateTime updatedAt;
  final bool synced;

  const Note({
    required this.id,
    required this.title,
    required this.content,
    required this.updatedAt,
    required this.synced,
  });

  Map<String, Object?> toDb() => {
        'id': id,
        'title': title,
        'content': content,
        'updated_at': updatedAt.toIso8601String(),
        'synced': synced ? 1 : 0,
      };

  factory Note.fromDb(Map<String, Object?> map) => Note(
        id: map['id'] as String,
        title: map['title'] as String,
        content: map['content'] as String,
        updatedAt: DateTime.parse(map['updated_at'] as String),
        synced: (map['synced'] as int) == 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'updated_at': updatedAt.toIso8601String(),
      };
}

class AppDatabase {
  AppDatabase._();
  static final instance = AppDatabase._();
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), 'notes.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            synced INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
    return _db!;
  }
}

class NotesRepository {
  final Database db;
  final Uuid uuid = const Uuid();

  // Change this to your deployed API URL later.
  static const apiBaseUrl = 'https://example.com/api';

  NotesRepository(this.db);

  Future<List<Note>> all() async {
    final rows = await db.query('notes', orderBy: 'updated_at DESC');
    return rows.map(Note.fromDb).toList();
  }

  Future<void> save({required String title, required String content, String? id}) async {
    final note = Note(
      id: id ?? uuid.v4(),
      title: title,
      content: content,
      updatedAt: DateTime.now().toUtc(),
      synced: false,
    );
    await db.insert('notes', note.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> unsyncedCount() async {
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM notes WHERE synced = 0');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> sync() async {
    final rows = await db.query('notes', where: 'synced = 0');
    if (rows.isEmpty) return 0;

    final notes = rows.map(Note.fromDb).toList();
    final response = await http.post(
      Uri.parse('$apiBaseUrl/sync'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'notes': notes.map((n) => n.toJson()).toList()}),
    ).timeout(const Duration(seconds: 8));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      for (final note in notes) {
        await db.update(
          'notes',
          {'synced': 1},
          where: 'id = ?',
          whereArgs: [note.id],
        );
      }
      return notes.length;
    }
    throw Exception('Server returned ${response.statusCode}');
  }
}

class MyApp extends StatelessWidget {
  final NotesRepository repository;
  const MyApp({super.key, required this.repository});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'My Notes',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.orange),
      home: NotesPage(repository: repository),
    );
  }
}

class NotesPage extends StatefulWidget {
  final NotesRepository repository;
  const NotesPage({super.key, required this.repository});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  List<Note> notes = [];
  bool online = false;
  bool syncing = false;
  String message = '';

  @override
  void initState() {
    super.initState();
    _load();
    Connectivity().onConnectivityChanged.listen((result) {
      if (!mounted) return;
      setState(() => online = result.any((r) => r != ConnectivityResult.none));
    });
    _checkConnectivity();
  }

  Future<void> _checkConnectivity() async {
    final result = await Connectivity().checkConnectivity();
    if (mounted) setState(() => online = result.any((r) => r != ConnectivityResult.none));
  }

  Future<void> _load() async {
    notes = await widget.repository.all();
    if (mounted) setState(() {});
  }

  Future<void> _sync() async {
    if (!online || syncing) return;
    setState(() {
      syncing = true;
      message = '';
    });
    try {
      final count = await widget.repository.sync();
      await _load();
      if (mounted) setState(() => message = '$count note(s) synced');
    } catch (e) {
      if (mounted) setState(() => message = 'Sync failed. Local data is safe.');
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> _openEditor([Note? note]) async {
    final title = TextEditingController(text: note?.title ?? '');
    final content = TextEditingController(text: note?.content ?? '');
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(note == null ? 'New Note' : 'Edit Note'),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
            const SizedBox(height: 12),
            TextField(
              controller: content,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Note'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (title.text.trim().isEmpty) return;
              await widget.repository.save(
                id: note?.id,
                title: title.text.trim(),
                content: content.text.trim(),
              );
              if (context.mounted) Navigator.pop(context, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == true) {
      await _load();
      if (online) _sync();
    }
  }

  Future<void> _delete(Note note) async {
    await widget.repository.delete(note.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Notes'),
        actions: [
          IconButton(
            tooltip: 'Sync',
            onPressed: online ? _sync : null,
            icon: syncing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Row(children: [
                Icon(Icons.circle, size: 11, color: online ? Colors.green : Colors.grey),
                const SizedBox(width: 6),
                Text(online ? 'Online' : 'Offline'),
              ]),
            ),
          ),
        ],
      ),
      body: Column(children: [
        if (message.isNotEmpty)
          MaterialBanner(
            content: Text(message),
            actions: [TextButton(onPressed: () => setState(() => message = ''), child: const Text('OK'))],
          ),
        Expanded(
          child: notes.isEmpty
              ? const Center(child: Text('No notes yet. Tap + to create one.'))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: notes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    return Card(
                      child: ListTile(
                        title: Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(note.content, maxLines: 2, overflow: TextOverflow.ellipsis),
                        leading: Icon(note.synced ? Icons.cloud_done : Icons.cloud_off),
                        onTap: () => _openEditor(note),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(note),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('New Note'),
      ),
    );
  }
}
