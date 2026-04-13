// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui;

// ignore: depend_on_referenced_packages
import 'package:js/js.dart';
import 'package:flutter/material.dart';

@JS('noticeEditorMount')
// ignore: non_constant_identifier_names
external html.Element _jsEditorMount(String viewId, String initialHtml);

@JS('noticeEditorGetHtml')
// ignore: non_constant_identifier_names
external String _jsEditorGetHtml(String viewId);

@JS('noticeEditorSetHtml')
// ignore: non_constant_identifier_names
external void _jsEditorSetHtml(String viewId, String html);

/// 엑셀 복붙을 지원하는 contenteditable 리치텍스트 에디터 (Web 전용)
class RichContentEditor extends StatefulWidget {
  final String viewId;
  final String initialHtml;
  final double height;

  const RichContentEditor({
    super.key,
    required this.viewId,
    this.initialHtml = '',
    this.height = 320,
  });

  @override
  State<RichContentEditor> createState() => RichContentEditorState();
}

class RichContentEditorState extends State<RichContentEditor> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = 'notice-editor-${widget.viewId}';
    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(_viewType, (int id) {
      return _jsEditorMount(_viewType, widget.initialHtml);
    });
  }

  /// 현재 에디터 HTML 내용 반환
  String getHtml() {
    try {
      return _jsEditorGetHtml(_viewType);
    } catch (_) {
      return '';
    }
  }

  /// 에디터 HTML 내용 설정
  void setHtml(String html) {
    try {
      _jsEditorSetHtml(_viewType, html);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(6),
        color: const Color(0xFFF9FAFB),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: HtmlElementView(viewType: _viewType),
      ),
    );
  }
}
