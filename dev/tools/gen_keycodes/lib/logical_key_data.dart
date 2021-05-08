// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:gen_keycodes/utils.dart';
import 'package:path/path.dart' as path;

import 'constants.dart';
import 'physical_key_data.dart';

bool _isControlCharacter(String label) {
  if (label.length != 1) {
    return false;
  }
  final int codeUnit = label.codeUnitAt(0);
  return (codeUnit <= 0x1f && codeUnit >= 0x00) || (codeUnit >= 0x7f && codeUnit <= 0x9f);
}

/// A pair of strings that represents left and right modifiers.
class _ModifierPair {
  const _ModifierPair(this.left, this.right);

  final String left;
  final String right;
}

List<T> _toNonEmptyArray<T>(dynamic source) {
  final List<dynamic>? dynamicNullableList = source as List<dynamic>?;
  final List<dynamic> dynamicList = dynamicNullableList ?? <dynamic>[];
  return dynamicList.cast<T>();
}

/// The data structure used to manage keyboard key entries.
///
/// The main constructor parses the given input data into the data structure.
///
/// The data structure can be also loaded and saved to JSON, with the
/// [LogicalKeyData.fromJson] constructor and [toJson] method, respectively.
class LogicalKeyData {
  factory LogicalKeyData(
    String chromiumKeys,
    String gtkKeyCodeHeader,
    String gtkNameMap,
    String windowsKeyCodeHeader,
    String windowsNameMap,
    String androidKeyCodeHeader,
    String androidNameMap,
    String macosLogicalToPhysical,
    String iosLogicalToPhysical,
    PhysicalKeyData physicalKeyData,
  ) {
    final Map<String, LogicalKeyEntry> data = <String, LogicalKeyEntry>{};
    _readKeyEntries(data, chromiumKeys);
    _readWindowsKeyCodes(data, windowsKeyCodeHeader, parseMapOfListOfString(windowsNameMap));
    _readGtkKeyCodes(data, gtkKeyCodeHeader, parseMapOfListOfString(gtkNameMap));
    _readAndroidKeyCodes(data, androidKeyCodeHeader, parseMapOfListOfString(androidNameMap));
    _readMacOsKeyCodes(data, physicalKeyData, parseMapOfListOfString(macosLogicalToPhysical));
    _readIosKeyCodes(data, physicalKeyData, parseMapOfListOfString(iosLogicalToPhysical));
    _readFuchsiaKeyCodes(data, physicalKeyData);
    // Sort entries by value
    final List<MapEntry<String, LogicalKeyEntry>> sortedEntries = data.entries.toList()..sort(
      (MapEntry<String, LogicalKeyEntry> a, MapEntry<String, LogicalKeyEntry> b) =>
        LogicalKeyEntry.compareByValue(a.value, b.value),
    );
    data
      ..clear()
      ..addEntries(sortedEntries);
    return LogicalKeyData._(data);
  }

  /// Parses the given JSON data and populates the data structure from it.
  factory LogicalKeyData.fromJson(Map<String, dynamic> contentMap) {
    final Map<String, LogicalKeyEntry> data = <String, LogicalKeyEntry>{};
    data.addEntries(contentMap.values.map((dynamic value) {
      final LogicalKeyEntry entry = LogicalKeyEntry.fromJsonMapEntry(value as Map<String, dynamic>);
      return MapEntry<String, LogicalKeyEntry>(entry.name, entry);
    }));
    return LogicalKeyData._(data);
  }

  /// Parses the input data given in from the various data source files,
  /// populating the data structure.
  ///
  /// None of the parameters may be null.
  LogicalKeyData._(this._data);

