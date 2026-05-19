import 'package:flutter/material.dart';

/// KSA 공용 로딩 인디케이터 — 3점 도트 펄스.
/// web/index.html의 초기 로딩 스피너와 동일한 톤(빨강 #E53935, 1.4s, 0.2s 간격).
class AppLoader extends StatefulWidget {
  final double dotSize;
  final double spacing;
  final Color? color;
  final String? message;

  const AppLoader({
    super.key,
    this.dotSize = 10,
    this.spacing = 8,
    this.color,
    this.message,
  });

  /// 풀스크린 중앙 정렬 + 선택적 메시지.
  static Widget centered({String? message, Color? color}) {
    return Center(
      child: AppLoader(message: message, color: color),
    );
  }

  /// 인라인 작은 사이즈 (버튼/리스트 등).
  static Widget small({Color? color}) {
    return AppLoader(dotSize: 6, spacing: 5, color: color);
  }

  @override
  State<AppLoader> createState() => _AppLoaderState();
}

class _AppLoaderState extends State<AppLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? const Color(0xFFE53935);
    final travel = widget.dotSize * 1.2;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: widget.dotSize + travel,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(3, (i) {
              return Padding(
                padding: EdgeInsets.only(
                    right: i < 2 ? widget.spacing : 0),
                child: _Dot(
                  controller: _ctrl,
                  delay: i * 0.143, // 0.2s / 1.4s ≈ 0.143
                  size: widget.dotSize,
                  travel: travel,
                  color: color,
                ),
              );
            }),
          ),
        ),
        if (widget.message != null) ...[
          const SizedBox(height: 16),
          Text(
            widget.message!,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final AnimationController controller;
  final double delay;
  final double size;
  final double travel;
  final Color color;

  const _Dot({
    required this.controller,
    required this.delay,
    required this.size,
    required this.travel,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // 0~1 사이클을 delay만큼 시프트 → 0~1
        var t = (controller.value - delay) % 1.0;
        if (t < 0) t += 1.0;

        // web/index.html keyframes: 0/80/100%는 baseline, 40%에서 peak
        double progress; // 0=baseline, 1=peak
        if (t < 0.4) {
          progress = t / 0.4; // 0 → 1
        } else if (t < 0.8) {
          progress = 1 - (t - 0.4) / 0.4; // 1 → 0
        } else {
          progress = 0;
        }

        final dy = -travel * progress;
        final opacity = 0.5 + 0.5 * progress;

        return Transform.translate(
          offset: Offset(0, dy),
          child: Opacity(
            opacity: opacity,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      },
    );
  }
}
