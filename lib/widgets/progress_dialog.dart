import 'dart:async';
import 'package:flutter/material.dart';
import 'app_loader.dart';

/// 진행 중 + 완료 애니메이션 다이얼로그
///
/// 사용법:
/// ```dart
/// final dialog = ProgressDialog(context);
/// dialog.show(message: '업로드 중...');
/// await doWork();
/// await dialog.complete(message: '업로드 완료');
/// ```
class ProgressDialog {
  final BuildContext _context;
  bool _isShowing = false;

  ProgressDialog(this._context);

  /// 로딩 다이얼로그 표시
  void show({required String message}) {
    if (_isShowing) return;
    _isShowing = true;
    showGeneralDialog(
      context: _context,
      barrierDismissible: false,
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 250),
      transitionBuilder: (ctx, anim, _, child) {
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1.0)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        );
      },
      pageBuilder: (ctx, _, __) => _ProgressContent(message: message),
    );
  }

  /// 완료 애니메이션 후 자동 닫기
  /// `show()` 호출 없이 단독으로도 사용 가능 (SnackBar 대체용)
  Future<void> complete({String message = '완료', int delayMs = 1200}) async {
    // 로딩 다이얼로그가 떠 있다면 먼저 닫기
    if (_isShowing) {
      _safePop();
      _isShowing = false;
    }

    // 완료 다이얼로그 표시 — barrier/박스 클릭으로 닫기 가능 (자동 dismiss 실패 대비)
    showGeneralDialog(
      context: _context,
      barrierDismissible: true,
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 250),
      transitionBuilder: (ctx, anim, _, child) {
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1.0)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutBack)),
            child: child,
          ),
        );
      },
      pageBuilder: (ctx, _, __) => _CompleteContent(message: message),
    );

    await Future.delayed(Duration(milliseconds: delayMs));
    _safePop();
  }

  /// 에러 표시 후 자동 닫기
  Future<void> error({String message = '오류가 발생했습니다', int delayMs = 1500}) async {
    if (_isShowing) {
      _safePop();
      _isShowing = false;
    }

    showGeneralDialog(
      context: _context,
      barrierDismissible: true,
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 250),
      transitionBuilder: (ctx, anim, _, child) {
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1.0)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutBack)),
            child: child,
          ),
        );
      },
      pageBuilder: (ctx, _, __) => _ErrorContent(message: message),
    );

    await Future.delayed(Duration(milliseconds: delayMs));
    _safePop();
  }

  /// 안전한 pop — context 무효/이미 닫힘 등 모든 예외 무시
  void _safePop() {
    try {
      final nav = Navigator.of(_context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    } catch (_) {/* context 무효 등 무시 */}
  }

  /// 강제 닫기
  void dismiss() {
    if (_isShowing) {
      _safePop();
      _isShowing = false;
    }
  }
}

/// 로딩 중 UI
class _ProgressContent extends StatelessWidget {
  final String message;
  const _ProgressContent({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 160,
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLoader(
              dotSize: 12,
              spacing: 10,
              color: Color(0xFFE53935),
            ),
            const SizedBox(height: 18),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF374151),
                    decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }
}

/// 완료 UI (체크 애니메이션)
class _CompleteContent extends StatefulWidget {
  final String message;
  const _CompleteContent({required this.message});

  @override
  State<_CompleteContent> createState() => _CompleteContentState();
}

class _CompleteContentState extends State<_CompleteContent>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _check;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _scale = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.5, curve: Curves.easeOutBack)));
    _check = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0.35, 1.0, curve: Curves.easeOut)));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 160,
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Transform.scale(
                scale: _scale.value,
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: CustomPaint(
                    painter: _CheckPainter(
                      progress: _check.value,
                      color: const Color(0xFF2196F3),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(widget.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF374151),
                    decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }
}

/// 에러 UI
class _ErrorContent extends StatefulWidget {
  final String message;
  const _ErrorContent({required this.message});

  @override
  State<_ErrorContent> createState() => _ErrorContentState();
}

class _ErrorContentState extends State<_ErrorContent>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _scale = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 160,
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _scale,
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  color: Color(0xFFE53935),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 30),
              ),
            ),
            const SizedBox(height: 18),
            Text(widget.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF374151),
                    decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }
}

/// 체크마크 그리기 (원 + 체크)
class _CheckPainter extends CustomPainter {
  final double progress;
  final Color color;

  _CheckPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    // 원 (filled)
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = color,
    );

    // 체크마크 (흰색)
    if (progress > 0) {
      final path = Path();
      final startX = size.width * 0.26;
      final startY = size.height * 0.52;
      final midX = size.width * 0.44;
      final midY = size.height * 0.68;
      final endX = size.width * 0.74;
      final endY = size.height * 0.36;

      if (progress <= 0.5) {
        final t = progress / 0.5;
        path.moveTo(startX, startY);
        path.lineTo(
          startX + (midX - startX) * t,
          startY + (midY - startY) * t,
        );
      } else {
        final t = (progress - 0.5) / 0.5;
        path.moveTo(startX, startY);
        path.lineTo(midX, midY);
        path.lineTo(
          midX + (endX - midX) * t,
          midY + (endY - midY) * t,
        );
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 3.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CheckPainter old) =>
      old.progress != progress;
}
