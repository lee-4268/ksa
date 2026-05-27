// SKO-OCEAN 시설점검 사진 공용 위젯 (CORS 우회 HTML <img> 기반).
// 사진 자체는 사내망 static-int.skons.co.kr 에서 서빙되므로 사내망에서만 표시됨.
// inspection_result_screen.dart 와 sisl_photo_search_screen.dart 에서 공용.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;

final Set<String> _sislRegisteredViewTypes = <String>{};

/// URL 을 안전한 viewType ID 로 변환 (영숫자/하이픈만 남김).
String _viewTypeForUrl(String url) {
  // URL 의 마지막 path segment (UUID) 만 사용 — 충분히 unique
  final last = url.split('/').last;
  final cleaned = last.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
  return 'sisl-img-$cleaned';
}

/// HTML <img> 태그를 platform view 로 등록.
/// fit: 'cover' 또는 'contain'.
void _ensureSislImageRegistered(String url, {String fit = 'cover'}) {
  final viewType = _viewTypeForUrl(url) + (fit == 'cover' ? '-cv' : '-ct');
  if (_sislRegisteredViewTypes.contains(viewType)) return;
  _sislRegisteredViewTypes.add(viewType);
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
    final wrap = html.DivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.overflow = 'hidden'
      ..style.backgroundColor = '#F3F4F6';
    final img = html.ImageElement()
      ..src = url
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = fit
      ..style.display = 'block';
    // 로드 실패 시 placeholder 아이콘 SVG 로 대체
    img.onError.listen((_) {
      img.remove();
      final placeholder = html.DivElement()
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.display = 'flex'
        ..style.alignItems = 'center'
        ..style.justifyContent = 'center'
        ..style.color = '#9CA3AF'
        ..innerHtml = '<svg width="32" height="32" viewBox="0 0 24 24" fill="currentColor">'
            '<path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/>'
            '</svg>';
      wrap.append(placeholder);
    });
    wrap.append(img);
    return wrap;
  });
}

/// 시설물 사진 1장을 새 탭으로 열기.
/// 사내망 사진은 cross-origin(CORS 미허용)이라 브라우저가 <a download> 의 파일명을
/// 무시하고 새 탭 이동만 됨 → 사용자가 새 탭에서 우클릭 저장하도록 함.
void downloadSislPhoto(Map<String, dynamic> item) {
  final url = (item['url'] ?? '').toString();
  if (url.isEmpty) return;
  html.window.open(url, '_blank');
}

/// 시설물 사진 여러 장을 새 탭으로 일괄 열기 (각 100ms 간격 — 팝업 차단 완화).
Future<void> openSislPhotosNewTab(List<Map<String, dynamic>> items) async {
  for (final it in items) {
    final url = (it['url'] ?? '').toString();
    if (url.isEmpty) continue;
    html.window.open(url, '_blank');
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

/// upload_date(YYYYMMDD 정수/문자) → 'YYYY-MM-DD' 포맷.
String fmtSislDate(dynamic raw) {
  final s = (raw ?? '').toString();
  if (s.length == 8) {
    return '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}';
  }
  return s;
}

/// SKO-OCEAN 사진 썸네일 타일. HTML <img> 기반(CORS 우회).
class SislPhotoTile extends StatelessWidget {
  final String url;
  final String label;
  final VoidCallback onTap;
  const SislPhotoTile({super.key, required this.url, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    _ensureSislImageRegistered(url, fit: 'cover');
    final viewType = '${_viewTypeForUrl(url)}-cv';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Stack(fit: StackFit.expand, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: HtmlElementView(
            viewType: viewType,
            // platform view 가 클릭을 흡수하지 않게 하여 InkWell.onTap 으로 통과
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          ),
        ),
        if (label.isNotEmpty)
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
              ),
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                  textAlign: TextAlign.center,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
      ]),
    );
  }
}

/// SKO-OCEAN 사진 확대 뷰어 (좌우 스와이프 + 회전/확대/다운로드).
class SislPhotoViewer extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final int initialIndex;
  const SislPhotoViewer({super.key, required this.items, required this.initialIndex});

  @override
  State<SislPhotoViewer> createState() => _SislPhotoViewerState();
}

class _SislPhotoViewerState extends State<SislPhotoViewer> {
  late final PageController _ctrl;
  late int _idx;
  // 페이지별 90° 단위 회전 카운트 (0~3). 페이지 이동해도 각자 유지.
  final Map<int, int> _rotations = {};
  // 페이지별 InteractiveViewer 트랜스폼 (확대/축소 버튼용).
  final Map<int, TransformationController> _transforms = {};

  @override
  void initState() {
    super.initState();
    _idx = widget.initialIndex;
    _ctrl = PageController(initialPage: _idx);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    for (final t in _transforms.values) {
      t.dispose();
    }
    super.dispose();
  }

  TransformationController _txCtrl(int i) =>
      _transforms.putIfAbsent(i, () => TransformationController());

