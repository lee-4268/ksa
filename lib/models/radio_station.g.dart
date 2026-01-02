// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'radio_station.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class RadioStationAdapter extends TypeAdapter<RadioStation> {
  @override
  final int typeId = 0;

  @override
  RadioStation read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return RadioStation(
      id: fields[0] as String,
      stationName: fields[1] as String,
      licenseNumber: fields[2] as String,
      address: fields[3] as String,
      latitude: fields[4] as double?,
      longitude: fields[5] as double?,
      memo: fields[6] as String?,
      frequency: fields[7] as String?,
      stationType: fields[8] as String?,
      owner: fields[9] as String?,
      inspectionDate: fields[10] as DateTime?,
      isInspected: fields[11] as bool,
      createdAt: fields[12] as DateTime?,
      updatedAt: fields[13] as DateTime?,
      callSign: fields[14] as String?,
      gain: fields[15] as String?,
      antennaCount: fields[16] as String?,
      remarks: fields[17] as String?,
      categoryName: fields[18] as String?,
      photoPaths: (fields[19] as List?)?.cast<String>(),
    );
  }

  @override
  void write(BinaryWriter writer, RadioStation obj) {
    writer
      ..writeByte(20)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.stationName)
      ..writeByte(2)
      ..write(obj.licenseNumber)
      ..writeByte(3)
      ..write(obj.address)
      ..writeByte(4)
      ..write(obj.latitude)
      ..writeByte(5)
      ..write(obj.longitude)
      ..writeByte(6)
      ..write(obj.memo)
      ..writeByte(7)
      ..write(obj.frequency)
      ..writeByte(8)
      ..write(obj.stationType)
      ..writeByte(9)
      ..write(obj.owner)
      ..writeByte(10)
      ..write(obj.inspectionDate)
      ..writeByte(11)
      ..write(obj.isInspected)
      ..writeByte(12)
      ..write(obj.createdAt)
      ..writeByte(13)
      ..write(obj.updatedAt)
      ..writeByte(14)
      ..write(obj.callSign)
      ..writeByte(15)
      ..write(obj.gain)
      ..writeByte(16)
      ..write(obj.antennaCount)
      ..writeByte(17)
      ..write(obj.remarks)
      ..writeByte(18)
      ..write(obj.categoryName)
      ..writeByte(19)
      ..write(obj.photoPaths);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioStationAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
