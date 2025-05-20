/**
 * OLD FILEimport 'dart:async';
import 'crc32.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// CanBluetooth Singleton
// Manages all Bluetooth communication and CAN message handling.
// Responsibilities:
// - Scanning for BT devices
// - Connecting and disconnecting from devices
// - Discovering GATT services and characteristics
// - Subscribing to notifications
// - Sending/receiving CAN frames
class CanBluetooth {
  // Private constructor for singleton
  CanBluetooth._();

  // Global singleton instance
  static final CanBluetooth instance = CanBluetooth._();

  // BT scan results
  final Map<String, ScanResult> scanResults = {};

  // Connected devices by ID
  final Map<String, BluetoothDevice> connectedDevices = {};

  // Services per device
  final Map<String, Map<String, BluetoothService>> deviceServices = {};

  // Characteristics per service per device
  final Map<String, Map<String, Map<String, BluetoothCharacteristic>>>
      deviceCharacteristics = {};

  // Writable characteristics per device
  final Map<String, Map<String, BluetoothCharacteristic>>
      writableCharacteristics = {};

  // Notify subscriptions per device/characteristic
  final Map<String, Map<String, StreamSubscription<List<int>>>> notifyStreams =
      {};

  // Cached CAN messages per device and CAN ID
  final Map<String, Map<int, BlueMessage>> deviceData = {};

  // Notifiers to trigger UI updates
  final ValueNotifier<DateTime> addedDevice = ValueNotifier(DateTime.now());
  final ValueNotifier<DateTime> connectedDevice = ValueNotifier(DateTime.now());
  final ValueNotifier<DateTime> update = ValueNotifier(DateTime.now());
  final ValueNotifier<DateTime> messageUpdate = ValueNotifier(DateTime.now());
  final ValueNotifier<BluetoothAdapterState> adapterState =
      ValueNotifier(FlutterBluePlus.adapterStateNow);

  // Stream for broadcasting received CAN messages
  final StreamController<BlueMessage> _messageStreamController =
      StreamController<BlueMessage>.broadcast();

  // Public stream consumers listen to
  Stream<BlueMessage> get messageStream => _messageStreamController.stream;

  // BT scanning and adapter state subscriptions
  late StreamSubscription<List<ScanResult>> scanStream;
  late StreamSubscription<BluetoothAdapterState> adapterStateStream;

  // Initializes BT listeners and clears cached state
  void init({LogLevel logLevel = LogLevel.info}) {
    scanStream = FlutterBluePlus.onScanResults.listen(_handleScanResults);

    adapterStateStream = FlutterBluePlus.adapterState.listen((state) {
      adapterState.value = state;
      debugPrint('Bluetooth Adapter State: $state');
    });

    FlutterBluePlus.setLogLevel(logLevel);

    scanResults.clear();
    connectedDevices.clear();
    deviceServices.clear();
    deviceCharacteristics.clear();
    notifyStreams.clear();
    writableCharacteristics.clear();
  }

  // Starts BT scan for nearby devices
  void startScan() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    update.value = DateTime.now();
  }

  // Stops BT scan
  void stopScan() {
    FlutterBluePlus.stopScan();
    update.value = DateTime.now();
  }

  // Handles new scan results and updates internal list
  void _handleScanResults(List<ScanResult> results) {
    for (var result in results) {
      scanResults[result.device.remoteId.str] = result;
    }
    addedDevice.value = DateTime.now(); // Notify UI
  }

  // Connects to a BT device and discovers its services
  Future<void> connect(BluetoothDevice device) async {
    try {
      await device.connect();
      connectedDevices[device.remoteId.str] = device;
      connectedDevice.value = DateTime.now();

      final services = await device.discoverServices();
      _mapServices(device, services);
    } catch (e) {
      debugPrint("Connection error: $e");
    }
  }

  // Disconnects from a BT device and cancels subscriptions
  void disconnect(BluetoothDevice device) {
    device.disconnect();
    connectedDevices.remove(device.remoteId.str);
    _cancelNotifyStreams(device.remoteId.str);
    connectedDevice.value = DateTime.now();
  }

  // Maps all services and characteristics and stores writable + notify ones
  void _mapServices(BluetoothDevice device, List<BluetoothService> services) {
    final deviceId = device.remoteId.str;

    for (var service in services) {
      deviceServices.putIfAbsent(deviceId, () => {})[service.uuid.str] =
          service;

      for (var characteristic in service.characteristics) {
        deviceCharacteristics.putIfAbsent(deviceId, () => {}).putIfAbsent(
                service.uuid.str, () => {})[characteristic.uuid.str] =
            characteristic;

        if (characteristic.properties.notify) {
          _subscribeToNotify(deviceId, characteristic);
        }

        if (characteristic.properties.write ||
            characteristic.properties.writeWithoutResponse) {
          writableCharacteristics.putIfAbsent(
              deviceId, () => {})[characteristic.uuid.str] = characteristic;
        }
      }
    }
  }

  // Subscribes to notifications for a characteristic
  void _subscribeToNotify(
      String deviceId, BluetoothCharacteristic characteristic) async {
    try {
      await characteristic.setNotifyValue(true);
      final stream = characteristic.lastValueStream.listen((value) {
      _handleCANMessage(deviceId, value);
        print(characteristic.characteristicUuid);
        print(value.map((e) => e.toRadixString(16)).join(" "));
      });

      notifyStreams.putIfAbsent(deviceId, () => {})[characteristic.uuid.str] =
          stream;
    } catch (e) {
      debugPrint("Notify error: $e");
    }
  }

  // Cancels all notify subscriptions for a device
  void _cancelNotifyStreams(String deviceId) {
    if (notifyStreams.containsKey(deviceId)) {
      for (var sub in notifyStreams[deviceId]!.values) {
        sub.cancel();
      }
      notifyStreams.remove(deviceId);
    }
  }

  // Parses an incoming CAN message and adds it to deviceData
  void _handleCANMessage(String deviceId, List<int> msg) {
    if (msg.length < 13) return;

    // Extract CAN ID from first 4 bytes
    final identifier =
        Uint8List.fromList(msg.sublist(0, 4)).buffer.asUint32List().first;

    // Flag logic can be added here if needed from msg[4]
    final blueMsg = BlueMessage(
      identifier: identifier,
      data: msg,
      flagged: false,
    );

    deviceData.putIfAbsent(deviceId, () => {})[identifier] = blueMsg;
    messageUpdate.value = DateTime.now();
    _messageStreamController.add(blueMsg); // Broadcast to UI
  }

//Update write to device to use the calculate checksum and then call it in the subscribe notify check this == this flutter: 2b68c570-8e48-11e7-bb31-be2e44b06b34
// flutter: 31 f 10 7 a0 10 8 0 0 0 0 0 0 0 0 c5 1b 8f 59, then make sure to change the way the can log is displaying output -
  // Sends data to a writable characteristic (ASCII or binary)
  Future<void> writeToDevice(
      String deviceId, String charUuid, List<int> data) async {
    try {
      final characteristic = writableCharacteristics[deviceId]?[charUuid];
      if (characteristic == null) {
        debugPrint("Characteristic not found for $deviceId / $charUuid");
        return;
      }
      if (!characteristic.properties.write &&
          !characteristic.properties.writeWithoutResponse) {
        debugPrint("Characteristic $charUuid is not writable");
        return;
      }

      final fullData = appendCrc32(data); // Add the checksum

      await characteristic.write(fullData, withoutResponse: true);
      debugPrint(
          "Sent ${fullData.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')} to $charUuid");
    } catch (e) {
      debugPrint(" Write failed: $e");
    }
  }

  // Reads from a readable characteristic
  Future<List<int>> readFromDevice(
      String deviceId, String serviceUuid, String charUuid) async {
    final characteristic =
        deviceCharacteristics[deviceId]?[serviceUuid]?[charUuid];
    if (characteristic != null && characteristic.properties.read) {
      return await characteristic.read();
    }
    return [];
  }
}

// Appends a 4-byte CRC32 checksum to the data using crc32.dart implementation
List<int> appendCrc32(List<int> data) {
  final crc = CRC32().calculate(data);
  final crcBytes = ByteData(4)..setUint32(0, crc, Endian.big);
  return [...data, ...crcBytes.buffer.asUint8List()];
}

// Data model representing a received CAN message
class BlueMessage {
  final List<int> data; // Raw message bytes
  final int identifier; // Parsed CAN ID (32-bit)
  final bool flagged; 

  BlueMessage({
    required this.data,
    required this.identifier,
    required this.flagged,
  });
}

 */

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'crc32.dart'; // Import your CRC32 implementation

