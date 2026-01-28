import 'package:hive/hive.dart';

part 'radio_station.g.dart';

@HiveType(typeId: 0)
class RadioStation extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String stationName; // 국소명 (ERP국소명)

  @HiveField(2)
  String licenseNumber; // 허가번호

  @HiveField(3)
  String address; // 주소 (설치장소)

  @HiveField(4)
  double? latitude; // 위도

  @HiveField(5)
  double? longitude; // 경도

  @HiveField(6)
  String? memo; // 특이사항 메모

  @HiveField(7)
  String? frequency; // 주파수

  @HiveField(8)
  String? stationType; // 무선국 종류

  @HiveField(9)
  String? owner; // 소유자

  @HiveField(10)
  DateTime? inspectionDate; // 검사일

  @HiveField(11)
  bool isInspected; // 검사 완료 여부

  @HiveField(12)
  DateTime createdAt;

  @HiveField(13)
  DateTime updatedAt;

  @HiveField(14)
  String? callSign; // 호출명칭

  @HiveField(15)
  String? gain; // 이득(dB)

  @HiveField(16)
  String? antennaCount; // 기수

  @HiveField(17)
  String? remarks; // 비고

  @HiveField(18)
  String? categoryName; // 카테고리 (파일명)

  @HiveField(19)
  List<String>? photoPaths; // 특이사항 사진 경로 목록

  @HiveField(20)
  String? typeApprovalNumber; // 형식검정번호

  @HiveField(21)
  String? installationType; // 설치대 (철탑형태) - 현재 값 (수정 가능)

  @HiveField(22)
  String? originalInstallationType; // 원본 설치대 (Import 시 저장, 변경 비교용)

  RadioStation({
    required this.id,
    required this.stationName,
    required this.licenseNumber,
    required this.address,
    this.latitude,
    this.longitude,
    this.memo,
    this.frequency,
    this.stationType,
    this.owner,
    this.inspectionDate,
    this.isInspected = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.callSign,
    this.gain,
    this.antennaCount,
    this.remarks,
    this.categoryName,
    this.photoPaths,
    this.typeApprovalNumber,
    this.installationType,
    this.originalInstallationType,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  RadioStation copyWith({
    String? id,
    String? stationName,
    String? licenseNumber,
    String? address,
    double? latitude,
    double? longitude,
    String? memo,
    String? frequency,
    String? stationType,
    String? owner,
    DateTime? inspectionDate,
    bool? isInspected,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? callSign,
    String? gain,
    String? antennaCount,
    String? remarks,
    String? categoryName,
    List<String>? photoPaths,
    String? typeApprovalNumber,
    String? installationType,
    String? originalInstallationType,
  }) {
    return RadioStation(
      id: id ?? this.id,
      stationName: stationName ?? this.stationName,
      licenseNumber: licenseNumber ?? this.licenseNumber,
      address: address ?? this.address,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      memo: memo ?? this.memo,
      frequency: frequency ?? this.frequency,
      stationType: stationType ?? this.stationType,
      owner: owner ?? this.owner,
      inspectionDate: inspectionDate ?? this.inspectionDate,
      isInspected: isInspected ?? this.isInspected,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      callSign: callSign ?? this.callSign,
      gain: gain ?? this.gain,
      antennaCount: antennaCount ?? this.antennaCount,
      remarks: remarks ?? this.remarks,
      categoryName: categoryName ?? this.categoryName,
      photoPaths: photoPaths ?? this.photoPaths,
      typeApprovalNumber: typeApprovalNumber ?? this.typeApprovalNumber,
      installationType: installationType ?? this.installationType,
      originalInstallationType: originalInstallationType ?? this.originalInstallationType,
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
      'memo': memo,
      'frequency': frequency,
      'stationType': stationType,
      'owner': owner,
      'inspectionDate': inspectionDate?.toIso8601String(),
      'isInspected': isInspected,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'callSign': callSign,
      'gain': gain,
      'antennaCount': antennaCount,
      'remarks': remarks,
      'categoryName': categoryName,
      'photoPaths': photoPaths,
      'typeApprovalNumber': typeApprovalNumber,
      'installationType': installationType,
      'originalInstallationType': originalInstallationType,
    };
  }

  factory RadioStation.fromJson(Map<String, dynamic> json) {
    return RadioStation(
      id: json['id'] as String,
      stationName: json['stationName'] as String,
      licenseNumber: json['licenseNumber'] as String,
      address: json['address'] as String,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      memo: json['memo'] as String?,
      frequency: json['frequency'] as String?,
      stationType: json['stationType'] as String?,
      owner: json['owner'] as String?,
      inspectionDate: json['inspectionDate'] != null
          ? DateTime.parse(json['inspectionDate'] as String)
          : null,
      isInspected: json['isInspected'] as bool? ?? false,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : DateTime.now(),
      callSign: json['callSign'] as String?,
      gain: json['gain'] as String?,
      antennaCount: json['antennaCount'] as String?,
      remarks: json['remarks'] as String?,
      categoryName: json['categoryName'] as String?,
      photoPaths: (json['photoPaths'] as List<dynamic>?)?.cast<String>(),
      typeApprovalNumber: json['typeApprovalNumber'] as String?,
      installationType: json['installationType'] as String?,
      originalInstallationType: json['originalInstallationType'] as String?,
    );
  }

  // 마커 표시용 이름 (호출명칭 우선)
  String get displayName => callSign?.isNotEmpty == true ? callSign! : stationName;

  bool get hasCoordinates => latitude != null && longitude != null;
}
