import 'dart:math';

/// Pairing codes for the phone cluster: a worker shows one, and a master
/// must know it to use the worker (checked by a challenge-response in
/// llama.cpp's RPC layer, so the code never crosses the network).
class ClusterPairing {
  ClusterPairing._();

  /// No 0/O or 1/I, so a code read off a screen can't be mistyped.
  static const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// 12 characters of a 32-letter alphabet: 60 bits.
  static const length = 12;

  /// A new random code, "ABCD-EFGH-JKLM".
  static String generate([Random? random]) {
    final rng = random ?? Random.secure();
    final raw = List.generate(length, (_) => alphabet[rng.nextInt(alphabet.length)]).join();
    return _format(raw);
  }

  /// The canonical form of what the user typed ("abcd efgh-jklm" →
  /// "ABCD-EFGH-JKLM"), or null when it can't be a pairing code.
  static String? normalize(String input) {
    final raw = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-_.]'), '');
    if (raw.length != length) return null;
    if (raw.split('').any((c) => !alphabet.contains(c))) return null;
    return _format(raw);
  }

  static String _format(String raw) =>
      '${raw.substring(0, 4)}-${raw.substring(4, 8)}-${raw.substring(8, 12)}';
}
