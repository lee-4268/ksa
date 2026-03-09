import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../services/auth_service.dart';
import '../services/certificate_service.dart';
import 'certificate_download_stub.dart'
    if (dart.library.html) 'certificate_download_web.dart' as dl;

/// 설치확인서 생성 화면 — 개별 / 일괄 탭
class CertificateScreen extends StatefulWidget {
  const CertificateScreen({super.key});

  @override
  State<CertificateScreen> createState() => _CertificateScreenState();
}

class _CertificateScreenState extends State<CertificateScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _service = CertificateService();

  static const _themeColor = Color(0xFF00838F);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _service.setAuthToken(context.read<AuthService>().authToken);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('설치확인서',
            style: TextStyle(
                color: Colors.black87, fontSize: 18, fontWeight: FontWeight.w600)),
        bottom: TabBar(
          controller: _tabController,
          labelColor: _themeColor,
          unselectedLabelColor: Colors.grey,
          indicatorColor: _themeColor,
          tabs: const [Tab(text: '개별 생성'), Tab(text: '일괄 생성')],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _IndividualTab(service: _service),
          _BatchTab(service: _service),
        ],
      ),
    );
  }
}

// ╔══════════════════════════════════════════════════════════════╗
// ║                     개별 생성 탭                              ║
// ╚══════════════════════════════════════════════════════════════╝
class _IndividualTab extends StatefulWidget {
  final CertificateService service;
  const _IndividualTab({required this.service});

  @override
  State<_IndividualTab> createState() => _IndividualTabState();
}

