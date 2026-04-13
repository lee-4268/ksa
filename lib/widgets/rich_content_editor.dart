// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
      final div = html.DivElement()
        ..contentEditable = 'true'
        ..tabIndex = 0
        ..style.cssText =
            'width:100%;height:100%;min-height:300px;padding:16px;'
            'box-sizing:border-box;font-size:15px;line-height:1.6;'
            'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;'
            'color:#374151;outline:none;overflow-y:auto;'
            'pointer-events:all;cursor:text;';

      // 엑셀/HTML paste 이벤트
      div.addEventListener('paste', (event) {
        event.preventDefault();
        final e = event as html.ClipboardEvent;
        final cd = e.clipboardData;
        if (cd == null) return;
        final types = cd.types ?? [];
        if (types.contains('text/html')) {
          var htmlStr = cd.getData('text/html');
          if (htmlStr.isNotEmpty) {
            // body 내부만 추출
            final tmp = html.DivElement()..innerHtml = htmlStr;
            final body = tmp.querySelector('body');
            var inner = body?.innerHtml ?? htmlStr;
            // mso 조건부 주석 제거
            inner = inner.replaceAll(
                RegExp(r'<!--\[if[^\]]*\]>[\s\S]*?<!\[endif\]-->'), '');
            // <style> 블록에서 xl 클래스(셀 서식)만 추출·보존
            final styleBuffer = StringBuffer();
            final styleMatches =
                RegExp(r'<style[^>]*>([\s\S]*?)<\/style>', caseSensitive: false)
                    .allMatches(inner);
            for (final sm in styleMatches) {
              final rules = sm.group(1) ?? '';
              final xlMatches =
                  RegExp(r'\.(xl\w+|x\w+)\s*\{([^}]+)\}').allMatches(rules);
              for (final rm in xlMatches) {
                final props = (rm.group(2) ?? '')
                    .replaceAll(RegExp(r'mso-[^;]+;?'), '')
                    .trim();
                if (props.isNotEmpty) {
                  styleBuffer.write('.${rm.group(1)}{$props}');
                }
              }
            }
            // style 블록 제거 후 xl 스타일만 다시 삽입
            inner = inner.replaceAll(
                RegExp(r'<style[^>]*>[\s\S]*?<\/style>', caseSensitive: false),
                '');
            if (styleBuffer.isNotEmpty) {
              inner = '<style>${styleBuffer.toString()}</style>$inner';
            }
            // ignore: deprecated_member_use
            html.document.execCommand('insertHTML', false, inner);
            return;
          }
        }
        final text = cd.getData('text/plain');
        if (text.isNotEmpty) {
          // ignore: deprecated_member_use
          html.document.execCommand('insertText', false, text);
        }
      });

      div.innerHtml = widget.initialHtml;
      _div = div;
      return div;
    });
  }

  /// 현재 에디터 HTML 내용 반환
  String getHtml() => _div?.innerHtml ?? '';

  /// 에디터 HTML 내용 설정
  void setHtml(String html) {
    _div?.innerHtml = html;
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
