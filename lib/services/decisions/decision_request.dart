import 'dart:convert';

/// Typed decisions: unstructured `state` in, yes/no answers, choices, scores
/// and numbers with probabilities out, read from the model's next-token
/// probabilities instead of generated text.
///
/// The request and response shapes follow Rizzo Flow's `/v1/decisions`
/// (Apache-2.0, see THIRD_PARTY_NOTICES.md), so scripts written for it can
/// point at the phone by changing the URL.

/// A request the engine refuses, with a message for the client.
class DecisionRequestError implements Exception {
  final String message;
  const DecisionRequestError(this.message);

  @override
  String toString() => message;
}

enum DecisionType { boolean, choice, score, numeric }

/// Every candidate, special ones included, is one uppercase answer letter.
const int maxDecisionCandidates = 26;
const int maxDecisionQuestions = 64;
const int maxDecisionStateBytes = 256000;
const int _maxText = 8000;

/// Ids of the candidates the engine adds itself.
const String insufficientId = '__insufficient__';
const String belowRangeId = '__below_range__';
const String aboveRangeId = '__above_range__';
const Set<String> unavailableIds = {insufficientId, belowRangeId, aboveRangeId};

class DecisionPolicy {
  /// Offer "cannot determine" as an answer.
  final bool allowAbstain;

  /// At or above this probability of "cannot determine" or out of range,
  /// the answer has no value.
  final double maxUnavailableProbability;

  /// Below this top probability the answer is `uncertain` and has no value.
  final double minTopProbability;

  const DecisionPolicy({
    this.allowAbstain = true,
    this.maxUnavailableProbability = 0.5,
    this.minTopProbability = 0,
  });

  static DecisionPolicy parse(Object? raw, String where) {
    if (raw == null) return const DecisionPolicy();
    final map = _object(raw, where);
    _onlyKeys(
        map,
        const {
          'allow_abstain',
          'max_unavailable_probability',
          'min_top_probability',
        },
        where);
    final abstain = map['allow_abstain'] ?? true;
    if (abstain is! bool) {
      throw DecisionRequestError('$where.allow_abstain must be a boolean');
    }
    final maxUnavailable = _number(map['max_unavailable_probability'] ?? 0.5,
        '$where.max_unavailable_probability');
    if (maxUnavailable <= 0 || maxUnavailable > 1) {
      throw DecisionRequestError(
          '$where.max_unavailable_probability must be in (0, 1]');
    }
    final minTop =
        _number(map['min_top_probability'] ?? 0, '$where.min_top_probability');
    if (minTop < 0 || minTop > 1) {
      throw DecisionRequestError(
          '$where.min_top_probability must be in [0, 1]');
    }
    return DecisionPolicy(
      allowAbstain: abstain,
      maxUnavailableProbability: maxUnavailable,
      minTopProbability: minTop,
    );
  }
}

/// One answer the model can pick, shown to it as a lettered option.
class DecisionCandidate {
  final String id;
  final String description;

  /// The number a score level or numeric anchor stands for.
  final double? value;

  const DecisionCandidate(this.id, this.description, [this.value]);
}

class DecisionQuestion {
  final String id;
  final DecisionType type;
  final String instructions;
  final DecisionPolicy policy;

  /// In the order the model sees them, special candidates last.
  final List<DecisionCandidate> candidates;

  /// Unit of a numeric question.
  final String? unit;

  const DecisionQuestion({
    required this.id,
    required this.type,
    required this.instructions,
    required this.policy,
    required this.candidates,
    this.unit,
  });

  static const _defaultTrue =
      'Yes. The evidence supports an affirmative answer to the question.';
  static const _defaultFalse =
      'No. The evidence supports a negative answer to the question.';
  static const _abstain =
      'Cannot determine the answer: the required information is not provided '
      'or is contradictory. A known value outside the numeric range is not '
      'missing information.';
  static final _optionId = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$');

