// GENERATED CODE - DO NOT MODIFY BY HAND
// Manually written to match the DownloadIndexEntry HiveType(typeId: 3).

part of 'download_index.dart';

class DownloadIndexEntryAdapter extends TypeAdapter<DownloadIndexEntry> {
  @override
  final int typeId = 3;

  @override
  DownloadIndexEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DownloadIndexEntry(
      videoId:      fields[0]  as String,
      path:         fields[1]  as String,
      thumbnailPath: (fields[2] as String?) ?? '',
      format:       (fields[3]  as String?) ?? 'm4a',
      bitrate:      (fields[4]  as int?)    ?? 0,
      sizeBytes:    (fields[5]  as int?)    ?? 0,
      title:        (fields[6]  as String?) ?? '',
      artist:       (fields[7]  as String?) ?? '',
      durationMs:   (fields[8]  as int?)    ?? 0,
      downloadedAt: (fields[9]  as DateTime?) ?? DateTime.now(),
      playlistIds:  (fields[10] as List?)?.cast<String>() ?? [],
    );
  }

  @override
  void write(BinaryWriter writer, DownloadIndexEntry obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.videoId)
      ..writeByte(1)
      ..write(obj.path)
      ..writeByte(2)
      ..write(obj.thumbnailPath)
      ..writeByte(3)
      ..write(obj.format)
      ..writeByte(4)
      ..write(obj.bitrate)
      ..writeByte(5)
      ..write(obj.sizeBytes)
      ..writeByte(6)
      ..write(obj.title)
      ..writeByte(7)
      ..write(obj.artist)
      ..writeByte(8)
      ..write(obj.durationMs)
      ..writeByte(9)
      ..write(obj.downloadedAt)
      ..writeByte(10)
      ..write(obj.playlistIds);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadIndexEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
