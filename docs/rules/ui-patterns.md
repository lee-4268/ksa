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
- SnackBar 대신 사용할 것

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
