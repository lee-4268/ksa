# KSA Project Guidelines

## UI Components

### DropdownButton 스타일 가이드
프로젝트 전체에서 DropdownButton 사용 시 아래 패턴을 따를 것:

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
      style: const TextStyle(color: Colors.black87, fontSize: 13),
      // ...
    ),
  ),
),
```

핵심 규칙:
- 배경: `Colors.white`
- 테두리: `Colors.grey.shade300`, 둥근 모서리 `BorderRadius.circular(10)`
- `DropdownButtonHideUnderline`으로 기본 밑줄 제거
- `isDense: true`로 컴팩트 레이아웃
- 아이콘: `Icons.arrow_drop_down`, 프로젝트 primary 색상 사용
- `dropdownColor: Colors.white`
