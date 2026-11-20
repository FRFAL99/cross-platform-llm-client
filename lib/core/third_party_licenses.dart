import 'package:flutter/foundation.dart'
    show LicenseEntry, LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart' show rootBundle;

const _pdfium = 'assets/licenses/pdfium';

/// Licenses of code and assets that Flutter's generated NOTICES does not
/// cover: native libraries compiled into the APK (llama.cpp and what it
/// vendors), the prebuilt PDFium library, build-time headers, and bundled
/// fonts. Dart packages, their
/// plugins and the Flutter engine are listed by Flutter itself.
///
/// Keep THIRD_PARTY_NOTICES.md in sync when this list changes.
const List<(List<String>, String)> thirdPartyLicenseAssets = [
  (['llama.cpp', 'ggml'], 'assets/licenses/llama.cpp.txt'),
  (['stb_image'], 'assets/licenses/stb.txt'),
  (['miniaudio'], 'assets/licenses/miniaudio.txt'),
  (['Vulkan-Headers'], 'assets/licenses/vulkan-headers.txt'),
  (['SPIRV-Headers'], 'assets/licenses/spirv-headers.txt'),
  (['TweetNaCl', 'poly1305-donna'], 'assets/licenses/crypto-public-domain.txt'),
  // PDFium, downloaded prebuilt by pdfrx (bblanchon/pdfium-binaries,
  // chromium/8125); its Dart packages only carry the wrapper's license.
  (['PDFium'], '$_pdfium/pdfium.txt'),
  (['pdfium-binaries'], '$_pdfium/pdfium-binaries.txt'),
  (['Abseil (in PDFium)'], '$_pdfium/abseil.txt'),
  (['Anti-Grain Geometry (in PDFium)'], '$_pdfium/agg23.txt'),
  (['Catapult (in PDFium)'], '$_pdfium/catapult.txt'),
  (['cpu_features (in PDFium)'], '$_pdfium/cpu_features.txt'),
  (['Dragonbox (in PDFium)'], '$_pdfium/dragonbox-Apache2-LLVM.txt'),
  (['Dragonbox (in PDFium)'], '$_pdfium/dragonbox-Boost.txt'),
  (['fast_float (in PDFium)'], '$_pdfium/fast_float.txt'),
  (['FreeType (in PDFium)'], '$_pdfium/freetype.txt'),
  (['HarfBuzz (in PDFium)'], '$_pdfium/harfbuzz.txt'),
  (['Highway (in PDFium)'], '$_pdfium/highway.txt'),
  (['ICU (in PDFium)'], '$_pdfium/icu.txt'),
  (['Little CMS (in PDFium)'], '$_pdfium/lcms.txt'),
  (['libjpeg-turbo (in PDFium)'], '$_pdfium/libjpeg_turbo.md'),
  (['libjpeg-turbo (in PDFium)'], '$_pdfium/libjpeg_turbo-ijg.txt'),
  (['OpenJPEG (in PDFium)'], '$_pdfium/libopenjpeg.txt'),
  (['libpng (in PDFium)'], '$_pdfium/libpng.txt'),
  (['libunwind (in PDFium)'], '$_pdfium/libunwind.txt'),
  (['LLVM libc (in PDFium)'], '$_pdfium/llvm-libc.txt'),
  (['simdutf (in PDFium)'], '$_pdfium/simdutf.txt'),
  (['zlib (in PDFium)'], '$_pdfium/zlib.txt'),
  (['Inter (font)'], 'assets/fonts/Inter-OFL.txt'),
  (['Fira Code (font)'], 'assets/fonts/FiraCode-OFL.txt'),
];

/// Adds [thirdPartyLicenseAssets] to the app's license page.
void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(_entries);
}

Stream<LicenseEntry> _entries() async* {
  for (final (packages, asset) in thirdPartyLicenseAssets) {
    final text = await rootBundle.loadString(asset);
    yield LicenseEntryWithLineBreaks(packages, text);
  }
}

/// Shown at the top of the license page.
const String appLegalese =
    'Based on cross-platform-llm-client by orailnoor and techjarves '
    '(MIT License). Local inference by llama.cpp (MIT, the ggml authors). '
    'Portions of this software are copyright © The FreeType Project '
    '(www.freetype.org). This software is based in part on the work of the '
    'Independent JPEG Group. '
    'Models are downloaded from Hugging Face and keep their own licenses, '
    'shown in each model\'s details.';