  /// Converts the data structure into a JSON structure that can be parsed by
  /// [LogicalKeyData.fromJson].
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> outputMap = <String, dynamic>{};
    for (final LogicalKeyEntry entry in _data.values) {
      outputMap[entry.name] = entry.toJson();
    }
    return outputMap;
  }

  /// Find an entry from name.
  ///
  /// Asserts if the name is not found.
  LogicalKeyEntry entryByName(String name) {
    assert(_data.containsKey(name),
        'Unable to find logical entry by name $name.');
    return _data[name]!;
  }

  /// All entries.
  Iterable<LogicalKeyEntry> get entries => _data.values;

  // Keys mapped from their names.
  final Map<String, LogicalKeyEntry> _data;

  /// Parses entries from Chromium's key mapping header file.
  ///
  /// Lines in this file look like either of these (without the ///):
  ///                Key        Enum      Unicode code point
  /// DOM_KEY_UNI("Backspace", BACKSPACE, 0x0008),
  ///                Key        Enum       Value
  /// DOM_KEY_MAP("Accel",      ACCEL,    0x0101),
  ///
  /// Flutter's supplemental_key_data.inc also has a new format
  /// that uses a character as the 3rd argument.
  ///                Key        Enum       Character
  /// DOM_KEY_UNI("KeyB",      KEY_B,      'b'),
  static void _readKeyEntries(Map<String, LogicalKeyEntry> data, String input) {
    final Map<String, String> unusedNumpad = Map<String, String>.from(_printableToNumpads);

    final RegExp domKeyRegExp = RegExp(
      r'DOM_KEY_(?<kind>UNI|MAP)\s*\(\s*'
      r'"(?<name>[^\s]+?)",\s*'
      r'(?<enum>[^\s]+?),\s*'
      r"(?:0[xX](?<unicode>[a-fA-F0-9]+)|'(?<char>.)')\s*"
      r'\)',
      // Multiline is necessary because some definitions spread across
      // multiple lines.
      multiLine: true,
    );
    final RegExp commentRegExp = RegExp(r'//.*$', multiLine: true);
    input = input.replaceAll(commentRegExp, '');
    for (final RegExpMatch match in domKeyRegExp.allMatches(input)) {
      final String webName = match.namedGroup('name')!;
      // ".AltGraphLatch"  is consumed internally and not expressed to the Web.
      if (webName.startsWith('.')) {
        continue;
      }
      final String name = LogicalKeyEntry.computeName(webName.replaceAll(RegExp('[^A-Za-z0-9]'), ''));
      final int value = match.namedGroup('unicode') != null ?
        getHex(match.namedGroup('unicode')!) :
        match.namedGroup('char')!.codeUnitAt(0);
      final String? keyLabel = match.namedGroup('kind')! == 'UNI' ? String.fromCharCode(value) : null;
      // If it's a modifier key, add left and right keys instead.
      // Don't add web names and values; they're solved with locations.
      if (_chromeModifiers.containsKey(name)) {
        final _ModifierPair pair = _chromeModifiers[name]!;
        data[pair.left] = LogicalKeyEntry.fromName(
          value: value + kLeftModifierPlane,
          name: pair.left,
          keyLabel: null, // Modifier keys don't have keyLabels
        )..webNames.add(pair.left)
         ..webValues.add(value + kLeftModifierPlane);
        data[pair.right] = LogicalKeyEntry.fromName(
          value: value + kRightModifierPlane,
          name: pair.right,
          keyLabel: null, // Modifier keys don't have keyLabels
        )..webNames.add(pair.right)
         ..webValues.add(value + kRightModifierPlane);
        continue;
      }

      // If it has a numpad counterpart, also add the numpad key.
      final String? char = value < 256 ? String.fromCharCode(value) : null;
      if (char != null && _printableToNumpads.containsKey(char)) {
        final String numpadName = _printableToNumpads[char]!;
        data[numpadName] = LogicalKeyEntry.fromName(
          value: char.codeUnitAt(0) + kNumpadPlane,
          name: numpadName,
          keyLabel: null, // Don't add keyLabel for numpad counterparts
        )..webNames.add(numpadName)
         ..webValues.add(char.codeUnitAt(0) + kNumpadPlane);
        unusedNumpad.remove(char);
      }

      data.putIfAbsent(name, () {
        final bool isPrintable = (keyLabel != null && !_isControlCharacter(keyLabel))
          || printable.containsKey(name)
          || value == 0; // "None" key
        return LogicalKeyEntry.fromName(
          value: value + (isPrintable ? kUnicodePlane : kUnprintablePlane),
          name: name,
          keyLabel: keyLabel,
        )..webNames.add(webName)
         ..webValues.add(value);
      });
    }

    // Make sure every Numpad key that we care about has been defined.
    unusedNumpad.forEach((String key, String value) {
      print('Unuadded numpad key $value');
    });
  }

  static void _readMacOsKeyCodes(
    Map<String, LogicalKeyEntry> data,
    PhysicalKeyData physicalKeyData,
    Map<String, List<String>> logicalToPhysical,
  ) {
    final Map<String, String> physicalToLogical = reverseMapOfListOfString(logicalToPhysical,
        (String logicalKeyName, String physicalKeyName) { print('Duplicate logical key name $logicalKeyName for macOS'); });

    physicalToLogical.forEach((String physicalKeyName, String logicalKeyName) {
      final PhysicalKeyEntry physicalEntry = physicalKeyData.entryByName(physicalKeyName);
      assert(physicalEntry.macOsScanCode != null,
        'Physical entry $physicalKeyName does not have a macOsScanCode.');
      final LogicalKeyEntry? logicalEntry = data[logicalKeyName];
      assert(logicalEntry != null,
        'Unable to find logical entry by name $logicalKeyName.');
      logicalEntry!.macOsKeyCodeNames.add(physicalEntry.name);
      logicalEntry.macOsKeyCodeValues.add(physicalEntry.macOsScanCode!);
    });
  }

  static void _readIosKeyCodes(
    Map<String, LogicalKeyEntry> data,
    PhysicalKeyData physicalKeyData,
    Map<String, List<String>> logicalToPhysical,
  ) {
    final Map<String, String> physicalToLogical = reverseMapOfListOfString(logicalToPhysical,
        (String logicalKeyName, String physicalKeyName) { print('Duplicate logical key name $logicalKeyName for iOS'); });

    physicalToLogical.forEach((String physicalKeyName, String logicalKeyName) {
      final PhysicalKeyEntry physicalEntry = physicalKeyData.entryByName(physicalKeyName);
      assert(physicalEntry.iosScanCode != null,
        'Physical entry $physicalKeyName does not have an iosScanCode.');
      final LogicalKeyEntry? logicalEntry = data[logicalKeyName];
      assert(logicalEntry != null,
        'Unable to find logical entry by name $logicalKeyName.');
      logicalEntry!.iosKeyCodeNames.add(physicalEntry.name);
      logicalEntry.iosKeyCodeValues.add(physicalEntry.iosScanCode!);
    });
  }

  /// Parses entries from GTK's gdkkeysyms.h key code data file.
  ///
  /// Lines in this file look like this (without the ///):
  ///  /** Space key. */
  ///  #define GDK_KEY_space 0x020
  static void _readGtkKeyCodes(Map<String, LogicalKeyEntry> data, String headerFile, Map<String, List<String>> nameToGtkName) {
    final RegExp definedCodes = RegExp(
      r'#define '
      r'GDK_KEY_(?<name>[a-zA-Z0-9_]+)\s*'
      r'0x(?<value>[0-9a-f]+),?',
    );
    final Map<String, String> gtkNameToFlutterName = reverseMapOfListOfString(nameToGtkName,
        (String flutterName, String gtkName) { print('Duplicate GTK logical name $gtkName'); });

    for (final RegExpMatch match in definedCodes.allMatches(headerFile)) {
      final String gtkName = match.namedGroup('name')!;
      final String? name = gtkNameToFlutterName[gtkName];
      final int value = int.parse(match.namedGroup('value')!, radix: 16);
      if (name == null) {
        // print('Unmapped GTK logical entry $gtkName');
        continue;
      }

      final LogicalKeyEntry? entry = data[name];
      if (entry == null) {
        print('Invalid logical entry by name $name (from GTK $gtkName)');
        continue;
      }
      entry
        ..gtkNames.add(gtkName)
        ..gtkValues.add(value);
    }
  }

  static void _readWindowsKeyCodes(Map<String, LogicalKeyEntry> data, String headerFile, Map<String, List<String>> nameMap) {
    // The mapping from the Flutter name (e.g. "enter") to the Windows name (e.g.
    // "RETURN").
    final Map<String, String> nameToFlutterName  = reverseMapOfListOfString(nameMap,
        (String flutterName, String windowsName) { print('Duplicate Windows logical name $windowsName'); });

    final RegExp definedCodes = RegExp(
      r'define '
      r'VK_(?<name>[A-Z0-9_]+)\s*'
      r'(?<value>[A-Z0-9_x]+),?',
    );
    for (final RegExpMatch match in definedCodes.allMatches(headerFile)) {
      final String windowsName = match.namedGroup('name')!;
      final String? name = nameToFlutterName[windowsName];
      final int value = int.tryParse(match.namedGroup('value')!)!;
      if (name == null) {
        print('Unmapped Windows logical entry $windowsName');
        continue;
      }
      final LogicalKeyEntry? entry = data[name];
      if (entry == null) {
        print('Invalid logical entry by name $name (from Windows $windowsName)');
        continue;
      }
      addNameValue(
        entry.windowsNames,
        entry.windowsValues,
        windowsName,
        value,
      );
    }
  }

  /// Parses entries from Android's keycodes.h key code data file.
  ///
  /// Lines in this file look like this (without the ///):
  ///  /** Left Control modifier key. */
  ///  AKEYCODE_CTRL_LEFT       = 113,
  static void _readAndroidKeyCodes(Map<String, LogicalKeyEntry> data, String headerFile, Map<String, List<String>> nameMap) {
    final Map<String, String> nameToFlutterName  = reverseMapOfListOfString(nameMap,
        (String flutterName, String androidName) { print('Duplicate Android logical name $androidName'); });

    final RegExp enumBlock = RegExp(r'enum\s*\{(.*)\};', multiLine: true);
    // Eliminate everything outside of the enum block.
    headerFile = headerFile.replaceAllMapped(enumBlock, (Match match) => match.group(1)!);
    final RegExp enumEntry = RegExp(
      r'AKEYCODE_(?<name>[A-Z0-9_]+)\s*'
      r'=\s*'
      r'(?<value>[0-9]+),?',
    );
    for (final RegExpMatch match in enumEntry.allMatches(headerFile)) {
      final String androidName = match.namedGroup('name')!;
      final String? name = nameToFlutterName[androidName];
      final int value = int.tryParse(match.namedGroup('value')!)!;
      if (name == null) {
        print('Unmapped Android logical entry $androidName');
        continue;
      }
      final LogicalKeyEntry? entry = data[name];
      if (entry == null) {
        print('Invalid logical entry by name $name (from Android $androidName)');
        continue;
      }
      entry
        ..androidNames.add(androidName)
        ..androidValues.add(value);
    }
  }

  static void _readFuchsiaKeyCodes(Map<String, LogicalKeyEntry> data, PhysicalKeyData physicalData) {
    for (final LogicalKeyEntry entry in data.values) {
      final int? value = (() {
        if (entry.value == 0) // "None" key
          return 0;
        final String? keyLabel = printable[entry.constantName];
        if (keyLabel != null && !entry.constantName.startsWith('numpad')) {
          return kUnicodePlane | (keyLabel.codeUnitAt(0) & kValueMask);
        } else {
          final PhysicalKeyEntry? physicalEntry = physicalData.tryEntryByName(entry.name);
          if (physicalEntry != null) {
            return kHidPlane | (physicalEntry.usbHidCode & kValueMask);
          }
        }
      })();
      if (value != null)
        entry.fuchsiaValues.add(value);
    }
  }

  // Map Web key to the pair of key names
  static late final Map<String, _ModifierPair> _chromeModifiers = () {
    final String rawJson = File(path.join(dataRoot, 'chromium_modifiers.json',)).readAsStringSync();
    return (json.decode(rawJson) as Map<String, dynamic>).map((String key, dynamic value) {
      final List<dynamic> pair = value as List<dynamic>;
      return MapEntry<String, _ModifierPair>(key, _ModifierPair(pair[0] as String, pair[1] as String));
    });
  }();

  /// Returns the static map of printable representations.
  static late final Map<String, String> printable = ((){
    final String printableKeys = File(path.join(dataRoot, 'printable.json',)).readAsStringSync();
    return (json.decode(printableKeys) as Map<String, dynamic>)
      .cast<String, String>();
  })();

  // Map printable to corresponding numpad key name
  static late final Map<String, String> _printableToNumpads = () {
    final String rawJson = File(path.join(dataRoot, 'printable_to_numpads.json',)).readAsStringSync();
    return (json.decode(rawJson) as Map<String, dynamic>).map((String key, dynamic value) {
      return MapEntry<String, String>(key, value as String);
    });
  }();

  /// Returns the static map of synonym representations.
  ///
  /// These include synonyms for keys which don't have printable
  /// representations, and appear in more than one place on the keyboard (e.g.
  /// SHIFT, ALT, etc.).
  static late final Map<String, List<String>> synonyms = ((){
    final String synonymKeys = File(path.join(dataRoot, 'synonyms.json',)).readAsStringSync();
    final Map<String, dynamic> dynamicSynonym = json.decode(synonymKeys) as Map<String, dynamic>;
    return dynamicSynonym.map((String name, dynamic values) {
      // The keygen and algorithm of macOS relies on synonyms being pairs.
      // See siblingKeyMap in macos_code_gen.dart.
      final List<String> names = (values as List<dynamic>).whereType<String>().toList();
      assert(names.length == 2);
      return MapEntry<String, List<String>>(name, names);
    });
  })();
}


