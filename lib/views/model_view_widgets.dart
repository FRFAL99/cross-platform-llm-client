part of 'model_view.dart';

// Models screen: small shared widgets.

/// Soft accent pill ("Load") for list rows.
class _SoftButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _SoftButton({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Opacity(
      opacity: onPressed == null ? 0.45 : 1,
      child: Material(
        color: t.accent.withValues(alpha: t.isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Text(label,
                style: t.small.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.accent)),
          ),
        ),
      ),
    );
  }
}

/// Small round icon button (download) for list rows.
class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const _RoundIconButton(
      {required this.icon, required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: onPressed == null ? 0.45 : 1,
        child: Material(
          color: t.fill,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 34,
              height: 34,
              child: Icon(icon, size: 18, color: t.text.withValues(alpha: 0.8)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small muted text button (sort toggle, refresh, filters).
class _TextAction extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? color;

  const _TextAction({
    required this.label,
    this.icon,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final fg = onTap == null ? t.faint : (color ?? t.muted);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      splashFactory: NoSplash.splashFactory,
      highlightColor: t.fill,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 15, color: fg),
            if (icon != null) const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: fg,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact round icon button for secondary row actions.
class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool destructive;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = onPressed == null
        ? t.faint
        : destructive
            ? t.red
            : t.muted;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          splashFactory: NoSplash.splashFactory,
          highlightColor: t.fill,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 19, color: color),
          ),
        ),
      ),
    );
  }
}

/// Rounded monogram tile coloured by model family, so rows are easy to tell
/// apart at a glance.
class _ModelAvatar extends StatelessWidget {
  final String name;
  final bool loaded;
  final double size;
  const _ModelAvatar({required this.name, this.loaded = false, this.size = 38});

  static const _families = <(String, String, Color)>[
    ('gemma', 'Ge', Color(0xFF4285F4)),
    ('qwen', 'Qw', Color(0xFF7C5CFF)),
    ('lfm', 'LF', Color(0xFF14B8A6)),
    ('llama', 'Ll', Color(0xFFF97316)),
    ('phi', 'Ph', Color(0xFF6366F1)),
    ('mistral', 'Mi', Color(0xFFF59E0B)),
    ('deepseek', 'DS', Color(0xFF0EA5E9)),
    ('smol', 'Sm', Color(0xFF22C55E)),
    ('minicpm', 'Mc', Color(0xFFE11D48)),
  ];
  static const _fallback = [
    Color(0xFF8B5CF6),
    Color(0xFF06B6D4),
    Color(0xFF84CC16),
    Color(0xFFEC4899),
    Color(0xFFF59E0B),
  ];

  (String, Color) _style() {
    final lower = name.toLowerCase();
    for (final (key, mono, color) in _families) {
      if (lower.contains(key)) return (mono, color);
    }
    final letters = name.replaceAll(RegExp(r'[^A-Za-z]'), '');
    final mono = letters.isEmpty
        ? '?'
        : letters.substring(0, letters.length >= 2 ? 2 : 1);
    return (mono, _fallback[name.hashCode.abs() % _fallback.length]);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final (mono, color) = _style();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: t.isDark ? 0.22 : 0.14),
            borderRadius: BorderRadius.circular(size * 0.3),
          ),
          child: Text(
            mono[0].toUpperCase() + mono.substring(1),
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: size * 0.36,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: t.isDark ? Color.lerp(color, Colors.white, 0.35) : color,
            ),
          ),
        ),
        if (loaded)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: t.green,
                shape: BoxShape.circle,
                border: Border.all(color: t.surface, width: 2),
              ),
            ),
          ),
      ]),
    );
  }
}
