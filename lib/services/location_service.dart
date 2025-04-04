import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class LocationService {
  static Stream<Position> getPositionStream() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1, // Update Firestore when moving 5 meters
      ),
    );
  }

  static Future<void> updateUserLocation(String groupId) async {
    try {
      String? userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId == null) {
        print("⚠️ User is not authenticated!");
        return;
      }

      Stream<Position> positionStream = getPositionStream();
      positionStream.listen((Position position) async {
        print("📌 Updating Firestore for: $userId | ${position.latitude}, ${position.longitude}");

        await FirebaseFirestore.instance
            .collection('groups')
            .doc(groupId)
            .collection('locations')
            .doc(userId)
            .set({
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        print("✅ Location saved!");
      });
    } catch (e) {
      print("❌ Error updating location: $e");
    }
  }
}
