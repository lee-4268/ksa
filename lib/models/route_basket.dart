class BasketStation {
  final String id;
  final String name;
  final double lat;
  final double lng;

  const BasketStation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
  });

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'lat': lat, 'lng': lng};

  factory BasketStation.fromJson(Map<String, dynamic> j) => BasketStation(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        lng: (j['lng'] as num?)?.toDouble() ?? 0,
      );
}

class RouteBasketEntry {
  final String entryId;
  final String title;
  final String weekLabel;
  final String joLabel;
  final List<BasketStation> stations;
  final DateTime createdAt;

  const RouteBasketEntry({
    required this.entryId,
    required this.title,
    required this.weekLabel,
    required this.joLabel,
    required this.stations,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'entry_id': entryId,
        'title': title,
        'week_label': weekLabel,
        'jo_label': joLabel,
        'stations': stations.map((s) => s.toJson()).toList(),
        'created_at': createdAt.toIso8601String(),
      };

  factory RouteBasketEntry.fromJson(Map<String, dynamic> j) {
    final list = j['stations'] as List? ?? [];
    return RouteBasketEntry(
      entryId: j['entry_id'] as String? ?? '',
      title: j['title'] as String? ?? '',
      weekLabel: j['week_label'] as String? ?? '',
      joLabel: j['jo_label'] as String? ?? '',
      stations: list.map((e) => BasketStation.fromJson(e as Map<String, dynamic>)).toList(),
      createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
