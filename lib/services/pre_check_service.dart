import 'dart:convert';

import 'package:http/http.dart' as http;

/// 사전대조 서비스 — 일정 등록 이전 단계(대상 배정 → 전산비교 → 변경신고 → 완료).
///
/// 상태는 서버의 inspection_targets.pre_check_status 가 갖는다. 일정보다 앞서는
/// 단계라 일정 워크플로우(workflow_status)와는 별개다.
class PreCheckService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  static const _apiTimeout = Duration(minutes: 3);

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_authToken ?? ''}',
        'Content-Type': 'application/json',
      };

  Map<String, dynamic> _decode(http.Response resp, String fallback) {
    final body = json.decode(utf8.decode(resp.bodyBytes));
    if (resp.statusCode != 200) {
      throw Exception(body is Map ? (body['detail'] ?? fallback) : fallback);
    }
    return body as Map<String, dynamic>;
  }

  /// 대상 목록. 본부 범위는 서버가 강제로 좁히므로 여기서 보내지 않는다.
  Future<PreCheckList> targets({
    required int year,
    String status = '',
    String team = '',
    String q = '',
    int limit = 500,
    int offset = 0,
  }) async {
    final uri = Uri.parse('$_baseUrl/pre-check/targets').replace(
      queryParameters: {
        'year': '$year',
        if (status.isNotEmpty) 'status': status,
        if (team.isNotEmpty) 'team': team,
        if (q.isNotEmpty) 'q': q,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return PreCheckList.fromJson(_decode(resp, '대상 조회 실패'));
  }

  /// 상태별 건수 + 팀 목록(필터 드롭다운용).
  Future<PreCheckSummary> summary(int year) async {
    final uri = Uri.parse('$_baseUrl/pre-check/summary')
        .replace(queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return PreCheckSummary.fromJson(_decode(resp, '집계 조회 실패'));
  }

  Future<PreCheckActionResult> _post(String path, Map<String, dynamic> body,
      String fallback) async {
    final resp = await http
        .post(Uri.parse('$_baseUrl$path'),
            headers: _headers, body: json.encode(body))
        .timeout(_apiTimeout);
    return PreCheckActionResult.fromJson(_decode(resp, fallback));
  }

  /// 본부담당자 — 사전대조 대상 선정.
  Future<PreCheckActionResult> request(
          {required int year, required List<String> licenseNos, String memo = ''}) =>
      _post('/pre-check/request',
          {'year': year, 'license_nos': licenseNos, 'memo': memo}, '요청 실패');

  /// 품개팀 — 전산비교 착수.
  Future<PreCheckActionResult> start(
          {required int year, required List<String> licenseNos}) =>
      _post('/pre-check/start',
          {'year': year, 'license_nos': licenseNos}, '착수 처리 실패');

  /// 품개팀 — 이상 없음 보고. 최종 완료가 아니라 본부 확인 대기 상태가 된다.
  Future<PreCheckActionResult> review({
    required int year,
    required List<String> licenseNos,
    required Map<String, int> summary,
    bool acknowledged = false,
  }) =>
      _post('/pre-check/review', {
        'year': year,
        'license_nos': licenseNos,
        'summary': summary,
        'acknowledged': acknowledged,
      }, '보고 실패');

  /// 품개팀 — 변경신고 요청.
  Future<PreCheckActionResult> changeRequest({
    required int year,
    required List<Map<String, dynamic>> items,
  }) =>
      _post('/pre-check/change-request', {'year': year, 'items': items},
          '변경신고 요청 실패');

  /// 품혁담당자 — 관리소 신고 완료.
  Future<PreCheckActionResult> file(
          {required int year, required List<String> licenseNos}) =>
      _post('/pre-check/file',
          {'year': year, 'license_nos': licenseNos}, '신고 완료 처리 실패');

  /// 본부담당자 — 최종 사전대조 완료.
  Future<PreCheckActionResult> complete(
          {required int year, required List<String> licenseNos, String memo = ''}) =>
      _post('/pre-check/complete',
          {'year': year, 'license_nos': licenseNos, 'memo': memo}, '완료 처리 실패');

  /// 본부담당자 — 되돌리기.
  Future<PreCheckActionResult> revert(
          {required int year, required List<String> licenseNos, String memo = ''}) =>
      _post('/pre-check/revert',
          {'year': year, 'license_nos': licenseNos, 'memo': memo}, '되돌리기 실패');
}

/// 사전대조 상태값 — 서버 pre_check.py 의 PC_* 와 1:1.
class PreCheckStatus {
  static const none = 'NONE'; // 서버는 빈 문자열, 조회 파라미터는 NONE
  static const requested = 'REQUESTED';
  static const inProgress = 'IN_PROGRESS';
  static const reviewed = 'REVIEWED';
  static const changeRequested = 'CHANGE_REQUESTED';
  static const changeFiled = 'CHANGE_FILED';
  static const done = 'PRE_CHECKED';

  /// 화면 표시 순서 = 실제 진행 순서.
  static const ordered = [
    none, requested, inProgress, reviewed,
    changeRequested, changeFiled, done,
  ];

  static String label(String s) => switch (s) {
        requested => '요청됨',
        inProgress => '대조중',
        reviewed => '이상없음',
        changeRequested => '변경신고요청',
        changeFiled => '신고완료',
        done => '대조완료',
        _ => '미요청',
      };

  /// 빈 문자열과 'NONE' 을 하나로 본다.
  static String normalize(String s) => (s.isEmpty || s == '') ? none : s;
}

class PreCheckTarget {
  final String licenseNo;
  final String callName;
  final String installPlace;
  final String roadAddress;
  final String quarter;
  final String sktHq;
  final String accessTeam;
  final String qualityTeam;
  final String tongsi;
  final String gongdae;
  final String status;
  final String requestedAt;
  final String doneAt;
  final bool hasSchedule;

  /// 서버가 내려주는 조작 가능 여부. 품개팀은 본부 전체를 보되 본인 팀만 고칠 수
  /// 있어서, 목록에는 있지만 체크가 막히는 행이 생긴다.
  final bool editable;

  PreCheckTarget({
    required this.licenseNo,
    required this.callName,
    required this.installPlace,
    required this.roadAddress,
    required this.quarter,
    required this.sktHq,
    required this.accessTeam,
    required this.qualityTeam,
    required this.tongsi,
    required this.gongdae,
    required this.status,
    required this.requestedAt,
    required this.doneAt,
    required this.hasSchedule,
    required this.editable,
  });

  factory PreCheckTarget.fromJson(Map<String, dynamic> j) => PreCheckTarget(
        licenseNo: j['허가번호'] ?? '',
        callName: j['호출명칭'] ?? '',
        installPlace: j['설치장소'] ?? '',
        roadAddress: j['도로명주소'] ?? '',
        quarter: j['분기'] ?? '',
        sktHq: j['skt본부'] ?? '',
        accessTeam: j['access담당'] ?? '',
        qualityTeam: j['품질개선팀'] ?? '',
        tongsi: j['통시'] ?? '',
        gongdae: j['공대'] ?? '',
        status: PreCheckStatus.normalize(j['pre_check_status'] ?? ''),
        requestedAt: j['requested_at'] ?? '',
        doneAt: j['done_at'] ?? '',
        hasSchedule: j['has_schedule'] == true,
        editable: j['editable'] == true,
      );
}

class PreCheckList {
  final int total;
  final List<PreCheckTarget> items;
  final String role;
  final String myTeam;

  PreCheckList(
      {required this.total,
      required this.items,
      required this.role,
      required this.myTeam});

  factory PreCheckList.fromJson(Map<String, dynamic> j) => PreCheckList(
        total: (j['total'] as num?)?.toInt() ?? 0,
        items: ((j['items'] as List?) ?? const [])
            .map((e) => PreCheckTarget.fromJson(e as Map<String, dynamic>))
            .toList(),
        role: j['role'] ?? 'member',
        myTeam: j['my_team'] ?? '',
      );
}

class PreCheckSummary {
  final Map<String, int> counts;
  final List<({String team, int count})> teams;
  final String role;
  final String myTeam;

  PreCheckSummary(
      {required this.counts,
      required this.teams,
      required this.role,
      required this.myTeam});

  factory PreCheckSummary.fromJson(Map<String, dynamic> j) => PreCheckSummary(
        counts: ((j['counts'] as Map?) ?? const {}).map(
            (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0)),
        teams: ((j['teams'] as List?) ?? const [])
            .map((e) => (
                  team: (e['team'] ?? '').toString(),
                  count: (e['count'] as num?)?.toInt() ?? 0
                ))
            .toList(),
        role: j['role'] ?? 'member',
        myTeam: j['my_team'] ?? '',
      );
}

/// 전이 API 공통 응답. 건너뛴 건을 이유별로 들고 온다.
class PreCheckActionResult {
  final int changed;
  final Map<String, int> skipped;
  final int count; // 변경신고 요청 시 등록된 항목 수

  PreCheckActionResult(
      {required this.changed, required this.skipped, this.count = 0});

  factory PreCheckActionResult.fromJson(Map<String, dynamic> j) =>
      PreCheckActionResult(
        changed: (j['changed'] as num?)?.toInt() ?? 0,
        skipped: ((j['skipped'] as Map?) ?? const {}).map(
            (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0)),
        count: (j['count'] as num?)?.toInt() ?? 0,
      );

  /// '3건 처리 · 권한없음 2건' 형태의 사람이 읽는 요약.
  String describe() {
    final buf = StringBuffer('$changed건 처리');
    if (skipped.isNotEmpty) {
      buf.write(' · ');
      buf.write(skipped.entries.map((e) => '${e.key} ${e.value}건').join(', '));
    }
    return buf.toString();
  }
}
