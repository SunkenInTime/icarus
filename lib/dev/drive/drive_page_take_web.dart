final class PageTakeBudget {
  const PageTakeBudget({required this.longestStepMs, required this.recordMs});

  final num longestStepMs;
  final num recordMs;
}

Future<List<String>> pageTakeCost({
  required int items,
  required int changed,
  int runs = 51,
  PageTakeBudget? budget,
}) =>
    throw UnsupportedError('the web build keeps no library on this device');
