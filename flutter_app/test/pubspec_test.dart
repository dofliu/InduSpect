import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// pubspec.yaml 的兩個守門。
///
/// 這兩件事都被人工犯過：
/// 1. `sort_pub_dependencies` 是本專案打開的 lint，但 `flutter:` / `flutter_test:`
///    兩個 sdk 相依習慣寫在最上面，而 linter 不看空行分段 —— 排序過的清單只要把
///    sdk 相依留在最上面，lint 就會紅在下一個相依那一行。
/// 2. 手動重排相依清單時掉了一個（`uuid`），這種掉件靠 analyze 抓不到，只有建置才會炸。
///    改成「lib/ 裡 import 得到的 package 都必須宣告」就能在測試階段擋下來。
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  final depLine = RegExp(r'^  ([a-z0-9_]+):');

  /// 取出某個 section 底下的相依名稱，順序即檔案順序。
  List<String> depsIn(String section) {
    final keys = <String>[];
    String? current;
    for (final raw in pubspec.split('\n')) {
      final line = raw.replaceAll('\r', '');
      if (line.isNotEmpty && !line.startsWith(' ') && line.trimRight().endsWith(':')) {
        final trimmed = line.trimRight();
        current = trimmed.substring(0, trimmed.length - 1);
        continue;
      }
      final match = depLine.firstMatch(line);
      if (match != null && current == section) {
        keys.add(match.group(1)!);
      }
    }
    return keys;
  }

  group('sort_pub_dependencies', () {
    for (final section in ['dependencies', 'dev_dependencies']) {
      test('$section 依字母排序（含 sdk 相依）', () {
        final keys = depsIn(section);
        expect(keys, isNotEmpty, reason: '$section 解析不到任何相依，解析邏輯壞了');
        final sorted = [...keys]..sort();
        expect(keys, sorted,
            reason: '$section 沒有依字母排序。sdk 相依（flutter / flutter_test）也算在裡面，'
                '不能為了慣例把它留在最上面。');
      });
    }

    test('flutter sdk 相依排在字母位置而不是最上面', () {
      final keys = depsIn('dependencies');
      expect(keys.indexOf('flutter'), greaterThan(0),
          reason: 'flutter 又被搬回 dependencies 最上面了，這會讓 lint 紅在下一行');
      expect(depsIn('dev_dependencies').indexOf('flutter_test'), greaterThan(0));
    });
  });

  group('相依宣告完整性', () {
    test('lib/ 裡 import 的每個 package 都在 pubspec 宣告過', () {
      final packageRef = RegExp(r'package:([a-z0-9_]+)/');
      final imported = <String>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final m in packageRef.allMatches(entity.readAsStringSync())) {
          imported.add(m.group(1)!);
        }
      }
      expect(imported, isNotEmpty, reason: 'lib/ 掃不到任何 package import，掃描邏輯壞了');

      final declared = <String>{...depsIn('dependencies'), ...depsIn('dev_dependencies')};
      // 自己的 package 名不會出現在相依裡。
      final missing = imported.difference(declared).difference({'induspect_ai'}).toList()
        ..sort();
      expect(missing, isEmpty,
          reason: '這些 package 有被 import 但沒宣告在 pubspec：$missing');
    });
  });
}
