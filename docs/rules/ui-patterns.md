# UI Patterns

## 테마 색상

| 용도 | 색상 |
|------|------|
| Primary (강조) | `#E53935` (레드/코랄) |
| Blue Accent | `#2196F3` |
| Green (합격/달성) | `#4CAF50` |
| Orange (경고) | `#FFA726` |
| 배경 | `#FAFAFB` |
| 카드 배경 | `Colors.white` |
| 텍스트 | `#111827` (진한), `#374151` (중간), `#6B7280` (연한) |

## DropdownButton 필수 패턴

```dart
Container(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
  decoration: BoxDecoration(
    color: Colors.white,
    border: Border.all(color: Colors.grey.shade300),
    borderRadius: BorderRadius.circular(10),
  ),
  child: DropdownButtonHideUnderline(
    child: DropdownButton<String>(
      isExpanded: true,
      isDense: true,
      icon: Icon(Icons.arrow_drop_down, color: primaryColor, size: 20),
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),  // 팝업 둥근 모서리 필수
      style: const TextStyle(color: Colors.black87, fontSize: 13),
    ),
  ),
),
```

필수 속성:
- `DropdownButtonHideUnderline`으로 감싸기
- `dropdownColor: Colors.white`
- `borderRadius: BorderRadius.circular(12)` — 팝업 메뉴 둥근 모서리
- `isDense: true`

## 차트 섹션 래퍼 (_chartSection)

모든 차트/테이블 섹션은 `_chartSection` 위젯으로 감쌈:
- 흰색 카드 + 둥근 모서리(12) + 그림자
- 아이콘 + 타이틀 헤더
- `child`로 내용 전달

## DataTable 규칙

- `TableBorder.all(color: #E5E7EB, borderRadius: 8)` — 둥근 테두리
- 줄무늬 배경: 짝수 `white`, 홀수 `#FAFAFB`, 합계 `#EEF2FF`
- 헤더: `#F3F4F6` 배경
- 중앙정렬: `Center(child: Text(...))`로 DataCell 감싸기
- 합격율 뱃지: 초록(달성)/노랑(근접)/빨강(미달)

### DataTable + IntrinsicHeight 주의사항
- `SingleChildScrollView(horizontal)` → `IntrinsicHeight`와 충돌 (render box 에러)
- `LayoutBuilder` + `FittedBox` → `IntrinsicHeight` 내부에서 충돌
- 안전한 조합: `ClipRect` + `DataTable` (넘침만 자름)
- 높이 맞춤이 필요 없으면 `Row(crossAxisAlignment: start)` 사용

## 도넛 차트 (DonutPainter)

- Filled Path 방식 (stroke arc 아님)
- 슬라이스 간 흰색 구분선 (2.5px)
- innerRadius: outerRadius * 0.45
- 연결선 + 컬러 점 + 퍼센트 라벨 (좌우 겹침 방지)
- `_labelPad`는 차트 크기 비례로 계산

## 바 차트 (본부별 목표 대비 합격율)

