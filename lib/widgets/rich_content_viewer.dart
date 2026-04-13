// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui;

// ignore: depend_on_referenced_packages
import 'package:js/js.dart';
import 'package:flutter/material.dart';

@JS('noticeViewerMount')
// ignore: non_constant_identifier_names
external html.Element _jsViewerMount(String viewId, String html);

@JS('noticeViewerUpdate')
// ignore: non_constant_identifier_names
external void _jsViewerUpdate(String viewId, String html);

/// HTML/평문 컨텐츠를 렌더링하는 뷰어 (Web 전용)
/// - HTML 태그가 포함된 경우 HTML로 렌더링 (엑셀 테이블 포함)
/// - 순수 텍스트인 경우 <pre>로 래핑해 렌더링
class RichContentViewer extends StatefulWidget {
  final String viewId;
  final String content;
  final double height;

  const RichContentViewer({
    super.key,
    required this.viewId,
    required this.content,
    this.height = 400,
  });

  @override
  State<RichContentViewer> createState() => _RichContentViewerState();
}

class _RichContentViewerState extends State<RichContentViewer> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = 'notice-viewer-${widget.viewId}';
    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(_viewType, (int id) {
      return _jsViewerMount(_viewType, widget.content);
    });
  }

  @override
  void didUpdateWidget(RichContentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      try {
        _jsViewerUpdate(_viewType, widget.content);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}
