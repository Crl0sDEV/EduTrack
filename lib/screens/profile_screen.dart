import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'edit_profile_screen.dart';
import 'main_screen.dart';
import 'home_screen.dart';

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
  Map<String, dynamic>? userData;
  String? _userType;
  String _userName = "";

  Future<String> _imageToBase64(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final decodedImage = img.decodeImage(bytes);
      if (decodedImage == null) throw Exception('Failed to decode image');
      
      final resizedImage = img.copyResize(decodedImage, width: 200, height: 200);
      final compressedBytes = img.encodeJpg(resizedImage, quality: 85);
      return base64Encode(compressedBytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Image error: ${e.toString()}'),
            behavior: SnackBarBehavior.floating,
          ),
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
          const SnackBar(
            content: Text('Profile picture updated!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update: ${e.toString()}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final userDoc = await _firestore
        .collection('users')
        .doc(_auth.currentUser?.uid)
        .get();
        
    if (mounted) {
      setState(() {
        _userType = userDoc['userType'];
        _userName = userDoc['name'] ?? ''; // Set the user name here
      });
    }
  }

  void _navigateToEditProfile() {
    final user = _auth.currentUser;
    if (user == null || userData == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EditProfileScreen(
          userId: user.uid,
          currentName: userData!['name'] ?? '',
          currentPhone: userData!['phone'] ?? '',
        ),
      ),
    ).then((_) {
      setState(() {});
    });
  }

  Widget _buildDrawer() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: const Color(0xFFFFC107), // Using your amber color
                  child: Text(
                    _userName.isNotEmpty ? _userName[0].toUpperCase() : "U",
                    style: TextStyle(
                      fontSize: 24,
                      color: colorScheme.onPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _userName,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  _userType ?? 'User',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          // ... [Rest of your drawer items remain the same]
          ListTile(
            leading: Icon(Icons.home, color: colorScheme.onSurface),
            title: const Text("Home"),
            onTap: () {
              Navigator.pop(context);
              if (_userType != null) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) => HomeScreen(userType: _userType!),
                  ),
                );
              }
            },
          ),
          ListTile(
            leading: Icon(Icons.person, color: colorScheme.onSurface),
            title: const Text("Profile"),
            onTap: () => Navigator.pop(context),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: colorScheme.error),
            title: Text(
              "Logout",
              style: TextStyle(color: colorScheme.error),
            ),
            onTap: () async {
              await _auth.signOut();
              if (context.mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const MainScreen()),
                );
              }
            },
          ),
        ],
      ),
    );

  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        centerTitle: true,
        elevation: 0,
      ),
      drawer: _buildDrawer(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: FutureBuilder<DocumentSnapshot>(
          future: _firestore.collection('users').doc(_auth.currentUser?.uid).get(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(),
              );
            }

            if (!snapshot.hasData || !snapshot.data!.exists) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No user data found',
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
              );
            }

            userData = snapshot.data!.data() as Map<String, dynamic>;
            final base64Image = userData!['profilePicture'] as String?;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    _isUploading
                        ? const CircularProgressIndicator()
                        : CircleAvatar(
                            radius: 60,
                            backgroundColor: colorScheme.primary.withOpacity(0.1),
                            backgroundImage: base64Image != null
                                ? MemoryImage(base64Decode(base64Image))
                                : null,
                            child: base64Image == null
                                ? Icon(
                                    Icons.person,
                                    size: 60,
                                    color: colorScheme.primary,
                                  )
                                : null,
                          ),
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colorScheme.background,
                          width: 2,
                        ),
                      ),
                      child: IconButton(
                        icon: Icon(
                          Icons.camera_alt,
                          size: 24,
                          color: colorScheme.onPrimary,
                        ),
                        onPressed: _pickAndUploadImage,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  userData!['name'] ?? 'No Name',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _auth.currentUser?.email ?? 'No Email',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 32),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: colorScheme.outline.withOpacity(0.2),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _buildProfileItem(
                          icon: Icons.school,
                          label: 'User Type',
                          value: userData!['userType'] ?? 'Unknown',
                        ),
                        const Divider(height: 24),
                        _buildProfileItem(
                          icon: Icons.phone,
                          label: 'Phone Number',
                          value: userData!['phone']?.isNotEmpty ?? false
                              ? userData!['phone']
                              : 'Not provided',
                        ),
                        const Divider(height: 24),
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
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _navigateToEditProfile,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFC107),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Edit Profile',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(
            icon,
            color: const Color(0xFFFFC107),
            size: 24,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
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