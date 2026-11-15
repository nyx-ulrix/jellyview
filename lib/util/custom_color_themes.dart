import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:fladder/theme.dart';

enum ColorThemes {
  netflix(
    name: 'Netflix Red',
    color: Color(0xFFE50914),
  ),
  fladder(
    name: 'Fladder',
    color: kDebugMode ? Colors.purpleAccent : Colors.orange,
  ),
  deepOrange(
    name: 'Deep Orange',
    color: Colors.deepOrange,
  ),
  amber(
    name: 'Amber',
    color: Colors.amber,
  ),
  green(
    name: 'Green',
    color: Colors.green,
  ),
  lightGreen(
    name: 'Light Green',
    color: Colors.lightGreen,
  ),
  lime(
    name: 'Lime',
    color: Colors.lime,
  ),
  cyan(
    name: 'Cyan',
    color: Colors.cyan,
  ),
  blue(
    name: 'Blue',
    color: Colors.blue,
  ),
  lightBlue(
    name: 'Light Blue',
    color: Colors.lightBlue,
  ),
  indigo(
    name: 'Indigo',
    color: Colors.indigo,
  ),
  deepBlue(
    name: 'Deep Blue',
    color: Color.fromARGB(255, 1, 34, 94),
  ),
  brown(
    name: 'Brown',
    color: Colors.brown,
  ),
  purple(
    name: 'Purple',
    color: Colors.purple,
  ),
  deepPurple(
    name: 'Deep Purple',
    color: Colors.deepPurple,
  ),
  blueGrey(
    name: 'Blue Grey',
    color: Colors.blueGrey,
  ),
  ;

  const ColorThemes({
    required this.name,
    required this.color,
  });

  final String name;
  final Color color;

  ColorScheme get schemeLight => this == netflix
      ? FladderTheme.netflixScheme(Brightness.light)
      : ColorScheme.fromSeed(seedColor: color, brightness: Brightness.light);

  ColorScheme get schemeDark => this == netflix
      ? FladderTheme.netflixScheme(Brightness.dark)
      : ColorScheme.fromSeed(seedColor: color, brightness: Brightness.dark);
}
