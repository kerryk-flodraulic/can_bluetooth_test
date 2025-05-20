// Flutter app to interface with a Puisi MCBox CAN device over Bluetooth.
// Features:
// - Scans and connects to BLE devices
// - Sends control state as CAN frames (ASCII or binary)
// - Parses and logs live CAN traffic from device
// - Supports UI-based control buttons, mutual exclusivity,
//   live/fixed feed display, filtering, and searching

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'bluetooth.dart';
import 'crc32.dart';
import 'dart:typed_data';

class CanLogEntry {
  final String canId; // Hex formatted ID
  final int dlc; // Data length
  final List<String> dataBytes; // D0-D7 in hex
  // final bool flag; // true if flagged
  final DateTime timestamp;

  CanLogEntry({
    required this.canId,
    required this.dlc,
    required this.dataBytes,
    // required this.flag,
    required this.timestamp,
  });
//Returns formatted timestamps like: "11:11.111"
  String get timestampFormatted =>
      '${timestamp.hour.toString().padLeft(2, '0')}:'
      '${timestamp.minute.toString().padLeft(2, '0')}:'
      '${timestamp.second.toString().padLeft(2, '0')}.'
      '${timestamp.millisecond.toString().padLeft(3, '0')}';
}

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    //Initialized the BT CAN manager
    CanBluetooth.instance.init();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const BluetoothCanReader(),
    );
  }
}

class BluetoothCanReader extends StatefulWidget {
  const BluetoothCanReader({super.key});
  @override
  State<BluetoothCanReader> createState() => _BluetoothCanReaderState();
}

class _BluetoothCanReaderState extends State<BluetoothCanReader> {
  final ScrollController _scrollController = ScrollController();
  final List<List<String>> canHistory = [];
  List<List<String>> filteredCanHistory = [];
  final TextEditingController _searchController = TextEditingController();
  bool _isPaused = false; // To pause/resume live feed
  bool _showLiveFeed = true; // Toggle live vs fixed feed
  final TextEditingController _deviceFilterController = TextEditingController();
  String _deviceNameFilter = '';
  String selectedChannel = 'All';
  String selectedCanId = 'All';
  String selectedData = 'All';
  String selectedTime = 'All';

  String selectedDlc = 'All';
  String selectedDirection = 'All';
  List<String> getUniqueOptions(int columnIndex) {
    final source =
        _showLiveFeed ? canHistory : fixedCanHistoryMap.values.toList();

    // Special case for Time column (index 4)
    if (columnIndex == 4) {
      final seconds = source.map((row) {
        final timeParts = row[4].split(RegExp(r'[:.]')); // mm:ss.mmm
        final minutes = int.tryParse(timeParts[0]) ?? 0;
        final secs = int.tryParse(timeParts[1]) ?? 0;
        return minutes * 60 + secs;
      });

      final Set<String> buckets = {};
      for (final sec in seconds) {
        final bucketStart = (sec ~/ 10) * 10;
        final bucketEnd = bucketStart + 10;
        buckets.add('$bucketStart–$bucketEnd s');
      }

      final sorted = buckets.toList()
        ..sort((a, b) {
          final aStart = int.parse(a.split('–')[0]);
          final bStart = int.parse(b.split('–')[0]);
          return aStart.compareTo(bStart);
        });

      return ['All', ...sorted];
    }

    // Default case for other columns
    final values = source.map((row) => row[columnIndex]).toSet().toList();
    values.sort();
    return ['All', ...values];
  }

// Applies all selected filters to the CAN history data.
// Filters include:
// - Group (button name)
// - Channel, CAN ID, DLC, Data, Direction, Contents
// - Time (bucketed into 10-second intervals)
// Supports switching between live feed and fixed feed view.

