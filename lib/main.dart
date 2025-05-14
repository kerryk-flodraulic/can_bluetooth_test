import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'bluetooth.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
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

  void _applyGroupFilter() {
    final source =
        _showLiveFeed ? canHistory : fixedCanHistoryMap.values.toList();

    filteredCanHistory =
        selectedGroupFilter.isEmpty || selectedGroupFilter == 'All'
            ? List.from(source)
            : source
                .where((row) => row[6]
                    .toLowerCase()
                    .contains(selectedGroupFilter.toLowerCase()))
                .toList();
  }

  final Map<String, List<String>> fixedCanHistoryMap = {};
  Timer? _liveCanTimer;
  DateTime? firstButtonPressTime;
  late DateTime _appStartTime;
  bool _isLiveFeedRunning = true;
  String selectedGroupFilter = 'All';
  List<String> selectedChannels = ['All'];
  List<String> selectedCanIds = ['All'];
  List<String> selectedDLCs = ['All'];
  List<String> selectedDataValues = ['All'];
  List<String> selectedTimestamps = ['All'];
  List<String> selectedDirections = ['All'];

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
    _appStartTime = DateTime.now();
    _ensureBluetoothPermissions();
    CanBluetooth.instance.init();
    CanBluetooth.instance.scan();
    _listenToBluetoothMessages();
    firstButtonPressTime = DateTime.now();
    _startLiveFeed();
    _applyGroupFilter();
  }

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

    for (var entry in bitMap.entries) {
      if (states[entry.key] == true) {
        int byte = entry.value[0];
        int bit = entry.value[1];
        bytes[byte] |= (1 << bit);
      }
    }

    return bytes;
  }

  List<String> createCanFrame(List<int> bytes, Duration duration) {
    String pressed = states.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .join(', ');
    String formattedTime = _formatDuration(duration);

    return [
      '1',
      '03FF0180',
      '8',
      bytes
          .getRange(1, 9)
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' '),
      formattedTime,
      'Transmitted',
      pressed.isEmpty ? 'No buttons pressed' : pressed,
    ];
  }

  void _startLiveFeed() {
    _liveCanTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isLiveFeedRunning || _isPaused) return;

      final now = DateTime.now();
      final elapsed = now.difference(firstButtonPressTime!);
      final bytes = getByteValues();
      final frame = createCanFrame(bytes, elapsed);
      final key = '${frame[3]}|${frame[6]}';

      setState(() {
        fixedCanHistoryMap[key] = frame;
        canHistory.add(frame);
        _applyGroupFilter();
      });

      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    });
  }

  void _listenToBluetoothMessages() {
    CanBluetooth.instance.messageStream.listen((msg) {
      final now = DateTime.now();
      final formattedTime =
          _formatDuration(now.difference(firstButtonPressTime!));

      final frame = [
        'Bluetooth',
        '03FF1410',
        msg.data.length.toString(),
        msg.data
            .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(' '),
        formattedTime,
        'Received',
        'From Bluetooth',
      ];

      setState(() {
        canHistory.add(frame);
        fixedCanHistoryMap['${frame[3]}|${frame[6]}'] = frame;
        _applyGroupFilter();
      });
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final millis = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$minutes:$seconds.$millis';
  }

  Widget controlButtons() {
    // Order matters here:
    final leftColumnGroups = [
      'Water Pump',
      'Engine',
      'Boom Movement',
      'Door',
      'Wand'
    ];
    final rightColumnGroups = [
      'Water Pressure',
      'Vacuum',
      'Boom Extension',
      'Dozer',
      'Vibrator'
    ];
    Widget buildGroup(String groupKey) {
      final controls = groupedControls[groupKey] ?? [];
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.center, // <-- Center contents
            children: [
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.center, // <-- Center title row
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
              Center(
                child: Wrap(
                  alignment: WrapAlignment.center, // <-- Center buttons
                  spacing: 10,
                  runSpacing: 10,
                  children: controls.map((control) {
                    final isActive = states[control] ?? false;
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          // Toggle the tapped control
                          states[control] = !isActive;

                          // Define mutual exclusivity rules
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
                            'Dozer out(F4), Tank Raise': ['Dozer in(F4), Tank Lower'],
                            'Dozer in(F4), Tank Lower' : ['Dozer out(F4), Tank Raise'],
                          };

                          // If this control has any conflicting pairs, turn them off
                          if (states[control] == true &&
                              exclusivityRules.containsKey(control)) {
                            for (var other in exclusivityRules[control]!) {
                              states[other] = false;
                            }
                          }

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
                              color:
                                  isActive ? Colors.tealAccent : Colors.grey),
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

  Widget groupFilterDropdown() {
    final options = ['All', ...groupedControls.keys];
    return DropdownButton<String>(
      value: selectedGroupFilter,
      onChanged: (value) => setState(() => selectedGroupFilter = value!),
      items: options.map((group) {
        return DropdownMenuItem(value: group, child: Text(group));
      }).toList(),
    );
  }

  Widget canLogTable() {
    final filteredRows = filteredCanHistory;

    return Container(
      height: 250,
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.tealAccent),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Container(
            color: Colors.teal.shade800,
            padding: const EdgeInsets.all(8),
            child: Row(children: const [
              Expanded(
                  child: Text('Channel',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              Expanded(
                  child: Text('CAN ID',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              Expanded(
                  child: Text('DLC',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              Expanded(
                  flex: 2,
                  child: Text('Data',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              Expanded(
                  child: Text('Time',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              Expanded(
                  child: Text('Direction',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              Expanded(
                  child: Text('Contents',
                      style: TextStyle(fontWeight: FontWeight.bold))),
            ]),
          ),
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
                    children: row
                        .map((cell) => Expanded(
                            child: Text(cell,
                                style: const TextStyle(fontSize: 12))))
                        .toList(),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget scanControl() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ElevatedButton.icon(
          onPressed: () => CanBluetooth.instance.scan(),
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text("Scan"),
        ),
        const SizedBox(width: 10),
        ElevatedButton.icon(
          onPressed: () => CanBluetooth.instance.stopScan(),
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
        builder: (_, __, ___) => ListView(
          children: CanBluetooth.instance.devices.entries.map((entry) {
            final device = entry.value.device;
            final name = entry.value.advertisementData.localName;

            final isConnected = CanBluetooth.instance.connectedDevices
                .contains(device.remoteId.str);

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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AARCOMM Virtual Remote'),
          centerTitle: true,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              scanControl(),
              const SizedBox(height: 16),
              const Text("Nearby Devices",
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
              ),
              const SizedBox(height: 16),
              bluetoothDeviceList(),
              const SizedBox(height: 16),
              const SizedBox(height: 16),
              const Text("Search Logs By Group",
                  style: TextStyle(fontSize: 16)),
              const Text("Control Buttons",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              controlButtons(),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _isPaused = !_isPaused;
                      });
                    },
                    child: Text(
                        _isPaused ? 'Resume Live Feed' : 'Pause Live Feed'),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _showLiveFeed = !_showLiveFeed;
                        _applyGroupFilter();
                      });
                    },
                    child: Text(
                        _showLiveFeed ? 'Show Fixed Feed' : 'Show Live Feed'),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent),
                    onPressed: () {
                      setState(() {
                        canHistory.clear();
                        fixedCanHistoryMap.clear();
                        filteredCanHistory.clear();
                      });
                    },
                    child: const Text('Clear History'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
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
              const Text("CAN Frame Logs",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
}
