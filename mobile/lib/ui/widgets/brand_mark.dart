/// The Tango KYC brand mark, drawn from the same transparent asset as the
/// splash and onboarding screens.
///
/// Centralised here so every screen shows one identical lockup instead of a
/// gradient plate with an unrelated Material icon. The asset is 1069x1119
/// (portrait), so height drives the size and the width follows the native ratio
/// with `BoxFit.contain`.
library;

import 'package:flutter/material.dart';

/// The brand lockup PNG, used verbatim: the already-transparent asset, so there
/// is no white square, halo or background plate behind the mark.
const String kBrandLogoAsset = 'assets/logo_transparent.png';

/// Home-only derivative of [kBrandLogoAsset] with the fully-transparent padding
/// cropped away. The drawing is byte-for-byte the same artwork; only the 15px
/// transparent margin is gone, so the mark fills its box and reads optically
/// aligned with adjacent text. The shared original stays untouched for the
/// splash, welcome and auth screens.
const String kHomeLogoAsset = 'assets/logo_home_cropped.png';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.height = 44, this.asset = kBrandLogoAsset});

  /// Height in logical pixels. The width is derived from the asset's ratio.
  final double height;

  /// Which lockup to draw. Defaults to the shared transparent original.
  final String asset;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Image.asset(
        asset,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
      ),
    );
  }
}