// CanBluetooth Singleton
// ----------------------
// Manages all Bluetooth communication and CAN message handling.
// Responsibilities:
// - Scanning for BT devices
// - Connecting and disconnecting from devices
// - Discovering GATT services and characteristics
// - Subscribing to notifications
// - Sending/receiving CAN frames with CRC32
class CanBluetooth {
  // Private constructor for singleton
  CanBluetooth._();

  // Global singleton instance
  static final CanBluetooth instance = CanBluetooth._();

  // BT scan results
  final Map<String, ScanResult> scanResults = {};

  // Connected devices by ID
  final Map<String, BluetoothDevice> connectedDevices = {};

  // Services per device
  final Map<String, Map<String, BluetoothService>> deviceServices = {};

  // Characteristics per service per device
  final Map<String, Map<String, Map<String, BluetoothCharacteristic>>>
      deviceCharacteristics = {};

  // Writable characteristics per device
  final Map<String, Map<String, BluetoothCharacteristic>>
      writableCharacteristics = {};

  // Notify subscriptions per device/characteristic
  final Map<String, Map<String, StreamSubscription<List<int>>>> notifyStreams =
      {};

  // Cached CAN messages per device and CAN ID
  final Map<String, Map<int, BlueMessage>> deviceData = {};

  // Notifiers to trigger UI updates
  final ValueNotifier<DateTime> addedDevice = ValueNotifier(DateTime.now());
  final ValueNotifier<DateTime> connectedDevice = ValueNotifier(DateTime.now());
  final ValueNotifier<DateTime> update = ValueNotifier(DateTime.now());
  final ValueNotifier<DateTime> messageUpdate = ValueNotifier(DateTime.now());
  final ValueNotifier<BluetoothAdapterState> adapterState =
      ValueNotifier(FlutterBluePlus.adapterStateNow);

