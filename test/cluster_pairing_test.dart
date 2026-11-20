import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:onelm/services/cluster_pairing.dart';

void main() {
  test('generates 12-character codes from the unambiguous alphabet', () {
    final rng = Random(1);
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      final code = ClusterPairing.generate(rng);
      expect(code, matches(RegExp(r'^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$')));
      expect(ClusterPairing.normalize(code), code);
      seen.add(code);
    }
    expect(seen.length, 200);
  });

  test('normalizes what people type', () {
    expect(ClusterPairing.normalize(' abcd efgh-jk23 '), 'ABCD-EFGH-JK23');
    expect(ClusterPairing.normalize('ABCDEFGHJK23'), 'ABCD-EFGH-JK23');
    expect(ClusterPairing.normalize('abcd_efgh.jk23'), 'ABCD-EFGH-JK23');
  });

  test('rejects wrong lengths and characters outside the alphabet', () {
    expect(ClusterPairing.normalize(''), isNull);
    expect(ClusterPairing.normalize('ABCD-EFGH-JK2'), isNull);
    expect(ClusterPairing.normalize('ABCD-EFGH-JK234'), isNull);
    expect(ClusterPairing.normalize('ABCD-EFGH-JK20'), isNull, reason: '0 is not used');
    expect(ClusterPairing.normalize('OBCD-EFGH-JK23'), isNull, reason: 'O is not used');
  });
}
