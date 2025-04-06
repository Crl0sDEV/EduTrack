import 'package:flutter/material.dart';

class LocationPinPainter extends CustomPainter {
  final Color color;

  LocationPinPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();

    // Draw pin head (circle) - slightly inset
    path.addOval(Rect.fromCircle(
      center: Offset(size.width / 2, size.width / 2),
      radius: size.width / 2 - 2, // Smaller radius
    ));

    // Draw pin point (triangle) - narrower and shorter
    path.moveTo(size.width / 2 - 8, size.width);  // Reduced from 10
    path.lineTo(size.width / 2 + 8, size.width);  // Reduced from 10
    path.lineTo(size.width / 2, size.height - 5); // Slightly shorter point
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}