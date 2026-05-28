// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../screens/inspection_result_screen.dart';

/// 확인증 스캔 바텀시트
///
/// 카메라 앱 직접 촬영 또는 갤러리에서 이미지 선택 →
/// base64 → /ocr/scan → 허가번호/호출명칭 추출 → 수검결과 열기
class CertScannerSheet extends StatefulWidget {
  const CertScannerSheet({super.key});

  @override
  State<CertScannerSheet> createState() => _CertScannerSheetState();
}

class _CertScannerSheetState extends State<CertScannerSheet> {
  Uint8List? _imageBytes;
  bool _scanning = false;
  String? _error;
  Map<String, dynamic>? _result;

  static const _apiBase = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  static const _blue        = Color(0xFF1565C0);
  static const _blueSoft    = Color(0xFFEFF6FF);
  static const _borderColor = Color(0xFFE5E7EB);
  static const _textPrimary = Color(0xFF111827);
  static const _textGray    = Color(0xFF6B7280);

  // ── 이미지 선택 ─────────────────────────────────────────────

  Future<void> _pickImage({required bool useCamera}) async {
    final input = html.FileUploadInputElement()
      ..accept = 'image/*'
      ..style.display = 'none';
    if (useCamera) input.setAttribute('capture', 'environment');

    html.document.body!.append(input);

    final completer = Completer<Uint8List?>();
    bool handled = false;

    input.onChange.listen((_) {
      if (handled) return;
      handled = true;
      final file = input.files?.first;
      if (file == null) { completer.complete(null); return; }
      final reader = html.FileReader()..readAsArrayBuffer(file);
      reader.onLoadEnd.first.then((_) {
        final res = reader.result;
        completer.complete(res is Uint8List ? res : null);
      });
    });
    input.addEventListener('cancel', (html.Event _) {
      if (!handled) { handled = true; completer.complete(null); }
    });
    input.click();

    final bytes = await completer.future;
    try { input.remove(); } catch (_) {}

    if (bytes == null || !mounted) return;
    setState(() { _imageBytes = bytes; _result = null; _error = null; });
    _scan(bytes);
  }

  // ── OCR 호출 ────────────────────────────────────────────────

  Future<void> _scan(Uint8List bytes) async {
    setState(() { _scanning = true; _error = null; });
    try {
      final b64    = base64Encode(bytes);
      final token  = context.read<AuthService>().authToken;
      final result = await _callOcr(b64, token);
      if (mounted) setState(() { _result = result; _scanning = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '스캔 실패: $e'; _scanning = false; });
    }
  }

  Future<Map<String, dynamic>> _callOcr(String b64, String? token) {
    final c = Completer<Map<String, dynamic>>();
    final xhr = html.HttpRequest()
      ..open('POST', '$_apiBase/ocr/scan')
      ..setRequestHeader('Content-Type', 'application/json');
    if (token != null) xhr.setRequestHeader('Authorization', 'Bearer $token');
    xhr.onLoad.listen((_) {
      if (xhr.status == 200) {
        try { c.complete(json.decode(xhr.responseText ?? '{}') as Map<String, dynamic>); }
        catch (_) { c.completeError(Exception('응답 파싱 오류')); }
      } else {
        c.completeError(Exception('서버 오류 (${xhr.status})'));
      }
    });
    xhr.onError.listen((_) => c.completeError(Exception('네트워크 오류')));
    xhr.send(json.encode({'image': b64}));
    return c.future;
  }

  // ── 수검결과 열기 ────────────────────────────────────────────

