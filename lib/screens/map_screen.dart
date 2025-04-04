import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:logger/logger.dart';

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

  LatLng _currentLocation =
      LatLng(14.966059, 120.955091); // Default: St. Paul College San Rafael
  final String? _currentUserId = FirebaseAuth.instance.currentUser?.uid;

  // School bounds
  final LatLngBounds _schoolBounds = LatLngBounds(
    LatLng(14.9655, 120.9545), // Southwest corner
    LatLng(14.9668, 120.9557), // Northeast corner
  );

  // Calculate school center
  late final LatLng _schoolCenter = LatLng(
    (_schoolBounds.south + _schoolBounds.north) / 2,
    (_schoolBounds.west + _schoolBounds.east) / 2,
  );

  // Store group data
  String? _teacherId;
  List<String> _memberIds = [];
  bool _isLoadingGroup = true;
  bool _isLocationLoading = false;

  @override
  void initState() {
    super.initState();
    _setupGroupListener();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateUserLocation();
    });
  }

  @override
  void dispose() {
    _groupSubscription?.cancel();
    _positionStreamSubscription?.cancel();
    super.dispose();
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
    logger.d("Updated group data - Teacher: $_teacherId, Members: $_memberIds");
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
              const SnackBar(content: Text("You're not in this group's member list")),
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

  void _handleNewPosition(Position position) {
    LatLng newLocation = LatLng(position.latitude, position.longitude);

    if (_schoolBounds.contains(newLocation)) {
      setState(() {
        _currentLocation = newLocation;
      });
    } else {
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
          maxZoom: 18.0,
        ),
      );
      setState(() {
        _isMapReady = true;
      });
    } catch (e) {
      logger.e("❌ Error fitting map to bounds: $e");
      try {
        _mapController.move(_schoolCenter, 17.5);
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

      // Check and request permissions
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
            content: const Text("Please enable location permissions in app settings"),
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

      // Try to get current position with timeout
      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
          timeLimit: const Duration(seconds: 15),
        ).catchError((e) {
          logger.w("Error getting position: $e");
          return null;
        });
      } catch (e) {
        logger.e("Position error: $e");
      }

      // Fallback to last known position if current fails
      if (position == null) {
        try {
          position = await Geolocator.getLastKnownPosition();
          if (position == null) {
            logger.w("No position available");
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Could not determine your location")),
              );
            }
            return;
          }
        } catch (e) {
          logger.e("Last known position error: $e");
          return;
        }
      }

      _handleNewPosition(position);

      // Cancel any existing stream
      _positionStreamSubscription?.cancel();

      // Set up new location stream
      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 10, // meters
          timeLimit: const Duration(seconds: 30),
        ),
      ).listen(
        _handleNewPosition,
        onError: (e) {
          logger.e("Location stream error: $e");
          if (mounted) {
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

  // Fetch user name from Firestore
  Future<String> _getUserName(String userId) async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      
      if (userDoc.exists && userDoc.data()!.containsKey('name')) {
        final name = userDoc.data()!['name'] as String?;
        if (name != null && name.isNotEmpty) {
          return name;
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

      // Fetch all user names in parallel
      final userNameFutures = allUserIds.map((userId) async {
        final name = await _getUserName(userId);
        
        final locationDoc = locationDocs.docs.where((doc) => doc.id == userId).firstOrNull;

        LatLng location = locationDoc != null
            ? LatLng(locationDoc['latitude'], locationDoc['longitude'])
            : LatLng(14.966073, 120.955121);

        return UserLocationData(
          id: userId,
          name: userId == _currentUserId ? "You" : name,
          isTeacher: userId == _teacherId,
          isCurrentUser: userId == _currentUserId,
          location: location,
        );
      }).toList();

      // Wait for all user data to be fetched
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
                        backgroundColor: user.isTeacher ? Colors.orange : Colors.blue,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Real-time Location Tracker")),
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
                    child: Text("❌ Firestore Error: ${locationSnapshot.error}"));
              }

              if (!locationSnapshot.hasData || locationSnapshot.data!.docs.isEmpty) {
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
                  initialZoom: 17.5,
                  minZoom: 16.0,
                  maxZoom: 19.0,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all,
                  ),
                  onMapReady: () {
                    if (!_isMapReady) {
                      _fitMapToSchoolBounds();
                    }
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: "https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}",
                    subdomains: const ['a', 'b', 'c'],
                    tileProvider: CancellableNetworkTileProvider(),
                    userAgentPackageName: 'com.example.unitrack',
                  ),
                  MarkerLayer(markers: markers),
                ],
              );
            },
          ),
          Positioned(
            top: 10,
            right: 10,
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
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton(
              heroTag: "map_screen_fab",
              mini: true,
              backgroundColor: Colors.white,
              onPressed: _fitMapToSchoolBounds,
              child: const Icon(Icons.crop_free, color: Color(0xFFFFC107)),
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