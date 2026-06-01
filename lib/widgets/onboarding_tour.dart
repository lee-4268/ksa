import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';

/// 첫 접속 시 1회 자동, 헤더 '?' 아이콘으로 재실행 가능한 코치마크 투어.
///
/// 사용 측에서:
///   final tour = OnboardingTour(targets);
///   await tour.maybeShowFirstTime(context);  // 자동 트리거
///   ...
///   tour.show(context);  // 수동 재실행
class OnboardingTour {
  static const String _doneKey = 'onboarding_v1_done';

  final OnboardingTargets targets;
  TutorialCoachMark? _tutorial;

  OnboardingTour(this.targets);

  Future<void> maybeShowFirstTime(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return;
    if (!context.mounted) return;
    show(context, markDoneOnFinish: true);
  }

  void show(BuildContext context, {bool markDoneOnFinish = true}) {
    final items = _buildTargets();
    if (items.isEmpty) return;
    _tutorial = TutorialCoachMark(
      targets: items,
      colorShadow: Colors.black,
      opacityShadow: 0.78,
      paddingFocus: 8,
      hideSkip: false,
      textSkip: '건너뛰기',
      textStyleSkip: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
      onFinish: () async {
        if (markDoneOnFinish) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_doneKey, true);
        }
      },
      onSkip: () {
        SharedPreferences.getInstance().then((p) => p.setBool(_doneKey, true));
        return true;
      },
    )..show(context: context);
  }

  List<TargetFocus> _buildTargets() {
    final out = <TargetFocus>[];

    void add(GlobalKey? key, String title, String body, {ShapeLightFocus shape = ShapeLightFocus.RRect, ContentAlign align = ContentAlign.bottom}) {
      if (key?.currentContext == null) return;
      out.add(TargetFocus(
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
              isLast: out.length == 4, // 5번째(마지막)면 true가 됨
            ),
          ),
        ],
      ));
    }

    add(targets.mapMenuKey, '현장 수검 Map',
        '지도에서 마커를 클릭하면 해당 국소의 검사 정보를 볼 수 있어요. 여러 국소를 묶어 최적 경로도 짤 수 있습니다.');
    add(targets.scheduleMenuKey, '일정 및 통계',
        '검사 일정과 진행 상황, 통계를 한 곳에서 확인하세요.');
    add(targets.callnameMenuKey, '호출명칭 / 설치확인서',
        '필요한 자료를 빠르게 조회하고, 설치확인서·전산비교도 여기서 처리해요.');
    add(targets.notificationKey, '알림',
        '새 공지·요청사항이 도착하면 여기에 표시됩니다.');
    add(targets.helpKey, '도움말',
        '이 투어를 다시 보고 싶을 때는 이 ? 아이콘을 누르세요.', shape: ShapeLightFocus.Circle, align: ContentAlign.bottom);

    return out;
  }
}

class OnboardingTargets {
  final GlobalKey? mapMenuKey;
  final GlobalKey? scheduleMenuKey;
  final GlobalKey? callnameMenuKey;
  final GlobalKey? notificationKey;
  final GlobalKey? helpKey;

  const OnboardingTargets({
    this.mapMenuKey,
    this.scheduleMenuKey,
    this.callnameMenuKey,
    this.notificationKey,
    this.helpKey,
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
