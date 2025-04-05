import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:logger/logger.dart';
import 'package:intl/intl.dart';
import 'package:badges/badges.dart' as badges;

class MapScreen extends StatefulWidget {
  final String groupId;

  const MapScreen({super.key, required this.groupId});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final Logger logger = Logger();
  final MapController _mapController = MapController();
  bool _isMapReady = false;
  StreamSubscription<DocumentSnapshot>? _groupSubscription;
  StreamSubscription<Position>? _positionStreamSubscription;
  StreamSubscription<QuerySnapshot>? _emergencyAlertsSubscription;
  List<DocumentSnapshot> _emergencyAlerts = [];
  List<Marker> _emergencyMarkers = [];
  bool _hasNewEmergency = false;
  bool _showSchoolBoundary = true;
  bool _isMapLocked = false;

  LatLng _currentLocation = const LatLng(14.966059, 120.955091);
  final String? _currentUserId = FirebaseAuth.instance.currentUser?.uid;

  final LatLngBounds _schoolBounds = LatLngBounds(
    const LatLng(14.9655, 120.9545), // SW corner
    const LatLng(14.9668, 120.9557), // NE corner
  );
  final double _schoolRadius = 100.0;

  late final LatLng _schoolCenter = LatLng(
    (_schoolBounds.south + _schoolBounds.north) / 2,
    (_schoolBounds.west + _schoolBounds.east) / 2,
  );

  String? _teacherId;
  List<String> _memberIds = [];
  bool _isLoadingGroup = true;
  bool _isLocationLoading = false;

  bool get _isStudent {
    return _teacherId != null && _currentUserId != _teacherId;
  }

