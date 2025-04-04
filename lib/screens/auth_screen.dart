import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:unitrack/screens/home_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLogin = true;
  bool _isPasswordVisible = false;
  String _userType = "Student"; // Default user type

  Future<void> _authenticate() async {
  String email = _emailController.text.trim();
  String password = _passwordController.text.trim();

  if (email.isEmpty || password.isEmpty) {
    Fluttertoast.showToast(
      msg: "Please fill all fields",
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.TOP,
      backgroundColor: Colors.redAccent,
      textColor: Colors.white,
    );
    return;
  }

  try {
    UserCredential userCredential;
    if (_isLogin) {
      // Login logic
      userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Fetch user type
      DocumentSnapshot userDoc = await _firestore
          .collection("users")
          .doc(userCredential.user!.uid)
          .get();
      if (userDoc.exists) {
        _userType = userDoc["userType"];
      }

      // ✅ Show Success Message for Login
      Fluttertoast.showToast(
        msg: "Login successful!",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Color(0xFFFFC107),
        textColor: Colors.white,
      );
    } else {
      // Sign-up logic
      userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Store user data in Firestore
      await _firestore.collection("users").doc(userCredential.user!.uid).set({
        "email": email,
        "uid": userCredential.user!.uid,
        "userType": _userType,
        "createdAt": FieldValue.serverTimestamp(),
      });

      // ✅ Show Success Message for Sign-Up
      Fluttertoast.showToast(
        msg: "Account created successfully!",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Color(0xFFFFC107),
        textColor: Colors.white,
      );
    }

    // Navigate to HomeScreen with user type
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => HomeScreen(userType: _userType)),
    );
  } catch (e) {
    // ❌ Show Error Message
    Fluttertoast.showToast(
      msg: "Error: ${e.toString()}",
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.TOP,
      backgroundColor: Colors.redAccent,
      textColor: Colors.white,
    );
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // Dark background
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // EduTracker Title
              Text(
                "EduTrack",
                style: GoogleFonts.lobsterTwo(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  fontStyle: FontStyle.italic,
                  color: const Color(0xFFFFC107), // Dandelion color
                ),
              ),
              const SizedBox(height: 30),

              // Authentication Form Box
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10), // Smooth borders
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 1,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: "Email",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.email),
                      ),
                    ),
                    const SizedBox(height: 15),

                    // Password Field with Toggle
                    TextField(
                      controller: _passwordController,
                      obscureText: !_isPasswordVisible,
                      decoration: InputDecoration(
                        labelText: "Password",
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _isPasswordVisible
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                          onPressed: () {
                            setState(() {
                              _isPasswordVisible = !_isPasswordVisible;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 15),

                    // Dropdown for user type (Only in Sign-Up)
                    if (!_isLogin)
                      DropdownButtonFormField<String>(
                        value: _userType,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: "Student", child: Text("Student")),
                          DropdownMenuItem(
                              value: "Teacher", child: Text("Teacher")),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _userType = value!;
                          });
                        },
                      ),
                    const SizedBox(height: 20),

                    // Auth Button (Moved closer to inputs)
                    ElevatedButton(
                      onPressed: _authenticate,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFC107),
                        foregroundColor: Colors.black87,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 30, vertical: 14),
                        textStyle: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(_isLogin ? "Login" : "Sign Up"),
                    ),

// Increased space between button and toggle text
                    const SizedBox(height: 30),

// Toggle between Login and Sign-Up (Left-aligned, Colored Text)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () {
                          setState(() {
                            _isLogin = !_isLogin;
                          });
                        },
                        child: RichText(
                          text: TextSpan(
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500),
                            children: [
                              TextSpan(
                                text: _isLogin
                                    ? "If you haven't registered yet? "
                                    : "If you already have an account? ",
                                style: const TextStyle(color: Colors.black),
                              ),
                              TextSpan(
                                text: _isLogin
                                    ? "Create an account"
                                    : "Login now",
                                style: const TextStyle(
                                  color: Color(0xFFFFC107),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
