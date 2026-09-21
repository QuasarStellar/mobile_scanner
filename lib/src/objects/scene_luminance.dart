/// @docImport 'package:mobile_scanner/src/mobile_scanner_controller.dart';
library;

/// This class represents the measured brightness of the camera scene.
///
/// These measurements are only emitted when
/// [MobileScannerController.reportSceneLuminance] is true.
class SceneLuminance {
  /// Create a new [SceneLuminance] instance.
  const SceneLuminance({required this.mean, required this.p90});

  /// Create a new [SceneLuminance] instance from the given [data] map.
  factory SceneLuminance.fromMap(Map<Object?, Object?> data) {
    return SceneLuminance(
      mean: (data['mean'] as num?)?.toDouble() ?? 0,
      p90: (data['p90'] as num?)?.toDouble() ?? 0,
    );
  }

  /// The average brightness of the sampled pixels, from 0 to 1.
  ///
  /// Because the camera continuously adjusts its exposure, this does not
  /// measure the ambient light level. It drops once the camera runs out of
  /// exposure and ISO headroom, which is the point where barcode detection
  /// starts to fail.
  final double mean;

  /// The 90th percentile of the brightness of the sampled pixels, from 0 to 1.
  ///
  /// A dark object that fills a well lit frame also has a low [mean], but keeps
  /// bright pixels around it. A genuinely dark scene has none, which is what
  /// separates the two.
  final double p90;

  @override
  String toString() => 'SceneLuminance(mean: $mean, p90: $p90)';
}
