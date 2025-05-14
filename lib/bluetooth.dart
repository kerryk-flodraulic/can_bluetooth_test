import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/material.dart';

class CanBluetooth {
  static final CanBluetooth instance = CanBluetooth();

  final Map<String, ScanResult> devices = {};
  final Map<String, Map<int, BlueMessage>> deviceData = {};
  final Set<String> connectedDevices = {};

  final ValueNotifier<DateTime> addedDevice = ValueNotifier(DateTime.now());
  final ValueNotifier<DateTime> connectedDevice = ValueNotifier(DateTime.now());
  final ValueNotifier<int> updateFromMessage = ValueNotifier(0);
  final ValueNotifier<DateTime> update = ValueNotifier(DateTime.now());

  final StreamController<BlueMessage> _messageStreamController = StreamController.broadcast();
  Stream<BlueMessage> get messageStream => _messageStreamController.stream;

  late StreamSubscription<List<ScanResult>> scanStream;
  late StreamSubscription<BluetoothAdapterState> adapterStateStream;

  void init() {
    scanStream = FlutterBluePlus.onScanResults.listen(_handleScanResults);
    adapterStateStream = FlutterBluePlus.adapterState.listen((state) {
      debugPrint('Bluetooth Adapter State: $state');
    });
  }

  void scan() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    update.value = DateTime.now();
  }

  void stopScan() {
    FlutterBluePlus.stopScan();
    update.value = DateTime.now();
  }

  void _handleScanResults(List<ScanResult> results) {
    for (var result in results) {
      final id = result.device.remoteId.str;
      devices[id] = result;
    }
    addedDevice.value = DateTime.now();
  }

  Future<void> connect(BluetoothDevice device) async {
    try {
      await device.connect();
      connectedDevices.add(device.remoteId.str);
      connectedDevice.value = DateTime.now();

      final services = await device.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.properties.notify) {
            await characteristic.setNotifyValue(true);
            characteristic.lastValueStream.listen((value) {
              _handleMessage(device, value);
            });
          }
        }
      }
    } catch (e) {
      debugPrint("Connection error: $e");
    }
  }

  void disconnect(BluetoothDevice device) {
    device.disconnect();
    connectedDevices.remove(device.remoteId.str);
    connectedDevice.value = DateTime.now();
  }

  void _handleMessage(BluetoothDevice device, List<int> msg) {
    if (msg.length < 5) return;

    final id = Uint8List.fromList(msg.skip(1).take(4).toList()).buffer.asUint32List().first;
    final deviceId = device.remoteId.str;

    final blueMsg = BlueMessage(id: id, data: msg);

    deviceData.putIfAbsent(deviceId, () => {});
    deviceData[deviceId]![id] = blueMsg;

    updateFromMessage.value++;
    _messageStreamController.add(blueMsg);
  }
}

class BlueMessage {
  final int id;
  final List<int> data;
  final DateTime timeStamp;

  BlueMessage({required this.id, required this.data}) : timeStamp = DateTime.now();
}
