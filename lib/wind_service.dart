import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Wilayat {
  final String id;
  final String ar;
  final String en;
  final String governorateAr;
  final double? lat;
  final double? lon;

  const Wilayat(this.id, this.ar, this.en, this.governorateAr, this.lat, this.lon);

  factory Wilayat.fromJson(Map<String, dynamic> json) => Wilayat(
        json['id'] as String,
        json['ar'] as String,
        json['en'] as String,
        json['governorateAr'] as String,
        (json['lat'] as num?)?.toDouble(),
        (json['lon'] as num?)?.toDouble(),
      );
}

class WindReading {
  final String day;
  final double ms;
  const WindReading(this.day, this.ms);
}

class WindLocation {
  final double lat;
  final double lon;
  final String source;
  const WindLocation(this.lat, this.lon, this.source);
}

bool validCoordinates(double lat, double lon) =>
    lat.isFinite && lon.isFinite && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;

String nasaDay(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';

String formatDay(String day) => '${day.substring(6, 8)}/${day.substring(4, 6)}/${day.substring(0, 4)}';

List<WindReading> parseWindSeries(dynamic decoded) {
  if (decoded is! Map) throw const FormatException('NASA JSON is not an object');
  final props = decoded['properties'];
  final params = props is Map ? props['parameter'] : null;
  final values = params is Map ? params['WS2M'] : null;
  if (values is! Map) throw const FormatException('Missing WS2M in NASA data');
  final readings = <WindReading>[];
  for (final entry in values.entries) {
    final day = entry.key.toString();
    if (!RegExp(r'^\d{8}$').hasMatch(day)) continue;
    final n = entry.value;
    if (n is! num) continue;
    final speed = n.toDouble();
    if (!speed.isFinite || speed < 0 || speed == -999) continue;
    readings.add(WindReading(day, speed));
  }
  readings.sort((a, b) => a.day.compareTo(b.day));
  return readings.length > 7 ? readings.sublist(readings.length - 7) : readings;
}

class WindService {
  static const endpoint = 'https://power.larc.nasa.gov/api/temporal/daily/point';
  static const geocoder = 'https://nominatim.openstreetmap.org/search';

  static Uri buildNasaUrl(double lat, double lon, DateTime end) {
    final start = DateTime.utc(end.year, end.month, end.day).subtract(const Duration(days: 59));
    return Uri.parse(endpoint).replace(queryParameters: {
      'parameters': 'WS2M',
      'community': 'AG',
      'latitude': '$lat',
      'longitude': '$lon',
      'start': nasaDay(start),
      'end': nasaDay(end),
      'format': 'JSON',
      'time-standard': 'LST',
    });
  }

  final http.Client client;
  WindService({http.Client? client}) : client = client ?? http.Client();

  Future<WindLocation> locationFor(Wilayat w) async {
    if (w.lat != null && w.lon != null) {
      return WindLocation(w.lat!, w.lon!, 'Representative centre');
    }
    final prefs = await SharedPreferences.getInstance();
    final key = 'oman_wind_location_${w.id}';
    final cached = prefs.getString(key);
    if (cached != null) {
      try {
        final data = jsonDecode(cached);
        if (data is Map && data['at'] is num &&
            DateTime.now().millisecondsSinceEpoch - (data['at'] as num).toInt() <
                const Duration(days: 180).inMilliseconds) {
          final lat = (data['lat'] as num).toDouble();
          final lon = (data['lon'] as num).toDouble();
          if (validCoordinates(lat, lon)) {
            return WindLocation(lat, lon, 'OpenStreetMap (cached)');
          }
        }
      } catch (_) {
        // Invalid cache: geocode once more after the user requests the location.
      }
    }
    // Nominatim: only user-triggered geocoding. No bulk lookups or autocomplete.
    final url = Uri.parse(geocoder).replace(queryParameters: {
      'q': '${w.en}, Oman', 'countrycodes': 'om', 'format': 'jsonv2', 'limit': '3',
    });
    final res = await client.get(url, headers: {
      'User-Agent': 'OmanWindExplorer/1.0 (educational personal weather app)',
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('Location lookup HTTP ${res.statusCode}. Use manual coordinates.');
    }
    final items = jsonDecode(res.body);
    if (items is! List || items.isEmpty) {
      throw Exception('لم نجد إحداثيات ${w.ar}. استخدم الإحداثيات اليدوية.');
    }
    final item = items.first;
    final lat = double.tryParse('${item['lat']}');
    final lon = double.tryParse('${item['lon']}');
    if (lat == null || lon == null || !validCoordinates(lat, lon)) {
      throw Exception('Location coordinates are invalid');
    }
    await prefs.setString(key, jsonEncode({
      'lat': lat, 'lon': lon, 'at': DateTime.now().millisecondsSinceEpoch,
    }));
    return WindLocation(lat, lon, 'OpenStreetMap location');
  }

  Future<List<WindReading>> fetchWind(double lat, double lon, DateTime end) async {
    if (!validCoordinates(lat, lon)) throw ArgumentError('Invalid latitude or longitude');
    final res = await client.get(buildNasaUrl(lat, lon, end), headers: {
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) {
      throw Exception('NASA HTTP ${res.statusCode}');
    }
    final readings = parseWindSeries(jsonDecode(res.body));
    if (readings.isEmpty) {
      throw Exception('لا توجد بيانات WS2M صالحة. اختر تاريخاً أقدم.');
    }
    return readings;
  }

  void dispose() => client.close();
}
