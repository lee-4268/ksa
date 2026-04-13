// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// style 속성을 포함한 모든 속성을 허용하는 NodeValidator
class _AllowAllValidator implements html.NodeValidator {
  const _AllowAllValidator();
  @override
  bool allowsElement(html.Element element) => true;
  @override
  bool allowsAttribute(html.Element element, String attributeName, String value) => true;
}

const _validator = _AllowAllValidator();

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
  html.DivElement? _div;

  @override
  void initState() {
    super.initState();
    _viewType = 'notice-editor-${widget.viewId}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int id) {
      // 테이블 테두리 폴백 스타일 — head에 삽입
      final fallbackStyle = html.StyleElement()
        ..id = 'notice-editor-table-style'
        ..text = 'table{border-collapse:collapse;} td,th{border:1px solid #d1d5db;padding:4px 8px;white-space:nowrap;}';
      if (html.document.getElementById('notice-editor-table-style') == null) {
        html.document.head!.append(fallbackStyle);
      }

      final div = html.DivElement()
        ..contentEditable = 'true'
        ..tabIndex = 0
        ..style.cssText =
            'width:100%;height:100%;padding:16px;'
            'box-sizing:border-box;font-size:15px;line-height:1.6;'
            'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;'
            'color:#374151;outline:none;overflow:auto;'
            'pointer-events:all;cursor:text;';

      // 엑셀/HTML paste 이벤트
      div.addEventListener('paste', (event) {
        event.preventDefault();
        final e = event as html.ClipboardEvent;
        final cd = e.clipboardData;
        if (cd == null) return;
        final types = cd.types ?? [];
        if (types.contains('text/html')) {
          final htmlStr = cd.getData('text/html');
          if (htmlStr.isNotEmpty) {
            final cleaned = _processExcelHtml(htmlStr);
            // ignore: deprecated_member_use
            html.document.execCommand('insertHTML', false, cleaned);
            return;
          }
        }
        final text = cd.getData('text/plain');
        if (text.isNotEmpty) {
          // ignore: deprecated_member_use
          html.document.execCommand('insertText', false, text);
        }
      });

      if (widget.initialHtml.isNotEmpty) {
        div.setInnerHtml(widget.initialHtml, validator: _validator);
      }
      _div = div;
      return div;
    });
  }

  /// 엑셀 HTML 정제: mso 조건부 주석 제거, xl 클래스 스타일 보존
  String _processExcelHtml(String raw) {
    // body 내부만 추출 (정규식으로 처리 — DivElement.innerHtml이 style 제거하므로)
    final bodyMatch = RegExp(r'<body[^>]*>([\s\S]*?)<\/body>', caseSensitive: false).firstMatch(raw);
    var inner = bodyMatch?.group(1) ?? raw;

    // mso 조건부 주석 제거
    inner = inner.replaceAll(RegExp(r'<!--\[if[^\]]*\]>[\s\S]*?<!\[endif\]-->'), '');

    // <style> 블록에서 xl/x 클래스 규칙 추출 (mso- 속성 제거 후 보존)
    final styleBuffer = StringBuffer();
    final styleMatches = RegExp(r'<style[^>]*>([\s\S]*?)<\/style>', caseSensitive: false).allMatches(inner);
    for (final sm in styleMatches) {
      final rules = sm.group(1) ?? '';
      final xlMatches = RegExp(r'\.(xl\w+|x\w+)\s*\{([^}]+)\}').allMatches(rules);
      for (final rm in xlMatches) {
        final props = (rm.group(2) ?? '').replaceAll(RegExp(r'mso-[^;]+;?\s*'), '').trim();
        if (props.isNotEmpty) styleBuffer.write('.${rm.group(1)}{$props}');
      }
    }

    // style 블록 제거
    inner = inner.replaceAll(RegExp(r'<style[^>]*>[\s\S]*?<\/style>', caseSensitive: false), '');

    // <style>은 execCommand('insertHTML')로 삽입 불가 → document.head에 직접 추가
    if (styleBuffer.isNotEmpty) {
      final styleEl = html.StyleElement()
        ..id = 'excel-paste-style-${DateTime.now().millisecondsSinceEpoch}'
        ..text = styleBuffer.toString();
      html.document.head!.append(styleEl);
    }

    return inner;
  }

  /// 현재 에디터 HTML 내용 반환 (head의 excel 스타일도 포함)
  String getHtml() {
    if (_div == null) return '';
    // head에 삽입된 excel-paste-style 수집
    final styleEls = html.document.head!.querySelectorAll('[id^="excel-paste-style-"]');
    final styleBuf = StringBuffer();
    for (final el in styleEls) {
      styleBuf.write('<style>${(el as html.StyleElement).text}</style>');
    }
    return '${styleBuf.toString()}${_div!.innerHtml}';
  }

  /// 에디터 HTML 내용 설정
  void setHtml(String htmlContent) {
    _div?.setInnerHtml(htmlContent, validator: _validator);
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
        child: HtmlElementView(
          viewType: _viewType,
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        ),
      ),
    );
  }
}
