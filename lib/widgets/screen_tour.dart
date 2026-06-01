import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';

/// 화면별 상세 투어 — 진입 시 1회 자동, 헤더 '?' 아이콘으로 재생.
///
/// 메인 OnboardingTour 가 "어떤 메뉴가 어디 있다" 를 안내한다면 ScreenTour 는
/// "이 화면 안에서 이 버튼은 뭘 하는 거다" 를 안내한다.
///
/// 사용 예 (화면 State 안):
///   late final ScreenTour _tour;
///   final _kFilterKey = GlobalKey();
///   @override void initState() {
///     super.initState();
///     _tour = ScreenTour(
///       screenKey: 'map',
///       steps: [
///         TourStep(_kFilterKey, '필터', '여기서 연도/지역을 좁힐 수 있어요.'),
///         ...
///       ],
///     );
///     WidgetsBinding.instance.addPostFrameCallback((_) {
///       Future.delayed(const Duration(milliseconds: 600), () {
///         if (mounted) _tour.maybeShowFirstTime(context);
///       });
///     });
///   }
class ScreenTour {
  final String screenKey;
  final List<TourStep> steps;
  final int version;

  ScreenTour({required this.screenKey, required this.steps, this.version = 1});

  String get _doneKey => 'tour_screen_${screenKey}_v${version}_done';

  Future<void> maybeShowFirstTime(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return;
    if (!context.mounted) return;
    show(context);
  }

  void show(BuildContext context) {
    final targets = <TargetFocus>[];
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (s.key?.currentContext == null) continue;
      targets.add(TargetFocus(
        identify: '${screenKey}_$i',
        keyTarget: s.key,
        shape: s.shape,
        radius: 10,
        contents: [
          TargetContent(
            align: s.align,
            builder: (ctx, ctrl) => _TourCard(
              title: s.title,
              body: s.body,
              onNext: ctrl.next,
              onSkip: ctrl.skip,
              isLast: i == steps.length - 1,
            ),
          ),
        ],
      ));
    }
    if (targets.isEmpty) return;

    TutorialCoachMark(
      targets: targets,
      colorShadow: Colors.black,
      opacityShadow: 0.78,
      paddingFocus: 8,
      hideSkip: false,
      textSkip: '건너뛰기',
      textStyleSkip: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
      onFinish: () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_doneKey, true);
      },
      onSkip: () {
        SharedPreferences.getInstance().then((p) => p.setBool(_doneKey, true));
        return true;
      },
    ).show(context: context);
  }
}

class TourStep {
  final GlobalKey? key;
  final String title;
  final String body;
  final ShapeLightFocus shape;
  final ContentAlign align;

  const TourStep(
    this.key,
    this.title,
    this.body, {
    this.shape = ShapeLightFocus.RRect,
    this.align = ContentAlign.bottom,
  });
}

/// 각 화면 헤더에 두는 도움말 아이콘.
///   AppBar(actions: [ScreenTourHelpButton(onTap: () => _tour.show(context))])
class ScreenTourHelpButton extends StatelessWidget {
  final VoidCallback onTap;
  final Color? color;
  final double size;
  const ScreenTourHelpButton({super.key, required this.onTap, this.color, this.size = 22});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.help_outline_rounded, size: size, color: color ?? Colors.grey.shade500),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      tooltip: '도움말 / 투어 다시보기',
      onPressed: onTap,
    );
  }
}

class _TourCard extends StatelessWidget {
  final String title;
  final String body;
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final bool isLast;

  const _TourCard({
    required this.title,
    required this.body,
    required this.onNext,
    required this.onSkip,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 14),
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
          const SizedBox(height: 8),
          Text(body,
              style: const TextStyle(fontSize: 13, color: Color(0xFF374151), height: 1.45)),
          const SizedBox(height: 14),
          Row(
            children: [
              TextButton(
                onPressed: onSkip,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: const Color(0xFF6B7280),
                ),
                child: const Text('건너뛰기', style: TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: onNext,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                child: Text(isLast ? '완료' : '다음',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
