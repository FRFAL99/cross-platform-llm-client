import 'package:flutter_test/flutter_test.dart';
import 'package:onelm/services/server/api_examples.dart';

void main() {
  const base = 'http://192.168.1.20:8080';

  test('every topic has code in every language', () {
    for (final topic in ApiExampleTopic.values) {
      for (final lang in ApiExampleLanguage.values) {
        final code = apiExample(topic, lang, baseUrl: base);
        expect(code, contains('$base/v1'), reason: '$topic/$lang');
      }
    }
  });

  test('sends the key only when one is required', () {
    for (final topic in ApiExampleTopic.values) {
      for (final lang in ApiExampleLanguage.values) {
        final open = apiExample(topic, lang, baseUrl: base);
        expect(open, isNot(contains('Bearer')), reason: '$topic/$lang');
        final keyed = apiExample(topic, lang, baseUrl: base, apiKey: 'k1');
        expect(keyed, contains('k1'), reason: '$topic/$lang');
      }
    }
  });

  test('SDK clients get a placeholder key when none is set', () {
    final code = apiExample(ApiExampleTopic.chat, ApiExampleLanguage.python,
        baseUrl: base, apiKey: '  ');
    expect(code, contains('api_key="not-needed"'));
  });

  test('decisions call the decisions endpoint', () {
    for (final lang in ApiExampleLanguage.values) {
      expect(
          apiExample(ApiExampleTopic.decisions, lang, baseUrl: base),
          contains('$base/v1/decisions'));
    }
  });
}
