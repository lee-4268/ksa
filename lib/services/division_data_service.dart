import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/radio_station.dart';
import 'excel_service.dart';

/// 본부별 수검 대상 데이터 관리 서비스
class DivisionDataService extends ChangeNotifier {
  final ExcelService _excelService = ExcelService();

  // 현재 본부 정보
  String? _currentDivisionId;
  String? _currentDivisionName;

  // 본부 전체 대상 데이터
  List<DivisionInspectionTarget> _targets = [];
  final Map<String, List<DivisionInspectionTarget>> _targetsByTeam = {};

  // 원본 Excel 바이트 (서식 유지 export용)
  Uint8List? _originalExcelBytes;
  String? _originalFileName;

  // 로딩 상태
  bool _isLoading = false;
  String? _errorMessage;
  double _loadingProgress = 0.0;
  String _loadingStatus = '';

  // Getters
  List<DivisionInspectionTarget> get targets => _targets;
  Map<String, List<DivisionInspectionTarget>> get targetsByTeam => _targetsByTeam;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  double get loadingProgress => _loadingProgress;
  String get loadingStatus => _loadingStatus;
  String? get currentDivisionId => _currentDivisionId;
  String? get currentDivisionName => _currentDivisionName;
  bool get hasOriginalExcel => _originalExcelBytes != null;

  /// 본부 정보 설정
  void setDivision(String divisionId, String divisionName) {
    _currentDivisionId = divisionId;
    _currentDivisionName = divisionName;
    notifyListeners();
  }

  /// 본부별 통계
  DivisionStats get stats {
    final total = _targets.length;
    final inspected = _targets.where((t) => t.isInspected).length;
    final pending = total - inspected;

    return DivisionStats(
      total: total,
      inspected: inspected,
      pending: pending,
      progressRate: total > 0 ? inspected / total : 0.0,
    );
  }

  /// 팀별 통계
  Map<String, TeamStats> get teamStats {
    final result = <String, TeamStats>{};

    for (final entry in _targetsByTeam.entries) {
      final teamName = entry.key;
      final teamTargets = entry.value;
      final total = teamTargets.length;
      final inspected = teamTargets.where((t) => t.isInspected).length;

      result[teamName] = TeamStats(
        teamName: teamName,
        total: total,
        inspected: inspected,
        pending: total - inspected,
        progressRate: total > 0 ? inspected / total : 0.0,
      );
    }

    return result;
  }

  /// 이번 주 통계
  WeeklyStats get weeklyStats {
    final now = DateTime.now();
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    final weekEnd = weekStart.add(const Duration(days: 6));

    // 이번 주 예정된 검사
    final scheduledThisWeek = _targets.where((t) {
      if (t.scheduledDate == null) return false;
      return t.scheduledDate!.isAfter(weekStart.subtract(const Duration(days: 1))) &&
             t.scheduledDate!.isBefore(weekEnd.add(const Duration(days: 1)));
    }).toList();

    // 이번 주 완료된 검사
    final completedThisWeek = scheduledThisWeek.where((t) => t.isInspected).length;

    return WeeklyStats(
      weekNumber: _getWeekNumber(now),
      scheduled: scheduledThisWeek.length,
      completed: completedThisWeek,
      progressRate: scheduledThisWeek.isNotEmpty
          ? completedThisWeek / scheduledThisWeek.length
          : 0.0,
    );
  }

  int _getWeekNumber(DateTime date) {
    final firstDayOfYear = DateTime(date.year, 1, 1);
    final daysDiff = date.difference(firstDayOfYear).inDays;
    return ((daysDiff + firstDayOfYear.weekday - 1) / 7).ceil();
  }

