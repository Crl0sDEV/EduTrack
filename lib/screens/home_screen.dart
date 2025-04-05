import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:unitrack/screens/main_screen.dart';
import 'package:unitrack/screens/map_screen.dart';
import 'package:unitrack/screens/profile_screen.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter/services.dart';
import 'dart:math';

class HomeScreen extends StatefulWidget {
  final String userType;

  const HomeScreen({super.key, required this.userType});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _joinCodeController = TextEditingController();
  StreamSubscription<DocumentSnapshot>? _userDataSubscription;
  final DateTime _startTime = DateTime.now();
  String _userName = "";
  TimeOfDay _selectedTime = TimeOfDay.now();
  DateTime _selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _deleteExpiredGroups();
    _fetchUserName();
    _setupUserDataListener();
  }

  @override
  void dispose() {
    _userDataSubscription?.cancel();
    _groupNameController.dispose();
    _joinCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _userName.isEmpty
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      "Welcome, $_userName",
                      key: ValueKey(_userName), 
                      style: const TextStyle(fontSize: 18),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
            ),
          ],
        ),
      ),
      drawer: _buildDrawer(context),
      body: _buildGroupList(),
      floatingActionButton: FloatingActionButton(
        onPressed: _showModal,
        backgroundColor: Color(0xFFFFC107),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
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
                  backgroundColor: Color(0xFFFFC107),
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
                  widget.userType,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          ListTile(
            leading: Icon(Icons.home, color: colorScheme.onSurface),
            title: const Text("Home"),
            onTap: () {
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: Icon(Icons.person, color: colorScheme.onSurface),
            title: const Text("Profile"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ProfileScreen()),
              );
            },
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

  Widget _buildGroupList() {
    return StreamBuilder<QuerySnapshot>(
      stream: widget.userType == "Teacher"
          ? _firestore
              .collection("groups")
              .where("createdBy", isEqualTo: _auth.currentUser!.uid)
              .snapshots()
          : _getStudentGroupsStream(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const Center(child: Text("No groups available."));
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(
              16, 10, 16, 10), // Left, Top, Right, Bottom
          children: snapshot.data!.docs.map((doc) {
            var data = doc.data() as Map<String, dynamic>;
            return _buildGroupCard(doc.id, data);
          }).toList(),
        );
      },
    );
  }

  Stream<QuerySnapshot> _getStudentGroupsStream() {
    String uid = _auth.currentUser!.uid;
    return _firestore
        .collection("groups")
        .where("members", arrayContains: uid)
        .snapshots();
  }

  Widget _buildGroupCard(String groupId, Map<String, dynamic> groupData) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('groups').doc(groupId).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }

        final data = snapshot.data!.data() as Map<String, dynamic>;

        if (data['groupName'] == null || 
          data['joinCode'] == null || 
          data['endTime'] == null || 
          data['endTime'] is! Timestamp) {
          return Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: 5,
            margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
            child: const Padding(
              padding: EdgeInsets.all(15),
              child: Text("Group has invalid end time format"),
            ),
          );
        }

        final endTime = (data['endTime'] as Timestamp).toDate();
        final now = DateTime.now();
        final timeRemaining = endTime.difference(now);
        final isExpired = timeRemaining.isNegative;
        final isExpiringSoon = !isExpired && timeRemaining.inMinutes <= 60;

        String formatExpirationTime(DateTime date) {
          final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
          final ampm = date.hour < 12 ? 'AM' : 'PM';
          return '${date.month}/${date.day}/${date.year} at $hour:${date.minute.toString().padLeft(2, '0')} $ampm';
        }

        if (isExpired) {
          return const SizedBox.shrink();
        }

        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (context) => MapScreen(groupId: groupId)),
            );
          },
          child: Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: 5,
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data["groupName"],
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 5),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("Code: ${data["joinCode"]}",
                          style: const TextStyle(color: Colors.grey)),
                      IconButton(
                        icon: const Icon(Icons.copy, color: Color(0xFFFFC107)),
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: data["joinCode"]));
                          _showToast("Code copied!");
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      const Icon(Icons.access_time,
                          size: 16, color: Colors.grey),
                      const SizedBox(width: 4),
                      Text(
                        "Expires: ${formatExpirationTime(endTime)}",
                        style:
                            const TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                    ],
                  ),
                  if (isExpiringSoon)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        "⚠️ Expires in ${timeRemaining.inMinutes} minutes!",
                        style: const TextStyle(
                            color: Colors.red, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _setupUserDataListener() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _userDataSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists) {
        final userData = snapshot.data() as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _userName = userData['name'] ??
                userData['email']?.split('@').first ??
                'Unknown';
          });
        }
      }
    });
  }

  Future<void> _fetchUserName() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (userDoc.exists) {
        final userData = userDoc.data() as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _userName = userData['name'] ??
                userData['email']?.split('@').first ??
                'Unknown';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _userName = user.email?.split('@').first ?? 'Unknown';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _userName =
              FirebaseAuth.instance.currentUser?.email?.split('@').first ??
                  'Unknown';
        });
      }
    }
  }

  void _deleteExpiredGroups() async {
  try {
    QuerySnapshot groups = await _firestore.collection("groups").get();
    DateTime now = DateTime.now();

    for (var doc in groups.docs) {
      var data = doc.data() as Map<String, dynamic>;

      if (data["endTime"] == null || data["endTime"] is! Timestamp) {
        continue;
      }

      try {
        DateTime endTime = (data["endTime"] as Timestamp).toDate();
        if (endTime.isBefore(now)) {
          await _firestore.collection("groups").doc(doc.id).delete();
        }
      } catch (e) {
        print("Error processing group ${doc.id}: $e");
      }
    }
  } catch (e) {
    print("Error deleting expired groups: $e");
  }
}

  void _showToast(String message) {
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.TOP,
      backgroundColor: Color(0xFFFFC107),
      textColor: Colors.white,
      fontSize: 16.0,
    );
  }

  void _showModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 30.0,
              left: 20,
              right: 20,
              top: 20),
          child: widget.userType == "Teacher"
              ? _buildTeacherModal()
              : _buildStudentModal(),
        );
      },
    );
  }

  Widget _buildTeacherModal() {
    Future<void> selectTime(BuildContext context) async {
      final TimeOfDay? picked = await showTimePicker(
        context: context,
        initialTime: _selectedTime,
      );
      if (picked != null && picked != _selectedTime) {
        setState(() {
          _selectedTime = picked;
        });
      }
    }

    Future<void> selectDate(BuildContext context) async {
      final DateTime? picked = await showDatePicker(
        context: context,
        initialDate: _selectedDate,
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 365)),
      );
      if (picked != null && picked != _selectedDate) {
        setState(() {
          _selectedDate = picked;
        });
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text("Create Group",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 15),
        TextField(
          controller: _groupNameController,
          decoration: const InputDecoration(
              labelText: "Group Name", border: OutlineInputBorder()),
        ),
        const SizedBox(height: 15),
        ListTile(
          title:
              Text("Date: ${_selectedDate.toLocal().toString().split(' ')[0]}"),
          trailing: const Icon(Icons.calendar_today),
          onTap: () => selectDate(context),
        ),
        ListTile(
          title: Text("Time: ${_selectedTime.format(context)}"),
          trailing: const Icon(Icons.access_time),
          onTap: () => selectTime(context),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _createGroup,
          style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFFFFC107),
              foregroundColor: Colors.white),
          child: const Text("Create Group"),
        ),
      ],
    );
  }

  Widget _buildStudentModal() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text("Join Group",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 15),
        TextField(
          controller: _joinCodeController,
          decoration: const InputDecoration(
              labelText: "Enter Join Code", border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _joinGroup,
          style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFFFFC107),
              foregroundColor: Colors.white),
          child: const Text("Join Group"),
        ),
      ],
    );
  }

  void _createGroup() async {
    if (_groupNameController.text.isEmpty) return;

    String generatedCode = _generateJoinCode();

    DateTime endTime = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );

    await _firestore.collection("groups").add({
      "groupName": _groupNameController.text,
      "startTime": _startTime,
      "endTime": endTime,
      "joinCode": generatedCode,
      "createdBy": _auth.currentUser!.uid,
      "members": [],
    });

    if (mounted) {
      Navigator.pop(context);
      _showToast("Group created successfully!");
    }
  }

  void _joinGroup() async {
    if (_joinCodeController.text.isEmpty) return;

    var query = await _firestore
        .collection("groups")
        .where("joinCode", isEqualTo: _joinCodeController.text)
        .get();

    if (query.docs.isNotEmpty) {
      var groupId = query.docs.first.id;
      await _firestore.collection("groups").doc(groupId).update({
        "members": FieldValue.arrayUnion([_auth.currentUser!.uid])
      });

      if (mounted) {
        Navigator.pop(context);
        _showToast("Successfully joined the group!");
      }
    } else {
      _showToast("Invalid code. Please try again.");
    }
  }

  String _generateJoinCode() {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    return String.fromCharCodes(Iterable.generate(
        6, (_) => chars.codeUnitAt(Random().nextInt(chars.length))));
  }
}