  static DecisionQuestion parse(String id, Object? raw) {
    final where = 'questions.$id';
    final map = _object(raw, where);
    final typeName = map['type'];
    final type = switch (typeName) {
      'boolean' => DecisionType.boolean,
      'choice' => DecisionType.choice,
      'score' => DecisionType.score,
      'numeric' => DecisionType.numeric,
      _ => throw DecisionRequestError(
          '$where.type must be boolean, choice, score or numeric'),
    };
    const common = {'type', 'instructions', 'policy'};
    final instructions = _text(map['instructions'], '$where.instructions');
    final policy = DecisionPolicy.parse(map['policy'], '$where.policy');
    final candidates = <DecisionCandidate>[];
    var reserved = 0;
    String? unit;

    switch (type) {
      case DecisionType.boolean:
        _onlyKeys(
            map, {...common, 'true_description', 'false_description'}, where);
        candidates
          ..add(DecisionCandidate(
              'false',
              map['false_description'] == null
                  ? _defaultFalse
                  : _text(map['false_description'], '$where.false_description'),
              0))
          ..add(DecisionCandidate(
              'true',
              map['true_description'] == null
                  ? _defaultTrue
                  : _text(map['true_description'], '$where.true_description'),
              1));
      case DecisionType.choice:
        _onlyKeys(map, {...common, 'options'}, where);
        final options = _list(map['options'], '$where.options', min: 2);
        for (var i = 0; i < options.length; i++) {
          final o = _object(options[i], '$where.options[$i]');
          _onlyKeys(o, const {'id', 'description'}, '$where.options[$i]');
          final optionId = o['id'];
          if (optionId is! String || !_optionId.hasMatch(optionId)) {
            throw DecisionRequestError('$where.options[$i].id must be 1-64 '
                'letters, digits, "_" or "-", starting with a letter or digit');
          }
          if (candidates.any((c) => c.id == optionId)) {
            throw DecisionRequestError('$where: option ids must be unique');
          }
          candidates.add(DecisionCandidate(optionId,
              _text(o['description'], '$where.options[$i].description')));
        }
      case DecisionType.score:
        _onlyKeys(map, {...common, 'levels'}, where);
        final levels = _list(map['levels'], '$where.levels', min: 2);
        for (var i = 0; i < levels.length; i++) {
          final level = _text(levels[i], '$where.levels[$i]');
          if (candidates.any((c) => c.description == level)) {
            throw DecisionRequestError(
                '$where: levels must have distinct descriptions');
          }
          candidates.add(DecisionCandidate('$i', level, i.toDouble()));
        }
      case DecisionType.numeric:
        _onlyKeys(map, {...common, 'unit', 'anchors'}, where);
        unit = _text(map['unit'], '$where.unit', max: 64);
        final anchors = _list(map['anchors'], '$where.anchors', min: 2);
        for (var i = 0; i < anchors.length; i++) {
          final a = _object(anchors[i], '$where.anchors[$i]');
          _onlyKeys(a, const {'value', 'description'}, '$where.anchors[$i]');
          final value = _number(a['value'], '$where.anchors[$i].value');
          if (candidates.isNotEmpty && value <= candidates.last.value!) {
            throw DecisionRequestError(
                '$where: anchor values must be strictly increasing');
          }
          final description =
              _text(a['description'], '$where.anchors[$i].description');
          candidates.add(DecisionCandidate(
              '$i',
              'Approximately ${formatNumber(value)} $unit: $description',
              value));
        }
        reserved = 2;
        candidates
          ..add(DecisionCandidate(belowRangeId,
              'The value is below ${formatNumber(candidates.first.value!)} $unit.'))
          ..add(DecisionCandidate(aboveRangeId,
              'The value is above ${formatNumber(candidates[candidates.length - 2].value!)} $unit.'));
    }
    if (policy.allowAbstain) {
      reserved++;
      candidates.add(const DecisionCandidate(insufficientId, _abstain));
    }
    if (candidates.length > maxDecisionCandidates) {
      throw DecisionRequestError(
          '$where: at most ${maxDecisionCandidates - reserved} entries fit '
          '($maxDecisionCandidates answer letters, $reserved reserved for '
          'abstention/out-of-range)');
    }
    return DecisionQuestion(
      id: id,
      type: type,
      instructions: instructions,
      policy: policy,
      candidates: List.unmodifiable(candidates),
      unit: unit,
    );
  }
}

