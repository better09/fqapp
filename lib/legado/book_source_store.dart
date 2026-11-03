import 'dart:convert';

import 'package:hive_ce/hive.dart';

import '../services/encrypted_hive.dart';
import 'book_source.dart';

/// 书源的本地列表。页面测试可以换成内存实现。
abstract class BookSourceRepository {
  Future<List<LegadoBookSource>> load();
  Future<void> save(List<LegadoBookSource> sources);
}

class MemoryBookSourceRepository implements BookSourceRepository {
  List<LegadoBookSource> items;
  MemoryBookSourceRepository([List<LegadoBookSource>? items])
    : items = items ?? [];

  @override
  Future<List<LegadoBookSource>> load() async => items;

  @override
  Future<void> save(List<LegadoBookSource> sources) async {
    items = sources;
  }
}

class HiveBookSourceRepository implements BookSourceRepository {
  static const boxName = 'book_sources';
  Box<dynamic>? _box;

  Future<Box<dynamic>> _open() async {
    return _box ??= await EncryptedHive.openBox<dynamic>(Hive, boxName);
  }

  @override
  Future<List<LegadoBookSource>> load() async {
    final box = await _open();
    final raw = box.get('sources');
    if (raw is! String || raw.trim().isEmpty) return const [];
    try {
      return parseBookSources(raw);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(List<LegadoBookSource> sources) async {
    final box = await _open();
    await box.put(
      'sources',
      jsonEncode(sources.map((source) => source.raw).toList()),
    );
  }
}