  // Stream for broadcasting received CAN messages
  final StreamController<BlueMessage> _messageStreamController =
      StreamController<BlueMessage>.broadcast();

  // Public stream consumers listen to
  Stream<BlueMessage> get messageStream => _messageStreamController.stream;

  // BT scanning and adapter state subscriptions
  late StreamSubscription<List<ScanResult>> scanStream;
  late StreamSubscription<BluetoothAdapterState> adapterStateStream;

  // Initializes Bluetooth scanning and adapter state monitoring
  void init({LogLevel logLevel = LogLevel.info}) {
    scanStream = FlutterBluePlus.onScanResults.listen(_handleScanResults);

    adapterStateStream = FlutterBluePlus.adapterState.listen((state) {
      adapterState.value = state;
      debugPrint('Bluetooth Adapter State: $state');
    });

    FlutterBluePlus.setLogLevel(logLevel);

    scanResults.clear();
    connectedDevices.clear();
    deviceServices.clear();
    deviceCharacteristics.clear();
    notifyStreams.clear();
    writableCharacteristics.clear();
  }

  // Starts Bluetooth device scan
  void startScan() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    update.value = DateTime.now();
  }

  // Stops Bluetooth device scan
  void stopScan() {
    FlutterBluePlus.stopScan();
    update.value = DateTime.now();
  }

  // Updates scan results
  void _handleScanResults(List<ScanResult> results) {
    for (var result in results) {
      scanResults[result.device.remoteId.str] = result;
    }
    addedDevice.value = DateTime.now(); // Notify UI
  }

  // Connects to a Bluetooth device and discovers services
  Future<void> connect(BluetoothDevice device) async {
    try {
      await device.connect();
      connectedDevices[device.remoteId.str] = device;
      connectedDevice.value = DateTime.now();

      final services = await device.discoverServices();
      _mapServices(device, services);
    } catch (e) {
      debugPrint("Connection error: $e");
    }
  }

  // Disconnects and cleans up
  void disconnect(BluetoothDevice device) {
    device.disconnect();
    connectedDevices.remove(device.remoteId.str);
    _cancelNotifyStreams(device.remoteId.str);
    connectedDevice.value = DateTime.now();
  }

  // Maps services and characteristics, sets up write and notify handlers
  void _mapServices(BluetoothDevice device, List<BluetoothService> services) {
    final deviceId = device.remoteId.str;

    for (var service in services) {
      print("Service UUID: ${service.uuid}");
      for (var char in service.characteristics) {
        print("  Characteristic UUID: ${char.uuid}");
        print(
            "    Notify: ${char.properties.notify}, Write: ${char.properties.write}");
      }
    }

    for (var service in services) {
      deviceServices.putIfAbsent(deviceId, () => {})[service.uuid.str] =
          service;

      for (var characteristic in service.characteristics) {
        deviceCharacteristics.putIfAbsent(deviceId, () => {}).putIfAbsent(
                service.uuid.str, () => {})[characteristic.uuid.str] =
            characteristic;

        if (characteristic.properties.notify) {
          _subscribeToNotify(deviceId, characteristic);
        }

        if (characteristic.properties.write ||
            characteristic.properties.writeWithoutResponse) {
          writableCharacteristics.putIfAbsent(
              deviceId, () => {})[characteristic.uuid.str] = characteristic;
        }
      }
    }
  }

  // Subscribes to notifications and logs incoming CAN messages
  void _subscribeToNotify(
      String deviceId, BluetoothCharacteristic characteristic) async {
    try {
      await characteristic.setNotifyValue(true);
      final stream = characteristic.lastValueStream.listen((value) {
        if (value.isNotEmpty) {
          debugPrint("Notify from ${characteristic.characteristicUuid}");
          debugPrint(
              "Raw: ${value.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}");

          _handleCANMessage(
              deviceId, value); // Now actively handles incoming data
        }
      });

      notifyStreams.putIfAbsent(deviceId, () => {})[characteristic.uuid.str] =
          stream;
    } catch (e) {
      debugPrint("Notify error: $e");
    }
  }

  // Cancels all notify listeners for a device
  void _cancelNotifyStreams(String deviceId) {
    if (notifyStreams.containsKey(deviceId)) {
      for (var sub in notifyStreams[deviceId]!.values) {
        sub.cancel();
      }
      notifyStreams.remove(deviceId);
    }
  }
 void _handleCANMessage(String deviceId, List<int> msg) {
    if (msg.length < 13) {
      debugPrint("Too short ? Got ${msg.length} bytes");
      return;
    }

    // Extract CAN ID from first 4 bytes (big-endian)
    final identifier = ByteData.sublistView(Uint8List.fromList(msg.sublist(0, 4)))
    .getUint32(0, Endian.little);


    debugPrint(
        " Raw from device (${msg.length} bytes): ${msg.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}");
final flagByte = msg[4]; 
    final blueMsg = BlueMessage(
      
      identifier: identifier,
      data: msg,
       flagged: flagByte != 0,
    );

    deviceData.putIfAbsent(deviceId, () => {})[identifier] = blueMsg;
    messageUpdate.value = DateTime.now();
    _messageStreamController.add(blueMsg);
  }

 
 

  
  List<int> appendCrc32(List<int> data) {
    final crc = CRC32().calculate(data);
    final crcBytes = ByteData(4)
      ..setUint32(0, crc, Endian.big); // Use Endian.little if required
    return [...data, ...crcBytes.buffer.asUint8List()];
  }

  // Sends a CAN frame to a writable characteristic, including checksum
  Future<void> writeToDevice(
      String deviceId, String charUuid, List<int> data) async {
    try {
      final characteristic = writableCharacteristics[deviceId]?[charUuid];
      if (characteristic == null) {
        debugPrint("Characteristic not found for $deviceId / $charUuid");
        return;
      }
      if (!characteristic.properties.write &&
          !characteristic.properties.writeWithoutResponse) {
        debugPrint("Characteristic $charUuid is not writable");
        return;
      }

      final fullData = appendCrc32(data); // Append the 4-byte CRC32

      await characteristic.write(fullData, withoutResponse: true);
      debugPrint(
          "Sent ${fullData.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')} to $charUuid");
    } catch (e) {
      debugPrint("Write failed: $e");
    }
  }

  // Reads a value from a characteristic if supported
  Future<List<int>> readFromDevice(
      String deviceId, String serviceUuid, String charUuid) async {
    final characteristic =
        deviceCharacteristics[deviceId]?[serviceUuid]?[charUuid];
    if (characteristic != null && characteristic.properties.read) {
      return await characteristic.read();
    }
    return [];
  }
}

// Represents a parsed CAN message
class BlueMessage {
  final List<int> data; // Raw bytes including CAN ID, data, CRC
  final int identifier; // Parsed 32-bit CAN ID
  final bool flagged; // Reserved for future use

  BlueMessage({
    required this.data,
    required this.identifier,
    required this.flagged,
  });
}
