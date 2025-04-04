import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'screens/home_screen.dart';
import 'screens/main_screen.dart';
import 'services/location_service.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const AuthCheck(),
    );
  }
}

class AuthCheck extends StatefulWidget {
  const AuthCheck({super.key});

  @override
  State<AuthCheck> createState() => _AuthCheckState();
}

class _AuthCheckState extends State<AuthCheck> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _isLoading = true;
  Widget _nextScreen = const MainScreen();

  @override
  void initState() {
    super.initState();
    _checkUser();
  }

  Future<void> _checkUser() async {
    User? user = _auth.currentUser;

    if (user != null) {
      DocumentSnapshot userDoc =
          await _firestore.collection("users").doc(user.uid).get();

      if (userDoc.exists) {
        String userType = userDoc["userType"];
        String? groupId;

        if (userType == "teacher") {
          groupId = await _getTeacherGroup(user.uid);
        } else if (userType == "student") {
          groupId = await _getStudentGroup(user.uid);
        }

        if (groupId != null) {
          LocationService.updateUserLocation(groupId);
        }

        _nextScreen = HomeScreen(userType: userType);
      }
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<String?> _getTeacherGroup(String userId) async {
    QuerySnapshot query = await _firestore
        .collection("groups")
        .where("creatorId", isEqualTo: userId)
        .limit(1)
        .get();

    if (query.docs.isNotEmpty) {
      return query.docs.first.id;
    }
    return null;
  }

  Future<String?> _getStudentGroup(String userId) async {
    QuerySnapshot query = await _firestore
        .collection("groups")
        .where("members", arrayContains: userId)
        .limit(1)
        .get();

    if (query.docs.isNotEmpty) {
      return query.docs.first.id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return _isLoading
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : _nextScreen;
  }
}