  void _openResultSheet() {
    final r = _result;
    if (r == null) return;
    final licenseNo = (r['license_no'] as String? ?? '').trim();
    final callname  = (r['callname']  as String? ?? '').trim();
    if (licenseNo.isEmpty) return;

    Navigator.pop(context);
    final ctx = context;
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
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Row(
      children: [
        const Icon(Icons.document_scanner_outlined, size: 20, color: _blue),
        const SizedBox(width: 10),
        const Text('확인증 스캔',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _textPrimary)),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 안내 문구
          _buildGuide(),
          const SizedBox(height: 20),

          // 이미지 선택 버튼 (카메라 / 갤러리)
          _buildPickButtons(),
          const SizedBox(height: 20),

          // 선택된 이미지 미리보기
          if (_imageBytes != null) ...[
            _buildPreview(),
            const SizedBox(height: 16),
          ],

          // OCR 결과
          if (_scanning)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  children: [
                    CircularProgressIndicator(color: _blue, strokeWidth: 2),
                    SizedBox(height: 10),
                    Text('텍스트 인식 중…',
                        style: TextStyle(fontSize: 13, color: _textGray)),
                  ],
                ),
              ),
            )
          else if (_result != null)
            _buildResultCard(),

          // 에러
          if (_error != null && !_scanning)
            _buildErrorCard(),

          // 수검결과 열기 버튼
          if ((_result?['license_no'] as String? ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildOpenButton(),
          ],

          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }

  Widget _buildGuide() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _blueSoft,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFBFDBFE)),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 16, color: _blue),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '무선국 검사 확인증을 촬영하거나 갤러리에서 사진을 선택하세요.\n'
            '허가번호·호출명칭을 자동으로 인식합니다.',
            style: TextStyle(fontSize: 12, color: Color(0xFF1E40AF), height: 1.5),
          ),
        ),
      ],
    ),
  );

  Widget _buildPickButtons() => Row(
    children: [
      Expanded(
        child: _PickButton(
          icon: Icons.camera_alt_outlined,
          label: '카메라 촬영',
          sub: '확인증을 직접 촬영',
          color: _blue,
          onTap: () => _pickImage(useCamera: true),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: _PickButton(
          icon: Icons.photo_library_outlined,
          label: '갤러리 선택',
          sub: '저장된 사진 불러오기',
          color: const Color(0xFF6D28D9),
          onTap: () => _pickImage(useCamera: false),
        ),
      ),
    ],
  );

  Widget _buildPreview() => ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: Stack(
      children: [
        Image.memory(
          _imageBytes!,
          width: double.infinity,
          height: 220,
          fit: BoxFit.cover,
        ),
        if (_scanning)
          Positioned.fill(
            child: Container(
              color: Colors.black38,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
              ),
            ),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ok ? _blueSoft : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: ok ? const Color(0xFFBFDBFE) : const Color(0xFFFDE68A),
        ),
      ),
      child: ok
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.check_circle_outline, size: 16, color: Color(0xFF1D4ED8)),
                  const SizedBox(width: 6),
                  const Text('인식 완료',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1D4ED8))),
                ]),
                const SizedBox(height: 10),
                _resultRow(Icons.tag_rounded, '허가번호', licenseNo, bold: true),
                if (callname.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _resultRow(Icons.cell_tower_rounded, '호출명칭', callname),
                ],
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.warning_amber_rounded, size: 15, color: Color(0xFFD97706)),
                  SizedBox(width: 6),
                  Text('인식 실패',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF92400E))),
                ]),
                const SizedBox(height: 6),
                const Text(
                  '허가번호를 인식하지 못했습니다.\n'
                  '· 확인증 전체가 화면에 들어오도록 촬영해 주세요\n'
                  '· 글자가 흔들리지 않고 선명한지 확인해 주세요\n'
                  '· 밝은 조명 환경에서 촬영하면 인식률이 높아집니다',
                  style: TextStyle(fontSize: 12, color: Color(0xFF92400E), height: 1.6),
                ),
              ],
            ),
    );
  }

  Widget _resultRow(IconData icon, String label, String value, {bool bold = false}) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 14, color: _blue),
      const SizedBox(width: 6),
      Text('$label  ', style: const TextStyle(fontSize: 12, color: _textGray)),
      Expanded(
        child: Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: const Color(0xFF1E3A8A),
          ),
        ),
      ),
    ],
  );

  Widget _buildErrorCard() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFEF2F2),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFFCA5A5)),
    ),
    child: Text(_error ?? '', style: const TextStyle(fontSize: 12, color: Color(0xFF991B1B))),
  );

  Widget _buildOpenButton() => SizedBox(
    width: double.infinity,
    child: ElevatedButton.icon(
      onPressed: _openResultSheet,
      icon: const Icon(Icons.open_in_new, size: 16),
      label: const Text('수검결과 입력 화면 열기',
          style: TextStyle(fontWeight: FontWeight.w700)),
      style: ElevatedButton.styleFrom(
        backgroundColor: _blue,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

// ── 이미지 선택 버튼 카드 ─────────────────────────────────────

class _PickButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final Color color;
  final VoidCallback onTap;

  const _PickButton({
    required this.icon,
    required this.label,
    required this.sub,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 26, color: color),
              ),
              const SizedBox(height: 10),
              Text(label,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
              const SizedBox(height: 2),
              Text(sub,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
