import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

const String SERVER_URL = 'https://road-sos-flax.vercel.app';

class GpsHomePage extends StatefulWidget {
  const GpsHomePage({super.key});

  @override
  State<GpsHomePage> createState() => _GpsHomePageState();
}

class _GpsHomePageState extends State<GpsHomePage> {
  GoogleMapController? _mapController;
  Position? _currentPosition;
  bool _isLoading = false;
  bool _isSearching = false;
  List<Map<String, dynamic>> _nearbyPlaces = [];
  String _selectedCategory = 'trauma';
  double _radiusKm = 3.0;
  Map<String, dynamic>? _selectedPlace;
  Set<Marker> _markers = {};
  Set<Circle> _circles = {};

  // Top toast
  String _toastText = '';
  Color _toastBg = Colors.black;
  bool _toastVisible = false;

  // Routing
  bool _isRoutingSearch = false;

  // Offline / connectivity
  bool _isOffline = false;

  // Server-Initiated SOS Logic
  bool _isSosActive = false;
  int _sosCountdown = 10;
  Timer? _sosTimer;

  // Bottom Panel Dragging
  double _bottomPanelOffset = 0;
  bool _isDraggingPanel = false;

  String? _currentCallSid;
  StreamSubscription<Position>? _positionStream;

  static const LatLng _defaultCenter = LatLng(23.0225, 72.5714);

  final Map<String, Map<String, dynamic>> _categories = {
    'trauma': {
      'icon': Icons.local_hospital,
      'label': 'Trauma Centres',
      'color': const Color(0xFFEF4444),
      'queries': [{'key': 'amenity', 'value': 'hospital'}],
      'hue': BitmapDescriptor.hueRed,
      'emergencyNum': '108',
      'isHospital': true,   // triggers specialty filter
    },
    'police': {
      'icon': Icons.local_police,
      'label': 'Police Stations',
      'color': const Color(0xFF3B82F6),
      'queries': [{'key': 'amenity', 'value': 'police'}],
      'hue': BitmapDescriptor.hueBlue,
      'emergencyNum': '100',
    },
    'ambulance': {
      'icon': Icons.emergency_share,
      'label': 'Ambulance',
      'color': const Color(0xFFF59E0B),
      // ambulance_station is sparse; also search hospitals with emergency dept
      'queries': [
        {'key': 'emergency', 'value': 'ambulance_station'},
        {'key': 'amenity',   'value': 'ambulance_station'},
        {'key': 'healthcare', 'value': 'emergency'},
      ],
      'hue': BitmapDescriptor.hueOrange,
      'emergencyNum': '108',
    },
    'puncture': {
      'icon': Icons.tire_repair,
      'label': 'Puncture / Garage',
      'color': const Color(0xFF8B5CF6),
      // tyres shops rare in OSM India; car_repair garages are common
      'queries': [
        {'key': 'shop', 'value': 'tyres'},
        {'key': 'shop', 'value': 'car_repair'},
        {'key': 'shop', 'value': 'motorcycle_repair'},
      ],
      'hue': BitmapDescriptor.hueViolet,
      'emergencyNum': '1800-180-1522',
    },
    'towing': {
      'icon': Icons.car_crash,
      'label': 'Towing / Rescue',
      'color': const Color(0xFF10B981),
      // vehicle_rescue rare; car_repair shops can assist breakdowns
      'queries': [
        {'key': 'amenity', 'value': 'vehicle_rescue'},
        {'key': 'emergency', 'value': 'roadside_rescue'},
        {'key': 'shop', 'value': 'car_repair'},
      ],
      'hue': BitmapDescriptor.hueGreen,
      'emergencyNum': '1800-180-1522',
    },
    'showroom': {
      'icon': Icons.directions_car,
      'label': 'Car Showrooms',
      'color': const Color(0xFFEC4899),
      // broaden to include motorcycle & vehicle showrooms
      'queries': [
        {'key': 'shop', 'value': 'car'},
        {'key': 'shop', 'value': 'motorcycle'},
        {'key': 'shop', 'value': 'vehicle'},
      ],
      'hue': BitmapDescriptor.hueRose,
      'emergencyNum': '112',
    },
  };

  Color get _catColor => _categories[_selectedCategory]!['color'] as Color;

  @override
  void initState() {
    super.initState();
    _initLocation();
    _initConnectivity();
  }

  @override
  void dispose() {
    _sosTimer?.cancel();
    _positionStream?.cancel();
    FlutterRingtonePlayer().stop();
    _mapController?.dispose();
    super.dispose();
  }