  void _applyGroupFilter() {
    final source =
        _showLiveFeed ? canHistory : fixedCanHistoryMap.values.toList();

    filteredCanHistory = source.where((row) {
      final groupMatch = selectedGroupFilter == 'All' ||
          row[6].toLowerCase().contains(selectedGroupFilter.toLowerCase());
      final channelMatch =
          selectedChannel == 'All' || row[0] == selectedChannel;
      final canIdMatch = selectedCanId == 'All' || row[1] == selectedCanId;
      final dlcMatch = selectedDlc == 'All' || row[2] == selectedDlc;
      final dataMatch = selectedData == 'All' || row[3] == selectedData;
      final directionMatch =
          selectedDirection == 'All' || row[5] == selectedDirection;
      final contentsMatch =
          selectedContents == 'All' || row[6] == selectedContents;

      //  Time filter with 10 sec bucket logic
      final timeMatch = selectedTime == 'All' ||
          (() {
            final parts = row[4].split(RegExp(r'[:.]'));
            final minutes = int.tryParse(parts[0]) ?? 0;
            final secs = int.tryParse(parts[1]) ?? 0;
            final totalSeconds = minutes * 60 + secs;

            if (selectedTime.contains('–')) {
              final bounds = selectedTime.split('–');
              final lower = int.tryParse(bounds[0]) ?? 0;
              final upper = int.tryParse(bounds[1].split(' ')[0]) ?? 9999;
              return totalSeconds >= lower && totalSeconds < upper;
            }

            return true;
          })();

      return groupMatch &&
          channelMatch &&
          canIdMatch &&
          dlcMatch &&
          dataMatch &&
          timeMatch &&
          directionMatch &&
          contentsMatch;
    }).toList();
  }

// Stores the most recent unique CAN frames (keyed by Data + Contents)
  final Map<String, List<String>> fixedCanHistoryMap = {};

// Timer used for periodically generating live CAN frames
  Timer? _liveCanTimer;

// Timestamp of the first button press (used to calculate elapsed time)
  DateTime? firstButtonPressTime;

// App startup time (used in logs or time calculations)
  late DateTime _appStartTime;

// Flag to enable/disable the live CAN frame feed
  bool _isLiveFeedRunning = true;

// UI filter values — updated via dropdowns or search
  String selectedGroupFilter =
      'All'; // Filter by control group (e.g., "Engine")
  List<String> selectedChannels = ['All']; // Filter by CAN channel (e.g., "0")
  List<String> selectedCanIds = ['All']; // Filter by CAN ID (e.g., "18FECA10")
  List<String> selectedDLCs = ['All']; // Filter by DLC (Data Length Code)
  List<String> selectedDataValues = [
    'All'
  ]; // Filter by full data payload (hex)
  List<String> selectedTimestamps = [
    'All'
  ]; // Filter by time bucket (e.g., "10–20 s")
  List<String> selectedDirections = [
    'All'
  ]; // Filter by message direction ("Transmitted", "Received")
  String selectedContents = 'All';

// Tracks the ON/OFF state of all RCU control buttons
// - Keys represent control names (as shown in UI)
// - Values are booleans: true = pressed/active, false = unpressed/inactive
// - Used to generate CAN data bytes and update button visuals
  final Map<String, bool> states = {
    'Water Pump On': false,
    'Water Pump Off': false,
    'Engine Increase': false,
    'Engine Decrease': false,
    'Water Pressure Increase': false,
    'Water Pressure Decrease': false,
    'Boom Up': false,
    'Boom Down': false,
    'Boom Retract': false,
    'Boom Extend': false,
    'Boom Left': false,
    'Boom Right': false,
    'Vacuum On': false,
    'Vacuum Off': false,
    'Door Unlock': false,
    'Door Lock': false,
    'Dozer out(F4), Tank Raise': false,
    'Dozer in(F4), Tank Lower': false,
    'Door Open': false,
    'Door Close': false,
    'Vibrator': false,
    'Wand Required': false,
    'Wand Off': false,
    'Wand Dropped': false,
    'Wand Fault': false,
  };
  // Grouping the control buttons by logical category.
  // These groups are used to organize the UI layout into cards with labeled icons.
  // Each list contains mutually exclusive or related digital control buttons
  // that the user can toggle, and their states are reflected in the CAN message bits.
  final Map<String, List<String>> groupedControls = {
    'Water Pump': ['Water Pump On', 'Water Pump Off'],
    'Water Pressure': ['Water Pressure Increase', 'Water Pressure Decrease'],
    'Engine': ['Engine Increase', 'Engine Decrease'],
    'Vacuum': ['Vacuum On', 'Vacuum Off'],
    'Boom Movement': ['Boom Up', 'Boom Down', 'Boom Left', 'Boom Right'],
    'Boom Extension': ['Boom Retract', 'Boom Extend'],
    'Door': ['Door Unlock', 'Door Lock', 'Door Open', 'Door Close'],
    'Dozer': ['Dozer out(F4), Tank Raise', 'Dozer in(F4), Tank Lower'],
    'Wand': ['Wand Required', 'Wand Off', 'Wand Dropped', 'Wand Fault'],
    'Vibrator': ['Vibrator'],
  };

  //Set icons for button sections
  final Map<String, IconData> groupIcons = {
    'Water Pump': Icons.water,
    'Water Pressure': Icons.speed,
    'Engine': Icons.engineering,
    'Vacuum': Icons.cleaning_services,
    'Boom Movement': Icons.open_with,
    'Boom Extension': Icons.extension,
    'Door': Icons.door_front_door,
    'Dozer': Icons.agriculture,
    'Wand': Icons.build_circle,
    'Vibrator': Icons.vibration,
  };

