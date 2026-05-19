// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 게시판/공지 HTML 렌더링용 화이트리스트 validator.
/// XSS 방어: <script>, on* 이벤트, javascript:/data: URL, iframe 등 위험 요소 차단.
/// 허용: 텍스트 서식·표·리스트·이미지·링크·일부 인라인 스타일.
class _SafeContentValidator implements html.NodeValidator {
  static const _allowedTags = <String>{
    // 블록·문단
    'P', 'DIV', 'BR', 'HR', 'BLOCKQUOTE', 'PRE', 'CODE',
    // 헤더
    'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
    // 인라인 텍스트
    'SPAN', 'STRONG', 'B', 'EM', 'I', 'U', 'S', 'STRIKE', 'SUB', 'SUP',
    'SMALL', 'MARK', 'FONT',
    // 리스트
    'UL', 'OL', 'LI',
    // 표
    'TABLE', 'THEAD', 'TBODY', 'TFOOT', 'TR', 'TH', 'TD', 'CAPTION', 'COLGROUP', 'COL',
    // 링크·이미지
    'A', 'IMG', 'FIGURE', 'FIGCAPTION',
  };

  // 모든 요소에 공통으로 허용되는 안전 속성
  static const _commonAttrs = <String>{
    'class', 'id', 'style', 'title', 'lang', 'dir',
    // 표 관련
    'colspan', 'rowspan', 'align', 'valign', 'width', 'height',
    'border', 'cellpadding', 'cellspacing',
  };

  // 태그별 추가 속성 화이트리스트
  static const _tagAttrs = <String, Set<String>>{
    'A': {'href', 'target', 'rel'},
    'IMG': {'src', 'alt', 'width', 'height'},
  };

  // 차단할 CSS 값 패턴 (XSS 우회) — expression(), javascript: URL, @import 등
  static bool _hasUnsafeStyle(String value) {
    final v = value.toLowerCase();
    if (v.contains('expression')) return true;
    if (v.contains('javascript:')) return true;
    if (v.contains('vbscript:')) return true;
    if (v.contains('behavior:')) return true;
    if (v.contains('@import')) return true;
    // url(javascript:...), url(data:...), url(vbscript:...) 패턴 탐지 (공백 허용)
    final urlIdx = v.indexOf('url(');
    if (urlIdx >= 0) {
      final after = v.substring(urlIdx + 4).trimLeft().replaceFirst(RegExp('^["\']'), '');
      if (after.startsWith('javascript:') ||
          after.startsWith('vbscript:') ||
          after.startsWith('data:')) {
        return true;
      }
    }
    return false;
  }

  // 차단할 URL 스킴
  static bool _isSafeUrl(String value) {
    final v = value.trim().toLowerCase();
    if (v.startsWith('javascript:') || v.startsWith('vbscript:') || v.startsWith('data:')) {
      return false;
    }
    // 상대경로, http(s), mailto, 앵커는 허용
    return true;
  }

  const _SafeContentValidator();

  @override
  bool allowsElement(html.Element element) {
    return _allowedTags.contains(element.tagName);
  }

  @override
  bool allowsAttribute(html.Element element, String attributeName, String value) {
    final attr = attributeName.toLowerCase();

    // on* 이벤트 핸들러 일괄 차단 (onerror, onclick, onload 등)
    if (attr.startsWith('on')) return false;

    // src/href 는 URL 스킴 검증
    if (attr == 'src' || attr == 'href') {
      if (!_isSafeUrl(value)) return false;
      // IMG src 의 data: 스킴은 차단 (위에서 처리), http/https/상대만 허용
      return true;
    }

    // style 속성은 위험 패턴 차단
    if (attr == 'style') {
      return !_hasUnsafeStyle(value);
    }

    // 태그별 화이트리스트
    final tagSpecific = _tagAttrs[element.tagName] ?? const <String>{};
    if (tagSpecific.contains(attr) || _commonAttrs.contains(attr)) {
      return true;
    }

    // data-* 는 일반적으로 안전 (DOM clobbering 외에는 실행 위험 없음)
    if (attr.startsWith('data-')) return true;

    return false;
  }
}

const _validator = _SafeContentValidator();

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
            'color:#374151;overflow:auto;user-select:text;-webkit-user-select:text;';

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
      child: HtmlElementView(
        viewType: _viewType,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
    );
  }
}