  void _rotateLeft() {
    setState(() {
      _rotations[_idx] = ((_rotations[_idx] ?? 0) - 1) % 4;
      if ((_rotations[_idx] ?? 0) < 0) _rotations[_idx] = _rotations[_idx]! + 4;
    });
  }

  void _rotateRight() {
    setState(() {
      _rotations[_idx] = ((_rotations[_idx] ?? 0) + 1) % 4;
    });
  }

  void _zoomIn() {
    final t = _txCtrl(_idx);
    final m = t.value.clone();
    final cur = m.getMaxScaleOnAxis();
    if (cur >= 5.0) return;
    m.scaleByDouble(1.4, 1.4, 1.0, 1.0);
    t.value = m;
  }

  void _zoomOut() {
    final t = _txCtrl(_idx);
    final m = t.value.clone();
    final cur = m.getMaxScaleOnAxis();
    if (cur <= 0.5) return;
    final s = 1 / 1.4;
    m.scaleByDouble(s, s, 1.0, 1.0);
    t.value = m;
  }

  void _resetTransform() {
    setState(() {
      _txCtrl(_idx).value = Matrix4.identity();
      _rotations[_idx] = 0;
    });
  }

  String _fmt(dynamic raw) => fmtSislDate(raw);

  /// 현재 사진 1장 다운로드 (공용 함수 사용).
  void _downloadCurrent() => downloadSislPhoto(widget.items[_idx]);

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_idx];
    final rotation = _rotations[_idx] ?? 0;
    final hasPrev = _idx > 0;
    final hasNext = _idx < widget.items.length - 1;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: Colors.transparent,
      child: Stack(children: [
        // 본문: 이미지 + 하단 액션
        Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Container(
              color: Colors.black,
              child: PageView.builder(
                controller: _ctrl,
                itemCount: widget.items.length,
                onPageChanged: (i) => setState(() => _idx = i),
                itemBuilder: (_, i) {
                  final url = (widget.items[i]['url'] ?? '').toString();
                  _ensureSislImageRegistered(url, fit: 'contain');
                  final viewType = '${_viewTypeForUrl(url)}-ct';
                  final rot = _rotations[i] ?? 0;
                  return InteractiveViewer(
                    transformationController: _txCtrl(i),
                    minScale: 0.5,
                    maxScale: 5.0,
                    child: RotatedBox(
                      quarterTurns: rot,
                      child: HtmlElementView(viewType: viewType),
                    ),
                  );
                },
              ),
            ),
          ),
          // 하단 액션 바
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.75),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _viewerAction(icon: Icons.rotate_left, tooltip: '왼쪽으로 회전', onTap: _rotateLeft),
              _viewerAction(icon: Icons.rotate_right, tooltip: '오른쪽으로 회전', onTap: _rotateRight),
              _viewerAction(icon: Icons.zoom_in, tooltip: '확대', onTap: _zoomIn),
              _viewerAction(icon: Icons.zoom_out, tooltip: '축소', onTap: _zoomOut),
              _viewerAction(icon: Icons.restore, tooltip: '원래대로', onTap: _resetTransform),
              _viewerAction(icon: Icons.open_in_new, tooltip: '새 탭으로 열기 (우클릭 저장)', onTap: _downloadCurrent),
              if (rotation != 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text('${rotation * 90}°',
                      style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ),
            ]),
          ),
        ]),
        // 좌상단 정보 칩
        Positioned(
          left: 12, top: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${_idx + 1} / ${widget.items.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text('${_fmt(item['upload_date'])} · 분류 ${item['reg_cls']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ]),
          ),
        ),
        // 우상단 닫기 버튼 — 뷰어의 가장 바깥 우상단
        Positioned(
          right: 8, top: 8,
          child: Material(
            color: Colors.black.withValues(alpha: 0.6),
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: '닫기',
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ),
        // 좌측 이전 화살표
        if (hasPrev)
          Positioned(
            left: 8, top: 0, bottom: 0,
            child: Center(child: _navArrow(
              icon: Icons.chevron_left,
              tooltip: '이전 사진',
              onTap: () => _ctrl.animateToPage(_idx - 1,
                  duration: const Duration(milliseconds: 200), curve: Curves.easeOut),
            )),
          ),
        // 우측 다음 화살표
        if (hasNext)
          Positioned(
            right: 8, top: 0, bottom: 0,
            child: Center(child: _navArrow(
              icon: Icons.chevron_right,
              tooltip: '다음 사진',
              onTap: () => _ctrl.animateToPage(_idx + 1,
                  duration: const Duration(milliseconds: 200), curve: Curves.easeOut),
            )),
          ),
      ]),
    );
  }

  Widget _viewerAction({required IconData icon, required String tooltip, required VoidCallback onTap}) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: Colors.white, size: 22),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _navArrow({required IconData icon, required String tooltip, required VoidCallback onTap}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: Colors.white, size: 32),
        onPressed: onTap,
      ),
    );
  }
}
