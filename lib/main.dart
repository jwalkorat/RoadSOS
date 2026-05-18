import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'gps/gps_home_page.dart';

void main() {
  runApp(const RoadSOSApp());
}

class RoadSOSApp extends StatelessWidget {
  const RoadSOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RoadSOS',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF10B981),
        ),
      ),
      home: const GpsHomePage(),
    );
  }
}