import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';

/// 첫 접속 시 1회 자동, 헤더 '?' 아이콘으로 재실행 가능한 코치마크 투어.
///
/// 데스크탑/모바일 분기:
/// - 데스크탑(사이드바 상시 노출): 사이드바 메뉴 → 알림 → 도움말 5단계
/// - 모바일(드로어): 햄버거 메뉴 강조 → 드로어 자동 열기 → 드로어 안 메뉴 →
///   드로어 닫고 도움말 안내
class OnboardingTour {
  static const String _doneKey = 'onboarding_v1_done';

  final OnboardingTargets targets;
  final bool isMobile;
  final VoidCallback? openDrawer;
  final VoidCallback? closeDrawer;
  TutorialCoachMark? _tutorial;

  OnboardingTour(
    this.targets, {
    this.isMobile = false,
    this.openDrawer,
    this.closeDrawer,
  });

  Future<void> maybeShowFirstTime(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return;
    if (!context.mounted) return;
    show(context, markDoneOnFinish: true);
  }

  void show(BuildContext context, {bool markDoneOnFinish = true}) {
    if (isMobile) {
      _showMobile(context, markDoneOnFinish: markDoneOnFinish);
    } else {
      _showDesktop(context, markDoneOnFinish: markDoneOnFinish);
    }
  }

  // ── 데스크탑: 한 번에 5단계 ──

  void _showDesktop(BuildContext context, {required bool markDoneOnFinish}) {
    final items = <TargetFocus?>[
      _step(targets.mapMenuKey, '현장 수검 Map',
          '지도에서 마커를 클릭하면 해당 국소의 검사 정보를 볼 수 있어요. 여러 국소를 묶어 최적 경로도 짤 수 있습니다.', isLast: false),
      _step(targets.scheduleMenuKey, '일정 및 통계',
          '검사 일정과 진행 상황, 통계를 한 곳에서 확인하세요.', isLast: false),
      _step(targets.callnameMenuKey, '호출명칭 / 설치확인서',
          '필요한 자료를 빠르게 조회하고, 설치확인서·전산비교도 여기서 처리해요.', isLast: false),
      _step(targets.notificationKey, '알림',
          '새 공지·요청사항이 도착하면 여기에 표시됩니다.', isLast: false),
      _step(targets.helpKey, '도움말',
          '이 투어를 다시 보고 싶을 때는 이 ? 아이콘을 누르세요.', isLast: true, shape: ShapeLightFocus.Circle),
    ].whereType<TargetFocus>().toList();

    if (items.isEmpty) return;
    _launch(context, items, onAllDone: () => _markDone(markDoneOnFinish));
  }

  // ── 모바일: 햄버거 → 드로어 자동 열기 → 드로어 안 메뉴 → 드로어 닫고 도움말 ──

  void _showMobile(BuildContext context, {required bool markDoneOnFinish}) {
    // 1단계: 햄버거 메뉴
    final first = _step(
      targets.menuButtonKey,
      '메뉴 열기',
      '왼쪽 위의 메뉴 버튼을 누르면 화면 전환 메뉴가 열려요. 자동으로 열어드릴게요.',
      isLast: false,
      shape: ShapeLightFocus.Circle,
    );
    if (first == null) {
      // 햄버거가 없으면 모바일 모드인데 의미 없으므로 데스크탑 흐름으로 폴백
      _showDesktop(context, markDoneOnFinish: markDoneOnFinish);
      return;
    }

    _launch(context, [first], onAllDone: () async {
      // 드로어 열고, 한 프레임 기다린 뒤 2단계 시작
      openDrawer?.call();
      await Future.delayed(const Duration(milliseconds: 400));
      if (!context.mounted) return;
      _showMobileStep2(context, markDoneOnFinish: markDoneOnFinish);
    });
  }

  void _showMobileStep2(BuildContext context, {required bool markDoneOnFinish}) {
    final items = <TargetFocus?>[
      _step(targets.mapMenuKey, '현장 수검 Map',
          '지도에서 마커를 클릭하면 해당 국소의 검사 정보를 볼 수 있고, 여러 국소를 묶어 최적 경로도 짤 수 있어요.', isLast: false),
      _step(targets.scheduleMenuKey, '일정 및 통계',
          '검사 일정과 진행 상황, 통계를 한 곳에서 확인하세요.', isLast: false),
      _step(targets.callnameMenuKey, '호출명칭 / 설치확인서',
          '필요한 자료를 빠르게 조회하고, 설치확인서·전산비교도 여기서 처리해요.', isLast: false),
    ].whereType<TargetFocus>().toList();

    if (items.isEmpty) {
      // 드로어 안 메뉴들이 아직 마운트 안 됐다면 키 등록이 PostFrame 이후일 수도.
      // 한 번 더 짧게 기다려보고 안 되면 그냥 마지막 단계로 점프.
      Future.delayed(const Duration(milliseconds: 200), () {
        if (!context.mounted) return;
        _showMobileFinal(context, markDoneOnFinish: markDoneOnFinish);
      });
      return;
    }

    _launch(context, items, onAllDone: () async {
      closeDrawer?.call();
      await Future.delayed(const Duration(milliseconds: 350));
      if (!context.mounted) return;
      _showMobileFinal(context, markDoneOnFinish: markDoneOnFinish);
    });
  }

  void _showMobileFinal(BuildContext context, {required bool markDoneOnFinish}) {
    final last = _step(
      targets.helpKey,
      '도움말',
      '이 투어를 다시 보고 싶을 때는 오른쪽 위의 ? 아이콘을 누르세요.',
      isLast: true,
      shape: ShapeLightFocus.Circle,
    );
    if (last == null) {
      _markDone(markDoneOnFinish);
      return;
    }
    _launch(context, [last], onAllDone: () => _markDone(markDoneOnFinish));
  }

  // ── 헬퍼 ──

  TargetFocus? _step(
    GlobalKey? key,
    String title,
    String body, {
    required bool isLast,
    ShapeLightFocus shape = ShapeLightFocus.RRect,
    ContentAlign align = ContentAlign.bottom,
  }) {
    if (key?.currentContext == null) return null;
    return TargetFocus(
      identify: title,
      keyTarget: key,
      shape: shape,
      radius: 10,
      contents: [
        TargetContent(
          align: align,
          builder: (ctx, ctrl) => _TourCard(
            title: title,
            body: body,
            onNext: ctrl.next,
            onSkip: ctrl.skip,
            isLast: isLast,
          ),
        ),
      ],
    );
  }

  void _launch(BuildContext context, List<TargetFocus> items, {required VoidCallback onAllDone}) {
    _tutorial = TutorialCoachMark(
      targets: items,
      colorShadow: Colors.black,
      opacityShadow: 0.78,
      paddingFocus: 8,
      hideSkip: false,
      textSkip: '건너뛰기',
      textStyleSkip: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
      onFinish: onAllDone,
      onSkip: () {
        _markDone(true);
        return true;
      },
    )..show(context: context);
  }

  Future<void> _markDone(bool shouldMark) async {
    if (!shouldMark) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_doneKey, true);
  }
}

class OnboardingTargets {
  final GlobalKey? mapMenuKey;
  final GlobalKey? scheduleMenuKey;
  final GlobalKey? callnameMenuKey;
  final GlobalKey? notificationKey;
  final GlobalKey? helpKey;
  final GlobalKey? menuButtonKey;

  const OnboardingTargets({
    this.mapMenuKey,
    this.scheduleMenuKey,
    this.callnameMenuKey,
    this.notificationKey,
    this.helpKey,
    this.menuButtonKey,
  });
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