/// A single entry in the key data structure.
///
/// Can be read from JSON with the [LogicalKeyEntry.fromJsonMapEntry] constructor, or
/// written with the [toJson] method.
class LogicalKeyEntry {
  /// Creates a single key entry from available data.
  LogicalKeyEntry({
    required this.value,
    required this.name,
    this.keyLabel,
  })  : webNames = <String>[],
        webValues = <int>[],
        macOsKeyCodeNames = <String>[],
        macOsKeyCodeValues = <int>[],
        iosKeyCodeNames = <String>[],
        iosKeyCodeValues = <int>[],
        gtkNames = <String>[],
        gtkValues = <int>[],
        windowsNames = <String>[],
        windowsValues = <int>[],
        androidNames = <String>[],
        androidValues = <int>[],
        fuchsiaValues = <int>[];

  LogicalKeyEntry.fromName({
    required int value,
    required String name,
    String? keyLabel,
  })  : this(
          value: value,
          name: name,
          keyLabel: keyLabel,
        );

  /// Populates the key from a JSON map.
  LogicalKeyEntry.fromJsonMapEntry(Map<String, dynamic> map)
    : value = map['value'] as int,
      name = map['name'] as String,
      webNames = _toNonEmptyArray<String>(map['names']['web']),
      webValues = _toNonEmptyArray<int>(map['values']['web']),
      macOsKeyCodeNames = _toNonEmptyArray<String>(map['names']['macOs']),
      macOsKeyCodeValues = _toNonEmptyArray<int>(map['values']['macOs']),
      iosKeyCodeNames = _toNonEmptyArray<String>(map['names']['ios']),
      iosKeyCodeValues = _toNonEmptyArray<int>(map['values']['ios']),
      gtkNames = _toNonEmptyArray<String>(map['names']['gtk']),
      gtkValues = _toNonEmptyArray<int>(map['values']['gtk']),
      windowsNames = _toNonEmptyArray<String>(map['names']['windows']),
      windowsValues = _toNonEmptyArray<int>(map['values']['windows']),
      androidNames = _toNonEmptyArray<String>(map['names']['android']),
      androidValues = _toNonEmptyArray<int>(map['values']['android']),
      fuchsiaValues = _toNonEmptyArray<int>(map['values']['fuchsia']),
      keyLabel = map['keyLabel'] as String?;