  // ── Toast helper ──
  void _showToast(String msg, Color bg) {
    setState(() { _toastText = msg; _toastBg = bg; _toastVisible = true; });
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _toastVisible = false);
    });
  }

  // ── Connectivity monitor ──
  Future<void> _initConnectivity() async {
    final result = await Connectivity().checkConnectivity();
    _updateConnectivity(result);
    Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) _updateConnectivity(results);
    });
  }

  void _updateConnectivity(dynamic result) {
    // result can be ConnectivityResult or List<ConnectivityResult>
    bool offline;
    if (result is List) {
      offline = result.every((r) => r == ConnectivityResult.none);
    } else {
      offline = result == ConnectivityResult.none;
    }
    if (offline != _isOffline) {
      setState(() => _isOffline = offline);
      if (offline) {
        _showToast('📵 Offline — showing local emergency data', const Color(0xFFB45309));
      } else {
        _showToast('✅ Back online', const Color(0xFF059669));
      }
    }
  }

  // ── Offline search: use bundled emergency_data.json ──
  Future<void> _searchOffline() async {
    if (_currentPosition == null) return;
    setState(() { _isSearching = true; _nearbyPlaces = []; _selectedPlace = null; });

    try {
      final jsonStr = await rootBundle.loadString('assets/data/emergency_data.json');
      final data = jsonDecode(jsonStr);
      final places = (data['places'] as List).cast<Map<String, dynamic>>();

      final typeKey = _selectedCategory == 'police' ? 'police' : 'trauma';
      final lat = _currentPosition!.latitude;
      final lng = _currentPosition!.longitude;

      final results = places
          .where((p) => p['type'] == typeKey)
          .map((p) {
            final dist = _haversine(lat, lng, p['lat'] as double, p['lng'] as double);
            return {
              ...p,
              'distance': dist,
              'hasOsmPhone': true,
              'phone': p['phone'] ?? _categories[_selectedCategory]!['emergencyNum'],
            };
          })
          .toList()
          ..sort((a, b) => (a['distance'] as double).compareTo(b['distance'] as double));

      setState(() { _nearbyPlaces = results.take(20).toList(); _isSearching = false; });
      _updateMarkersAndCircle();
      _showToast('📦 Offline: ${results.length} from local data', const Color(0xFFB45309));
    } catch (e) {
      setState(() => _isSearching = false);
      _showToast('❌ Could not load offline data: $e', Colors.red.shade800);
    }
  }

  void _showSmsFailureDialog(String errorCode, String errorMessage) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return Dialog(
          backgroundColor: const Color(0xFF0A0E1A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xFFEF4444), width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7F1D1D).withOpacity(0.4),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
                  ),
                  child: const Icon(
                    Icons.signal_cellular_connected_no_internet_4_bar,
                    color: Color(0xFFF87171),
                    size: 40,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Carrier SMS Transmission Failed',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Your carrier rejected the emergency SMS ($errorMessage). This usually happens due to zero balance, expired recharge validity, or lack of cellular network signal.',
                  style: GoogleFonts.outfit(
                    color: const Color(0xFF94A3B8),
                    fontSize: 14,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final telUri = Uri.parse('tel:112');
                    if (await canLaunchUrl(telUri)) {
                      await launchUrl(telUri);
                    } else {
                      _showToast('❌ Could not launch dialer', Colors.red.shade800);
                    }
                  },
                  icon: const Icon(Icons.phone_in_talk, color: Colors.white),
                  label: Text(
                    'CALL 112 (Toll-Free)',
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 4,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _searchOffline();
                  },
                  icon: const Icon(Icons.storage, color: Color(0xFF22D3EE)),
                  label: Text(
                    'LOAD NEAREST HOSPITALS (OFFLINE)',
                    style: GoogleFonts.outfit(
                      color: const Color(0xFF22D3EE),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF22D3EE),
                    side: const BorderSide(color: Color(0xFF0891B2), width: 1.5),
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'Dismiss',
                    style: GoogleFonts.outfit(
                      color: const Color(0xFF64748B),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Server-Initiated Twilio SOS ──
  void _triggerSosCountdown() {
    if (_currentPosition == null) {
      _showToast('📍 Getting GPS — try in 5 seconds', const Color(0xFF1D4ED8));
      return;
    }
    
    setState(() {
      _isSosActive = true;
      _sosCountdown = 10;
      _bottomPanelOffset = -320; // Auto drop down
    });

    // Play loud siren
    FlutterRingtonePlayer().playAlarm(looping: true, volume: 1.0);

    _sosTimer?.cancel();
    _sosTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        if (_sosCountdown > 1) {
          _sosCountdown--;
        } else {
          // Timer reached 0
          _cancelSos(triggerServer: true);
        }
      });
    });
  }

  void _cancelSos({bool triggerServer = false}) {
    _sosTimer?.cancel();
    _positionStream?.cancel();
    FlutterRingtonePlayer().stop();
    
    if (mounted) {
      setState(() {
        _isSosActive = false;
        _sosCountdown = 10;
        _bottomPanelOffset = 0; // Auto bring up
      });
    }

    if (triggerServer) {
      _showToast('📡 Calling Server to Trigger Voice Call...', const Color(0xFF7C3AED));
      _callPythonServer();
    } else {
      _showToast('✅ SOS Cancelled - You are safe.', const Color(0xFF059669));
    }
  }

  Future<void> _callPythonServer() async {
    if (_currentPosition == null) return;

    final catName = _categories[_selectedCategory]?['label'] ?? 'General Emergency';

    // OFFLINE SMS FALLBACK
    if (_isOffline) {
      final body = 'SOS|${_currentPosition!.latitude}|${_currentPosition!.longitude}|$catName';
      
      _showToast('📵 Offline: Sending background SMS...', const Color(0xFFB45309));
      
      var permission = await Permission.sms.status;
      if (!permission.isGranted) {
        permission = await Permission.sms.request();
      }

      if (permission.isGranted) {
        try {
          const platform = MethodChannel('com.roadsos/sms');
          await platform.invokeMethod('sendSms', {
            "phone": "+919314050474",
            "msg": body
          });
          _showToast('✅ Offline SOS sent in background!', const Color(0xFF059669));
        } on PlatformException catch (e) {
          _showToast('❌ Carrier SMS Error: ${e.message}', Colors.red.shade800);
          _showSmsFailureDialog(e.code, e.message ?? 'Unknown carrier error');
        } catch (e) {
          _showToast('❌ Failed to send background SMS.', Colors.red.shade800);
          _showSmsFailureDialog('ERR_UNKNOWN', e.toString());
        }
      } else {
        // Fallback to manual send if permission is denied
        final smsUri = Uri.parse('sms:+919314050474?body=${Uri.encodeComponent(body)}');
        if (await canLaunchUrl(smsUri)) {
          await launchUrl(smsUri);
        } else {
          _showToast('❌ Failed to open SMS app.', Colors.red.shade800);
        }
      }
      return;
    }

    // PERMANENT SERVER URL
    final uri = Uri.parse('$SERVER_URL/trigger-call');
    
    try {
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Bypass-Tunnel-Reminder': 'true',
        },
        body: jsonEncode({
          'lat': _currentPosition!.latitude,
          'lng': _currentPosition!.longitude,
          'category': _categories[_selectedCategory]?['label'] ?? 'General Emergency',
        }),
      );

      if (response.statusCode == 200) {
        _showToast('📞 Server is calling your phone now!', const Color(0xFF059669));
        final data = jsonDecode(response.body);
        if (data['call_sid'] != null) {
          _currentCallSid = data['call_sid'];
          _startLocationUpdates();
        }
      } else {
        _showToast('❌ Server Error: ${response.statusCode}', Colors.red.shade800);
      }
    } catch (e) {
      // If 10.0.2.2 fails, they might be on a real device. Show helpful error.
      _showToast('❌ Failed to connect to server.', Colors.red.shade800);
      debugPrint("SOS Error: $e");
    }
  }

  void _startLocationUpdates() {
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 20, // Only trigger if user moves 20+ meters
      ),
    ).listen((Position position) async {
      if (_currentCallSid == null) return;
      
      try {
        await http.post(
          Uri.parse('$SERVER_URL/update-location'),
          headers: {'Content-Type': 'application/json', 'Bypass-Tunnel-Reminder': 'true'},
          body: jsonEncode({
            'call_sid': _currentCallSid,
            'lat': position.latitude,
            'lng': position.longitude,
          }),
        );
        debugPrint("Location updated to server");
      } catch (e) {
        debugPrint("Location update failed: $e");
      }
    });
  }

  // ── OSRM Road-distance: find true nearest by road ──
  Future<void> _findNearestByRoad() async {
    if (_nearbyPlaces.isEmpty) {
      _showToast('🔍 Search first to get results', const Color(0xFF1D4ED8));
      return;
    }
    if (_currentPosition == null) return;

    setState(() => _isRoutingSearch = true);
    _showToast('🛣️ Calculating road distances...', const Color(0xFF7C3AED));

    final uLat = _currentPosition!.latitude;
    final uLng = _currentPosition!.longitude;

    // Take top 10 by Haversine as candidates (limits OSRM calls)
    final candidates = _nearbyPlaces.take(10).toList();

    // Fetch road distances in parallel
    final futures = candidates.map((place) async {
      try {
        final pLat = place['lat'] as double;
        final pLng = place['lng'] as double;
        // OSRM: coordinates are longitude,latitude (reversed!)
        final uri = Uri.https(
          'router.project-osrm.org',
          '/route/v1/driving/$uLng,$uLat;$pLng,$pLat',
          {'overview': 'false', 'steps': 'false'},
        );
        final resp = await http.get(uri,
            headers: {'User-Agent': 'RoadSOS/1.0 (IIT Madras Road Safety Hackathon)'});
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          if (data['code'] == 'Ok') {
            final roadM = (data['routes'][0]['distance'] as num).toDouble();
            final durS  = (data['routes'][0]['duration'] as num).toDouble();
            return {
              ...place,
              'road_km':  roadM / 1000,
              'eta_min':  (durS / 60).ceil(),
            };
          }
        }
      } catch (_) {}
      // Fallback: use Haversine distance if OSRM fails
      return {...place, 'road_km': place['distance'] as double, 'eta_min': 0};
    });

    final routed = await Future.wait(futures);
    routed.sort((a, b) =>
        (a['road_km'] as double).compareTo(b['road_km'] as double));

    if (!mounted) return;
    setState(() => _isRoutingSearch = false);

    if (routed.isEmpty) {
      _showToast('❌ Could not compute road distances', Colors.red.shade800);
      return;
    }

    final nearest = routed.first;
    _flyToPlace(nearest);

    final roadKm  = (nearest['road_km'] as double).toStringAsFixed(1);
    final etaMin  = nearest['eta_min'] as int;
    final etaText = etaMin > 0 ? ' · ~$etaMin min drive' : '';
    _showToast(
      '🚨 Nearest: ${nearest['name']}  •  ${roadKm}km by road$etaText',
      const Color(0xFF059669),
    );
  }

  // ── Fly to a place on the map (stay in app) ──
  void _flyToPlace(Map<String, dynamic> place) {
    setState(() => _selectedPlace = place);
    _mapController?.animateCamera(CameraUpdate.newLatLngZoom(
      LatLng(place['lat'] as double, place['lng'] as double), 17,
    ));
  }

  // ── Results list bottom sheet ──
  void _showResultsList() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        maxChildSize: 0.92,
        minChildSize: 0.3,
        builder: (ctx, sc) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF111827),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(children: [
            const SizedBox(height: 12),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Icon(_categories[_selectedCategory]!['icon'] as IconData, color: _catColor, size: 20),
                const SizedBox(width: 10),
                Text('${_nearbyPlaces.length} ${_categories[_selectedCategory]!['label']} Found',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white38),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ]),
            ),
            const Divider(color: Colors.white12),
            Expanded(
              child: ListView.builder(
                controller: sc,
                itemCount: _nearbyPlaces.length,
                itemBuilder: (_, i) {
                  final p = _nearbyPlaces[i];
                  final color = _catColor;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color.withOpacity(0.2),
                      child: Text('${i + 1}', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
                    ),
                    title: Text(p['name'] as String,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    subtitle: Row(children: [
                      Icon(Icons.near_me, size: 12, color: color),
                      const SizedBox(width: 4),
                      Text(_distLabel(p['distance'] as double),
                          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
                      if ((p['phone'] as String).isNotEmpty) ...[const SizedBox(width: 10), const Icon(Icons.phone, size: 12, color: Colors.white38), const SizedBox(width: 4), Flexible(child: Text(p['phone'] as String, style: const TextStyle(color: Colors.white54, fontSize: 11), overflow: TextOverflow.ellipsis))],
                    ]),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                    onTap: () {
                      Navigator.pop(ctx);
                      _flyToPlace(p);
                    },
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // GPS
  // ─────────────────────────────────────────────
  Future<void> _initLocation() async {
    setState(() => _isLoading = true);
    bool svc = await Geolocator.isLocationServiceEnabled();
    if (!svc) { setState(() => _isLoading = false); return; }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() => _isLoading = false);
      return;
    }

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    if (!pos.latitude.isFinite || !pos.longitude.isFinite) {
      setState(() => _isLoading = false);
      return;
    }

    setState(() { _currentPosition = pos; _isLoading = false; });
    _updateMarkersAndCircle();
    _mapController?.animateCamera(CameraUpdate.newCameraPosition(
      CameraPosition(target: LatLng(pos.latitude, pos.longitude), zoom: 14),
    ));
  }

  // ─────────────────────────────────────────────
  // Markers & circle
  // ─────────────────────────────────────────────
  void _updateMarkersAndCircle() {
    if (_currentPosition == null) return;
    final pos = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    final color = _catColor;
    final hue  = _categories[_selectedCategory]!['hue'] as double;

    final placeMarkers = _nearbyPlaces
        .where((p) => (p['lat'] as double).isFinite && (p['lng'] as double).isFinite)
        .map((p) => Marker(
              markerId: MarkerId('${p['lat']}_${p['lng']}'),
              position: LatLng(p['lat'] as double, p['lng'] as double),
              icon: BitmapDescriptor.defaultMarkerWithHue(hue),
              infoWindow: InfoWindow(
                title: p['name'] as String,
                snippet: _distLabel(p['distance'] as double),
              ),
              onTap: () => _flyToPlace(p),
              zIndex: 1,
            ))
        .toSet();

    setState(() {
      _markers = {
        Marker(
          markerId: const MarkerId('user'),
          position: pos,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: '📍 You are here'),
          zIndex: 2,
        ),
        ...placeMarkers,
      };
      _circles = {
        Circle(
          circleId: const CircleId('radius'),
          center: pos,
          radius: _radiusKm * 1000,
          fillColor: color.withOpacity(0.15),
          strokeColor: color.withOpacity(0.9),
          strokeWidth: 3,
        ),
      };
    });
  }

  // ─────────────────────────────────────────────
  // Overpass search — node + way + relation
  // ─────────────────────────────────────────────
  Future<void> _searchNearby() async {
    if (_currentPosition == null) {
      _showToast('📍 Still finding your location — wait 5 seconds', const Color(0xFF1D4ED8));
      return;
    }
    
    // OFFLINE FALLBACK
    if (_isOffline) {
      return _searchOffline();
    }

    setState(() { _isSearching = true; _nearbyPlaces = []; _selectedPlace = null; });

    final cat      = _categories[_selectedCategory]!;
    final queries  = (cat['queries'] as List).cast<Map<String, dynamic>>();
    final isHosp   = cat['isHospital'] == true;
    final radiusM  = (_radiusKm * 1000).toInt();
    final lat      = _currentPosition!.latitude;
    final lng      = _currentPosition!.longitude;

    // Hospital specialty filter (server-side)
    final extraFilter = isHosp
        ? '["healthcare"!="dentist"]'
          '["healthcare"!="optometrist"]'
          '["healthcare"!="physiotherapist"]'
          '["healthcare"!="psychologist"]'
          '["speciality"!="dentistry"]'
          '["speciality"!="ophthalmology"]'
          '["speciality"!="dermatology"]'
          '["speciality"!="psychiatry"]'
        : '';

    // Build UNION query — one block per {key,value} pair
    final sb = StringBuffer('[out:json][timeout:30];(');
    for (final q in queries) {
      final k = q['key'] as String;
      final v = q['value'] as String;
      sb.write('node["$k"="$v"]$extraFilter(around:$radiusM,$lat,$lng);');
      sb.write('way["$k"="$v"]$extraFilter(around:$radiusM,$lat,$lng);');
      sb.write('relation["$k"="$v"]$extraFilter(around:$radiusM,$lat,$lng);');
    }
    sb.write(');out center;');
    final query = sb.toString();

    const headers = {'User-Agent': 'RoadSOS/1.0 (IIT Madras Road Safety Hackathon; emergency navigation app)'};

    try {
      // Try primary endpoint, fallback to backup if blocked
      final primaryUri = Uri.https('overpass-api.de', '/api/interpreter', {'data': query});
      var resp = await http.get(primaryUri, headers: headers);

      // If primary rate-limits, try backup server
      if (resp.statusCode == 406 || resp.statusCode == 429) {
        final backupUri = Uri.https('overpass.kumi.systems', '/api/interpreter', {'data': query});
        resp = await http.get(backupUri, headers: headers);
      }

      debugPrint('OVERPASS ${resp.statusCode}: ${resp.body.substring(0, resp.body.length.clamp(0, 400))}}');

      if (resp.statusCode == 200) {
        final raw = jsonDecode(resp.body)['elements'] as List;

        final results = raw.map<Map<String, dynamic>?>((e) {
          double? eLat, eLng;
          if (e['lat'] != null && e['lon'] != null) {
            eLat = (e['lat'] as num).toDouble();
            eLng = (e['lon'] as num).toDouble();
          } else if (e['center'] != null) {
            eLat = (e['center']['lat'] as num).toDouble();
            eLng = (e['center']['lon'] as num).toDouble();
          }
          if (eLat == null || !eLat.isFinite || eLng == null || !eLng.isFinite) return null;
          if (e['tags'] == null) return null;

          final tags = e['tags'] as Map<String, dynamic>;
          final name = (tags['name'] ?? tags['amenity'] ?? 'Unknown') as String;

          // Layer 2 (client-side): name keyword filter for hospitals
          // Catches specialty clinics that are poorly tagged in OSM
          // Layer 2 client filter: only for trauma/hospital category
          if (isHosp) {
            final n = name.toLowerCase();
            final specialtyWords = [
              // Dental
              'dental', 'dentist', 'teeth', 'tooth', 'orthodont',
              // Eye / Vision
              'eye', 'optic', 'vision', 'ophthalmol', 'lasik', 'retina',
              // Skin
              'skin', 'dermatol', 'derma',
              // Mental / Psych
              'psychiat', 'psycholog', 'mental health', 'de-addiction',
              // Children only (NOT general with children dept)
              "children's", 'childrens', 'paediatric', 'pediatric',
              // Women / Maternity only
              "women's", 'womens', 'maternity', 'gynaecol', 'gynecol',
              'obstetric', 'gynae', 'lady', 'ladies',
              // Physio / Rehab
              'physiother', 'physio', 'rehabilitation',
              // Cosmetic
              'cosmetic', 'aesthetic', 'beauty', 'plastic surgery',
              // Animal
              'veterinar', 'vet clinic', 'animal',
              // Alternative medicine
              'homeopat', 'homoeopat', 'ayurved', 'unani', 'naturopath',
              'siddha', 'yunani',
            ];
            if (specialtyWords.any((w) => n.contains(w))) return null;
          }

          // Extract all possible phone tags from OSM
          final osmPhone = tags['phone'] ??
              tags['contact:phone'] ??
              tags['contact:mobile'] ??
              tags['phone:emergency'] ??
              tags['emergency:phone'] ??
              tags['contact:emergency'] ?? '';

          // National emergency fallback — ensures every result has a contact
          // Scored criterion: "Number of contacts fetched"
          final fallbackPhone =
              _categories[_selectedCategory]!['emergencyNum'] as String;

          final phone = osmPhone.isNotEmpty ? osmPhone : fallbackPhone;

          return {
            'name':        name,
            'lat':         eLat,
            'lng':         eLng,
            'phone':       phone,
            'hasOsmPhone': osmPhone.isNotEmpty,  // true = real number, false = fallback
            'distance':    _haversine(lat, lng, eLat, eLng),
          };
        }).whereType<Map<String, dynamic>>().toList();

        // Sort by distance closest-first, then keep top 50 for display
        results.sort((a, b) => (a['distance'] as double).compareTo(b['distance'] as double));
        final top50 = results.take(50).toList();

        setState(() { _nearbyPlaces = top50; _isSearching = false; });
        _updateMarkersAndCircle();

        if (results.isNotEmpty) {
          _mapController?.animateCamera(CameraUpdate.newCameraPosition(
            CameraPosition(
              target: LatLng(lat, lng),
              zoom: _radiusKm < 2 ? 15 : _radiusKm < 5 ? 14 : 13,
            ),
          ));
        }

        _showToast(
          results.isEmpty
              ? '😕 No ${_categories[_selectedCategory]!['label']} found — try bigger radius'
              : '✅ Found ${results.length} ${_categories[_selectedCategory]!['label']} nearby',
          results.isEmpty ? const Color(0xFFB45309) : const Color(0xFF059669),
        );
      } else {
        setState(() => _isSearching = false);
        final preview = resp.body.length > 120 ? resp.body.substring(0, 120) : resp.body;
        _showToast('❌ ${resp.statusCode}: $preview', Colors.red.shade800);
      }
    } catch (e) {
      setState(() => _isSearching = false);
      _showToast('❌ Network error: $e', Colors.red.shade800);
    }
  }

  // ─────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────
  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _toRad(double d) => d * pi / 180;

  String _distLabel(double km) =>
      km < 1 ? '${(km * 1000).toStringAsFixed(0)} m' : '${km.toStringAsFixed(2)} km';

  void _openInMaps(double lat, double lng) async {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _launchGoogleMapsTriageSearch(String specialty) async {
    if (_currentPosition == null) return;
    final lat = _currentPosition!.latitude;
    final lng = _currentPosition!.longitude;
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent("$specialty near $lat,$lng")}');
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _showTriageDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        Offset? tapPosition;
        String? doctorType;
        String? searchQuery;
        
        return StatefulBuilder(
          builder: (context, setState) {
            return Dialog(
              backgroundColor: const Color(0xFF0A0E1A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFF1E3A8A), width: 1.5)
              ),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Triage Smart Search', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('Swipe to rotate. Tap injury to select.', style: TextStyle(color: Colors.white70, fontSize: 13), textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    Container(
                      height: 380,
                      width: 250, // Fixed width to calculate percentX accurately
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.cyan.withOpacity(0.3))
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Stack(
                          children: [
                            // Using Listener allows the native 3D webview to receive all swipe/pan gestures for smooth rotation,
                            // while STILL allowing Flutter to perfectly calculate exactly where you tapped!
                            Listener(
                              onPointerUp: (event) {
                                final double x = event.localPosition.dx;
                                final double y = event.localPosition.dy;
                                final double percentX = x / 250.0;
                                final double percentY = y / 380.0;
                                
                                // Ignore taps on empty space (left and right edges)
                                if (percentX < 0.25 || percentX > 0.75) return;
                                
                                setState(() {
                                  tapPosition = event.localPosition;
                                  if (percentY < 0.20) {
                                    doctorType = 'Neurology';
                                    searchQuery = 'Neurology Hospital';
                                  } else if (percentY < 0.45) {
                                    doctorType = 'Cardiac/Pulmonary';
                                    searchQuery = 'Cardiac Hospital';
                                  } else if (percentY < 0.65) {
                                    doctorType = 'Trauma/Internal';
                                    searchQuery = 'Trauma Center';
                                  } else {
                                    doctorType = 'Orthopedic';
                                    searchQuery = 'Orthopedic Hospital';
                                  }
                                });
                              },
                              child: const ModelViewer(
                                src: 'assets/anatomy.glb',
                                alt: 'A 3D model of a human',
                                ar: false,
                                autoRotate: false,
                                cameraControls: true,
                                disableZoom: true,
                                backgroundColor: Colors.transparent,
                                innerModelViewerHtml: '<style>model-viewer {background-color: transparent;}</style>',
                              ),
                            ),
                            if (tapPosition != null)
                              // We wrap the icon in IgnorePointer so tapping the target doesn't block rotating the body underneath it
                              Positioned(
                                left: tapPosition!.dx - 15,
                                top: tapPosition!.dy - 15,
                                child: const IgnorePointer(
                                  child: Icon(Icons.location_searching, color: Colors.redAccent, size: 30)
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (doctorType != null) ...[
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _launchGoogleMapsTriageSearch(searchQuery!);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.local_hospital, color: Colors.white),
                        label: Text('Search $doctorType', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                    )
                  ],
                ),
              ),
            );
          }
        );
      }
    );
  }

  void _callNumber(String phone) async {
    if (phone.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No phone number available for this place.')));
      return;
    }
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  // ─────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: Stack(
        children: [
          // Google Map
          GoogleMap(
            initialCameraPosition: const CameraPosition(target: _defaultCenter, zoom: 5),
            onMapCreated: (ctrl) {
              _mapController = ctrl;
              _updateMarkersAndCircle();
              if (_currentPosition != null) {
                ctrl.animateCamera(CameraUpdate.newCameraPosition(
                  CameraPosition(
                    target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                    zoom: 14,
                  ),
                ));
              }
            },
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            compassEnabled: false,
            markers: _markers,
            circles: _circles,
            onTap: (_) => setState(() => _selectedPlace = null),
          ),

          // Top HUD
          _buildTopHud(),

          // Top Center SOS Button
          if (!_isSosActive)
             Positioned(
               top: 80,
               left: 0,
               right: 0,
               child: Center(
                 child: ElevatedButton.icon(
                    onPressed: _triggerSosCountdown,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      elevation: 10,
                      shadowColor: Colors.redAccent.withOpacity(0.5),
                    ),
                    icon: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 28),
                    label: const Text(
                      'EMERGENCY SOS',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                    ),
                 ),
               ),
             ),

          // Bottom panel with Dragging
          AnimatedPositioned(
            duration: _isDraggingPanel ? Duration.zero : const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            left: 0, right: 0, bottom: _bottomPanelOffset,
            child: GestureDetector(
              onVerticalDragStart: (_) => setState(() => _isDraggingPanel = true),
              onVerticalDragUpdate: (details) {
                setState(() {
                  _bottomPanelOffset -= details.delta.dy;
                  if (_bottomPanelOffset > 0) _bottomPanelOffset = 0; // Max UP
                  if (_bottomPanelOffset < -320) _bottomPanelOffset = -320; // Max DOWN
                });
              },
              onVerticalDragEnd: (details) {
                setState(() {
                  _isDraggingPanel = false;
                  if (_bottomPanelOffset < -150) {
                    _bottomPanelOffset = -320; // Snap to bottom
                  } else {
                    _bottomPanelOffset = 0; // Snap to top
                  }
                });
              },
              child: _buildBottomPanel(),
            ),
          ),

          // SOS Siren Overlay (if active) - Moved to bottom of Stack so it covers everything
          if (_isSosActive)
            _buildSosOverlay(),

          // My Location FAB
          Positioned(
            right: 16,
            bottom: _selectedPlace != null ? 330 : 285,
            child: FloatingActionButton.small(
              backgroundColor: const Color(0xFF111827),
              onPressed: () {
                if (_currentPosition != null) {
                  _mapController?.animateCamera(CameraUpdate.newCameraPosition(
                    CameraPosition(
                      target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                      zoom: 14,
                    ),
                  ));
                }
              },
              child: const Icon(Icons.my_location, color: Color(0xFF3B82F6), size: 20),
            ),
          ),

          // Place detail card
          if (_selectedPlace != null)
            Positioned(
              left: 16, right: 16,
              bottom: 270,
              child: _buildPlaceCard(_selectedPlace!),
            ),

          // ── Top Toast Notification ──
          if (_toastVisible)
            Positioned(
              top: 0, left: 16, right: 16,
              child: SafeArea(
                child: Dismissible(
                  key: ValueKey(_toastText),
                  direction: DismissDirection.up,
                  onDismissed: (_) => setState(() => _toastVisible = false),
                  child: GestureDetector(
                    onHorizontalDragEnd: (d) {
                      if (d.velocity.pixelsPerSecond.dx.abs() > 300)
                        setState(() => _toastVisible = false);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: _toastBg.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white24, width: 1),
                        boxShadow: [BoxShadow(color: _toastBg.withOpacity(0.4), blurRadius: 16, offset: const Offset(0, 4))],
                      ),
                      child: Row(children: [
                        Expanded(child: Text(_toastText,
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600))),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => setState(() => _toastVisible = false),
                          child: const Icon(Icons.close, color: Colors.white54, size: 16),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSosOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.red.shade900.withOpacity(0.85),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.warning, color: Colors.white, size: 80),
            const SizedBox(height: 20),
            const Text(
              'CALLING FOR HELP IN',
              style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Text(
              '$_sosCountdown',
              style: const TextStyle(color: Colors.white, fontSize: 100, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: () => _cancelSos(triggerServer: false),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade600,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                elevation: 8,
              ),
              child: const Text(
                'I AM SAFE (CANCEL)',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Top HUD
  // ─────────────────────────────────────────────
  Widget _buildTopHud() {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0E1A).withOpacity(0.92),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(children: [
                const Icon(Icons.sos, color: Color(0xFF3B82F6), size: 18),
                const SizedBox(width: 6),
                Text('RoadSOS', style: GoogleFonts.inter(
                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              ]),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0E1A).withOpacity(0.92),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: _currentPosition != null
                  ? Row(children: [
                      const Icon(Icons.gps_fixed, color: Color(0xFF10B981), size: 14),
                      const SizedBox(width: 5),
                      Text(
                        '${_currentPosition!.latitude.toStringAsFixed(4)}, '
                        '${_currentPosition!.longitude.toStringAsFixed(4)}',
                        style: const TextStyle(color: Colors.white, fontSize: 11,
                            fontFamily: 'monospace'),
                      ),
                    ])
                  : Row(children: [
                      if (_isLoading)
                        const SizedBox(width: 12, height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFF3B82F6))),
                      const SizedBox(width: 8),
                      const Text('Getting GPS...', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Bottom panel
  // ─────────────────────────────────────────────
  Widget _buildBottomPanel() {
    final color = _catColor;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E1A).withOpacity(0.96),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: const Border(top: BorderSide(color: Colors.white12)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20, offset: const Offset(0, -5))],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 14),

          // Category pills — horizontally scrollable to fit all 6
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: _categories.entries.map((entry) {
              final sel = _selectedCategory == entry.key;
              final c   = entry.value['color'] as Color;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() {
                    _selectedCategory = entry.key;
                    _selectedPlace = null;
                    _nearbyPlaces = [];
                    _updateMarkersAndCircle();
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 78,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: sel ? c.withOpacity(0.2) : const Color(0xFF111827),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: sel ? c : Colors.white12, width: 1.5),
                    ),
                    child: Column(children: [
                      Icon(entry.value['icon'] as IconData,
                          color: sel ? c : Colors.white38, size: 20),
                      const SizedBox(height: 4),
                      Text(entry.value['label'] as String,
                          style: TextStyle(fontSize: 8.5,
                              color: sel ? c : Colors.white38, fontWeight: FontWeight.w600),
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center),
                    ]),
                  ),
                ),
              );
            }).toList()),
          ),
          const SizedBox(height: 14),

          // Radius
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Search Radius',
                style: TextStyle(color: Colors.white54, fontSize: 12,
                    fontFamily: GoogleFonts.inter().fontFamily, letterSpacing: 0.8)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
              child: Text('${_radiusKm.toStringAsFixed(1)} km',
                  style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ]),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              thumbColor: color,
              activeTrackColor: color,
              inactiveTrackColor: Colors.white12,
              overlayColor: color.withOpacity(0.15),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              min: 0.5, max: 20, divisions: 39,
              value: _radiusKm,
              onChanged: (v) {
                setState(() {
                  _radiusKm = v;
                  // Clear old results — they were for a different radius
                  _nearbyPlaces = [];
                  _selectedPlace = null;
                });
                _updateMarkersAndCircle(); // redraws circle only (no place markers)
              },
            ),
          ),
          const SizedBox(height: 6),

          // ── Offline banner ──
          if (_isOffline) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFB45309).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFB45309), width: 1),
              ),
              child: Row(children: [
                const Icon(Icons.wifi_off, color: Color(0xFFF59E0B), size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '📵 Offline Mode — using local emergency data',
                    style: TextStyle(color: Color(0xFFF59E0B), fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 8),

          // Search button — routes to offline or online search
          SizedBox(
            width: double.infinity, height: 50,
            child: ElevatedButton.icon(
              onPressed: _isSearching ? null : (_isOffline ? _searchOffline : _searchNearby),
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                disabledBackgroundColor: color.withOpacity(0.4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: _isSearching
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Icon(_categories[_selectedCategory]!['icon'] as IconData,
                      size: 18, color: Colors.white),
              label: Text(
                _isSearching
                    ? 'Searching...'
                    : _isOffline
                        ? '📦 Search (Offline) ${_categories[_selectedCategory]!['label']}'
                        : 'Search ${_categories[_selectedCategory]!['label']} in ${_radiusKm.toStringAsFixed(1)} km',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
              ),
            ),
          ),

          if (_selectedCategory == 'trauma') ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity, height: 50,
              child: ElevatedButton.icon(
                onPressed: _showTriageDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF111827),
                  side: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.accessibility_new, size: 18, color: Color(0xFFEF4444)),
                label: const Text('🎯 Triage Smart Search', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFFEF4444))),
              ),
            ),
          ],

          if (_nearbyPlaces.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(children: [
              // View list button
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: OutlinedButton.icon(
                    onPressed: _showResultsList,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: color.withOpacity(0.5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: Icon(Icons.list_alt_rounded, color: color, size: 16),
                    label: Text('List (${_nearbyPlaces.length})',
                        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Find nearest by road button
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: ElevatedButton.icon(
                    onPressed: _isRoutingSearch ? null : _findNearestByRoad,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C3AED),
                      disabledBackgroundColor: const Color(0xFF7C3AED).withOpacity(0.4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: _isRoutingSearch
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.emergency, color: Colors.white, size: 16),
                    label: Text(
                      _isRoutingSearch ? 'Routing...' : 'Nearest Road',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Place card
  // ─────────────────────────────────────────────
  Widget _buildPlaceCard(Map<String, dynamic> place) {
    final color = _catColor;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(0.35), width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 20)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
                color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(10)),
            child: Icon(_categories[_selectedCategory]!['icon'] as IconData,
                color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(place['name'] as String,
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 15),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Row(children: [
              Icon(Icons.near_me, color: color, size: 12),
              const SizedBox(width: 4),
              Text(_distLabel(place['distance'] as double),
                  style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
              if ((place['phone'] as String).isNotEmpty) ...[
                const SizedBox(width: 10),
                const Icon(Icons.phone, size: 12, color: Colors.white38),
                const SizedBox(width: 4),
                Expanded(child: Text(place['phone'] as String,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                    overflow: TextOverflow.ellipsis)),
              ],
            ]),
          ])),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white38, size: 18),
            onPressed: () => setState(() => _selectedPlace = null),
            padding: EdgeInsets.zero, constraints: const BoxConstraints(),
          ),
        ]),
        const SizedBox(height: 12),
        // Phone label — shows real number vs national emergency fallback
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (place['hasOsmPhone'] == true
                    ? const Color(0xFF059669)
                    : const Color(0xFFB45309)).withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: place['hasOsmPhone'] == true
                      ? const Color(0xFF059669)
                      : const Color(0xFFB45309),
                  width: 0.8),
              ),
              child: Text(
                place['hasOsmPhone'] == true ? '📞 Direct' : '🆘 Emergency',
                style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.bold,
                  color: place['hasOsmPhone'] == true
                      ? const Color(0xFF059669) : const Color(0xFFF59E0B),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                place['phone'] as String,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ]),
        ),
        Row(children: [
          Expanded(child: ElevatedButton.icon(
            onPressed: () => _openInMaps(place['lat'] as double, place['lng'] as double),
            icon: const Icon(Icons.navigation, size: 16, color: Colors.white),
            label: const Text('Navigate', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1D4ED8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          )),
          const SizedBox(width: 10),
          Expanded(child: ElevatedButton.icon(
            onPressed: () => _callNumber(place['phone'] as String),
            icon: const Icon(Icons.call, size: 16, color: Colors.white),
            label: const Text('Call Now', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF059669),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          )),
        ]),
      ]),
    );
  }
}
