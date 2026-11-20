/// Result of one generation: its text, and the endpoint of the cluster
/// worker that dropped out meanwhile (null when none did).
typedef GenerationAttempt = ({String text, String? lostWorker});

/// Runs a generation again after a phone of the cluster drops out, once the
/// model has been reloaded on the phones that are left.
class LostWorkerRetry {
  LostWorkerRetry._();

  /// Runs [attempt]. If a worker was lost, calls [recover] (reload the model
  /// without it) and, if that worked and the user didn't stop meanwhile
  /// ([stopped]), runs [attempt] once more. The retry is only transparent
  /// while nothing was streamed to [onToken]; otherwise it needs
  /// [onRestart], called before the second run streams from the start.
  static Future<String> run({
    required Future<GenerationAttempt> Function(
            void Function(String token)? onToken)
        attempt,
    required Future<bool> Function(String worker) recover,
    required bool Function() stopped,
    String Function(String worker)? nameFor,
    void Function(String worker)? onRetry,
    void Function(String token)? onToken,
    void Function()? onRestart,
  }) async {
    var streamed = false;
    final forward = onToken == null
        ? null
        : (String token) {
            streamed = true;
            onToken(token);
          };

    final first = await attempt(forward);
    final worker = first.lostWorker;
    if (worker == null) return first.text;

    final name = nameFor?.call(worker) ?? worker;
    final reloaded = await recover(worker);
    if (!reloaded) {
      return 'ERROR: The phone cluster lost $name in the middle of this '
          'answer and the model could not be reloaded. Load it again, then '
          'try again.';
    }
    if (stopped() || (streamed && onRestart == null)) {
      return 'ERROR: The phone cluster lost $name in the middle of this '
          'answer. The model was reloaded without it; try again.';
    }
    onRetry?.call(worker);
    if (streamed) onRestart!();
    final second = await attempt(forward);
    if (second.lostWorker != null) {
      // Don't loop: the next request reloads again.
      return 'ERROR: The phone cluster lost another phone while answering '
          'again. Check the cluster, then try again.';
    }
    return second.text;
  }
}