  @override
  void initState() {
    super.initState();
    //Record the app start time for log time stamping
    _appStartTime = DateTime.now();
    //Request necessary BT permisisns
    _ensureBluetoothPermissions();
    //Initialize BT manager and begin scanning for devices
    CanBluetooth.instance.init();
    CanBluetooth.instance.startScan();
    //Begin listening for incomming  BT CAN Messages
    _listenToBluetoothMessages();
    //Set ref times for button pressed based frame timings
    firstButtonPressTime = DateTime.now();
    //Start the live feed timer to simulate the outgoing CAN frames
    _startLiveFeed();

    //Apply initial group-based filtering to frame log
    _applyGroupFilter();
    //Refresh UI when a new BT device is connected
    CanBluetooth.instance.addedDevice.addListener(() {
      setState(() {});
    });
  }

//Returns the name of the currently connected bluetooth device and falls back to unnamed device is no name is available.
  String get connectedDeviceName {
    if (CanBluetooth.instance.connectedDevices.isEmpty) {
      return 'Not connected';
    }

    final connectedId = CanBluetooth.instance.connectedDevices.keys.first;
    final device = CanBluetooth.instance.connectedDevices[connectedId];

    final entry = CanBluetooth.instance.scanResults.entries.firstWhere(
      (e) => e.value.device.remoteId.str == connectedId,
      orElse: () => CanBluetooth.instance.scanResults.entries.first,
    );

    final name = entry.value.advertisementData.localName;

    return name.isNotEmpty ? name : '(Unnamed Device)';
  }

//Requests the necessary BT and location permissions based on platform (Android/IOS/MACOS in pref runners)
  Future<void> _ensureBluetoothPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetooth,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.location,
      ].request();
    } else if (Platform.isIOS) {
      await [
        Permission.bluetooth,
        Permission.locationWhenInUse,
      ].request();
    }
  }

//Map of control names to [byte index, bit condition]
  List<int> getByteValues() {
    List<int> bytes = List.filled(9, 0);
    Map<String, List<int>> bitMap = {
      'Water Pump On': [1, 0],
      'Water Pump Off': [1, 1],
      'Engine Increase': [1, 2],
      'Engine Decrease': [1, 3],
      'Water Pressure Increase': [1, 4],
      'Water Pressure Decrease': [1, 5],
      'Boom Up': [2, 0],
      'Boom Down': [2, 1],
      'Boom Retract': [2, 2],
      'Boom Extend': [2, 3],
      'Boom Left': [2, 4],
      'Boom Right': [2, 5],
      'Vacuum On': [3, 0],
      'Vacuum Off': [3, 1],
      'Door Unlock': [3, 3],
      'Door Lock': [3, 4],
      'Dozer out(F4), Tank Raise': [3, 5],
      'Dozer in(F4), Tank Lower': [3, 6],
      'Door Open': [3, 7],
      'Door Close': [4, 0],
      'Vibrator': [4, 1],
      'Wand Required': [8, 0],
      'Wand Off': [8, 1],
      'Wand Dropped': [8, 2],
      'Wand Fault': [8, 3],
    };
//If a control is active set its correspondinf bit in the byte
    for (var entry in bitMap.entries) {
      if (states[entry.key] == true) {
        int byte = entry.value[0];
        int bit = entry.value[1];
        bytes[byte] |= (1 << bit);
      }
    }

    return bytes;
  }

  /// Constructs a CAN frame entry as a list of strings.
  /// This frame is later used for logging or display in the CAN history table.
  List<String> createCanFrame(List<int> bytes, Duration duration) {
    // Collect all currently pressed buttons as a single comma-separated string
    String pressed = states.entries
        .where((entry) => entry.value) // Filter for active (true) buttons
        .map((entry) => entry.key) // Get the button names
        .join(', '); // Join them with commas

    // Format the time since app start or first interaction
    String formattedTime = _formatDuration(duration);

    return [
      '1', // Channel (hardcoded to '1' for now — could be dynamic if needed)
      '18FECA10', // CAN ID (fixed PGN used for transmission)
      '8', // DLC: Data Length Code (always 8 in this app)

      // Format the data bytes from byte[1] to byte[8] (skip byte[0], the control map header)
      bytes
          .getRange(1, 9)
          .map((b) => b
              .toRadixString(16)
              .padLeft(2, '0')
              .toUpperCase()) // Convert each byte to 2-digit hex
          .join(' '), // Combine into space-separated string

      formattedTime, // Time of frame creation, formatted as mm:ss.mmm
      'Transmitted', // Direction of the frame
      pressed.isEmpty
          ? 'No buttons pressed'
          : pressed, // Summary of active controls
    ];
  }

