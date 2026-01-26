import 'package:hive_flutter/hive_flutter.dart';
import '../models/radio_station.dart';

class StorageService {
  static const String _boxName = 'radio_stations';
  late Box<RadioStation> _box;

  /// Hive 초기화
  Future<void> init() async {
    await Hive.initFlutter();
    Hive.registerAdapter(RadioStationAdapter());
    _box = await Hive.openBox<RadioStation>(_boxName);
  }

  /// 모든 무선국 조회
  List<RadioStation> getAllStations() {
    return _box.values.toList();
  }

  /// 무선국 저장
  Future<void> saveStation(RadioStation station) async {
    await _box.put(station.id, station);
  }

  /// 여러 무선국 저장
  Future<void> saveStations(List<RadioStation> stations) async {
    final Map<String, RadioStation> entries = {
      for (var station in stations) station.id: station,
    };
    await _box.putAll(entries);
  }

  /// 무선국 삭제
  Future<void> deleteStation(String id) async {
    await _box.delete(id);
  }

  /// 모든 무선국 삭제
  Future<void> clearAllStations() async {
    await _box.clear();
  }

  /// 무선국 조회
  RadioStation? getStation(String id) {
    return _box.get(id);
  }

  /// 메모 업데이트
  Future<void> updateMemo(String id, String memo) async {
    final station = _box.get(id);
    if (station != null) {
      station.memo = memo;
      station.updatedAt = DateTime.now();
      await station.save();
    }
  }

  /// 검사 완료 상태 업데이트
  Future<void> updateInspectionStatus(String id, bool isInspected) async {
    final station = _box.get(id);
    if (station != null) {
      station.isInspected = isInspected;
      station.inspectionDate = isInspected ? DateTime.now() : null;
      station.updatedAt = DateTime.now();
      await station.save();
    }
  }

  /// 사진 경로 업데이트
  Future<void> updatePhotoPaths(String id, List<String> photoPaths) async {
    final station = _box.get(id);
    if (station != null) {
      station.photoPaths = photoPaths;
      station.updatedAt = DateTime.now();
      await station.save();
    }
  }

  /// 설치대(철탑형태) 업데이트
  Future<void> updateInstallationType(String id, String installationType) async {
    final station = _box.get(id);
    if (station != null) {
      station.installationType = installationType;
      station.updatedAt = DateTime.now();
      await station.save();
    }
  }
}