- 성능: 초록(#4CAF50), 서류: 파란(#2196F3), 미달: 빨강(#E53935)
- 목표선: 검정 2px 세로선
- `AnimatedContainer`로 바 길이 전환
- 본부별 행 간격: `margin: bottom 10`
- 합계 행: 인디고 배경(#EEF2FF) + 테두리(#C7D2FE)

## ProgressDialog (로딩/완료 애니메이션)

```dart
final dialog = ProgressDialog(context);
dialog.show(message: '업로드 중...');
await doWork();
await dialog.complete(message: '업로드 완료');  // 체크 애니메이션
// 또는
await dialog.error(message: '실패');  // X 애니메이션
```

- 화면 중앙 팝업 (fade + scale 진입)
- 로딩: CircularProgressIndicator
- 완료: 파란 원 + 체크마크 애니메이션 (1.2초 후 자동 닫힘)
- 에러: 빨간 원 + X 아이콘 (1.5초 후 자동 닫힘)
- **SnackBar 사용 금지** — 모든 사용자 피드백(성공/실패/로딩)은 ProgressDialog로 처리할 것

## 분기 선택 버튼

- `AnimatedContainer` + `InkWell` 리플
- 선택: primary 색 배경 + 흰 텍스트
- 미선택: 흰 배경 + 회색 테두리

## 소형 차트 (Acc.담당별 Trend)

- 200px 높이, 10px 패딩
- X축 라벨: "1월1주" 형식, 45도 회전
- 성능(빨강) + 서류(파랑) 두 라인
- 클릭 시 확대 다이얼로그 (showGeneralDialog + fade + scale easeOutBack)
- 확대 시 fontSize: 13

## DashboardScreen 외부 선택 동기화

`DashboardScreen`은 `selectedRegion` prop을 받아 외부 필터와 지도 선택 상태를 동기화:

```dart
DashboardScreen(
  showStats: false,
  selectedRegion: _selectedRegion,  // 외부 필터와 지도 강조 동기화
  onRegionSelected: (region) { ... },
)
```

- `initState`: 초기 selectedRegion을 내부 key로 변환해 반영
- `didUpdateWidget`: 외부 값 변화 시 내부 `_selectedRegion` 갱신
- shortName → map key 변환: `_shortNameToKey()` (강남→gangnam 등)

## 전역 텍스트 선택

- `main.dart`의 MaterialApp `builder`에서 앱 전체를 `SelectionArea`로 감쌈 — 웹에서 드래그 선택/복사 가능 (Flutter 웹 기본값은 선택 불가)
- 개별 화면에서 `SelectableText`를 중복 사용할 필요 없음. 드래그 제스처 위젯(컬럼 리사이즈 등)은 제스처 아레나에서 우선권을 가지므로 공존

## 모바일(좁은 화면) 대응 규칙

- 게시글 상세 메타줄(작성자·날짜·조회수)은 고정 `Row` + `|` 구분자 금지 → `Wrap(spacing: 20, runSpacing: 8)` 사용 (좁으면 다음 줄로 흐름)
- 상세 카드 내부 패딩: `MediaQuery.of(context).size.width < 600 ? 16 : 32`
- 테이블의 허가번호(16자리) 셀은 `maxLines: 1` + 컬럼폭 145 이상 (줄바꿈 방지)
- 일정 화면 필터 바는 좁은 화면(<600px)에서 기본 접힘 — 헤더 탭으로 토글, 접힘 시 '적용중' 배지 + 건수 표시 (`_filterCollapsedUser`, 데스크탑은 항상 펼침)

## 인라인 배경 (현황 리포트 달성/미달성)

전체 너비를 채우지 않고 텍스트 너비만큼만 배경 적용:
```dart
Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Container(
      padding: ...,
      color: bgColor,
      child: Text(...),
    ),
  ],
)
```
`Expanded`나 `전체폭 Container` 사용 금지 — Row mainAxisSize.min 필수.

## Excel 다운로드 다이얼로그 (3단계)

본부 → 월 → 주차 순서로 선택:
- 월 선택 시 `getResultsWeeks()` 호출로 실제 업로드된 주차만 표시
- 주차 로딩 중 CircularProgressIndicator 표시
- 선택 항목이 없으면 '전체'로 처리

## 워크플로우 상태 배지 (Phase 1~5)

`_buildStatusBadge(status)` — 모든 화면에서 동일한 색/라벨 사용:

| 상태 | 라벨 | 색 |
|------|------|-----|
| REGISTERED | 등록됨 | `#6E7780` |
| PRE_CHECK | 사전점검중 | `#6B47DC` |
| PRE_CHECK_DONE | 점검완료 | `#1A8754` |
| CHANGE_FILING | 변경개설중 | `#E17055` |
| RE_CHECK | 재점검대기 | `#E17055` |
| REPORT_ISSUED | 내역서발급 | `#0984E3` |
| SUBMITTED | 접수완료 | `#0984E3` |
| INSPECTED | 수검완료 | `#2D3436` |

### 셀 내 배지 + 부가 정보 패턴 (높이 제한 안 침범)
일정 화면 셀은 `dataRowMaxHeight: 46` 제약이 있어 세 줄 이상은 아래 행을 침범함.
SUBMITTED 행에 접수번호 / INSPECTED 행에 재점검 칩 같은 부가 정보는 **배지 옆 한 줄**로:
```dart
Row(mainAxisSize: MainAxisSize.min, children: [
  _buildStatusBadge(status),
  const SizedBox(width: 4),
  Flexible(child: Text('#$submission',
      style: ..., maxLines: 1, overflow: TextOverflow.ellipsis)),
])
```

## 알림 종 아이콘 (Phase 5)

`widgets/notification_bell_button.dart`의 `NotificationBellButton` 위젯 재사용:
- 안 읽음 카운트 빨간 배지 (60초 폴링)
- 클릭 → `NotificationPanel` 다이얼로그 (안 읽음 토글 + 모두 읽음 + 타입별 색상 배지)
- **홈 화면에만 노출** — 모바일 AppBar 우상단 / 데스크탑은 사이드바 사용자 카드는 중복 회피로 제거됨

### 로그인 자동 팝업
- `maybeShowLoginNotificationPopup(context, svc)` — 홈 컨텐츠 `initState`에서 `addPostFrameCallback`으로 호출
- 안 읽음 > 0 이고 오늘 '보지 않기' 미설정 시 자동 표시
- 패널 푸터에 "오늘은 더이상 보지 않기" 체크박스 → SharedPreferences에 날짜키로 저장 (자정에 자동 초기화)
- key 포맷: `notification_popup_hidden_YYYY-MM-DD`

## 홈 대시보드 위젯 (Phase 5)

`widgets/inspection_dashboard_widget.dart`의 `InspectionDashboardWidget`:
- 위치: 홈 화면 커뮤니티 ↔ 바로가기 사이
- 역할 자동 분기 (admin/manager/member) — 백엔드 `GET /inspection/dashboard?year=`에 위임
- 상태별 8개 카드 (반응형 그리드: 720+ = 4열 / 480+ = 3열 / 그 외 2열)
- 재점검 필요 + 행정처분 대상(부적합 시정기한 지남) 알림 카드 (개수 0이면 자동 숨김)
- 지연 건 상위 5개 미니 리스트
- 카드 클릭 → 일정 화면으로 점프 + 해당 필터 자동 적용 (`InspectionScheduleScreen.initialStatusFilter`)
- 재점검 카드 클릭 → 일정 화면 `_recheckOnly` 토글 ON (특수 토큰 `'RECHECK'` 사용)

## 일정 화면 탭 순서 (Phase 5 보정)

- 좌(인덱스 0): 수검 대상 현황 (기본 진입)
- 우(인덱스 1): 매트릭스
- 매트릭스 셀 클릭 시 → `_tabCtrl.animateTo(0)`으로 수검대상 탭 이동

## 알림 팝업 다이얼로그 명세 (Modern Minimal) widgets/notification_dialog.dart의 NotificationDialog:

- 구조 및 레이아웃:
- 위젯: AlertDialog 대신 커스텀 Dialog 사용 (기본 패딩 제거 목적)
- 너비 제한: ConstrainedBox를 통한 maxWidth: 320 고정 (슬림한 카드 형태)
- 외부 여백: insetPadding: horizontal 40 (화면 양끝에서 충분히 이격)
- 곡률: BorderRadius.circular(24) 적용
- 상단 비주얼 (Header):
- 아이콘: Icons.notifications_active_rounded (Red 톤)
- 배경: 아이콘을 감싸는 연한 레드 컬러의 원형 컨테이너 (시각적 포인트)
- 정렬: 모든 요소 중앙 정렬 (Center Alignment)
- 텍스트 스타일 (Content):
- 타이틀: unreadCount 포함, fontSize: 17, fontWeight: 800, Color: 0xFF111827
- 설명문: fontSize: 13, lineHeight: 1.4, Color: 0xFF6B7280 (최대 2줄 권장)
- 옵션 선택 (Toggle Area):
- 형태: 배경색(0xFFF9FAFB)이 포함된 둥근 칩(Chip) 스타일 컨테이너
- 구성: Icons.check_box_rounded + '오늘은 더이상 보지 않기' 텍스트
- 인터랙션: StatefulBuilder를 통한 내부 hideToday 상태 토글 및 시각적 피드백(색상 변경)
- 액션 버튼 (Actions):
- 배치: 수직(Vertical) 스택 배치 (너비 꽉 차게)
- 메인 버튼 (알림 보기): ElevatedButton, Blue(0xFF2563EB), elevation: 0, borderRadius: 12
- 보조 버튼 (닫기): TextButton, Color: 0xFF9CA3AF, fontSize: 13
- 클릭 이벤트: Navigator.pop(context, true/false) 반환