// Starts a timer that simulates transmitting a CAN frame every second
// Only runs if the live feed is active and not paused
  void _startLiveFeed() {
    _liveCanTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Skip if feed is paused or disabled
      if (!_isLiveFeedRunning || _isPaused) return;

      // Calculate time elapsed since first button press
      final now = DateTime.now();
      final elapsed = now.difference(firstButtonPressTime!);

      // Convert current control states into CAN frame bytes
      final bytes = getByteValues();

      // Generate a formatted frame for display
      final frame = createCanFrame(bytes, elapsed);

      // Unique key = data + pressed buttons
      final key =
          '${frame[3]}|${frame[6]}'; // Uniquely identifies frame by Data | Contents

      setState(() {
        // Update or insert frame in deduplicated map
        fixedCanHistoryMap[key] = frame;

        // Always append frame to full history
        canHistory.add(frame);

        // Re-apply current filters to refresh the view
        _applyGroupFilter();
      });
    });
  }

  void _listenToBluetoothMessages() {
    CanBluetooth.instance.messageStream.listen((msg) {
      final bytes = msg.data;

      if (bytes.length < 13) {
        print(' Incomplete frame: ${bytes.length} bytes');
        return;
      }
//Extracts 4- byte CAN ID (Big Endian)

      final canId = msg.identifier;
      //ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, 4)))
      //  .getUint32(0, Endian.big);

      // final canIdHex = canIdInt.toRadixString(16).padLeft(8, '0').toUpperCase();
      //  final canIdDisplay = '$canIdHex ($canIdInt)';

      //  final canId =
      //   ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, 4)))
      //     .getUint32(0, Endian.little); // matches CANKing decimal IDs
//converts the integer to a hexadecimal string (base 16).nsures the hex string is exactly 8 characters long, padding with 0s on the left if necessary.

      final canIdHex = canId.toRadixString(16).padLeft(8, '0').toUpperCase();
      final canIdDisplay =
          '$canIdHex'; // this was removed-- ($canId)'; // Hex + decimal in one

      final dlc = 8;

      //Extract D0-D7 bytes
      final dataList = bytes
          .sublist(5, 13)
          .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
          .toList();

      final dataHexString = dataList.join(' ');

      final formattedTime = _formatDuration(
          DateTime.now().difference(firstButtonPressTime ?? DateTime.now()));

      // Updated variable here
      print('CAN ID: $canIdHex  DLC: $dlc  DATA (hex): $dataHexString');

      /** FINAL CRC INFO REMOVED - NOT ACCURATE 
      * 
      final crcBytes = bytes.sublist(bytes.length - 4);
      final crcDisplay = crcBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
*/
      final frame = [
        '0', // Channel
        canIdDisplay, // CAN ID: HEX
        dlc.toString(), // DLC
        dataHexString, // Data
        formattedTime, // Time
        'Received', // Direction
        'From Bluetooth',
        // crcDisplay // CRC column
      ];

      setState(() {
        // Add the new CAN frame to the live history list (includes duplicates)
        canHistory.add(frame);

        // Add/update the frame in the fixed history map using a unique key:
        // Key is combination of Data + Contents to avoid duplicate entries
        fixedCanHistoryMap['${frame[3]}|${frame[6]}'] = frame;

        // Re-apply filters so the UI updates according to current filter selections
        _applyGroupFilter();
      });
    });
  }

  /// Formats a Duration into a string like "MM:SS.mmm"
  /// Used for timestamping CAN log entries relative to app or button start time
  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final millis = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$minutes:$seconds.$millis';
  }

  /// Builds the grouped control buttons UI for all digital controls.
  /// Buttons are arranged into two vertical columns of group cards for visual balance.
  Widget controlButtons() {
    // Define which groups appear in the left column
    final leftColumnGroups = [
      'Water Pump',
      'Engine',
      'Boom Movement',
      'Door',
      'Wand'
    ];

    // Define which groups appear in the right column
    final rightColumnGroups = [
      'Water Pressure',
      'Vacuum',
      'Boom Extension',
      'Dozer',
      'Vibrator'
    ];

    // Builds a card widget for each control group (e.g., Water Pump, Boom Movement)
    // Displays the group icon, title, and its associated toggle buttons.
    Widget buildGroup(String groupKey) {
      // Retrieve the list of controls for this group
      final controls = groupedControls[groupKey] ?? [];

      return Card(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.center, // Center all contents
            children: [
              // Group header row with icon and title
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(groupIcons[groupKey], color: Colors.tealAccent),
                  const SizedBox(width: 10),
                  Text(
                    groupKey,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.tealAccent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Group control buttons (toggle buttons)
              Center(
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: controls.map((control) {
                    final isActive = states[control] ?? false;

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          // Toggle the tapped button's state
                          states[control] = !isActive;

                          // Define mutual exclusivity rules between controls
                          final exclusivityRules = {
                            'Water Pump On': ['Water Pump Off'],
                            'Water Pump Off': ['Water Pump On'],
                            'Water Pressure Increase': [
                              'Water Pressure Decrease'
                            ],
                            'Water Pressure Decrease': [
                              'Water Pressure Increase'
                            ],
                            'Engine Increase': ['Engine Decrease'],
                            'Engine Decrease': ['Engine Increase'],
                            'Vacuum On': ['Vacuum Off'],
                            'Vacuum Off': ['Vacuum On'],
                            'Boom Up': ['Boom Down'],
                            'Boom Down': ['Boom Up'],
                            'Boom Left': ['Boom Right'],
                            'Boom Right': ['Boom Left'],
                            'Door Unlock': ['Door Lock'],
                            'Door Lock': ['Door Unlock'],
                            'Door Open': ['Door Close'],
                            'Door Close': ['Door Open'],
                            'Boom Retract': ['Boom Extend'],
                            'Boom Extend': ['Boom Retract'],
                            'Dozer out(F4), Tank Raise': [
                              'Dozer in(F4), Tank Lower'
                            ],
                            'Dozer in(F4), Tank Lower': [
                              'Dozer out(F4), Tank Raise'
                            ],
                          };

                          // Disable conflicting control(s) if the current one is turned on
                          if (states[control] == true &&
                              exclusivityRules.containsKey(control)) {
                            for (var other in exclusivityRules[control]!) {
                              states[other] = false;
                            }
                          }

                          // Update the CAN frame log with the new control states
                          final bytes = getByteValues();
                          final frame = createCanFrame(
                            bytes,
                            DateTime.now().difference(firstButtonPressTime!),
                          );
                          final key = '${frame[3]}|${frame[6]}';
                          fixedCanHistoryMap[key] = frame;
                          canHistory.add(frame);
                          _applyGroupFilter();
                        });
                      },

                      // UI styling with animation for toggle feedback
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isActive
                              ? Colors.tealAccent.withOpacity(0.2)
                              : Colors.grey[800],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isActive ? Colors.tealAccent : Colors.grey,
                          ),
                        ),
                        child: Text(
                          control,
                          style: TextStyle(
                            color: isActive ? Colors.tealAccent : Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      );
    }

    //Return left and right column layout for all groups
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            children: leftColumnGroups.map(buildGroup).toList(),
          ),
        ),
        Expanded(
          child: Column(
            children: rightColumnGroups.map(buildGroup).toList(),
          ),
        ),
      ],
    );
  }

  /// Builds a dropdown menu for filtering CAN log entries by control group.
  /// Populated using the keys from `groupedControls`, with an 'All' option at the top.
  Widget groupFilterDropdown() {
    // Create list of options: 'All' + each control group name
    final options = ['All', ...groupedControls.keys];

    return DropdownButton<String>(
      value: selectedGroupFilter, // Currently selected group
      onChanged: (value) => setState(() {
        selectedGroupFilter = value!; // Update selection
        _applyGroupFilter(); // Re-apply filtering to CAN logs
      }),
      items: options.map((group) {
        return DropdownMenuItem(
          value: group,
          child: Text(group), // Displayed label
        );
      }).toList(),
    );
  }