  final int value;

  final String name;

  /// The name of the key suitable for placing in comments.
  String get commentName => computeCommentName(name);

  String get constantName => computeConstantName(commentName);

  /// The name of the key, mostly derived from the DomKey name in Chromium,
  /// but where there was no DomKey representation, derived from the Chromium
  /// symbol name.
  final List<String> webNames;

  /// The value of the key.
  final List<int> webValues;

  /// The names of the key codes that corresponds to this logical key on macOS,
  /// created from the corresponding physical keys.
  final List<String> macOsKeyCodeNames;

  /// The key codes that corresponds to this logical key on macOS, created from
  /// the physical key list substituted with the key mapping.
  final List<int> macOsKeyCodeValues;

  /// The names of the key codes that corresponds to this logical key on iOS,
  /// created from the corresponding physical keys.
  final List<String> iosKeyCodeNames;

  /// The key codes that corresponds to this logical key on iOS, created from the
  /// physical key list substituted with the key mapping.
  final List<int> iosKeyCodeValues;

  /// The list of names that GTK gives to this key (symbol names minus the
  /// prefix).
  final List<String> gtkNames;

  /// The list of GTK key codes matching this key, created by looking up the
  /// Linux name in the GTK data, and substituting the GTK key code
  /// value.
  final List<int> gtkValues;