  /// Excel 파일에서 수검 대상 Import
  Future<bool> importFromExcel() async {
    _isLoading = true;
    _errorMessage = null;
    _loadingProgress = 0.0;
    _loadingStatus = '파일 선택 중...';
    notifyListeners();

    try {
      final result = await _excelService.importExcelFile();

      if (result == null) {
        _isLoading = false;
        _loadingStatus = '';
        notifyListeners();
        return false;
      }

      _loadingProgress = 0.3;
      _loadingStatus = '데이터 처리 중...';
      notifyListeners();
      await Future.delayed(Duration.zero);

      // 원본 Excel 저장 (서식 유지용)
      _originalExcelBytes = result.originalBytes;
      _originalFileName = result.fileName;

      // RadioStation을 DivisionInspectionTarget으로 변환
      _targets = result.stations.map((station) =>
        DivisionInspectionTarget.fromRadioStation(station)
      ).toList();

      _loadingProgress = 0.6;
      _loadingStatus = '팀별 분류 중...';
      notifyListeners();
      await Future.delayed(Duration.zero);

      // 팀별 분류 (임시로 카테고리 기준, 추후 팀 할당 로직 추가)
      _organizeByTeam();

      _loadingProgress = 0.9;
      _loadingStatus = '클라우드 저장 중...';
      notifyListeners();
      await Future.delayed(Duration.zero);

      // 클라우드에 저장
      await _saveToCloud();

      _loadingProgress = 1.0;
      _loadingStatus = '완료!';
      notifyListeners();

      await Future.delayed(const Duration(milliseconds: 500));

      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();

      return true;
    } catch (e) {
      _errorMessage = 'Import 실패: $e';
      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();
      return false;
    }
  }

  /// 팀별로 대상 분류
  void _organizeByTeam() {
    _targetsByTeam.clear();

    for (final target in _targets) {
      final teamName = target.assignedTeamName ?? '미배정';
      _targetsByTeam.putIfAbsent(teamName, () => []);
      _targetsByTeam[teamName]!.add(target);
    }
  }

  /// 특정 대상에 팀 할당
  void assignTeam(String targetId, String teamId, String teamName) {
    final index = _targets.indexWhere((t) => t.id == targetId);
    if (index != -1) {
      _targets[index] = _targets[index].copyWith(
        assignedTeamId: teamId,
        assignedTeamName: teamName,
      );
      _organizeByTeam();
      notifyListeners();
    }
  }

  /// 대상 정보 수정
  void updateTarget(String targetId, {
    String? memo,
    bool? isInspected,
    DateTime? inspectionDate,
    DateTime? scheduledDate,
    String? installationType,
  }) {
    final index = _targets.indexWhere((t) => t.id == targetId);
    if (index != -1) {
      _targets[index] = _targets[index].copyWith(
        memo: memo,
        isInspected: isInspected,
        inspectionDate: inspectionDate,
        scheduledDate: scheduledDate,
        installationType: installationType,
      );
      _organizeByTeam();
      notifyListeners();

      // 클라우드 동기화 (백그라운드)
      _syncTargetToCloud(_targets[index]);
    }
  }

  /// 클라우드에 저장
  Future<void> _saveToCloud() async {
    if (_currentDivisionId == null) return;

    const mutation = '''
      mutation CreateDivisionInspectionBatch(\$input: CreateDivisionInspectionBatchInput!) {
        createDivisionInspectionBatch(input: \$input) {
          success
          count
        }
      }
    ''';

    try {
      // 배치로 저장 (실제 구현 시 pagination 필요)
      final targetsJson = _targets.map((t) => t.toJson()).toList();

      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {
            'divisionId': _currentDivisionId,
            'year': DateTime.now().year,
            'targets': targetsJson,
            'originalExcelKey': _originalFileName,
          }
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      await Amplify.API.mutate(request: request).response;
      debugPrint('클라우드 저장 완료: ${_targets.length}개');
    } catch (e) {
      debugPrint('클라우드 저장 실패 (로컬만 유지): $e');
    }
  }

  /// 단일 대상 클라우드 동기화
  Future<void> _syncTargetToCloud(DivisionInspectionTarget target) async {
    // 백그라운드에서 동기화
    try {
      const mutation = '''
        mutation UpdateInspectionTarget(\$input: UpdateInspectionTargetInput!) {
          updateInspectionTarget(input: \$input) {
            id
          }
        }
      ''';

      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': target.toJson(),
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      await Amplify.API.mutate(request: request).response;
    } catch (e) {
      debugPrint('동기화 실패: $e');
    }
  }