// Builds the CAN Frame Log Table UI
// - Fixed-height container with styled border
// - Header row with dropdown filters per column
// - Scrollable list of filtered CAN frames below
  Widget canLogTable() {
    final filteredRows = filteredCanHistory;

    return Container(
      height: 300,
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        // Header Row: Filter dropdowns for each column
        border: Border.all(color: Colors.tealAccent),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Sticky Header with Dropdowns
          Container(
            color: Colors.teal.shade800,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                // Each dropdown calls setState and reapplies filters on change
                buildHeaderDropdown(
                    'Channel', selectedChannel, getUniqueOptions(0), (val) {
                  setState(() => selectedChannel = val!);
                  _applyGroupFilter();
                }, flex: 1),
                buildHeaderDropdown(
                    'CAN ID', selectedCanId, getUniqueOptions(1), (val) {
                  setState(() => selectedCanId = val!);
                  _applyGroupFilter();
                }, flex: 1),
                buildHeaderDropdown('DLC', selectedDlc, getUniqueOptions(2),
                    (val) {
                  setState(() => selectedDlc = val!);
                  _applyGroupFilter();
                }, flex: 1),
                buildHeaderDropdown('Data', selectedData, getUniqueOptions(3),
                    (val) {
                  setState(() => selectedData = val!);
                  _applyGroupFilter();
                }, flex: 2),
                buildHeaderDropdown('Time', selectedTime, getUniqueOptions(4),
                    (val) {
                  setState(() => selectedTime = val!);
                  _applyGroupFilter();
                }, flex: 1),
                buildHeaderDropdown(
                    'Direction', selectedDirection, getUniqueOptions(5), (val) {
                  setState(() => selectedDirection = val!);
                  _applyGroupFilter();
                }, flex: 1),
                buildHeaderDropdown(
                    'Contents', selectedContents, getUniqueOptions(6), (val) {
                  setState(() => selectedContents = val!);
                  _applyGroupFilter();
                }, flex: 2),
                // buildHeaderDropdown('CRC', 'All', ['All'], (_) {}, flex: 1), <-- Removed CRC column
              ],
            ),
          ),

          // Scrollable List of Filtered Rows

          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: filteredRows.length,
              itemBuilder: (_, index) {
                final row = filteredRows[index];
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.white12)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                          flex: 1,
                          child: Text(row[0],
                              style: const TextStyle(fontSize: 12))), // Channel
                      Expanded(
                          flex: 1,
                          child: Text(row[1],
                              style: const TextStyle(fontSize: 12))), // CAN ID

                      Expanded(
                          flex: 1,
                          child: Text(row[2],
                              style: const TextStyle(fontSize: 12))), // DLC
                      Expanded(
                        flex: 2,
                        child:
                            Text(row[3], style: const TextStyle(fontSize: 12)),
                      ),

                      // Data
                      Expanded(
                          flex: 1,
                          child: Text(row[4],
                              style: const TextStyle(fontSize: 12))), // Time
                      Expanded(
                        flex: 1,
                        child: Text(
                          row[5],
                          style: TextStyle(
                            fontSize: 12,
                            color: row[5] == 'Received'
                                ? Colors.greenAccent
                                : row[5] == 'Transmitted'
                                    ? Colors.cyanAccent
                                    : Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ), // Direction
                      Expanded(
                          flex: 2,
                          child: Text(row[6],
                              style: const TextStyle(fontSize: 12))),

                      // Contents

                      /*
                      Expanded(
                          flex: 1,
                          child: Text(row.length > 7 ? row[7] : '',
                              style: const TextStyle(fontSize: 12))), // CRC
                              **/ //<--Removed CRC coulumns
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // Builds a styled dropdown menu used in the CAN log table header
// - Displays column name as a label (e.g., "CAN ID")
// - Provides selectable filter options for that column
// - Triggers a callback on selection change
// - Supports dynamic width via `flex`
  Widget buildHeaderDropdown(
      String label, // Column label (e.g., "Data", "Time")
      String selectedValue, // Currently selected value
      List<String> options, // List of values to choose from
      ValueChanged<String?> onChanged, // Callback when user selects an option
      {required int flex} // Width ratio for layout
      ) {
    return Expanded(
      flex: flex,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.teal.shade700,
          border: Border(
            right: BorderSide(color: Colors.grey.shade800),
          ),
        ),

        // Hides default underline for a cleaner UI
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            value: selectedValue, // Current selection
            icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
            dropdownColor: Colors.grey[900], // Dark-themed dropdown
            borderRadius: BorderRadius.circular(8),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.white,
              fontSize: 13,
            ),
            onChanged: onChanged, // Triggered when user selects an option

            // Dropdown items
            items: options.map((val) {
              return DropdownMenuItem(
                value: val,
                child: Text(
                  val,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),

            // Custom builder to always show label like "CAN ID ▼"
            selectedItemBuilder: (context) {
              return options.map((_) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '$label ▼',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 13,
                    ),
                  ),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }

  // Builds a row of Bluetooth scan control buttons:
// - "Scan" starts scanning for nearby BLE devices
// - "Stop" halts the ongoing scan
  Widget scanControl() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Start scanning for Bluetooth devices
        ElevatedButton.icon(
          onPressed: () =>
              CanBluetooth.instance.startScan(), // Start device scan
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text("Scan"),
        ),

        const SizedBox(width: 10),

        // Stop the ongoing Bluetooth scan
        ElevatedButton.icon(
          onPressed: () => CanBluetooth.instance.stopScan(), // Stop device scan
          icon: const Icon(Icons.stop),
          label: const Text("Stop"),
        ),
      ],
    );
  }

  Widget bluetoothDeviceList() {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.tealAccent),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ValueListenableBuilder(
        valueListenable: CanBluetooth.instance.addedDevice,
        builder: (_, __, ___) {
          final entries =
              CanBluetooth.instance.scanResults.entries.where((entry) {
            final name = entry.value.advertisementData.localName.toLowerCase();
            return name.contains(_deviceNameFilter);
          }).toList();
          //Render each device
          return ListView(
            children: entries.map((entry) {
              final device = entry.value.device;
              final name = entry.value.advertisementData.localName;

              final isConnected = CanBluetooth.instance.connectedDevices
                  .containsKey(device.remoteId.str);

              return ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(name.isNotEmpty ? name : '(Unnamed)'),
                subtitle: Text(device.remoteId.str),
                trailing: ElevatedButton(
                  onPressed: () {
                    if (isConnected) {
                      CanBluetooth.instance.disconnect(device);
                    } else {
                      CanBluetooth.instance.connect(device);
                    }
                  },
                  child: Text(isConnected ? 'Disconnect' : 'Connect'),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AARCOMM Virtualalized RCU'),
          centerTitle: true,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              buildNearHeader(),
              const SizedBox(height: 10),
              scanControl(),
              const SizedBox(height: 12),
              //Device stat. display
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Tooltip(
                    message: 'Connected to: $connectedDeviceName',
                    preferBelow: false,
                    waitDuration: const Duration(milliseconds: 300),
                    child: Icon(
                      Icons.bluetooth_connected,
                      size: 28,
                      color: connectedDeviceName == 'Not connected'
                          ? Colors.grey
                          : Colors.tealAccent,
                    ),
                  ),
                  //Text feild to filter scanned devices by name
                  const SizedBox(width: 8),
                  Text(
                    connectedDeviceName == 'Not connected'
                        ? 'No device connected'
                        : 'Connected to: $connectedDeviceName',
                    style: TextStyle(
                      color: connectedDeviceName == 'Not connected'
                          ? Colors.grey
                          : Colors.tealAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _deviceFilterController,
                decoration: InputDecoration(
                  hintText: 'Filter by device name...',
                  prefixIcon: Icon(Icons.filter_list),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Colors.tealAccent),
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    _deviceNameFilter = value.trim().toLowerCase();
                  });
                },
              ),
              const SizedBox(height: 12),
              bluetoothDeviceList(),
              const SizedBox(height: 16),
              const SizedBox(height: 16),
              buildControlHeader(),
              controlButtons(),
              const SizedBox(height: 16),
              //Action buttons: Clear, Send, Pause etc...
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[850],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.tealAccent.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        //  Clear Selected Buttons
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange[700],
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              for (var key in states.keys) {
                                states[key] = false;
                              }
                              final bytes = getByteValues();
                              final frame = createCanFrame(
                                bytes,
                                DateTime.now()
                                    .difference(firstButtonPressTime!),
                              );
                              final key = '${frame[3]}|${frame[6]}';
                              fixedCanHistoryMap[key] = frame;
                              canHistory.add(frame);
                              _applyGroupFilter();
                            });
                          },
                          icon: const Icon(Icons.clear_all),
                          label: const Text('Clear Selected Buttons'),
                        ),

                        // SEND TO CANKING BUTTON
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.lightBlue,
                            foregroundColor: Colors.white,
                          ),
                          /**
                           * onPressed: () async {
                            final connected =
                                CanBluetooth.instance.connectedDevices;
                            if (connected.isEmpty) {
                              debugPrint(' No Bluetooth device connected');
                              return;
                            }

                            final deviceId = connected.keys.first;
                            final writable = CanBluetooth
                                .instance.writableCharacteristics[deviceId];

                            if (writable == null || writable.isEmpty) {
                              debugPrint(' No writable characteristic found');
                              return;
                            }

                            final charUuid = writable.keys.first;
                            debugPrint('Writable UUIDs: ${writable.keys}');

                            // final canId = [
                            //   0x03,
                            //   0xFF,
                            //   0x01,
                            //   0x80
                            // ]; //  CAN ID: 03FF0180
                            // final flag = [0x00];
                            
                            final canId = [0x18, 0xFE, 0xCA, 0x10]; // 18FECA10
                            final dataBytes =
                                getByteValues().getRange(1, 9).toList();
                            final dlc = dataBytes.length;
                            final frameToSend = [
                              ...canId,
                              dlc,
                              ...dataBytes
                            ];

                            await CanBluetooth.instance
                                .writeToDevice(deviceId, charUuid, frameToSend);
                            debugPrint('Sent CAN frame to $charUuid on $deviceId');
                            debugPrint(
                                ' Sent CAN frame: ${frameToSend.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
                          },
                           */

                          // Sends the current control state as an ASCII-formatted CAN command over Bluetooth
                          // Steps:
                          // 1. Validate that a Bluetooth device is connected
                          // 2. Locate the writable characteristic
                          // 3. Convert button state to data bytes (D1–D8)
                          // 4. Format the CAN frame as a string: TX:<CAN_ID>,<DLC>,<D0>,...,<D7>
                          // 5. Encode the string to ASCII bytes and write to the device

                          onPressed: () async {
                            final connected =
                                CanBluetooth.instance.connectedDevices;
                            if (connected.isEmpty) {
                              debugPrint(' No Bluetooth device connected');
                              return;
                            }

                            final deviceId = connected.keys.first;
                            final writable = CanBluetooth
                                .instance.writableCharacteristics[deviceId];
                            if (writable == null || writable.isEmpty) {
                              debugPrint(' No writable characteristic found');
                              return;
                            }

                            final charUuid = writable.keys.first;
                            final characteristic = writable[charUuid];
                            if (characteristic == null) {
                              debugPrint(
                                  ' Writable characteristic object is null');
                              return;
                            }

                            final canId = [0x18, 0xFE, 0xCA, 0x10]; // 4 bytes
                            final flags = [0x00]; // 1 byte: reserved/flags
                            final dataBytes = getByteValues()
                                .getRange(1, 9)
                                .toList(); // D0–D7
                            final dlc = [
                              dataBytes.length
                            ]; // 1 byte: data length (usually 8)

                            final rawFrame = [
                              ...canId,
                              ...flags,
                              ...dlc,
                              ...dataBytes
                            ];

                            final fullFrame =
                                CanBluetooth.instance.appendCrc32(rawFrame);
                            await characteristic.write(fullFrame,
                                withoutResponse: true);

                            debugPrint(
                                ' Sent to CANKing: ${fullFrame.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
                          },

                          icon: const Icon(Icons.send),
                          label: const Text('Send to CANKing'),
                        ),

                        //  Pause/Resume
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isPaused ? Colors.green : Colors.amber[700],
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              _isPaused = !_isPaused;
                            });
                          },
                          icon:
                              Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                          label: Text(_isPaused
                              ? 'Resume Live Feed'
                              : 'Pause Live Feed'),
                        ),

                        //  Show Live/Fixed Feed
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.indigoAccent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              _showLiveFeed = !_showLiveFeed;
                              _applyGroupFilter();
                            });
                          },
                          icon: const Icon(Icons.swap_horiz),
                          label: Text(_showLiveFeed
                              ? 'Show Fixed Feed'
                              : 'Show Live Feed'),
                        ),

                        //  Clear History
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepOrange,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              canHistory.clear();
                              fixedCanHistoryMap.clear();
                              filteredCanHistory.clear();
                            });
                          },
                          icon: const Icon(Icons.delete_forever),
                          label: const Text('Clear History'),
                        ),

                        // Reset Timer
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              firstButtonPressTime = DateTime.now();
                            });
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Reset Timer'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              buildCanLogHeader(),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Type group name (e.g., Water Pump)',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Colors.tealAccent),
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    selectedGroupFilter = value;
                    _applyGroupFilter();
                  });
                },
              ),
              const SizedBox(height: 16),
              const SizedBox(height: 16),
              canLogTable(),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _liveCanTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // Builds a styled header row for the Bluetooth device section