class _IndividualTabState extends State<_IndividualTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // 테마 색상
  static const _accent = Color(0xFFE53935);
  static const _accentBlue = Color(0xFF1565C0);

  final _queryCtrl = TextEditingController();
  final _zpwinoCtrl = TextEditingController();
  final _zpwinaCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _installerCtrl = TextEditingController(text: '에스케이텔레콤 주식회사');
  final _antennaCountCtrl = TextEditingController(text: '1');
  final _otherAntennaCtrl = TextEditingController(text: '0');
  final _coZpwinoCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();

  String _antennaFrameType = '-';
  final List<String> _antennaFrameOptions = [
    '-', '철탑(지면)', '강관주', '통신주', '원폴(건물)', '옥내, 터널, 지하, 차량',
    '쌍통신주', '기설물', '옥내외 혼합형', '간이폴 및 비기준 설치대',
    '한전주(KT통신주)', '철탑(건물)', '프레임', '복합형(원폴, 분산프레임 등)', '모노폴',
  ];

  String _sharingType = '-';
  final List<String> _sharingOptions = ['-', '단독', '공용'];

  // 공동신청 시설자명 체크박스
  bool _coSkt = false;
  bool _coKt = false;
  bool _coLgu = false;

  bool _isLooking = false;
  bool _isGenerating = false;
  String? _lookupError;

  // 이미지
  Uint8List? _blueprintBytes;
  String? _blueprintName;
  final List<Uint8List> _photoBytes = [];
  final List<String> _photoNames = [];

  // 미리보기 탭
  int _previewTab = 0; // 0: 설치확인서, 1: 현장사진

  @override
  void dispose() {
    _queryCtrl.dispose();
    _zpwinoCtrl.dispose();
    _zpwinaCtrl.dispose();
    _addressCtrl.dispose();
    _installerCtrl.dispose();
    _antennaCountCtrl.dispose();
    _otherAntennaCtrl.dispose();
    _coZpwinoCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  String get _coInstallerName {
    final parts = <String>[];
    if (_coSkt) parts.add('SKT');
    if (_coKt) parts.add('KT');
    if (_coLgu) parts.add('LGU+');
    return parts.join(', ');
  }

  String get _antennaCountDisplay {
    final ac = int.tryParse(_antennaCountCtrl.text) ?? 1;
    final oac = int.tryParse(_otherAntennaCtrl.text) ?? 0;
    return oac > 0 ? '$ac(타$oac)' : '$ac';
  }

  Future<void> _doLookup() async {
    final q = _queryCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() { _isLooking = true; _lookupError = null; });
    try {
      final res = await widget.service.lookup(q);
      if (!mounted) return;
      if (res['found'] == true) {
        _zpwinoCtrl.text = res['zpwino'] ?? '';
        _zpwinaCtrl.text = res['zpwina'] ?? '';
        _addressCtrl.text = res['zpwiadr'] ?? '';
        final frame = res['zpirty3'] ?? '';
        _antennaFrameType = _antennaFrameOptions.contains(frame) ? frame : '-';
        _lookupError = null;
      } else {
        _lookupError = '조회 결과가 없습니다.';
      }
    } catch (e) {
      _lookupError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _isLooking = false);
    }
  }

  /// FilePicker wrapper — 첫 호출 focus race condition 자동 재시도
  Future<FilePickerResult?> _tryPickImage() async {
    try {
      return await FilePicker.platform
          .pickFiles(type: FileType.image, withData: true);
    } catch (e) {
      debugPrint('FilePicker 오류: $e');
      return null;
    }
  }

  Future<FilePickerResult?> _pickImageSafe() async {
    final sw = Stopwatch()..start();
    var result = await _tryPickImage();
    sw.stop();
    if ((result == null || result.files.isEmpty) &&
        sw.elapsedMilliseconds < 2000) {
      result = await _tryPickImage();
    }
    return result;
  }

  Future<void> _pickBlueprint() async {
    final result = await _pickImageSafe();
    if (result != null && result.files.isNotEmpty && result.files.single.bytes != null) {
      setState(() {
        _blueprintBytes = result.files.single.bytes;
        _blueprintName = result.files.single.name;
      });
    }
  }

  Future<void> _pickPhoto(int index) async {
    final result = await _pickImageSafe();
    if (result != null && result.files.isNotEmpty && result.files.single.bytes != null) {
      setState(() {
        if (index < _photoBytes.length) {
          _photoBytes[index] = result.files.single.bytes!;
          _photoNames[index] = result.files.single.name;
        } else {
          _photoBytes.add(result.files.single.bytes!);
          _photoNames.add(result.files.single.name);
        }
      });
    }
  }

  void _removePhoto(int index) {
    setState(() {
      _photoBytes.removeAt(index);
      _photoNames.removeAt(index);
    });
  }

  String _bytesToBase64DataUrl(Uint8List bytes) {
    return 'data:image/jpeg;base64,${base64Encode(bytes)}';
  }

  Map<String, dynamic> _buildFormData() {
    return {
      'installer_name': _installerCtrl.text.isEmpty ? '에스케이텔레콤 주식회사' : _installerCtrl.text,
      'zpwino': _zpwinoCtrl.text,
      'zpwina': _zpwinaCtrl.text,
      'zpwiadr': _addressCtrl.text,
      'antenna_frame_type': _antennaFrameType == '-' ? '' : _antennaFrameType,
      'sharing_type': _sharingType == '-' ? '' : _sharingType,
      'antenna_count': int.tryParse(_antennaCountCtrl.text) ?? 1,
      'other_antenna_count': int.tryParse(_otherAntennaCtrl.text) ?? 0,
      'co_installer_name': _coInstallerName,
      'co_zpwino': _coZpwinoCtrl.text,
      'remark': _remarkCtrl.text,
    };
  }

  Future<void> _generate(String format) async {
    if (_zpwinoCtrl.text.trim().isEmpty && _zpwinaCtrl.text.trim().isEmpty) {
      _showSnack('먼저 허가번호를 조회하거나 입력하세요.');
      return;
    }
    setState(() => _isGenerating = true);
    try {
      final photosB64 = _photoBytes.map((b) => _bytesToBase64DataUrl(b)).toList();
      final blueprintB64 = _blueprintBytes != null ? _bytesToBase64DataUrl(_blueprintBytes!) : null;
      final bytes = await widget.service.generate(
        formData: _buildFormData(),
        format: format,
        photosBase64: photosB64.isNotEmpty ? photosB64 : null,
        blueprintBase64: blueprintB64,
      );
      final ext = format == 'hwpx' ? 'hwpx' : 'pdf';
      final zpwino = _zpwinoCtrl.text.isNotEmpty ? _zpwinoCtrl.text : 'cert';
      dl.downloadFileBytes(bytes, '$zpwino.$ext');
      if (mounted) _showSnack('설치확인서 다운로드 완료');
    } catch (e) {
      if (mounted) _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isWide = MediaQuery.of(context).size.width > 900;

    if (isWide) {
      return Row(
        children: [
          // 왼쪽: 입력 폼 (다크 테마)
          SizedBox(
            width: 420,
            child: _buildFormPanel(),
          ),
          // 오른쪽: 미리보기
          Expanded(child: _buildPreviewPanel()),
        ],
      );
    }

    // 좁은 화면: 폼만 표시
    return _buildFormPanel();
  }

  // ── 왼쪽 입력 폼 ──
  Widget _buildFormPanel() {
    return Container(
      color: Colors.white,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // 타이틀
          const Text('무선국 설치확인서',
              style: TextStyle(color: Colors.black87, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('허가번호 입력 시 DB에서 자동으로 정보를 불러옵니다',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(height: 24),

          // 허가번호 입력
          _formLabel('허가번호', required: true, sub: '하이픈 기호(-, hyphen) 제외, 숫자만 입력하세요.'),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _formField(_queryCtrl, '허가번호 입력 (예: 3220104100)',
                  onSubmitted: (_) => _doLookup())),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _isLooking ? null : _doLookup,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _isLooking
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('조회'),
                ),
              ),
            ],
          ),
          if (_lookupError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_lookupError!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
          const SizedBox(height: 16),

          // 호출명칭
          _formLabel('호출명칭'),
          const SizedBox(height: 6),
          _formField(_zpwinaCtrl, '자동 입력'),
          const SizedBox(height: 16),

          // 설치장소
          _formLabel('설치장소'),
          const SizedBox(height: 6),
          _formField(_addressCtrl, '자동 입력'),
          const SizedBox(height: 24),

          // ── 시설자 정보 ──
          _sectionTitle('시설자 정보'),
          _formLabel('시설자명'),
          const SizedBox(height: 6),
          _formField(_installerCtrl, '에스케이텔레콤 주식회사'),
          const SizedBox(height: 16),

          _formLabel('안테나설치대 형태'),
          const SizedBox(height: 6),
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _antennaFrameType,
                isExpanded: true,
                style: const TextStyle(color: Colors.black87, fontSize: 14),
                icon: Icon(Icons.keyboard_arrow_down, color: Colors.grey.shade600),
                items: _antennaFrameOptions.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (v) => setState(() => _antennaFrameType = v ?? '-'),
              ),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _formLabel('공용 안테나 수'),
                    const SizedBox(height: 6),
                    _formField(_antennaCountCtrl, '1', keyboardType: TextInputType.number),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _formLabel('타사 안테나 수'),
                    const SizedBox(height: 6),
                    _formField(_otherAntennaCtrl, '0', keyboardType: TextInputType.number),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          _formLabel('공용화 구분'),
          const SizedBox(height: 6),
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _sharingType,
                isExpanded: true,
                style: const TextStyle(color: Colors.black87, fontSize: 14),
                icon: Icon(Icons.keyboard_arrow_down, color: Colors.grey.shade600),
                items: _sharingOptions.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (v) => setState(() => _sharingType = v ?? '-'),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ── 공동신청 ──
          _sectionTitle('공동신청 (선택)'),
          _formLabel('공동신청 시설자명'),
          const SizedBox(height: 8),
          Row(
            children: [
              _checkboxChip('SKT', _coSkt, (v) => setState(() => _coSkt = v)),
              const SizedBox(width: 8),
              _checkboxChip('KT', _coKt, (v) => setState(() => _coKt = v)),
              const SizedBox(width: 8),
              _checkboxChip('LGU+', _coLgu, (v) => setState(() => _coLgu = v)),
            ],
          ),
          const SizedBox(height: 16),
          _formLabel('공동신청 허가번호'),
          const SizedBox(height: 6),
          _formField(_coZpwinoCtrl, '(필요 시 입력)'),
          const SizedBox(height: 24),

          // ── 첨부 자료 ──
          _sectionTitle('첨부 자료'),
          _formLabel('설계도면'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _pickBlueprint,
            child: Container(
              height: 80,
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),
              ),
              child: _blueprintBytes != null
                  ? Stack(
                      children: [
                        Center(child: Image.memory(_blueprintBytes!, height: 70, fit: BoxFit.contain)),
                        Positioned(
                          top: 4, right: 4,
                          child: GestureDetector(
                            onTap: () => setState(() { _blueprintBytes = null; _blueprintName = null; }),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                              child: const Icon(Icons.close, size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.image_outlined, color: Colors.grey.shade400, size: 28),
                        const SizedBox(height: 4),
                        Text('클릭하여 이미지 선택', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 16),

          _formLabel('현장사진 (최대 8장)'),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 8,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1,
            ),
            itemBuilder: (_, i) {
              final hasPhoto = i < _photoBytes.length;
              return GestureDetector(
                onTap: () => hasPhoto ? null : _pickPhoto(i),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: hasPhoto
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(7),
                              child: Image.memory(_photoBytes[i], fit: BoxFit.cover),
                            ),
                            Positioned(
                              top: 2, right: 2,
                              child: GestureDetector(
                                onTap: () => _removePhoto(i),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                                  child: const Icon(Icons.close, size: 12, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.image_outlined, color: Colors.grey.shade400, size: 22),
                            Text('${i + 1}', style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                          ],
                        ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // 특이사항
          _formLabel('특이사항'),
          const SizedBox(height: 6),
          TextField(
            controller: _remarkCtrl,
            maxLines: 3,
            style: const TextStyle(color: Colors.black87, fontSize: 14),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '특이사항이 있으면 입력하세요',
              hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              filled: true,
              fillColor: Colors.grey.shade100,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _accent, width: 1.5)),
            ),
          ),
          const SizedBox(height: 24),

          // 생성 버튼
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isGenerating ? null : () => _generate('pdf'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _isGenerating
                        ? const SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('PDF 다운로드', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isGenerating ? null : () => _generate('hwpx'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accentBlue,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _isGenerating
                        ? const SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('HWPX 다운로드', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── 오른쪽 미리보기 패널 ──
  Widget _buildPreviewPanel() {
    return Container(
      color: Colors.grey.shade100,
      child: Column(
        children: [
          // 미리보기 탭
          Container(
            color: Colors.white,
            child: Row(
              children: [
                _previewTabBtn(0, '설치확인서'),
                _previewTabBtn(1, '현장사진'),
              ],
            ),
          ),
          // 미리보기 내용
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _previewTab == 0 ? _buildCertPreview() : _buildPhotoPreview(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewTabBtn(int idx, String label) {
    final active = _previewTab == idx;
    return GestureDetector(
      onTap: () => setState(() => _previewTab = idx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? _CertificateScreenState._themeColor : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(label,
            style: TextStyle(
              color: active ? _CertificateScreenState._themeColor : Colors.grey,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              fontSize: 13,
            )),
      ),
    );
  }

  // ── 설치확인서 미리보기 ──
  Widget _buildCertPreview() {
    final installer = _installerCtrl.text.isEmpty ? '에스케이텔레콤 주식회사' : _installerCtrl.text;
    return Container(
      color: Colors.white,
      child: Column(
        children: [
          // 별지 텍스트
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('[별지] 이동통신무선국 설치 확인서',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade700)),
            ),
          ),
          // 제목 행 (통합 셀)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Colors.black, width: 0.5),
                left: BorderSide(color: Colors.black, width: 0.5),
                right: BorderSide(color: Colors.black, width: 0.5),
              ),
            ),
            child: const Text('이동통신무선국 설치 확인서',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          ),
          // 테이블
          Table(
            border: TableBorder.all(color: Colors.black, width: 0.5),
            columnWidths: const {
              0: FixedColumnWidth(80),
              1: FlexColumnWidth(1),
              2: FixedColumnWidth(80),
              3: FlexColumnWidth(1),
            },
            children: [
              // 시설자명 | 허가번호
              _tRow('시설자명', installer, '허가번호', _zpwinoCtrl.text),
              // 공동신청 시설자명 | 공동신청 허가번호
              _tRow2('공동신청 시설자명\n(필요 시 입력)', _coInstallerName, '공동신청 허가번호\n(필요 시 입력)', _coZpwinoCtrl.text),
              // 안테나설치대 형태 | 호출명칭
              TableRow(children: [
                _tHeaderCellSm('안테나설치대 형태'),
                _tValueCell(_antennaFrameType),
                _tHeaderCell('호출명칭'),
                _tValueCell(_zpwinaCtrl.text),
              ]),
              // 공용화 구분 | 안테나 수
              _tRow('공용화 구분', _sharingType, '안테나 수', _antennaCountDisplay),
              // 설치장소
              _tRowSpan('설치장소', _addressCtrl.text),
              // 특이사항
              _tRowSpan('특이사항', _remarkCtrl.text.isEmpty ? '-' : _remarkCtrl.text),
            ],
          ),
          // 설계도면 (큰 영역)
          Table(
            border: TableBorder.all(color: Colors.black, width: 0.5),
            columnWidths: const {
              0: FixedColumnWidth(80),
              1: FlexColumnWidth(1),
            },
            children: [
              TableRow(children: [
                _tHeaderCell('설계\n도면'),
                Container(
                  height: 250,
                  alignment: Alignment.center,
                  child: _blueprintBytes != null
                      ? Image.memory(_blueprintBytes!, fit: BoxFit.contain)
                      : Text('-', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                ),
              ]),
            ],
          ),
          // 현장사진 행
          Table(
            border: TableBorder.all(color: Colors.black, width: 0.5),
            columnWidths: const {
              0: FixedColumnWidth(80),
              1: FlexColumnWidth(1),
            },
            children: [
              TableRow(children: [
                _tHeaderCell('현장\n사진'),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_photoBytes.isNotEmpty ? "붙임' 참조" : '-',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      Text('※ 굵은 글씨 항목은 필수 항목',
                          style: TextStyle(fontSize: 8, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
              ]),
            ],
          ),
        ],
      ),
    );
  }

  // ── 현장사진 미리보기 ──
  Widget _buildPhotoPreview() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('[붙임] 현장사진',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 8,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, mainAxisSpacing: 4, crossAxisSpacing: 4, childAspectRatio: 1,
            ),
            itemBuilder: (_, i) {
              return Container(
                decoration: BoxDecoration(border: Border.all(color: Colors.black, width: 0.5)),
                child: i < _photoBytes.length
                    ? Image.memory(_photoBytes[i], fit: BoxFit.contain)
                    : const SizedBox(),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── 테이블 Helper ──
  TableRow _tRow(String h1, String v1, String h2, String v2) {
    return TableRow(children: [
      _tHeaderCell(h1),
      _tValueCell(v1),
      _tHeaderCell(h2),
      _tValueCell(v2),
    ]);
  }

  TableRow _tRow2(String h1, String v1, String h2, String v2) {
    return TableRow(children: [
      _tHeaderCellSm(h1),
      _tValueCell(v1),
      _tHeaderCellSm(h2),
      _tValueCell(v2),
    ]);
  }

  TableRow _tRowSpan(String header, String value) {
    return TableRow(children: [
      _tHeaderCell(header),
      _tValueCell(value),
      const SizedBox(),
      const SizedBox(),
    ]);
  }

  Widget _tHeaderCell(String text) {
    return TableCell(
      verticalAlignment: TableCellVerticalAlignment.middle,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Text(text, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _tHeaderCellSm(String text) {
    return TableCell(
      verticalAlignment: TableCellVerticalAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Text(text, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 8)),
      ),
    );
  }

  Widget _tValueCell(String text) {
    return TableCell(
      verticalAlignment: TableCellVerticalAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Text(text.isEmpty ? '-' : text, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10)),
      ),
    );
  }

  // ── 폼 Helper ──
  Widget _formLabel(String text, {bool required = false, String? sub}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(text, style: const TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w500)),
            if (required)
              const Text(' *', style: TextStyle(color: _accent, fontSize: 13)),
          ],
        ),
        if (sub != null)
          Text(sub, style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
      ],
    );
  }

  Widget _formField(TextEditingController ctrl, String hint,
      {TextInputType? keyboardType, void Function(String)? onSubmitted}) {
    return SizedBox(
      height: 48,
      child: TextField(
        controller: ctrl,
        keyboardType: keyboardType,
        onSubmitted: onSubmitted,
        onChanged: (_) => setState(() {}),
        style: const TextStyle(color: Colors.black87, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          filled: true,
          fillColor: Colors.grey.shade100,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _accent, width: 1.5)),
        ),
      ),
    );
  }

  Widget _checkboxChip(String label, bool value, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: value ? _accent.withValues(alpha: 0.1) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: value ? _accent : Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(value ? Icons.check_box : Icons.check_box_outline_blank,
                size: 18, color: value ? _accent : Colors.grey.shade400),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: value ? _accent : Colors.black87, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text, style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

// ╔══════════════════════════════════════════════════════════════╗
// ║                     일괄 생성 탭                              ║
// ╚══════════════════════════════════════════════════════════════╝
class _BatchTab extends StatefulWidget {
  final CertificateService service;
  const _BatchTab({required this.service});

  @override
  State<_BatchTab> createState() => _BatchTabState();
}

class _BatchTabState extends State<_BatchTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const _themeColor = Color(0xFF00838F);

  int _step = 0;
  final _batchInputCtrl = TextEditingController();
  bool _isBatchLooking = false;
  String? _batchLookupError;

  List<Map<String, dynamic>> _lookupItems = [];
  int _foundCount = 0;

  final _bInstallerCtrl = TextEditingController(text: '에스케이텔레콤 주식회사');
  final _bSharingCtrl = TextEditingController();
  final _bAntennaCountCtrl = TextEditingController(text: '1');
  final _bOtherAntennaCtrl = TextEditingController(text: '0');

  bool _isUploadingPhotos = false;
  String? _photoJobId;
  Map<String, dynamic>? _photoSummary;
  String? _photoUploadError;

  bool _isGenerating = false;
  double _progress = 0;
  int _genCurrent = 0;
  int _genTotal = 0;
  String? _currentZpwino;
  String? _resultJobId;
  int _successCount = 0;
  int _failCount = 0;
  bool _genDone = false;
  String? _genError;
  bool _isDownloading = false;

  @override
  void dispose() {
    _batchInputCtrl.dispose();
    _bInstallerCtrl.dispose();
    _bSharingCtrl.dispose();
    _bAntennaCountCtrl.dispose();
    _bOtherAntennaCtrl.dispose();
    super.dispose();
  }

  List<String> _parseZpwinoList() {
    final text = _batchInputCtrl.text.trim();
    if (text.isEmpty) return [];
    return text.split(RegExp(r'[\n,;]+'))
        .map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList();
  }

  Future<void> _doBatchLookup() async {
    final list = _parseZpwinoList();
    if (list.isEmpty) { setState(() => _batchLookupError = '허가번호를 입력하세요.'); return; }
    if (list.length > 500) { setState(() => _batchLookupError = '최대 500건까지 조회 가능합니다.'); return; }
    setState(() { _isBatchLooking = true; _batchLookupError = null; });
    try {
      final res = await widget.service.batchLookup(list);
      if (!mounted) return;
      _lookupItems = (res['items'] as List).map((e) => e as Map<String, dynamic>).toList();
      _foundCount = res['found'] as int? ?? 0;
      _step = 1;
    } catch (e) {
      _batchLookupError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _isBatchLooking = false);
    }
  }

  Future<void> _uploadPhotoZip() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['zip'], withData: true);
    if (result == null || result.files.single.bytes == null) return;
    setState(() { _isUploadingPhotos = true; _photoUploadError = null; });
    try {
      final res = await widget.service.uploadPhotos(result.files.single.bytes!, result.files.single.name);
      if (!mounted) return;
      _photoJobId = res['photo_job_id'] as String?;
      _photoSummary = res['summary'] as Map<String, dynamic>?;
    } catch (e) {
      _photoUploadError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _isUploadingPhotos = false);
    }
  }

  Future<void> _startBatchGenerate() async {
    final foundItems = _lookupItems.where((it) => it['found'] == true).toList();
    if (foundItems.isEmpty) { _showSnack('조회된 항목이 없습니다.'); return; }
    setState(() {
      _step = 2; _isGenerating = true; _progress = 0;
      _genCurrent = 0; _genTotal = foundItems.length; _genDone = false; _genError = null;
    });
    final items = foundItems.map((it) => {
      'zpwino': it['zpwino'] ?? it['input_zpwino'],
      'zpwina': it['zpwina'] ?? '', 'zpwiadr': it['zpwiadr'] ?? '', 'zpirty3': it['zpirty3'] ?? '',
    }).toList();
    final common = {
      'installer_name': _bInstallerCtrl.text,
      'sharing_type': _bSharingCtrl.text,
      'antenna_count': int.tryParse(_bAntennaCountCtrl.text) ?? 1,
      'other_antenna_count': int.tryParse(_bOtherAntennaCtrl.text) ?? 0,
    };
    try {
      await for (final ev in widget.service.batchGenerate(items: items, common: common, photoJobId: _photoJobId)) {
        if (!mounted) return;
        final type = ev['type'] as String? ?? '';
        if (type == 'progress') {
          setState(() {
            _genCurrent = ev['current'] as int? ?? _genCurrent;
            _genTotal = ev['total'] as int? ?? _genTotal;
            _currentZpwino = ev['zpwino'] as String?;
            _progress = _genTotal > 0 ? _genCurrent / _genTotal : 0;
          });
        } else if (type == 'complete') {
          setState(() {
            _resultJobId = ev['job_id'] as String?; _successCount = ev['success'] as int? ?? 0;
            _failCount = ev['fail'] as int? ?? 0; _genDone = true; _isGenerating = false; _progress = 1.0;
          });
        } else if (type == 'error') {
          setState(() { _genError = ev['message'] as String? ?? '오류 발생'; _isGenerating = false; });
        }
      }
    } catch (e) {
      if (mounted) setState(() { _genError = e.toString().replaceFirst('Exception: ', ''); _isGenerating = false; });
    }
  }

  Future<void> _downloadResult() async {
    if (_resultJobId == null) return;
    setState(() => _isDownloading = true);
    try {
      final res = await widget.service.getDownloadUrl(_resultJobId!);
      final url = res['url'] as String?;
      final filename = res['filename'] as String? ?? '설치확인서.zip';
      if (url != null) { dl.openDownloadUrl(url, filename); if (mounted) _showSnack('다운로드 시작'); }
    } catch (e) {
      if (mounted) _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  void _resetBatch() {
    setState(() {
      _step = 0; _lookupItems = []; _foundCount = 0; _photoJobId = null;
      _photoSummary = null; _photoUploadError = null; _resultJobId = null;
      _genDone = false; _genError = null; _progress = 0;
    });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildStepIndicator(),
          const SizedBox(height: 16),
          if (_step == 0) _buildStep0(),
          if (_step == 1) _buildStep1(),
          if (_step == 2) _buildStep2(),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Row(children: [
      _stepDot(0, '허가번호 입력'), _stepLine(0), _stepDot(1, '설정 및 사진'), _stepLine(1), _stepDot(2, '생성'),
    ]);
  }

  Widget _stepDot(int idx, String label) {
    final active = _step >= idx;
    return Expanded(child: Column(children: [
      CircleAvatar(radius: 14, backgroundColor: active ? _themeColor : Colors.grey.shade300,
        child: Text('${idx + 1}', style: TextStyle(color: active ? Colors.white : Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.bold))),
      const SizedBox(height: 4),
      Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: active ? _themeColor : Colors.grey.shade500)),
    ]));
  }

  Widget _stepLine(int idx) {
    return Container(width: 30, height: 2, color: _step > idx ? _themeColor : Colors.grey.shade300);
  }

  Widget _buildStep0() {
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('허가번호 목록 입력', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      const SizedBox(height: 4),
      Text('줄바꿈, 쉼표, 세미콜론으로 구분 (최대 500건)', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      const SizedBox(height: 12),
      TextField(controller: _batchInputCtrl, maxLines: 8,
        decoration: InputDecoration(hintText: '예:\nKR-12345678\nKR-23456789', hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _themeColor, width: 1.5)))),
      if (_batchLookupError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_batchLookupError!, style: const TextStyle(color: Colors.red, fontSize: 13))),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, child: ElevatedButton(
        onPressed: _isBatchLooking ? null : _doBatchLookup,
        style: ElevatedButton.styleFrom(backgroundColor: _themeColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        child: _isBatchLooking ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('일괄 조회'),
      )),
    ]));
  }

  Widget _buildStep1() {
    final notFound = _lookupItems.where((it) => it['found'] != true).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.checklist, size: 18, color: _themeColor), const SizedBox(width: 6),
          const Text('조회 결과', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const Spacer(), TextButton(onPressed: _resetBatch, child: const Text('다시 입력', style: TextStyle(fontSize: 12))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _statChip('전체', _lookupItems.length, Colors.grey), const SizedBox(width: 8),
          _statChip('성공', _foundCount, Colors.green), const SizedBox(width: 8),
          _statChip('미조회', _lookupItems.length - _foundCount, Colors.red),
        ]),
        if (notFound.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text('미조회: ${notFound.map((e) => e['input_zpwino']).join(', ')}', style: TextStyle(fontSize: 12, color: Colors.red.shade700), maxLines: 3, overflow: TextOverflow.ellipsis)),
      ])),
      const SizedBox(height: 12),
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.settings, size: 18, color: _themeColor), const SizedBox(width: 6), const Text('공통 설정', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14))]),
        const SizedBox(height: 12),
        _bField('시설자명', _bInstallerCtrl), _bField('공용화 구분', _bSharingCtrl, hint: '예: 단독, 공용'),
        Row(children: [
          Expanded(child: _bField('안테나 수', _bAntennaCountCtrl, keyboardType: TextInputType.number)),
          const SizedBox(width: 8),
          Expanded(child: _bField('타사 안테나 수', _bOtherAntennaCtrl, keyboardType: TextInputType.number)),
        ]),
      ])),
      const SizedBox(height: 12),
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.photo_library, size: 18, color: _themeColor), const SizedBox(width: 6), const Text('사진 ZIP 업로드 (선택)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14))]),
        const SizedBox(height: 4),
        Text('ZIP 내 허가번호 폴더/파일명으로 자동 매칭', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          onPressed: _isUploadingPhotos ? null : _uploadPhotoZip,
          icon: _isUploadingPhotos ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file, size: 18),
          label: Text(_isUploadingPhotos ? '업로드 중...' : (_photoJobId != null ? '다시 업로드' : 'ZIP 파일 선택')),
          style: OutlinedButton.styleFrom(foregroundColor: _themeColor, padding: const EdgeInsets.symmetric(vertical: 12)),
        )),
        if (_photoUploadError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_photoUploadError!, style: const TextStyle(color: Colors.red, fontSize: 12))),
        if (_photoSummary != null) Padding(padding: const EdgeInsets.only(top: 8), child: Container(
          padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(8)),
          child: Text('사진 매칭: ${_photoSummary!.length}건', style: TextStyle(fontSize: 12, color: Colors.green.shade800)),
        )),
      ])),
      const SizedBox(height: 20),
      SizedBox(width: double.infinity, child: ElevatedButton.icon(
        onPressed: (_foundCount == 0 || _isGenerating) ? null : _startBatchGenerate,
        style: ElevatedButton.styleFrom(backgroundColor: _themeColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        icon: const Icon(Icons.play_arrow, size: 20), label: Text('일괄 생성 ($_foundCount건)'),
      )),
      const SizedBox(height: 24),
    ]);
  }

  Widget _buildStep2() {
    return _card(Padding(padding: const EdgeInsets.all(4), child: Column(children: [
      if (_isGenerating) ...[
        Icon(Icons.hourglass_top, size: 48, color: _themeColor.withValues(alpha: 0.6)),
        const SizedBox(height: 16),
        Text('설치확인서 생성 중...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey.shade800)),
        const SizedBox(height: 8),
        Text('$_genCurrent / $_genTotal', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _themeColor)),
        if (_currentZpwino != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_currentZpwino!, style: TextStyle(fontSize: 12, color: Colors.grey.shade500))),
        const SizedBox(height: 16),
        ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(value: _progress, minHeight: 8, backgroundColor: Colors.grey.shade200, valueColor: const AlwaysStoppedAnimation<Color>(_themeColor))),
        const SizedBox(height: 8),
        Text('${(_progress * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
      ],
      if (_genDone) ...[
        const Icon(Icons.check_circle, size: 56, color: Colors.green), const SizedBox(height: 16),
        const Text('생성 완료', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _statChip('성공', _successCount, Colors.green), const SizedBox(width: 12),
          if (_failCount > 0) _statChip('실패', _failCount, Colors.red),
        ]),
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: _isDownloading ? null : _downloadResult,
          style: ElevatedButton.styleFrom(backgroundColor: _themeColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          icon: _isDownloading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.download, size: 20),
          label: const Text('ZIP 다운로드'),
        )),
        const SizedBox(height: 10),
        TextButton(onPressed: _resetBatch, child: const Text('새로 시작')),
      ],
      if (_genError != null) ...[
        const Icon(Icons.error_outline, size: 56, color: Colors.red), const SizedBox(height: 16),
        Text('오류 발생', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.red.shade700)),
        const SizedBox(height: 8),
        Text(_genError!, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        const SizedBox(height: 16),
        TextButton(onPressed: _resetBatch, child: const Text('다시 시도')),
      ],
    ])));
  }

  Widget _statChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
      child: Text('$label $count', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _darken(color))),
    );
  }

  Color _darken(Color c) => HSLColor.fromColor(c).withLightness((HSLColor.fromColor(c).lightness * 0.7).clamp(0.0, 1.0)).toColor();

  Widget _card(Widget child) {
    return Card(color: Colors.white, elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
      child: Padding(padding: const EdgeInsets.all(16), child: child));
  }

  Widget _bField(String label, TextEditingController ctrl, {String? hint, TextInputType? keyboardType}) {
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: TextField(controller: ctrl, keyboardType: keyboardType,
      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _themeColor, width: 1.5)))));
  }
}