  /// The list of names that Windows gives to this key (symbol names minus the
  /// prefix).
  final List<String> windowsNames;

  /// The list of Windows key codes matching this key, created by looking up the
  /// Windows name in the Chromium data, and substituting the Windows key code
  /// value.
  final List<int> windowsValues;

  /// The list of names that Android gives to this key (symbol names minus the
  /// prefix).
  final List<String> androidNames;

  /// The list of Android key codes matching this key, created by looking up the
  /// Android name in the Chromium data, and substituting the Android key code
  /// value.
  final List<int> androidValues;

  final List<int> fuchsiaValues;

  /// A string indicating the letter on the keycap of a letter key.
  ///
  /// This is only used to generate the key label mapping in keyboard_map.dart.
  /// [LogicalKeyboardKey.keyLabel] uses a different definition and is generated
  /// differently.
  final String? keyLabel;

  /// Creates a JSON map from the key data.
  Map<String, dynamic> toJson() {
    return removeEmptyValues(<String, dynamic>{
      'name': name,
      'value': value,
      'keyLabel': keyLabel,
      'names': <String, dynamic>{
        'web': webNames,
        'macOs': macOsKeyCodeNames,
        'ios': iosKeyCodeNames,
        'gtk': gtkNames,
        'windows': windowsNames,
        'android': androidNames,
      },
      'values': <String, List<int>>{
        'web': webValues,
        'macOs': macOsKeyCodeValues,
        'ios': iosKeyCodeValues,
        'gtk': gtkValues,
        'windows': windowsValues,
        'android': androidValues,
        'fuchsia': fuchsiaValues,
      },
    });
  }

