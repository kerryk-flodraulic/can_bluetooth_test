import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class CanBluetooth {
  static CanBluetooth instance = CanBluetooth();
  Map<String, BluetoothDevice> devices ={};

  ValueNotifier<DateTime> addedDevice = ValueNotifier(DateTime.now());
  ValueNotifier<DateTime> connectedDevice = ValueNotifier(DateTime.now());
  ValueNotifier<BluetoothAdapterState> adapterState = ValueNotifier(FlutterBluePlus.adapterStateNow);
  ValueNotifier<DateTime> updateFromMessage = ValueNotifier(DateTime.now());
  ValueNotifier<DateTime> update = ValueNotifier(DateTime.now());
  List<String> connectedDevices = [];

  Map<String,Map<int,BlueMessage>> deviceData = {};

  Map<String, Map<String,BluetoothService>> deviceServices ={};
  Map<String, Map<String,Map<String,BluetoothCharacteristic>>> deviceCharacteristics ={};
  Map<String, Map<String,StreamSubscription>> deviceCharacteristicsStreams ={};
  Map<String, Map<String,StreamConsumer>> device ={};

  late StreamSubscription scanStream;
  late StreamSubscription scanState;

  void init({LogLevel logLevel = LogLevel.none}){
    scanStream = FlutterBluePlus.onScanResults.listen(scannedDevice);
    scanState = FlutterBluePlus.adapterState.listen(adapterStateUpdated);
    changeLogLevel(logLevel);
  }

  void changeLogLevel(LogLevel logLevel){
    FlutterBluePlus.setLogLevel(logLevel);
  }

  void scan(){
    FlutterBluePlus.startScan();
    FlutterBluePlus.cancelWhenScanComplete(scanStream);
    update.value = DateTime.now();
  }

  void stopScan(){
    FlutterBluePlus.stopScan();
        update.value = DateTime.now();
  }
  void adapterStateUpdated(BluetoothAdapterState adapterStateValue ){
    adapterState.value = adapterStateValue;
  }

  void scannedDevice(List<ScanResult> results){
    if(results.isEmpty) return;
    ScanResult result = results.last;
    devices[result.device.remoteId.str] = result.device;
    addedDevice.value = DateTime.now();
  }


  void connect(BluetoothDevice device){
    device.connect();
    device.connectionState.listen((connectionState){
      if(connectionState == BluetoothConnectionState.connected && device.isConnected){
        connectedDevices.add(device.remoteId.str);
        connectedDevice.value = DateTime.now();
        service(device);
      }
      if(connectionState == BluetoothConnectionState.disconnected){
        connectedDevices.remove(device.remoteId.str);
        connectedDevice.value = DateTime.now();
      }
    });
  }

  void disconnect(BluetoothDevice device){
    device.disconnect();
    if(deviceCharacteristicsStreams.containsKey(device.advName)){
      for(String key in deviceCharacteristicsStreams[device.advName]!.keys){
         deviceCharacteristicsStreams[device.advName]![key]!.cancel();
      }
    }
  }

  void service(BluetoothDevice device)async{
    List<BluetoothService> services = await device.discoverServices();
    for(BluetoothService service in services){
      if(!deviceServices.containsKey(device.advName)) deviceServices[device.advName] = {};
      deviceServices[device.advName]![service.uuid.str] = service;
      readCharacteristics(service);
    }
  }

  void readCharacteristics(BluetoothService service)async{
    var characteristics = service.characteristics;
    BluetoothDevice? device;
    for(BluetoothCharacteristic characteristic in characteristics) {
      device ??= characteristic.device;
      if(!deviceCharacteristics.containsKey(device.advName)) deviceCharacteristics[device.advName] = {};
      if(!deviceCharacteristics[device.advName]!.containsKey(service.uuid.str)) deviceCharacteristics[device.advName]![service.uuid.str] = {};
      deviceCharacteristics[device.advName]![service.uuid.str]![characteristic.uuid.str] = characteristic;

      List<String> properties = [];
      if(characteristic.properties.authenticatedSignedWrites) properties.add("authenticatedSignedWrites");
      if(characteristic.properties.broadcast) properties.add("broadcast");
      if(characteristic.properties.extendedProperties) properties.add("extendedProperties");
      if(characteristic.properties.indicate) properties.add("indicate");
      if(characteristic.properties.indicateEncryptionRequired) properties.add("indicateEncryptionRequired");
      if(characteristic.properties.notify) properties.add("notify");
      if(characteristic.properties.notifyEncryptionRequired) properties.add("notifyEncryptionRequired");
      if(characteristic.properties.read) properties.add("read");
      if(characteristic.properties.write) properties.add("write");
      if(characteristic.properties.writeWithoutResponse) properties.add("writeWithoutResponse");
      debugPrint("${device.advName} : ${characteristic.uuid.str} $properties");

      if(characteristic.properties.read){
        if(!deviceCharacteristicsStreams.containsKey(device.advName)) deviceCharacteristicsStreams[device.advName] = {};
      }
      if(characteristic.properties.notify){
        await characteristic.setNotifyValue(true);
        deviceCharacteristicsStreams[device.advName]![characteristic.uuid.str] = onRead(characteristic).listen((value)=>handleCANMessage(device!,value));
      }
      if(characteristic.properties.write){
        if(!deviceCharacteristicsStreams.containsKey(device.advName)) deviceCharacteristicsStreams[device.advName] = {};
      }
    }
  }

  void handleCANMessage(BluetoothDevice device,List<int> msg){
    if(!deviceData.containsKey(device.remoteId.str)) deviceData[device.remoteId.str] = {};
    if(msg.length > 5){
      //bool isCan = (msg[0] == 0x31);
      Uint8List valuesParsed = Uint8List.fromList(msg.skip(1).toList());
      int id =  valuesParsed.buffer.asUint32List().first;
      if(!deviceData[device.remoteId.str]!.containsKey(id)){
        deviceData[device.remoteId.str]![id] = BlueMessage(data:msg);
      }
      else{
        deviceData[device.remoteId.str]![id]!.update(id: id, rawData: msg);
      }
      updateFromMessage.value = DateTime.now();
    }
  }

  void write(BluetoothCharacteristic characteristic, List<int>data) => characteristic.write(data);
  Future<List<int>> read(BluetoothCharacteristic characteristic) => characteristic.read();
  Stream<List<int>> onRead(BluetoothCharacteristic characteristic)=> characteristic.lastValueStream.asBroadcastStream();

}

class BlueMessage{
  int id = 0;
  List <int> data = [];
  DateTime timeStamp = DateTime.now();
  BlueMessage({required this.data});

  void update({required int id, required List<int> rawData}){
    data = rawData;
    timeStamp = DateTime.now();
    debugPrint("Updated: $rawData @ Time: $timeStamp");
  }
}