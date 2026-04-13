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

    var result = text;

    // <style> 블록을 document.head로 이동 (xl 클래스 배경색 등 서식 보존)
    final styleMatches = RegExp(r'<style[^>]*>([\s\S]*?)<\/style>', caseSensitive: false).allMatches(text);
    for (final sm in styleMatches) {
      final styleEl = html.StyleElement()
        ..id = 'notice-viewer-style-${sm.start}'
        ..text = sm.group(1) ?? '';
      // 중복 삽입 방지
      if (html.document.getElementById('notice-viewer-style-${sm.start}') == null) {
        html.document.head!.append(styleEl);
      }
    }
    // HTML에서 style 블록 제거 (head로 이동했으므로)
    result = result.replaceAll(RegExp(r'<style[^>]*>[\s\S]*?<\/style>', caseSensitive: false), '');

    // 테이블 셀에 white-space:nowrap 강제 적용
    result = result.replaceAllMapped(
      RegExp(r'<(td|th)(\s[^>]*)?>', caseSensitive: false),
      (m) {
        final tag = m.group(1)!;
        final attrs = m.group(2) ?? '';
        if (attrs.contains('style=')) {
          return '<$tag${attrs.replaceFirstMapped(
            RegExp(r'style="([^"]*)"', caseSensitive: false),
            (sm) => 'style="${sm.group(1)};white-space:nowrap;"',
          )}>';
        }
        return '<$tag$attrs style="white-space:nowrap;">';
      },
    );

    return result;
  }

  @override
  void initState() {
    super.initState();
    _viewType = 'notice-viewer-${widget.viewId}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int id) {
      // 테이블 테두리 폴백 스타일 — head에 삽입 (platform view 안 style은 무시됨)
      final fallbackStyle = html.StyleElement()
        ..id = 'notice-viewer-table-style'
        ..text = 'table{border-collapse:collapse;} td,th{border:1px solid #d1d5db;padding:4px 8px;white-space:nowrap;}';
      if (html.document.getElementById('notice-viewer-table-style') == null) {
        html.document.head!.append(fallbackStyle);
      }

      final wrap = html.DivElement()
        ..style.cssText =
            'width:100%;height:100%;box-sizing:border-box;font-size:14px;'
            'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;'
            'color:#374151;overflow:auto;';

      // (platform view 내부 style은 적용 안 되므로 head 방식으로 대체)
      final style = html.StyleElement();

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
