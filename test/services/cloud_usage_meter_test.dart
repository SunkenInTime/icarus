import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/cloud_usage_meter.dart';

void main() {
  late List<(String, Map<String, Object>)> reported;
  late Map<String, int>? disk;
  late CloudUsageMeter meter;

  CloudUsageMeter makeMeter({Duration interval = const Duration(hours: 1)}) =>
      CloudUsageMeter(
        report: (event, properties) async => reported.add((event, properties)),
        load: () => disk,
        save: (counts) async => disk = counts,
        reportInterval: interval,
        saveDelay: const Duration(milliseconds: 10),
      );

  setUp(() {
    reported = [];
    disk = null;
    meter = makeMeter();
  });

  test('reports counts only, summed since the last report', () async {
    meter
      ..batchSent(3)
      ..batchSent(1)
      ..pageWatched(87)
      ..copyPass(4)
      ..copyFullRead(548)
      ..copyFullRead(2);

    await meter.report();

    final (event, properties) = reported.single;
    expect(event, 'cloud_usage');
    expect(properties, {
      'batches_sent': 2,
      'ops_sent': 4,
      'pages_watched': 1,
      'page_rows_watched': 87,
      'copy_passes': 1,
      'copy_strategies_listed': 4,
      'copy_full_reads': 2,
      'copy_rows_read': 550,
      'interval_minutes': 60,
      'from_last_session': false,
    });
  });

  test('nothing counted, nothing reported', () async {
    await meter.report();
    expect(reported, isEmpty);
  });

  test('reports on its own once the interval passes', () async {
    meter = makeMeter(interval: const Duration(milliseconds: 30));
    meter.batchSent(1);

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(reported.single.$2['batches_sent'], 1);
  });

  test('a session closed before its report sends it on the next start',
      () async {
    meter.batchSent(2);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(disk, {'batches_sent': 1, 'ops_sent': 2});

    // The app closes here; the next start reads what was left.
    final next = makeMeter();
    await next.reportLeftover();

    expect(reported.single.$2, {
      'batches_sent': 1,
      'ops_sent': 2,
      'interval_minutes': 60,
      'from_last_session': true,
    });
    expect(disk, isNull);
  });

  test('a sent report leaves nothing to send again', () async {
    meter.batchSent(1);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await meter.report();

    await makeMeter().reportLeftover();

    expect(reported, hasLength(1));
  });
}
