import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:simple_flutterble/bluetooth.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  Widget buttonRow(BluetoothDevice device){
    return Flex(
      direction: Axis.horizontal,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if(!device.isConnected) Expanded(child: ElevatedButton(onPressed: ()=>CanBluetooth.instance.connect(device), child: Text("Connect"))),
        if(device.isConnected) Expanded(child:ElevatedButton(onPressed: ()=>CanBluetooth.instance.disconnect(device), child: Text("Disconnect")))
      ]);
  }

  Widget bluetoothDeviceRow(String deviceKey){
    BluetoothDevice device = CanBluetooth.instance.devices[deviceKey]!;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Flex(direction: Axis.horizontal,children: [
        Expanded(flex: 10, child: Icon(Icons.bluetooth)),
        Expanded(flex: 35, child: Text(device.advName)),
        Expanded(flex: 35, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: FittedBox(fit: BoxFit.fitWidth, child: Text(device.remoteId.str, maxLines: 1,)),
        )),
        Expanded(flex: 25, child:buttonRow(device))
      ]),
    );
  }

  Widget bluetoothList(){
    return ListenableBuilder(listenable: Listenable.merge([
       CanBluetooth.instance.addedDevice,
        CanBluetooth.instance.connectedDevice, 
    ]),
    builder: (context,child)=> ListView.separated(
        itemCount: CanBluetooth.instance.devices.length,
        separatorBuilder: (context,index)=>Divider(),
        itemBuilder: (context,index) =>bluetoothDeviceRow(CanBluetooth.instance.devices.keys.elementAt(index))
    ));
  }

  Widget scanningButton(){
    if(FlutterBluePlus.isScanningNow){
      return ElevatedButton(onPressed: () => CanBluetooth.instance.stopScan(), child:Text("Stop Scanning"));
    }
    return ElevatedButton(onPressed: () => CanBluetooth.instance.scan(), child:Text("Scan For Bluetooth"));
  }

  Widget messages(){
    return ListenableBuilder(listenable: Listenable.merge([
       CanBluetooth.instance.updateFromMessage
    ]),
    builder: (context,child){
      if(CanBluetooth.instance.deviceData.isEmpty) return SizedBox();
      if(CanBluetooth.instance.connectedDevices.isEmpty) return SizedBox();
      if(!CanBluetooth.instance.deviceData.containsKey(CanBluetooth.instance.connectedDevices.last)) return SizedBox();
      print(CanBluetooth.instance.deviceData);
      return ListView.separated(
      itemCount: CanBluetooth.instance.deviceData[CanBluetooth.instance.connectedDevices.last]!.length,
      separatorBuilder: (context, index) => Divider(),
      itemBuilder: (context, index) => Container(child: Text(CanBluetooth.instance.deviceData[CanBluetooth.instance.connectedDevices.last]!.values.elementAt(index).data.toString()),),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    CanBluetooth.instance.init();
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Flex(direction: Axis.horizontal,children: [
          
          Expanded( child: Flex(
            direction: Axis.vertical,
            children:[
              Expanded(flex: 1, child: ListenableBuilder(listenable:CanBluetooth.instance.update, builder: (context,child)=>scanningButton())),
              Expanded(flex:9,child: bluetoothList())
            ],)),

            Expanded(
              child: Flex(
              direction: Axis.vertical,
              children:[
                Expanded(flex: 1, child: Text("Data")),
                Expanded(flex:9, child:messages())
                //Expanded(flex:9,child: TextField(maxLines: 100,))
              ],),
            )


          ])
        ),
      ),
    );
  }
}