  @override
  void initState() {
    super.initState();
    _setupGroupListener();
    _setupEmergencyAlertsListener();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateUserLocation();
    });
  }

  @override
  void dispose() {
    _groupSubscription?.cancel();
    _positionStreamSubscription?.cancel();
    _emergencyAlertsSubscription?.cancel();
    super.dispose();
  }

  void _toggleSchoolBoundary() {
    setState(() {
      _showSchoolBoundary = !_showSchoolBoundary;
    });
  }

  void _toggleMapLock() {
    setState(() {
      _isMapLocked = !_isMapLocked;
      if (_isMapLocked) {
        _fitMapToSchoolBounds(); // Snap back to bounds when locked
      }
    });
  }

  void _setupGroupListener() {
    _groupSubscription = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists) {
        _processGroupData(snapshot.data()!);
      }
    }, onError: (error) {
      logger.e("Group listener error: $error");
    });
  }

  void _processGroupData(Map<String, dynamic> data) {
    final newMemberIds = List<String>.from(data['members'] ?? []);
    final newTeacherId = data['createdBy'] as String?;

    if (newTeacherId != null && !newMemberIds.contains(newTeacherId)) {
      newMemberIds.add(newTeacherId);
    }

    if (mounted) {
      setState(() {
        _teacherId = newTeacherId;
        _memberIds = newMemberIds;
        _isLoadingGroup = false;
      });
    }
  }

  void _updateEmergencyMarkers() {
    setState(() {
      // Get current highlight markers (if any)
      final highlightMarkers =
          _emergencyMarkers.where((m) => m.width == 50.0).toList();

      // Create new markers from alerts
      final newMarkers = _emergencyAlerts
          .map((alert) {
            final data = alert.data() as Map<String, dynamic>;
            final geoPoint = data['location'] as GeoPoint?;
            if (geoPoint == null) return null;

            final location = LatLng(geoPoint.latitude, geoPoint.longitude);
            logger.d(
                "Displaying emergency at: ${location.latitude}, ${location.longitude}");

            // Check if this location is already highlighted
            final isHighlighted =
                highlightMarkers.any((m) => m.point == location);

            return Marker(
              point: location,
              width: isHighlighted ? 50.0 : 40.0,
              height: isHighlighted ? 50.0 : 40.0,
              child: Icon(
                Icons.emergency,
                color: Colors.red,
                size: isHighlighted ? 50 : 40,
              ),
            );
          })
          .whereType<Marker>()
          .toList();

      // Combine new markers with existing highlights
      _emergencyMarkers = [...newMarkers, ...highlightMarkers];
    });
  }

  Future<void> _verifyGroupMembership() async {
    if (_currentUserId == null) return;

    try {
      final groupDoc = await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupId)
          .get();

      if (groupDoc.exists) {
        final data = groupDoc.data()!;
        final members = List<String>.from(data['members'] ?? []);
        final teacherId = data['createdBy'] as String?;

        if (teacherId != null && !members.contains(teacherId)) {
          members.add(teacherId);
        }

        if (!members.contains(_currentUserId)) {
          logger.w("User $_currentUserId not in group members: $members");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text("You're not in this group's member list")),
            );
          }
          return;
        }

        logger.d("User membership verified");
        if (mounted) {
          setState(() {
            _memberIds = members;
            _teacherId = teacherId;
          });
        }
      }
    } catch (e) {
      logger.e("Error verifying membership: $e");
    }
  }

  void _handleNewPosition(Position? position) {
    if (position == null) {
      logger.w("Received null position update");
      return;
    }

    LatLng newLocation = LatLng(position.latitude, position.longitude);

    if (mounted) {
      // Only call setState if widget is still mounted
      setState(() {
        _currentLocation = newLocation;
      });
    }

    // Still log if outside school bounds
    if (!_schoolBounds.contains(newLocation)) {
      logger.w("⚠️ User is outside school bounds!");
    }

    _updateLocationFirestore(position.latitude, position.longitude);
  }

  void _updateLocationFirestore(double lat, double lng) {
    if (_currentUserId == null || !_memberIds.contains(_currentUserId)) {
      logger.w("Cannot update location - user not in group");
      return;
    }

    FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('locations')
        .doc(_currentUserId)
        .set({
      'latitude': lat,
      'longitude': lng,
      'timestamp': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)).catchError((e) {
      logger.e("Firestore update error: $e");
    });
  }

  void _fitMapToSchoolBounds() {
    try {
      _mapController.fitBounds(
        _schoolBounds,
        options: const FitBoundsOptions(
          padding: EdgeInsets.all(20.0),
          maxZoom: 18.5, // Tighter zoom
        ),
      );
      setState(() {
        _isMapReady = true;
      });
    } catch (e) {
      logger.e("❌ Error fitting map to bounds: $e");
      try {
        _mapController.move(_schoolCenter, 18.0); // Higher zoom level
      } catch (e) {
        logger.e("❌ Error moving map: $e");
      }
    }
  }

  Future<void> _updateUserLocation() async {
    if (_isLocationLoading) return;

    setState(() {
      _isLocationLoading = true;
    });

    try {
      await _verifyGroupMembership();

      if (_currentUserId == null || !_memberIds.contains(_currentUserId)) {
        logger.w("User not in group members list");
        return;
      }

      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        bool enabled = await Geolocator.openLocationSettings();
        if (!enabled) {
          logger.w("Location services not enabled");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Please enable location services")),
            );
          }
          return;
        }
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          logger.w("Location permissions denied");
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        logger.w("Location permissions permanently denied");
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Location Permission Required"),
            content: const Text(
                "Please enable location permissions in app settings"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: () => Geolocator.openAppSettings(),
                child: const Text("Open Settings"),
              ),
            ],
          ),
        );
        return;
      }

      Position? position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 15),
      ).catchError((e) {
        logger.w("Error getting position: $e");
        return null;
      });

      if (position == null) {
        position = await Geolocator.getLastKnownPosition();
        if (position == null) {
          logger.w("No position available");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text("Could not determine your location")),
            );
          }
          return;
        }
      }

      _handleNewPosition(position);

      _positionStreamSubscription?.cancel();
      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 10,
        ),
      ).listen(
        (position) {
          if (mounted) {
            // Check mounted before handling position
            _handleNewPosition(position);
          }
        },
        onError: (e) {
          if (mounted) {
            // Check mounted before showing error
            logger.e("Location stream error: $e");
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Location error: ${e.toString()}")),
            );
          }
        },
        cancelOnError: false,
      );
    } catch (e) {
      logger.e("Error in location updates: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error updating location: ${e.toString()}")),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLocationLoading = false;
        });
      }
    }
  }

  Future<String> _getUserName(String userId) async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      if (userDoc.exists) {
        final data = userDoc.data();
        if (data != null && data.containsKey('name')) {
          return data['name'] as String? ?? 'Unknown';
        }
      }
      return "Unknown";
    } catch (e) {
      logger.e("Error fetching user name: $e");
      return "Unknown";
    }
  }

  Future<List<UserLocationData>> _fetchAllUsers() async {
    if (_isLoadingGroup) return [];

    try {
      final locationDocs = await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupId)
          .collection('locations')
          .get();

      List<UserLocationData> users = [];
      final allUserIds = {..._memberIds};
      if (_teacherId != null) allUserIds.add(_teacherId!);

      final userNameFutures = allUserIds.map((userId) async {
        final name = await _getUserName(userId);
        final locationDoc =
            locationDocs.docs.where((doc) => doc.id == userId).firstOrNull;
        LatLng location = locationDoc != null
            ? LatLng(locationDoc['latitude'], locationDoc['longitude'])
            : const LatLng(14.966073, 120.955121);

        return UserLocationData(
          id: userId,
          name: userId == _currentUserId ? "You" : name,
          isTeacher: userId == _teacherId,
          isCurrentUser: userId == _currentUserId,
          location: location,
        );
      }).toList();

      users = await Future.wait(userNameFutures);

      users.sort((a, b) {
        if (a.isTeacher && !b.isTeacher) return -1;
        if (!a.isTeacher && b.isTeacher) return 1;
        if (a.isCurrentUser && !b.isCurrentUser) return -1;
        if (!a.isCurrentUser && b.isCurrentUser) return 1;
        return a.name.compareTo(b.name);
      });

      return users;
    } catch (e) {
      logger.e("❌ Error fetching users: $e");
      return [];
    }
  }

  void _navigateToUserLocation(LatLng location) {
    try {
      _mapController.move(location, 18.0);
    } catch (e) {
      logger.e("❌ Error navigating to user location: $e");
    }
  }

  void _navigateToAlertLocation(LatLng location) {
    if (!_isMapReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Map is not ready yet")),
      );
      return;
    }

    try {
      // Close the dialog first
      Navigator.of(context).pop();

      // Add a small delay to ensure dialog is fully closed
      Future.delayed(const Duration(milliseconds: 300), () {
        // Move to the location with animation
        _mapController.move(location, 18.0);

        // Create a temporary highlighted marker
        final highlightMarker = Marker(
          point: location,
          width: 50.0,
          height: 50.0,
          child: const Icon(
            Icons.emergency,
            color: Colors.red,
            size: 50,
          ),
        );

        // Keep existing markers and add the highlight
        setState(() {
          _emergencyMarkers = [
            ..._emergencyMarkers.where((m) => m.point != location),
            highlightMarker
          ];
        });

        // Remove highlight after 5 seconds
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted) {
            setState(() {
              _emergencyMarkers =
                  _emergencyMarkers.where((m) => m.point != location).toList();
            });
          }
        });
      });
    } catch (e) {
      logger.e("Error navigating to alert location: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Could not navigate to location: ${e.toString()}")),
      );
    }
  }

  void _showUserListDialog(List<UserLocationData> users) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Group Members',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: users.length,
                  itemBuilder: (context, index) {
                    final user = users[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            user.isTeacher ? Colors.orange : Colors.blue,
                        child: Icon(
                          user.isTeacher ? Icons.school : Icons.person,
                          color: Colors.white,
                        ),
                      ),
                      title: Text(user.name),
                      subtitle: Text(user.isTeacher ? 'Teacher' : 'Student'),
                      trailing: const Icon(Icons.my_location),
                      onTap: () {
                        Navigator.pop(context);
                        _navigateToUserLocation(user.location);
                      },
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEmergencyDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Emergency Alert"),
        content: const Text(
            "Are you sure you want to send an emergency alert to your teacher?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              _sendEmergencyAlert();
              Navigator.pop(context);
            },
            child:
                const Text("Send Alert", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _sendEmergencyAlert() async {
    if (_teacherId == null || _currentUserId == null) return;

    try {
      Position? position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      ).catchError((e) {
        logger.w("Error getting position for emergency: $e");
        return null;
      });

      if (position == null) {
        position = await Geolocator.getLastKnownPosition();
        if (position == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Could not determine your location")),
          );
          return;
        }
      }

      final currentLocation = LatLng(position.latitude, position.longitude);

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .get();

      String studentName = 'Unknown';
      if (userDoc.exists) {
        final data = userDoc.data();
        if (data != null && data.containsKey('name')) {
          studentName = data['name'] as String? ?? 'Unknown';
        } else if (data != null && data.containsKey('email')) {
          final email = data['email'] as String?;
          if (email != null) {
            studentName = email.split('@').first;
          }
        }
      }

      // Ensure groupId is included in the alert
      await FirebaseFirestore.instance.collection('emergency_alerts').add({
        'studentId': _currentUserId,
        'studentName': studentName,
        'createdBy': _teacherId,
        'groupId': widget.groupId, // This is crucial
        'timestamp': FieldValue.serverTimestamp(),
        'location':
            GeoPoint(currentLocation.latitude, currentLocation.longitude),
        'status': 'pending',
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Emergency alert sent to teacher!"),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Failed to send alert: ${e.toString()}"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _setupEmergencyAlertsListener() {
    if (_teacherId == null) {
      Future.delayed(const Duration(seconds: 1), _setupEmergencyAlertsListener);
      return;
    }

    if (_currentUserId != _teacherId) return;

    _emergencyAlertsSubscription?.cancel();

    _emergencyAlertsSubscription = FirebaseFirestore.instance
        .collection('emergency_alerts')
        .where('createdBy', isEqualTo: _teacherId)
        .where('groupId', isEqualTo: widget.groupId)
        .where('status', isEqualTo: 'pending')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return; // Check mounted first
      setState(() {
        _emergencyAlerts = snapshot.docs;
        _hasNewEmergency = snapshot.docs.isNotEmpty;
      });
      _updateEmergencyMarkers();
    }, onError: (error) {
      if (mounted) {
        // Check mounted for errors too
        logger.e("Emergency alerts listener error: $error");
      }
    });
  }

  Future<void> _markAlertAsResponded(String alertId) async {
    await FirebaseFirestore.instance
        .collection('emergency_alerts')
        .doc(alertId)
        .update({'status': 'responded'});
  }

  void _showEmergencyAlertsDialog() {
    _updateEmergencyMarkers();
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
            maxWidth: MediaQuery.of(context).size.width * 0.9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Emergency Alerts',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                  child: _emergencyAlerts.isEmpty
                      ? const Center(child: Text("No active emergency alerts"))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _emergencyAlerts.length,
                          itemBuilder: (context, index) {
                            final alert = _emergencyAlerts[index].data()
                                as Map<String, dynamic>;
                            final geoPoint = alert['location'] as GeoPoint?;
                            final alertLocation = geoPoint != null
                                ? LatLng(geoPoint.latitude, geoPoint.longitude)
                                : null;

                            return ListTile(
                              leading: const Icon(Icons.emergency,
                                  color: Colors.red),
                              title: Text(
                                  alert['studentName'] ?? 'Unknown student'),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      "Sent ${DateFormat('MMM d, h:mm a').format((alert['timestamp'] as Timestamp).toDate())}"),
                                  if (alertLocation != null)
                                    Text(
                                        "Location: ${alertLocation.latitude.toStringAsFixed(6)}, ${alertLocation.longitude.toStringAsFixed(6)}"),
                                ],
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.location_on),
                                onPressed: () {
                                  if (alertLocation != null) {
                                    logger.d(
                                        "Navigating to emergency at: ${alertLocation.latitude}, ${alertLocation.longitude}");
                                    _navigateToAlertLocation(alertLocation);
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content:
                                              Text("Invalid location data")),
                                    );
                                  }
                                },
                              ),
                              onTap: () async {
                                await _markAlertAsResponded(
                                    _emergencyAlerts[index].id);
                                if (alertLocation != null) {
                                  _navigateToAlertLocation(alertLocation);
                                }
                              },
                            );
                          },
                        )),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      // Clear markers when dialog closes
      if (mounted) {
        setState(() {
          _emergencyMarkers = [];
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const Text(
              "Location Tracker",
              style: TextStyle(fontSize: 18),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('groups')
                .doc(widget.groupId)
                .collection('locations')
                .snapshots(),
            builder: (context, locationSnapshot) {
              if (locationSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (locationSnapshot.hasError) {
                logger.e("❌ Firestore Error: ${locationSnapshot.error}");
                return Center(
                    child:
                        Text("❌ Firestore Error: ${locationSnapshot.error}"));
              }

              if (!locationSnapshot.hasData ||
                  locationSnapshot.data!.docs.isEmpty) {
                return const Center(child: Text("ℹ️ No locations found."));
              }

              List<Marker> markers = locationSnapshot.data!.docs
                  .map((doc) {
                    try {
                      String userId = doc.id;
                      double lat = doc['latitude'];
                      double lng = doc['longitude'];
                      LatLng userPosition = LatLng(lat, lng);

                      Color markerColor;
                      if (userId == _teacherId) {
                        markerColor = const Color(0xFFFFC107);
                      } else if (userId == _currentUserId) {
                        markerColor = Colors.red;
                      } else {
                        markerColor = Colors.blue;
                      }

                      return Marker(
                        point: userPosition,
                        width: 40.0,
                        height: 40.0,
                        child: Icon(
                          Icons.location_pin,
                          color: markerColor,
                          size: 40,
                        ),
                      );
                    } catch (e) {
                      logger.w("⚠️ Invalid location data: ${doc.id}");
                      return null;
                    }
                  })
                  .whereType<Marker>()
                  .toList();

              return FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _schoolCenter,
                  initialZoom: 18.0, // Increased from 17.5 to zoom in closer
                  minZoom: 17.0, // Prevent zooming out too far
                  maxZoom: 19.0,
                  interactionOptions: InteractionOptions(
                    flags: _isMapLocked
                        ? InteractiveFlag
                            .none // Disable all interactions when locked
                        : InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                  onMapReady: () {
                    if (!_isMapReady) {
                      _fitMapToSchoolBounds();
                    }
                  },
                  onPositionChanged: (MapPosition position, bool hasGesture) {
                    // Optional: You can add logic here to prevent panning outside bounds
                    if ( _isMapLocked && hasGesture) {
                      _fitMapToSchoolBounds();
                      final currentBounds = position.bounds;
                      if (!_schoolBounds.containsBounds(currentBounds!)) {
                        // If user panned outside, gently nudge back
                        Future.delayed(Duration.zero, () {
                          _mapController.fitBounds(_schoolBounds,
                              options: const FitBoundsOptions(
                                padding: EdgeInsets.all(20.0),
                              ));
                        });
                      }
                    }
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        "https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}",
                    subdomains: const ['a', 'b', 'c'],
                    tileProvider: CancellableNetworkTileProvider(),
                    userAgentPackageName: 'com.example.unitrack',
                  ),
                  if (_showSchoolBoundary)
                    CircleLayer(
                      circles: [
                        CircleMarker(
                          point: _schoolCenter,
                          radius: _schoolRadius,
                          useRadiusInMeter: true,
                          color: Colors.blue.withOpacity(0.03),
                          borderColor: Colors.blue,
                          borderStrokeWidth: 2.0,
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      ...markers, // Your existing user markers
                      ..._emergencyMarkers, // Emergency location markers
                    ],
                  ),
                ],
              );
            },
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Tooltip(
              message: 'View group members',
              child: FloatingActionButton(
                mini: true,
                backgroundColor: Colors.white,
                onPressed: () async {
                  if (_isLoadingGroup) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Loading group data...')));
                    return;
                  }

                  final users = await _fetchAllUsers();
                  if (users.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No users found')));
                    return;
                  }

                  _showUserListDialog(users);
                },
                child: const Icon(Icons.people, color: Color(0xFFFFC107)),
              ),
            ),
          ),
          Positioned(
            top: 60,
            right: 10,
            child: Tooltip(
              message: 'Reset view to school area',
              child: FloatingActionButton(
                heroTag: "map_screen_fab",
                mini: true,
                backgroundColor: Colors.white,
                onPressed: _fitMapToSchoolBounds,
                child: const Icon(Icons.crop_free, color: Color(0xFFFFC107)),
              ),
            ),
          ),
          if (_isStudent)
            Positioned(
              top: 110,
              right: 10,
              child: Tooltip(
                message: 'Send emergency alert',
                child: FloatingActionButton(
                  mini: true,
                  heroTag: "emergency_fab",
                  backgroundColor: Colors.white,
                  onPressed: _showEmergencyDialog,
                  child: const Icon(Icons.emergency, color: Color(0xFFFFC107)),
                ),
              ),
            ),
          if (!_isStudent && _teacherId == _currentUserId)
            Positioned(
              top: 110,
              right: 10,
              child: Tooltip(
                message: 'View emergency alerts',
                child: FloatingActionButton(
                  heroTag: "emergency_notification",
                  mini: true,
                  backgroundColor: Colors.white,
                  onPressed: _showEmergencyAlertsDialog,
                  child: _hasNewEmergency
                      ? const badges.Badge(
                          badgeContent:
                              Text('!', style: TextStyle(color: Colors.red)),
                          child: Icon(Icons.notifications, color: Colors.red),
                        )
                      : const Icon(Icons.notifications,
                          color: Color(0xFFFFC107)),
                ),
              ),
            ),
          Positioned(
            top: 160, // Below the emergency button
            right: 10,
            child: Tooltip(
              message: _showSchoolBoundary
                  ? 'Hide school boundary'
                  : 'Show school boundary',
              child: FloatingActionButton(
                heroTag: "boundary_toggle",
                mini: true,
                backgroundColor: Colors.white,
                onPressed: _toggleSchoolBoundary,
                child: Icon(
                  _showSchoolBoundary ? Icons.layers_clear : Icons.layers,
                  color: Color(0xFFFFC107),
                ),
              ),
            ),
          ),
          Positioned(
            top: 210, // Position below the boundary toggle button
            right: 10,
            child: Tooltip(
              message: _isMapLocked ? 'Unlock map' : 'Lock map to school area',
              child: FloatingActionButton(
                heroTag: "map_lock",
                mini: true,
                backgroundColor: Colors.white,
                onPressed: _toggleMapLock,
                child: Icon(
                  _isMapLocked ? Icons.lock : Icons.lock_open,
                  color: Color(0xFFFFC107),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class UserLocationData {
  final String id;
  final String name;
  final bool isTeacher;
  final bool isCurrentUser;
  final LatLng location;

  UserLocationData({
    required this.id,
    required this.name,
    required this.isTeacher,
    required this.isCurrentUser,
    required this.location,
  });
}
