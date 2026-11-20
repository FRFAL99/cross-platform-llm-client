import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/lost_worker_retry.dart';

void main() {
  /// Attempts that stream [tokens] and then report [lost] (one per run).
  Future<GenerationAttempt> Function(void Function(String)?) attempts(
    List<String?> lost, {
    List<String> tokens = const [],
    List<int>? runs,
  }) {
    var i = 0;
    return (onToken) async {
      final n = i++;
      runs?.add(n);
      for (final t in tokens) {
        onToken?.call(t);
      }
      return (text: 'answer $n', lostWorker: lost[n]);
    };
  }

  test('no lost worker: one run, no reload', () async {
    var reloads = 0;
    final text = await LostWorkerRetry.run(
      attempt: attempts([null]),
      recover: (_) async => ++reloads > 0,
      stopped: () => false,
    );
    expect(text, 'answer 0');
    expect(reloads, 0);
  });

  test('lost before anything streamed: reloads and answers again', () async {
    final reloaded = <String>[];
    final runs = <int>[];
    final text = await LostWorkerRetry.run(
      attempt: attempts(['10.0.0.2:50052', null], runs: runs),
      recover: (w) async {
        reloaded.add(w);
        return true;
      },
      stopped: () => false,
      onToken: (_) {},
    );
    expect(text, 'answer 1');
    expect(reloaded, ['10.0.0.2:50052']);
    expect(runs, [0, 1]);
  });

  test('after streaming, starts over only with onRestart', () async {
    var restarts = 0;
    final seen = <String>[];
    final text = await LostWorkerRetry.run(
      attempt: attempts(['w', null], tokens: ['a', 'b']),
      recover: (_) async => true,
      stopped: () => false,
      onToken: seen.add,
      onRestart: () {
        restarts++;
        seen.clear();
      },
    );
    expect(text, 'answer 1');
    expect(restarts, 1);
    expect(seen, ['a', 'b'], reason: 'only the second run is shown');

    final noRestart = await LostWorkerRetry.run(
      attempt: attempts(['w', null], tokens: ['a']),
      recover: (_) async => true,
      stopped: () => false,
      onToken: (_) {},
      nameFor: (_) => 'Pixel 7',
    );
    expect(noRestart, startsWith('ERROR: The phone cluster lost Pixel 7'));
    expect(noRestart, contains('reloaded without it'));
  });

  test('no retry when the reload fails or the user stopped', () async {
    final failed = await LostWorkerRetry.run(
      attempt: attempts(['w', null]),
      recover: (_) async => false,
      stopped: () => false,
    );
    expect(failed, contains('could not be reloaded'));

    final stopped = await LostWorkerRetry.run(
      attempt: attempts(['w', null]),
      recover: (_) async => true,
      stopped: () => true,
    );
    expect(stopped, startsWith('ERROR:'));
  });

  test('a second lost worker does not loop', () async {
    var reloads = 0;
    final text = await LostWorkerRetry.run(
      attempt: attempts(['a', 'b', null]),
      recover: (_) async {
        reloads++;
        return true;
      },
      stopped: () => false,
    );
    expect(text, contains('lost another phone'));
    expect(reloads, 1);
  });
}
