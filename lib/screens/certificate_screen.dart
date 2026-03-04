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

  // ───── 색상 상수 ─────
  static const _themeColor = Color(0xFF00838F);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final token = context.read<AuthService>().authToken;
    _service.setAuthToken(token);
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
                color: Colors.black87,
                fontSize: 18,
                fontWeight: FontWeight.w600)),
        bottom: TabBar(
          controller: _tabController,
          labelColor: _themeColor,
          unselectedLabelColor: Colors.grey,
          indicatorColor: _themeColor,
          tabs: const [
            Tab(text: '개별 생성'),
            Tab(text: '일괄 생성'),
          ],
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

  final _queryCtrl = TextEditingController();
  final _installerCtrl = TextEditingController();
  final _zpwinoCtrl = TextEditingController();
  final _zpwinaCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _antennaFrameCtrl = TextEditingController();
  final _sharingCtrl = TextEditingController();
  final _antennaCountCtrl = TextEditingController(text: '1');
  final _otherAntennaCtrl = TextEditingController(text: '0');
  final _coInstallerCtrl = TextEditingController();
  final _coZpwinoCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();

  bool _isLooking = false;
  bool _isGenerating = false;
  String? _lookupError;

  // 이미지
  Uint8List? _blueprintBytes;
  String? _blueprintName;
  final List<Uint8List> _photoBytes = [];
  final List<String> _photoNames = [];

  @override
  void dispose() {
    _queryCtrl.dispose();
    _installerCtrl.dispose();
    _zpwinoCtrl.dispose();
    _zpwinaCtrl.dispose();
    _addressCtrl.dispose();
    _antennaFrameCtrl.dispose();
    _sharingCtrl.dispose();
    _antennaCountCtrl.dispose();
    _otherAntennaCtrl.dispose();
    _coInstallerCtrl.dispose();
    _coZpwinoCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _doLookup() async {
    final q = _queryCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _isLooking = true;
      _lookupError = null;
    });
    try {
      final res = await widget.service.lookup(q);
      if (!mounted) return;
      if (res['found'] == true) {
        _zpwinoCtrl.text = res['zpwino'] ?? '';
        _zpwinaCtrl.text = res['zpwina'] ?? '';
        _addressCtrl.text = res['zpwiadr'] ?? '';
        _antennaFrameCtrl.text = res['zpirty3'] ?? '';
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

  Future<void> _pickBlueprint() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result != null && result.files.single.bytes != null) {
      setState(() {
        _blueprintBytes = result.files.single.bytes;
        _blueprintName = result.files.single.name;
      });
    }
  }

  Future<void> _pickPhotos() async {
    if (_photoBytes.length >= 6) {
      _showSnack('사진은 최대 6장까지 첨부 가능합니다.');
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result != null) {
      for (final f in result.files) {
        if (_photoBytes.length >= 6) break;
        if (f.bytes != null) {
          _photoBytes.add(f.bytes!);
          _photoNames.add(f.name);
        }
      }
      setState(() {});
    }
  }

  String _bytesToBase64DataUrl(Uint8List bytes) {
    return 'data:image/jpeg;base64,${base64Encode(bytes)}';
  }

  Map<String, dynamic> _buildFormData() {
    return {
      'installer_name':
          _installerCtrl.text.isEmpty ? '에스케이텔레콤 주식회사' : _installerCtrl.text,
      'zpwino': _zpwinoCtrl.text,
      'zpwina': _zpwinaCtrl.text,
      'zpwiadr': _addressCtrl.text,
      'antenna_frame_type': _antennaFrameCtrl.text,
      'sharing_type': _sharingCtrl.text,
      'antenna_count': int.tryParse(_antennaCountCtrl.text) ?? 1,
      'other_antenna_count': int.tryParse(_otherAntennaCtrl.text) ?? 0,
      'co_installer_name': _coInstallerCtrl.text,
      'co_zpwino': _coZpwinoCtrl.text,
      'remark': _remarkCtrl.text,
    };
  }

  Future<void> _generate(String format) async {
    if (_zpwinoCtrl.text.trim().isEmpty && _zpwinaCtrl.text.trim().isEmpty) {
      _showSnack('먼저 허가번호/호출명칭을 조회하거나 입력하세요.');
      return;
    }
    setState(() => _isGenerating = true);
    try {
      final photosB64 =
          _photoBytes.map((b) => _bytesToBase64DataUrl(b)).toList();
      final blueprintB64 =
          _blueprintBytes != null ? _bytesToBase64DataUrl(_blueprintBytes!) : null;

      final bytes = await widget.service.generate(
        formData: _buildFormData(),
        format: format,
        photosBase64: photosB64.isNotEmpty ? photosB64 : null,
        blueprintBase64: blueprintB64,
      );

      final ext = format == 'hwpx' ? 'hwpx' : 'pdf';
      final zpwino = _zpwinoCtrl.text.isNotEmpty ? _zpwinoCtrl.text : 'cert';
      dl.downloadFileBytes(bytes, '설치확인서_$zpwino.$ext');
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 조회 ──
          _buildCard(
            title: '허가번호/호출명칭 조회',
            icon: Icons.search,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _queryCtrl,
                        decoration: _inputDeco('허가번호 또는 호출명칭 입력'),
                        onSubmitted: (_) => _doLookup(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _isLooking ? null : _doLookup,
                      style: _btnStyle(),
                      child: _isLooking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('조회'),
                    ),
                  ],
                ),
                if (_lookupError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_lookupError!,
                        style: const TextStyle(color: Colors.red, fontSize: 13)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── 기본 정보 ──
          _buildCard(
            title: '기본 정보',
            icon: Icons.info_outline,
            child: Column(
              children: [
                _fieldRow('시설자명', _installerCtrl, hint: '에스케이텔레콤 주식회사'),
                _fieldRow('허가번호', _zpwinoCtrl),
                _fieldRow('호출명칭', _zpwinaCtrl),
                _fieldRow('설치장소', _addressCtrl),
                _fieldRow('안테나설치대 형태', _antennaFrameCtrl),
                _fieldRow('공용화 구분', _sharingCtrl, hint: '예: 단독, 공용'),
                Row(
                  children: [
                    Expanded(child: _fieldRow('안테나 수', _antennaCountCtrl,
                        keyboardType: TextInputType.number)),
                    const SizedBox(width: 8),
                    Expanded(child: _fieldRow('타사 안테나 수', _otherAntennaCtrl,
                        keyboardType: TextInputType.number)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── 공동신청 ──
          _buildCard(
            title: '공동신청 (선택)',
            icon: Icons.people_outline,
            child: Column(
              children: [
                _fieldRow('공동신청 시설자명', _coInstallerCtrl),
                _fieldRow('공동신청 허가번호', _coZpwinoCtrl),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── 특이사항 ──
          _buildCard(
            title: '특이사항',
            icon: Icons.note_outlined,
            child: TextField(
              controller: _remarkCtrl,
              maxLines: 3,
              decoration: _inputDeco('특이사항 입력 (선택)'),
            ),
          ),
          const SizedBox(height: 12),

          // ── 설계도면 ──
          _buildCard(
            title: '설계도면',
            icon: Icons.image_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickBlueprint,
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('도면 이미지 선택'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _CertificateScreenState._themeColor),
                ),
                if (_blueprintName != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Chip(
                      label: Text(_blueprintName!, style: const TextStyle(fontSize: 12)),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () => setState(() {
                        _blueprintBytes = null;
                        _blueprintName = null;
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── 현장사진 ──
          _buildCard(
            title: '현장사진 (최대 6장)',
            icon: Icons.photo_library_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  onPressed: _photoBytes.length >= 6 ? null : _pickPhotos,
                  icon: const Icon(Icons.add_photo_alternate, size: 18),
                  label: Text('사진 추가 (${_photoBytes.length}/6)'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _CertificateScreenState._themeColor),
                ),
                if (_photoNames.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: List.generate(_photoNames.length, (i) {
                      return Chip(
                        label: Text(_photoNames[i],
                            style: const TextStyle(fontSize: 12)),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () => setState(() {
                          _photoBytes.removeAt(i);
                          _photoNames.removeAt(i);
                        }),
                      );
                    }),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ── 생성 버튼 ──
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isGenerating ? null : () => _generate('pdf'),
                  style: _btnStyle(),
                  icon: const Icon(Icons.picture_as_pdf, size: 18),
                  label: _isGenerating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('PDF 생성'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isGenerating ? null : () => _generate('hwpx'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1565C0),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.description, size: 18),
                  label: _isGenerating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('HWPX 생성'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Helpers ──

  Widget _buildCard(
      {required String title, required IconData icon, required Widget child}) {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: _CertificateScreenState._themeColor),
              const SizedBox(width: 6),
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14)),
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _fieldRow(String label, TextEditingController ctrl,
      {String? hint, TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctrl,
        keyboardType: keyboardType,
        decoration: _inputDeco(label, hint: hint),
      ),
    );
  }

  InputDecoration _inputDeco(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(
            color: _CertificateScreenState._themeColor, width: 1.5),
      ),
    );
  }

  ButtonStyle _btnStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: _CertificateScreenState._themeColor,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

  // Step tracking
  int _step = 0; // 0: 입력, 1: 결과/설정, 2: 생성중/완료

  // Step 0: 허가번호 입력
  final _batchInputCtrl = TextEditingController();
  bool _isBatchLooking = false;
  String? _batchLookupError;

  // Step 1: 조회 결과
  List<Map<String, dynamic>> _lookupItems = [];
  int _foundCount = 0;

  // 공통 설정
  final _bInstallerCtrl =
      TextEditingController(text: '에스케이텔레콤 주식회사');
  final _bSharingCtrl = TextEditingController();
  final _bAntennaCountCtrl = TextEditingController(text: '1');
  final _bOtherAntennaCtrl = TextEditingController(text: '0');

  // 사진 ZIP
  bool _isUploadingPhotos = false;
  String? _photoJobId;
  Map<String, dynamic>? _photoSummary;
  String? _photoUploadError;

  // Step 2: 생성
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

  // 다운로드
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
    return text
        .split(RegExp(r'[\n,;]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  }

  Future<void> _doBatchLookup() async {
    final list = _parseZpwinoList();
    if (list.isEmpty) {
      setState(() => _batchLookupError = '허가번호를 입력하세요.');
      return;
    }
    if (list.length > 500) {
      setState(() => _batchLookupError = '최대 500건까지 조회 가능합니다.');
      return;
    }
    setState(() {
      _isBatchLooking = true;
      _batchLookupError = null;
    });
    try {
      final res = await widget.service.batchLookup(list);
      if (!mounted) return;
      _lookupItems =
          (res['items'] as List).map((e) => e as Map<String, dynamic>).toList();
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
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return;

    setState(() {
      _isUploadingPhotos = true;
      _photoUploadError = null;
    });
    try {
      final res = await widget.service.uploadPhotos(
        result.files.single.bytes!,
        result.files.single.name,
      );
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
    final foundItems =
        _lookupItems.where((it) => it['found'] == true).toList();
    if (foundItems.isEmpty) {
      _showSnack('조회된 항목이 없습니다.');
      return;
    }
    setState(() {
      _step = 2;
      _isGenerating = true;
      _progress = 0;
      _genCurrent = 0;
      _genTotal = foundItems.length;
      _genDone = false;
      _genError = null;
    });

    final items = foundItems
        .map((it) => {
              'zpwino': it['zpwino'] ?? it['input_zpwino'],
              'zpwina': it['zpwina'] ?? '',
              'zpwiadr': it['zpwiadr'] ?? '',
              'zpirty3': it['zpirty3'] ?? '',
            })
        .toList();

    final common = {
      'installer_name': _bInstallerCtrl.text,
      'sharing_type': _bSharingCtrl.text,
      'antenna_count': int.tryParse(_bAntennaCountCtrl.text) ?? 1,
      'other_antenna_count': int.tryParse(_bOtherAntennaCtrl.text) ?? 0,
    };

    try {
      await for (final ev in widget.service.batchGenerate(
        items: items,
        common: common,
        photoJobId: _photoJobId,
      )) {
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
            _resultJobId = ev['job_id'] as String?;
            _successCount = ev['success'] as int? ?? 0;
            _failCount = ev['fail'] as int? ?? 0;
            _genDone = true;
            _isGenerating = false;
            _progress = 1.0;
          });
        } else if (type == 'error') {
          setState(() {
            _genError = ev['message'] as String? ?? '생성 중 오류 발생';
            _isGenerating = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _genError = e.toString().replaceFirst('Exception: ', '');
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _downloadResult() async {
    if (_resultJobId == null) return;
    setState(() => _isDownloading = true);
    try {
      final res = await widget.service.getDownloadUrl(_resultJobId!);
      final url = res['url'] as String?;
      final filename = res['filename'] as String? ?? '설치확인서.zip';
      if (url != null) {
        dl.openDownloadUrl(url, filename);
        if (mounted) _showSnack('다운로드 시작');
      }
    } catch (e) {
      if (mounted) _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  void _resetBatch() {
    setState(() {
      _step = 0;
      _lookupItems = [];
      _foundCount = 0;
      _photoJobId = null;
      _photoSummary = null;
      _photoUploadError = null;
      _resultJobId = null;
      _genDone = false;
      _genError = null;
      _progress = 0;
    });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Stepper indicator
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
    return Row(
      children: [
        _stepDot(0, '허가번호 입력'),
        _stepLine(0),
        _stepDot(1, '설정 및 사진'),
        _stepLine(1),
        _stepDot(2, '생성'),
      ],
    );
  }

  Widget _stepDot(int idx, String label) {
    final active = _step >= idx;
    return Expanded(
      child: Column(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: active ? _themeColor : Colors.grey.shade300,
            child: Text('${idx + 1}',
                style: TextStyle(
                    color: active ? Colors.white : Colors.grey.shade600,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 4),
          Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11,
                  color: active ? _themeColor : Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _stepLine(int idx) {
    final active = _step > idx;
    return Container(
      width: 30,
      height: 2,
      color: active ? _themeColor : Colors.grey.shade300,
    );
  }

  // ── Step 0: 허가번호 입력 ──
  Widget _buildStep0() {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('허가번호 목록 입력',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 4),
            Text('줄바꿈, 쉼표, 세미콜론으로 구분하여 입력 (최대 500건)',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 12),
            TextField(
              controller: _batchInputCtrl,
              maxLines: 8,
              decoration: InputDecoration(
                hintText: '예:\nKR-12345678\nKR-23456789\nKR-34567890',
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _themeColor, width: 1.5),
                ),
              ),
            ),
            if (_batchLookupError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_batchLookupError!,
                    style: const TextStyle(color: Colors.red, fontSize: 13)),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isBatchLooking ? null : _doBatchLookup,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _themeColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _isBatchLooking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('일괄 조회'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Step 1: 조회 결과 + 설정 ──
  Widget _buildStep1() {
    final notFound =
        _lookupItems.where((it) => it['found'] != true).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 조회 결과 요약
        Card(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.checklist, size: 18, color: _themeColor),
                    const SizedBox(width: 6),
                    const Text('조회 결과',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const Spacer(),
                    TextButton(
                      onPressed: _resetBatch,
                      child: const Text('다시 입력',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _statChip('전체', _lookupItems.length, Colors.grey),
                    const SizedBox(width: 8),
                    _statChip('조회 성공', _foundCount, Colors.green),
                    const SizedBox(width: 8),
                    _statChip(
                        '미조회', _lookupItems.length - _foundCount, Colors.red),
                  ],
                ),
                if (notFound.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '미조회: ${notFound.map((e) => e['input_zpwino']).join(', ')}',
                    style:
                        TextStyle(fontSize: 12, color: Colors.red.shade700),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // 공통 설정
        Card(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.settings, size: 18, color: _themeColor),
                  const SizedBox(width: 6),
                  const Text('공통 설정',
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                ]),
                const SizedBox(height: 12),
                _batchField('시설자명', _bInstallerCtrl),
                _batchField('공용화 구분', _bSharingCtrl, hint: '예: 단독, 공용'),
                Row(
                  children: [
                    Expanded(
                        child: _batchField('안테나 수', _bAntennaCountCtrl,
                            keyboardType: TextInputType.number)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _batchField('타사 안테나 수', _bOtherAntennaCtrl,
                            keyboardType: TextInputType.number)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // 사진 ZIP 업로드
        Card(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.photo_library, size: 18, color: _themeColor),
                  const SizedBox(width: 6),
                  const Text('사진 ZIP 업로드 (선택)',
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                ]),
                const SizedBox(height: 4),
                Text(
                  'ZIP 파일 내 허가번호 폴더/파일명으로 자동 매칭됩니다.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isUploadingPhotos ? null : _uploadPhotoZip,
                    icon: _isUploadingPhotos
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.upload_file, size: 18),
                    label: Text(_isUploadingPhotos
                        ? '업로드 중...'
                        : (_photoJobId != null ? '다시 업로드' : 'ZIP 파일 선택')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _themeColor,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                if (_photoUploadError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_photoUploadError!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                if (_photoSummary != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '사진 매칭: ${_photoSummary!.length}건 (도면/사진 포함)',
                      style: TextStyle(
                          fontSize: 12, color: Colors.green.shade800),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),

        // 생성 버튼
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: (_foundCount == 0 || _isGenerating)
                ? null
                : _startBatchGenerate,
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.play_arrow, size: 20),
            label: Text('일괄 생성 ($_foundCount건)'),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Step 2: 생성 진행률 / 완료 ──
  Widget _buildStep2() {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (_isGenerating) ...[
              Icon(Icons.hourglass_top,
                  size: 48, color: _themeColor.withValues(alpha: 0.6)),
              const SizedBox(height: 16),
              Text('설치확인서 생성 중...',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade800)),
              const SizedBox(height: 8),
              Text('$_genCurrent / $_genTotal',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: _themeColor)),
              if (_currentZpwino != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_currentZpwino!,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500)),
                ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 8,
                  backgroundColor: Colors.grey.shade200,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(_themeColor),
                ),
              ),
              const SizedBox(height: 8),
              Text('${(_progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade600)),
            ],
            if (_genDone) ...[
              const Icon(Icons.check_circle, size: 56, color: Colors.green),
              const SizedBox(height: 16),
              const Text('생성 완료',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _statChip('성공', _successCount, Colors.green),
                  const SizedBox(width: 12),
                  if (_failCount > 0)
                    _statChip('실패', _failCount, Colors.red),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isDownloading ? null : _downloadResult,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _themeColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: _isDownloading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download, size: 20),
                  label: const Text('ZIP 다운로드'),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _resetBatch,
                child: const Text('새로 시작'),
              ),
            ],
            if (_genError != null) ...[
              const Icon(Icons.error_outline, size: 56, color: Colors.red),
              const SizedBox(height: 16),
              Text('오류 발생',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.red.shade700)),
              const SizedBox(height: 8),
              Text(_genError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade600)),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _resetBatch,
                child: const Text('다시 시도'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, color: color.shade700),
      ),
    );
  }

  Widget _batchField(String label, TextEditingController ctrl,
      {String? hint, TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctrl,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _themeColor, width: 1.5),
          ),
        ),
      ),
    );
  }
}

extension on Color {
  Color get shade700 {
    final hsl = HSLColor.fromColor(this);
    return hsl.withLightness((hsl.lightness * 0.7).clamp(0.0, 1.0)).toColor();
  }
}
