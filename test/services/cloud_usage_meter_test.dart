import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/cloud_usage_meter.dart';

void main() {
  late List<(String, Map<String, Object>)> reported;
  late Map<String, int>? disk;
  late DateTime clock;

  CloudUsageMeter makeMeter() => CloudUsageMeter(
        report: (event, properties) async => reported.add((event, properties)),
        load: () => disk,
        save: (counts) async => disk = counts,
        now: () => clock,
        reportInterval: const Duration(minutes: 30),
      );

  setUp(() {
    reported = [];
    disk = null;
    clock = DateTime(2026, 10, 19, 12);
  });

  test('keeps counts on disk as they change, summed', () async {
    makeMeter()
      ..batchSent(3)
      ..batchSent(1)
      ..pageWatched(87)
      ..copyPass(4)
      ..copyFullRead(548)
      ..copyFullRead(2);
    await pumpEventQueue();

    expect(reported, isEmpty);
    expect(disk, {
      'batches_sent': 2,
      'ops_sent': 4,
      'pages_watched': 1,
      'page_rows_watched': 87,
      'copy_passes': 1,
      'copy_strategies_listed': 4,
      'copy_full_reads': 2,
      'copy_rows_read': 550,
    });
  });

  test('sends with the first count once the interval passed', () async {
    final meter = makeMeter()..batchSent(1);
    clock = clock.add(const Duration(minutes: 29));
    meter.batchSent(1);
    await pumpEventQueue();
    expect(reported, isEmpty);

    clock = clock.add(const Duration(minutes: 1));
    meter.pageWatched(10);
    await pumpEventQueue();

    expect(reported.single.$1, 'cloud_usage');
    expect(reported.single.$2, {
      'batches_sent': 2,
      'ops_sent': 2,
      'pages_watched': 1,
      'page_rows_watched': 10,
      'interval_minutes': 30,
      'from_last_session': false,
    });
    expect(disk, isNull);

    // The next report counts from here.
    meter.batchSent(5);
    await pumpEventQueue();
    expect(reported, hasLength(1));
    expect(disk, {'batches_sent': 1, 'ops_sent': 5});
  });

  test('a session that ends early sends its counts on the next start',
      () async {
    makeMeter().batchSent(2);
    await pumpEventQueue();

    // The app closes here; the next start reads what was left.
    await makeMeter().reportLeftover();

    expect(reported.single.$2, {
      'batches_sent': 1,
      'ops_sent': 2,
      'interval_minutes': 30,
      'from_last_session': true,
    });
    expect(disk, isNull);
  });

  test('nothing left, nothing sent at start', () async {
    await makeMeter().reportLeftover();
    expect(reported, isEmpty);
  });
}
