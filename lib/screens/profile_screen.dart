import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ImagePicker _picker = ImagePicker();
  File? _imageFile;
  bool _isUploading = false;

  Future<String> _imageToBase64(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();

      
      final decodedImage = img.decodeImage(bytes);
      if (decodedImage == null) {
        throw Exception('Failed to decode image');
      }

      
      final resizedImage = img.copyResize(
        decodedImage,
        width: 200,
        height: 200, 
      );

      final compressedBytes = img.encodeJpg(resizedImage, quality: 85);
      return base64Encode(compressedBytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image error: ${e.toString()}')),
        );
      }
      rethrow;
    }
  }

  Future<void> _pickAndUploadImage() async {
  setState(() => _isUploading = true);
  try {
    final pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80, 
      maxWidth: 800,    
    );
    
    if (pickedFile == null) return;

    _imageFile = File(pickedFile.path);
    
    
    if (!await _imageFile!.exists()) {
      throw Exception('Selected file does not exist');
    }

    final base64Image = await _imageToBase64(_imageFile!);

    await _firestore.collection('users').doc(_auth.currentUser!.uid).update({
      'profilePicture': base64Image,
      'lastUpdated': FieldValue.serverTimestamp(),
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile picture updated!')),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update: ${e.toString()}')),
      );
    }
  } finally {
    if (mounted) {
      setState(() => _isUploading = false);
    }
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: Color(0xFFFFC107),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: FutureBuilder<DocumentSnapshot>(
          future:
              _firestore.collection('users').doc(_auth.currentUser?.uid).get(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (!snapshot.hasData || !snapshot.data!.exists) {
              return const Center(child: Text('No user data found'));
            }

            final userData = snapshot.data!.data() as Map<String, dynamic>;
            final base64Image = userData['profilePicture'] as String?;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 20),
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    _isUploading
                        ? const CircularProgressIndicator()
                        : CircleAvatar(
                            radius: 50,
                            backgroundColor: Color(0xFFFFC107).withOpacity(0.3),
                            backgroundImage: base64Image != null
                                ? MemoryImage(base64Decode(base64Image))
                                : null,
                            child: base64Image == null
                                ? const Icon(
                                    Icons.person,
                                    size: 50,
                                    color: Color(0xFFFFC107),
                                  )
                                : null,
                          ),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Color(0xFFFFC107),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.camera_alt,
                            size: 20, color: Colors.white),
                        onPressed: _pickAndUploadImage,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  userData['name'] ?? 'No Name',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _auth.currentUser?.email ?? 'No Email',
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 30),
                Card(
                  elevation: 3,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        _buildProfileItem(
                          icon: Icons.school,
                          label: 'User Type',
                          value: userData['userType'] ?? 'Unknown',
                        ),
                        const Divider(),
                        _buildProfileItem(
                          icon: Icons.phone,
                          label: 'Phone',
                          value: userData['phone'] ?? 'Not provided',
                        ),
                        const Divider(),
                        _buildProfileItem(
                          icon: Icons.calendar_today,
                          label: 'Member Since',
                          value: _auth.currentUser?.metadata.creationTime
                                  ?.toString()
                                  .split(' ')[0] ??
                              'Unknown',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: ElevatedButton(
                      onPressed: () {
                        
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Color(0xFFFFC107),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Edit Profile'),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildProfileItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, color: Color(0xFFFFC107)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