// - Displays a Bluetooth icon, title text, and Wi-Fi icon
// - Used to visually indicate the scanning section of the app
  Widget buildNearHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Bluetooth icon (left)
          const Icon(Icons.bluetooth, color: Colors.tealAccent),

          const SizedBox(width: 8),

          // Header title
          const Text(
            'Available Bluetooth Devices',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.tealAccent,
              shadows: [
                Shadow(
                  blurRadius: 3,
                  color: Colors.black45,
                  offset: Offset(1, 1),
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Wi-Fi icon (right)
          const Icon(Icons.wifi, color: Colors.tealAccent),
        ],
      ),
    );
  }

// Builds a stylized header row for the CAN frame log section
// - Displays a car icon, a bold title, and a receipt icon
// - Used to visually label the CAN log display area

  Widget buildCanLogHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Left icon
          const Icon(Icons.directions_car, color: Colors.tealAccent),

          const SizedBox(width: 8),

          // Section title
          Text(
            'CAN Frame Logs',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.tealAccent,
              shadows: [
                Shadow(
                  blurRadius: 3,
                  color: Colors.black45,
                  offset: Offset(1, 1),
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Right icon
          const Icon(Icons.receipt_long, color: Colors.tealAccent),
        ],
      ),
    );
  }

// Builds a stylized header row for the digital control button section
// - Shows a remote icon, title, and radio button icon
// - Clearly marks the section containing all virtual RCU buttons

  Widget buildControlHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.settings_remote, color: Colors.tealAccent),
          const SizedBox(width: 8),
          const Text(
            'AARCOM RCU Digital Control Buttons',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.tealAccent,
              shadows: [
                Shadow(
                  blurRadius: 3,
                  color: Colors.black45,
                  offset: Offset(1, 1),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.radio_button_checked, color: Colors.tealAccent),
        ],
      ),
    );
  }
}
