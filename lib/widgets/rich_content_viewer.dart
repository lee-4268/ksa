// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// style 속성을 포함한 모든 속성을 허용하는 NodeValidator
class _AllowAllValidator implements html.NodeValidator {
  const _AllowAllValidator();
  @override
  bool allowsElement(html.Element element) => true;
  @override
  bool allowsAttribute(html.Element element, String attributeName, String value) => true;
}

const _validator = _AllowAllValidator();

/// HTML/평문 컨텐츠를 렌더링하는 뷰어 (Web 전용)
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
  html.DivElement? _contentDiv;

  String _renderHtml(String text) {
    if (text.isEmpty) return '';
    final hasTag = RegExp(r'<[a-zA-Z][^>]*>').hasMatch(text);
    if (!hasTag) {
      final escaped = text
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      return '<pre style="white-space:pre-wrap;font-family:inherit;margin:0">$escaped</pre>';
    }
    // 테이블 셀에 white-space:nowrap 강제 적용 (엑셀 inline style에 추가)
    return text.replaceAllMapped(
      RegExp(r'<(td|th)(\s[^>]*)?>', caseSensitive: false),
      (m) {
        final tag = m.group(1)!;
        final attrs = m.group(2) ?? '';
        // 이미 style 속성이 있으면 white-space 추가, 없으면 새로 삽입
        if (attrs.contains('style=')) {
          return '<$tag${attrs.replaceFirstMapped(
            RegExp(r'style="([^"]*)"', caseSensitive: false),
            (sm) => 'style="${sm.group(1)};white-space:nowrap;"',
          )}>';
        }
        return '<$tag$attrs style="white-space:nowrap;">';
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _viewType = 'notice-viewer-${widget.viewId}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int id) {
      final wrap = html.DivElement()
        ..style.cssText =
            'width:100%;height:100%;box-sizing:border-box;font-size:14px;'
            'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;'
            'color:#374151;overflow:auto;';

      // 엑셀 inline style이 없을 때 폴백 최소 스타일
      final style = html.StyleElement()
        ..text = 'table{border-collapse:collapse;} td,th{border:1px solid #d1d5db;padding:4px 8px;white-space:nowrap;}';

      final contentDiv = html.DivElement();
      contentDiv.setInnerHtml(_renderHtml(widget.content), validator: _validator);

      wrap.append(style);
      wrap.append(contentDiv);
      _contentDiv = contentDiv;
      return wrap;
    });
  }

  @override
  void didUpdateWidget(RichContentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content && _contentDiv != null) {
      _contentDiv!.setInnerHtml(_renderHtml(widget.content), validator: _validator);
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