  /// 클라우드에서 데이터 로드
  Future<void> loadFromCloud() async {
    if (_currentDivisionId == null) return;

    _isLoading = true;
    _loadingStatus = '데이터 로드 중...';
    notifyListeners();

    try {
      const query = '''
        query GetDivisionTargets(\$divisionId: ID!, \$year: Int!) {
          divisionInspectionTargets(divisionId: \$divisionId, year: \$year) {
            items {
              id
              stationName
              licenseNumber
              address
              latitude
              longitude
              callSign
              gain
              antennaCount
              remarks
              installationType
              assignedTeamId
              assignedTeamName
              isInspected
              inspectionDate
              scheduledDate
              memo
              photoKeys
            }
          }
        }
      ''';

      final request = GraphQLRequest<String>(
        document: query,
        variables: {
          'divisionId': _currentDivisionId,
          'year': DateTime.now().year,
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.query(request: request).response;

      if (response.data != null) {
        final data = jsonDecode(response.data!) as Map<String, dynamic>;
        final items = data['divisionInspectionTargets']['items'] as List<dynamic>;

        _targets = items.map((item) =>
          DivisionInspectionTarget.fromJson(item as Map<String, dynamic>)
        ).toList();

        _organizeByTeam();
      }

      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();
    } catch (e) {
      _errorMessage = '데이터 로드 실패: $e';
      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();
    }
  }

  /// 원본 서식 유지 Excel Export
  Future<String?> exportWithOriginalFormat() async {
    if (_originalExcelBytes == null) {
      _errorMessage = '원본 Excel 파일이 없습니다.';
      notifyListeners();
      return null;
    }

    try {
      // RadioStation 리스트로 변환
      final stations = _targets.map((t) => t.toRadioStation()).toList();

      final filePath = await _excelService.exportWithOriginalFormat(
        _originalExcelBytes!,
        stations,
        _originalFileName ?? '수검대상',
        saveOnly: false,
      );

      return filePath;
    } catch (e) {
      _errorMessage = 'Export 실패: $e';
      notifyListeners();
      return null;
    }
  }

  /// 데이터 초기화
  void clear() {
    _targets.clear();
    _targetsByTeam.clear();
    _originalExcelBytes = null;
    _originalFileName = null;
    _errorMessage = null;
    notifyListeners();
  }
}

/// 본부 수검 대상 모델
class DivisionInspectionTarget {
  final String id;
  final String stationName;
  final String licenseNumber;
  final String address;
  final double? latitude;
  final double? longitude;
  final String? callSign;
  final String? gain;
  final String? antennaCount;
  final String? remarks;
  final String? installationType;
  final String? originalInstallationType;

  // 팀 할당 정보
  final String? assignedTeamId;
  final String? assignedTeamName;

  // 검사 정보
  final bool isInspected;
  final DateTime? inspectionDate;
  final DateTime? scheduledDate;
  final String? memo;
  final List<String>? photoKeys;

  final DateTime createdAt;
  final DateTime updatedAt;

  DivisionInspectionTarget({
    required this.id,
    required this.stationName,
    required this.licenseNumber,
    required this.address,
    this.latitude,
    this.longitude,
    this.callSign,
    this.gain,
    this.antennaCount,
    this.remarks,
    this.installationType,
    this.originalInstallationType,
    this.assignedTeamId,
    this.assignedTeamName,
    this.isInspected = false,
    this.inspectionDate,
    this.scheduledDate,
    this.memo,
    this.photoKeys,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  factory DivisionInspectionTarget.fromRadioStation(RadioStation station) {
    return DivisionInspectionTarget(
      id: station.id,
      stationName: station.stationName,
      licenseNumber: station.licenseNumber,
      address: station.address,
      latitude: station.latitude,
      longitude: station.longitude,
      callSign: station.callSign,
      gain: station.gain,
      antennaCount: station.antennaCount,
      remarks: station.remarks,
      installationType: station.installationType,
      originalInstallationType: station.originalInstallationType,
      isInspected: station.isInspected,
      inspectionDate: station.inspectionDate,
      scheduledDate: station.scheduledDate,
      memo: station.memo,
      photoKeys: station.photoPaths,
      createdAt: station.createdAt,
      updatedAt: station.updatedAt,
    );
  }

  factory DivisionInspectionTarget.fromJson(Map<String, dynamic> json) {
    return DivisionInspectionTarget(
      id: json['id'] as String,
      stationName: json['stationName'] as String,
      licenseNumber: json['licenseNumber'] as String? ?? '',
      address: json['address'] as String,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      callSign: json['callSign'] as String?,
      gain: json['gain'] as String?,
      antennaCount: json['antennaCount'] as String?,
      remarks: json['remarks'] as String?,
      installationType: json['installationType'] as String?,
      originalInstallationType: json['originalInstallationType'] as String?,
      assignedTeamId: json['assignedTeamId'] as String?,
      assignedTeamName: json['assignedTeamName'] as String?,
      isInspected: json['isInspected'] as bool? ?? false,
      inspectionDate: json['inspectionDate'] != null
          ? DateTime.parse(json['inspectionDate'] as String)
          : null,
      scheduledDate: json['scheduledDate'] != null
          ? DateTime.parse(json['scheduledDate'] as String)
          : null,
      memo: json['memo'] as String?,
      photoKeys: (json['photoKeys'] as List<dynamic>?)?.cast<String>(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'stationName': stationName,
      'licenseNumber': licenseNumber,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'callSign': callSign,
      'gain': gain,
      'antennaCount': antennaCount,
      'remarks': remarks,
      'installationType': installationType,
      'originalInstallationType': originalInstallationType,
      'assignedTeamId': assignedTeamId,
      'assignedTeamName': assignedTeamName,
      'isInspected': isInspected,
      'inspectionDate': inspectionDate?.toIso8601String(),
      'scheduledDate': scheduledDate?.toIso8601String(),
      'memo': memo,
      'photoKeys': photoKeys,
    };
  }

  RadioStation toRadioStation() {
    return RadioStation(
      id: id,
      stationName: stationName,
      licenseNumber: licenseNumber,
      address: address,
      latitude: latitude,
      longitude: longitude,
      callSign: callSign,
      gain: gain,
      antennaCount: antennaCount,
      remarks: remarks,
      installationType: installationType,
      originalInstallationType: originalInstallationType,
      isInspected: isInspected,
      inspectionDate: inspectionDate,
      scheduledDate: scheduledDate,
      memo: memo,
      photoPaths: photoKeys,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  DivisionInspectionTarget copyWith({
    String? id,
    String? stationName,
    String? licenseNumber,
    String? address,
    double? latitude,
    double? longitude,
    String? callSign,
    String? gain,
    String? antennaCount,
    String? remarks,
    String? installationType,
    String? originalInstallationType,
    String? assignedTeamId,
    String? assignedTeamName,
    bool? isInspected,
    DateTime? inspectionDate,
    DateTime? scheduledDate,
    String? memo,
    List<String>? photoKeys,
  }) {
    return DivisionInspectionTarget(
      id: id ?? this.id,
      stationName: stationName ?? this.stationName,
      licenseNumber: licenseNumber ?? this.licenseNumber,
      address: address ?? this.address,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      callSign: callSign ?? this.callSign,
      gain: gain ?? this.gain,
      antennaCount: antennaCount ?? this.antennaCount,
      remarks: remarks ?? this.remarks,
      installationType: installationType ?? this.installationType,
      originalInstallationType: originalInstallationType ?? this.originalInstallationType,
      assignedTeamId: assignedTeamId ?? this.assignedTeamId,
      assignedTeamName: assignedTeamName ?? this.assignedTeamName,
      isInspected: isInspected ?? this.isInspected,
      inspectionDate: inspectionDate ?? this.inspectionDate,
      scheduledDate: scheduledDate ?? this.scheduledDate,
      memo: memo ?? this.memo,
      photoKeys: photoKeys ?? this.photoKeys,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}

/// 본부 통계
class DivisionStats {
  final int total;
  final int inspected;
  final int pending;
  final double progressRate;

  DivisionStats({
    required this.total,
    required this.inspected,
    required this.pending,
    required this.progressRate,
  });
}

/// 팀 통계
class TeamStats {
  final String teamName;
  final int total;
  final int inspected;
  final int pending;
  final double progressRate;

  TeamStats({
    required this.teamName,
    required this.total,
    required this.inspected,
    required this.pending,
    required this.progressRate,
  });
}

/// 주간 통계
class WeeklyStats {
  final int weekNumber;
  final int scheduled;
  final int completed;
  final double progressRate;

  WeeklyStats({
    required this.weekNumber,
    required this.scheduled,
    required this.completed,
    required this.progressRate,
  });
}
