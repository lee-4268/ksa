// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// 브라우저에서 presigned URL로 다운로드
void openDownloadUrl(String url, String filename) {
  final anchor = html.AnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  html.document.body?.children.add(anchor);
  anchor.click();
  anchor.remove();
}
