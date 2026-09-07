import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_geometry_compare.dart';

/// 三片互比的**方向性**（`geometry.py::compare_metric` 的 `direction`）。
///
/// 這件事只有聲音層需要，而搞錯的後果是結論完全反過來：某片的寬頻位準比另兩片
/// **低**不代表它有問題，若不限方向，最安靜的那片會被標成前緣侵蝕。
///
/// 兩個容易漏掉的細節都有測：
/// ①有方向時「離群者」是最高（最低）那片，不是離中位數最遠那片——兩片往相反方向
///   偏時這兩者不同；②z 照樣算完才被方向性否決，因為現場看到「差很多卻沒報」時，
///   那個 z 是唯一的線索。
void main() {
  group('both（預設）', () {
    test('離群者是離中位數最遠那片，兩個方向都標記', () {
      final low = BladeGeometryCompare.compareMetric(
          'm', [10.0, 0.0, 10.5], 1.0);
      expect(low.flagged, isTrue);
      expect(low.outlierIndex, 1);

      final high = BladeGeometryCompare.compareMetric(
          'm', [10.0, 30.0, 10.5], 1.0);
      expect(high.flagged, isTrue);
      expect(high.outlierIndex, 1);
      expect(high.direction, MetricDirection.both);
    });
  });

  group('high：只有偏高才算徵兆', () {
    test('偏高 → 標記', () {
      final c = BladeGeometryCompare.compareMetric(
          'band_level_db', [0.0, 4.0, 0.2], 0.8,
          direction: MetricDirection.high);
      expect(c.flagged, isTrue);
      expect(c.outlierIndex, 1);
      expect(c.outlierDeviation, greaterThan(0));
    });

    test('偏低 → **不**標記，但 z 照樣算出來', () {
      final c = BladeGeometryCompare.compareMetric(
          'band_level_db', [0.0, -4.0, 0.2], 0.8,
          direction: MetricDirection.high);
      expect(c.flagged, isFalse,
          reason: '比另兩片安靜不是缺陷——這是這個參數存在的唯一理由');
      expect(c.z.isFinite, isTrue, reason: 'z 不能因為方向不對就變 NaN');
      expect(c.z, greaterThan(0.0));
    });

    test('兩片往相反方向偏時，抓的是最吵的那片而不是偏離最多的', () {
      // 中位數是 0；−9 離中位數最遠，但缺陷徵兆是 +5 那片
      final c = BladeGeometryCompare.compareMetric(
          'band_level_db', [0.0, 5.0, -9.0], 0.8,
          direction: MetricDirection.high);
      expect(c.outlierIndex, 1, reason: 'high 模式要指向最高的那片');
      expect(c.outlierDeviation, greaterThan(0));

      // 同一組數字在 both 模式下會指向 −9 那片
      final both =
          BladeGeometryCompare.compareMetric('m', [0.0, 5.0, -9.0], 0.8);
      expect(both.outlierIndex, 2);
    });
  });

  group('low：只有偏低才算徵兆', () {
    test('偏低 → 標記；偏高 → 不標記', () {
      final lo = BladeGeometryCompare.compareMetric('m', [0.0, -4.0, 0.2], 0.8,
          direction: MetricDirection.low);
      expect(lo.flagged, isTrue);
      expect(lo.outlierIndex, 1);

      final hi = BladeGeometryCompare.compareMetric('m', [0.0, 4.0, 0.2], 0.8,
          direction: MetricDirection.low);
      expect(hi.flagged, isFalse);
    });
  });

  group('與方向無關的既有守門仍然成立', () {
    test('三片都散開時不標記（差距要明顯大於另兩片彼此差）', () {
      final c = BladeGeometryCompare.compareMetric(
          'band_level_db', [0.0, 6.0, 3.0], 0.5,
          direction: MetricDirection.high);
      // 6 與另兩片平均 1.5 差 4.5，但另兩片彼此差 3.0 → 4.5 < 2×3.0
      expect(c.flagged, isFalse);
      expect(c.z, greaterThan(3.0), reason: 'z 過門檻，是被 spread 條件擋掉的');
    });

    test('NaN 不參與；可用值少於兩個時不標記', () {
      final c = BladeGeometryCompare.compareMetric(
          'm', [double.nan, 4.0, double.nan], 0.5,
          direction: MetricDirection.high);
      expect(c.flagged, isFalse);
      expect(c.outlierIndex, 1, reason: '唯一的有限值');
      expect(c.z.isNaN, isTrue);

      final all = BladeGeometryCompare.compareMetric(
          'm', [double.nan, double.nan, double.nan], 0.5,
          direction: MetricDirection.high);
      expect(all.flagged, isFalse);
      expect(all.direction, MetricDirection.high,
          reason: '早退路徑也要帶著 direction，否則報告上會顯示錯的判準');
    });
  });

  group('序列化', () {
    test('direction 進 JSON，字串值與 geometry.py 相同', () {
      expect(
          BladeGeometryCompare.compareMetric('m', [0.0, 4.0, 0.2], 0.8,
                  direction: MetricDirection.high)
              .toJson()['direction'],
          'high');
      expect(
          BladeGeometryCompare.compareMetric('m', [0.0, 4.0, 0.2], 0.8)
              .toJson()['direction'],
          'both');
      expect(MetricDirection.low.wire, 'low');
    });
  });
}