class DecisionRequest {
  /// A string, a JSON object or a JSON list: the evidence to judge.
  final Object state;

  /// In request order.
  final List<DecisionQuestion> questions;

  const DecisionRequest(this.state, this.questions);

  /// Validates a `/v1/decisions` body. Nothing is truncated: a request that
  /// doesn't fit is refused with a [DecisionRequestError].
  static DecisionRequest parse(Object? body) {
    final map = _object(body, 'body');
    // `model` is accepted (and ignored) because OpenAI-style clients send it.
    _onlyKeys(map, const {'state', 'questions', 'mode', 'model'}, 'body');
    final mode = map['mode'] ?? 'shared';
    if (mode != 'shared' && mode != 'direct') {
      throw const DecisionRequestError('mode must be "shared" or "direct"');
    }
    final state = map['state'];
    if (state is! String && state is! Map && state is! List) {
      throw const DecisionRequestError(
          'state must be a string, a JSON object or a JSON list');
    }
    if ((state is String && state.trim().isEmpty) ||
        (state is Map && state.isEmpty) ||
        (state is List && state.isEmpty)) {
      throw const DecisionRequestError('state must not be empty');
    }
    if (utf8.encode(jsonEncode(state)).length > maxDecisionStateBytes) {
      throw const DecisionRequestError(
          'state exceeds 256 KB; it is never truncated');
    }
    final questions = map['questions'];
    if (questions is! Map || questions.isEmpty) {
      throw const DecisionRequestError(
          'questions must be an object with at least one question');
    }
    if (questions.length > maxDecisionQuestions) {
      throw const DecisionRequestError(
          'At most $maxDecisionQuestions questions per request');
    }
    final parsed = <DecisionQuestion>[];
    for (final entry in questions.entries) {
      final id = entry.key as String;
      if (id.trim().isEmpty || id.length > 128) {
        throw const DecisionRequestError(
            'Question ids must have 1-128 nonblank characters');
      }
      parsed.add(DecisionQuestion.parse(id, entry.value));
    }
    return DecisionRequest(state, List.unmodifiable(parsed));
  }
}

/// `1`, `2.5`, `1e+21`: like Python's `:g` for the values people write.
String formatNumber(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return value.toString();
}

Map<String, dynamic> _object(Object? raw, String where) {
  if (raw is! Map) throw DecisionRequestError('$where must be a JSON object');
  return raw.cast<String, dynamic>();
}

List<dynamic> _list(Object? raw, String where, {required int min}) {
  if (raw is! List || raw.length < min) {
    throw DecisionRequestError('$where must be a list of at least $min items');
  }
  if (raw.length > maxDecisionCandidates) {
    throw DecisionRequestError(
        '$where has more than $maxDecisionCandidates items');
  }
  return raw;
}

String _text(Object? raw, String where, {int max = _maxText}) {
  if (raw is! String || raw.trim().isEmpty) {
    throw DecisionRequestError('$where must be a nonblank string');
  }
  final text = raw.trim();
  if (text.length > max) {
    throw DecisionRequestError('$where is longer than $max characters');
  }
  return text;
}

double _number(Object? raw, String where) {
  if (raw is! num || !raw.isFinite || raw.abs() > 1e100) {
    throw DecisionRequestError('$where must be a finite number');
  }
  return raw.toDouble();
}

void _onlyKeys(Map<String, dynamic> map, Set<String> allowed, String where) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw DecisionRequestError('$where: unknown field "$key"');
    }
  }
}
