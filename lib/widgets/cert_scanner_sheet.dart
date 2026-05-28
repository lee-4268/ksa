// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../screens/inspection_result_screen.dart';

/// 모바일 앱바 스캔 버튼 → 카메라 → OCR → 수검결과 입력 바텀시트
class CertScannerSheet extends StatefulWidget {
  const CertScannerSheet({super.key});

  @override
  State<CertScannerSheet> createState() => _CertScannerSheetState();
}

class _CertScannerSheetState extends State<CertScannerSheet> {
  static int _counter = 0;
  late final String _viewId;

  html.VideoElement? _video;
  html.MediaStream? _stream;

  bool _cameraReady = false;
  bool _scanning    = false;
  String? _error;
  Map<String, dynamic>? _result;

  static const _apiBase = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  static const _borderColor = Color(0xFFE5E7EB);
  static const _blue        = Color(0xFF1565C0);
  static const _blueSoft    = Color(0xFFEFF6FF);
  static const _textPrimary = Color(0xFF111827);
  static const _textGray    = Color(0xFF6B7280);

  @override
  void initState() {
    super.initState();
    _viewId = 'cert-scanner-${_counter++}';
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final stream = await html.window.navigator.mediaDevices!.getUserMedia({
        'video': {'facingMode': 'environment'},
        'audio': false,
      });
      _stream = stream;

      final video = html.VideoElement()
        ..srcObject = stream
        ..autoplay = true
        ..setAttribute('playsinline', 'true')
        ..style.width  = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover';
      _video = video;

      ui_web.platformViewRegistry.registerViewFactory(_viewId, (_) => video);

      video.onPlay.first.then((_) {
        if (mounted) setState(() => _cameraReady = true);
      });
    } catch (_) {
      if (mounted) setState(() => _error = '카메라 접근 권한이 필요합니다.\n브라우저 주소창의 자물쇠 아이콘을 눌러 카메라 권한을 허용해 주세요.');
    }
  }

  Future<void> _capture() async {
    final video = _video;
    if (video == null || !_cameraReady) return;
    setState(() { _scanning = true; _result = null; _error = null; });

    try {
      final w = video.videoWidth  > 0 ? video.videoWidth  : 1280;
      final h = video.videoHeight > 0 ? video.videoHeight : 720;
      final canvas = html.CanvasElement(width: w, height: h);
      canvas.context2D.drawImage(video, 0, 0);
      final dataUrl = canvas.toDataUrl('image/jpeg', 0.85);
      final base64  = dataUrl.split(',').last;

      final token  = context.read<AuthService>().authToken;
      final result = await _callOcr(base64, token);

      if (mounted) setState(() { _result = result; _scanning = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '스캔 실패: $e'; _scanning = false; });
    }
  }

  Future<Map<String, dynamic>> _callOcr(String base64Img, String? token) {
    final completer = Completer<Map<String, dynamic>>();
    final xhr = html.HttpRequest()
      ..open('POST', '$_apiBase/ocr/scan')
      ..setRequestHeader('Content-Type', 'application/json');
    if (token != null) xhr.setRequestHeader('Authorization', 'Bearer $token');

    xhr.onLoad.listen((_) {
      if (xhr.status == 200) {
        try {
          completer.complete(
            json.decode(xhr.responseText ?? '{}') as Map<String, dynamic>,
          );
        } catch (_) {
          completer.completeError(Exception('응답 파싱 오류'));
        }
      } else {
        completer.completeError(Exception('서버 오류 (${xhr.status})'));
      }
    });
    xhr.onError.listen((_) => completer.completeError(Exception('네트워크 오류')));
    xhr.send(json.encode({'image': base64Img}));
    return completer.future;
  }

  void _openResultSheet() {
    final r = _result;
    if (r == null) return;
    final licenseNo = (r['license_no'] as String? ?? '').trim();
    final callname  = (r['callname']  as String? ?? '').trim();
    if (licenseNo.isEmpty) return;

    Navigator.pop(context);
    final ctx = context; // capture before pop
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.92,
        child: InspectionResultScreen(
          year: DateTime.now().year,
          licenseNo: licenseNo,
          callname: callname,
          isSheet: true,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stream?.getTracks().forEach((t) => t.stop());
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          _buildHandle(),
          _buildHeader(),
          const Divider(height: 1, color: _borderColor),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHandle() => Container(
    margin: const EdgeInsets.only(top: 10, bottom: 6),
    width: 36, height: 4,
    decoration: BoxDecoration(
      color: const Color(0xFFDDE0E4),
      borderRadius: BorderRadius.circular(2),
    ),
  );

  Widget _buildHeader() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    child: Row(
      children: [
        const Icon(Icons.document_scanner_outlined, size: 20, color: _blue),
        const SizedBox(width: 10),
        const Text('확인증 스캔',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _textPrimary)),
        const SizedBox(width: 6),
        const Text('카메라로 비추고 촬영·스캔',
            style: TextStyle(fontSize: 11, color: _textGray)),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close, size: 20, color: _textGray),
          onPressed: () => Navigator.pop(context),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    ),
  );

  Widget _buildBody() {
    if (_error != null && !_scanning && _result == null) {
      return _buildErrorState();
    }
    return Column(
      children: [
        // 카메라 뷰
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _cameraReady
                  ? HtmlElementView(viewType: _viewId)
                  : _buildCameraLoading(),
            ),
          ),
        ),
        // OCR 결과
        if (_result != null) _buildResultCard(),
        // 하단 버튼
        _buildActions(),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
      ],
    );
  }

  Widget _buildCameraLoading() => Container(
    color: Colors.black87,
    child: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          SizedBox(height: 12),
          Text('카메라 연결 중…',
              style: TextStyle(color: Colors.white60, fontSize: 13)),
        ],
      ),
    ),
  );

  Widget _buildErrorState() => Padding(
    padding: const EdgeInsets.all(40),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.no_photography_outlined, size: 52, color: Color(0xFF9CA3AF)),
        const SizedBox(height: 16),
        Text(
          _error ?? '',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: _textGray, height: 1.6),
        ),
      ],
    ),
  );

  Widget _buildResultCard() {
    final r = _result!;
    final licenseNo = (r['license_no'] as String? ?? '').trim();
    final callname  = (r['callname']  as String? ?? '').trim();
    final ok = licenseNo.isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: ok ? _blueSoft : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ok ? const Color(0xFFBFDBFE) : const Color(0xFFFDE68A)),
      ),
      child: ok
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _resultRow(Icons.tag_rounded, '허가번호', licenseNo, bold: true),
                if (callname.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _resultRow(Icons.cell_tower_rounded, '호출명칭', callname),
                ],
              ],
            )
          : const Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFD97706)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '허가번호를 인식하지 못했습니다. 확인증이 잘 보이도록 다시 촬영해 주세요.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF92400E)),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _resultRow(IconData icon, String label, String value, {bool bold = false}) => Row(
    children: [
      Icon(icon, size: 13, color: _blue),
      const SizedBox(width: 6),
      Text('$label  ', style: const TextStyle(fontSize: 11, color: _textGray)),
      Expanded(
        child: Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: const Color(0xFF1E3A8A),
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );

  Widget _buildActions() {
    final hasLicense = (_result?['license_no'] as String? ?? '').trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _scanning ? null : _capture,
              icon: _scanning
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _blue))
                  : const Icon(Icons.camera_alt_outlined, size: 18),
              label: Text(_scanning
                  ? '스캔 중…'
                  : (_result == null ? '촬영·스캔' : '다시 스캔')),
              style: OutlinedButton.styleFrom(
                foregroundColor: _blue,
                side: const BorderSide(color: Color(0xFF3B82F6)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          if (hasLicense) ...[
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _openResultSheet,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('수검결과 열기'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _blue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
