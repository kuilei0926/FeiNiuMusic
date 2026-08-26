import 'package:flutter/widgets.dart';

import '../../app/services/feiniu/api_client.dart';

/// Returns the decoded square-cover dimension for a logical display size.
///
/// Cover URLs stay at the canonical 800px size so network and disk caches are
/// shared. Only the in-memory decode is resized to the pixels the screen needs.
int coverMemoryCacheDimension({
  required double logicalSize,
  required double devicePixelRatio,
  int maxDimension = FeiNiuApiClient.coverRequestSize,
}) {
  if (!logicalSize.isFinite || logicalSize <= 0) return 1;
  if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) return 1;
  return (logicalSize * devicePixelRatio).ceil().clamp(1, maxDimension).toInt();
}

int coverMemoryCacheDimensionOf(BuildContext context, double logicalSize) {
  return coverMemoryCacheDimension(
    logicalSize: logicalSize,
    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
  );
}