  @override
  String toString() {
    return "'$name': (value: ${toHex(value)}) ";
  }

  /// Gets the named used for the key constant in the definitions in
  /// keyboard_key.dart.
  ///
  /// If set by the constructor, returns the name set, but otherwise constructs
  /// the name from the various different names available, making sure that the
  /// name isn't a Dart reserved word (if it is, then it adds the word "Key" to
  /// the end of the name).
  static String computeName(String rawName) {
    final String result = rawName.replaceAll('PinP', 'PInP');
    if (kDartReservedWords.contains(result)) {
      return '${result}Key';
    }
    return result;
  }

  /// Takes the [name] and converts it from lower camel case to capitalized
  /// separate words (e.g. "wakeUp" converts to "Wake Up").
  static String computeCommentName(String name) {
    final String replaced = name.replaceAllMapped(
      RegExp(r'(Digit|Numpad|Lang|Button|Left|Right)([0-9]+)'), (Match match) => '${match.group(1)} ${match.group(2)}',
    );
    return replaced
      // 'fooBar' => 'foo Bar', 'fooBAR' => 'foo BAR'
      .replaceAllMapped(RegExp(r'([^A-Z])([A-Z])'), (Match match) => '${match.group(1)} ${match.group(2)}')
      // 'ABCDoo' => 'ABC Doo'
      .replaceAllMapped(RegExp(r'([A-Z])([A-Z])([a-z])'), (Match match) => '${match.group(1)} ${match.group(2)}${match.group(3)}')
      // 'AB1' => 'AB 1', 'F1' => 'F1'
      .replaceAllMapped(RegExp(r'([A-Z]{2,})([0-9])'), (Match match) => '${match.group(1)} ${match.group(2)}')
      // 'Foo1' => 'Foo 1'
      .replaceAllMapped(RegExp(r'([a-z])([0-9])'), (Match match) => '${match.group(1)} ${match.group(2)}')
      .trim();
  }

  static String computeConstantName(String commentName) {
    // Convert the first word in the comment name.
    final String lowerCamelSpace = commentName.replaceFirstMapped(RegExp(r'^[^ ]+'),
      (Match match) => match[0]!.toLowerCase(),
    );
    final String result = lowerCamelSpace.replaceAll(' ', '');
    if (kDartReservedWords.contains(result)) {
      return '${result}Key';
    }
    return result;
  }

  static int compareByValue(LogicalKeyEntry a, LogicalKeyEntry b) =>
      a.value.compareTo(b.value);
}
