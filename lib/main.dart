import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ScannerScreen(),
    );
  }
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  @override
  void initState() {
    super.initState();
    _checkBluetoothState();
    _listenToScanResults();
  }

  void _checkBluetoothState() {
    FlutterBluePlus.adapterState.listen((state) {
      setState(() {
        _adapterState = state;
      });
    });
  }

  void _listenToScanResults() {
    FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _scanResults = results;
      });
    });
  }

  void _startScan() {
    if (_adapterState != BluetoothAdapterState.on) {
      _showSnackBar('请先打开蓝牙');
      return;
    }

    setState(() {
      _isScanning = true;
      _scanResults.clear();
    });

    FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 15),
      withServices: [],
    );
  }

  void _stopScan() {
    FlutterBluePlus.stopScan();
    setState(() {
      _isScanning = false;
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('BLE Scanner'),
        actions: [
          IconButton(
            icon: Icon(_isScanning ? Icons.stop : Icons.search),
            onPressed: _isScanning ? _stopScan : _startScan,
            tooltip: _isScanning ? '停止扫描' : '开始扫描',
          ),
        ],
      ),
      body: _adapterState != BluetoothAdapterState.on
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.bluetooth_disabled, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('蓝牙未开启', style: TextStyle(fontSize: 18)),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: () {
                      FlutterBluePlus.turnOn();
                    },
                    child: const Text('打开蓝牙'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                if (_isScanning)
                  const LinearProgressIndicator(),
                Expanded(
                  child: _scanResults.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.bluetooth_searching,
                                size: 64,
                                color: Colors.grey[400],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _isScanning
                                    ? '正在扫描设备...'
                                    : '点击搜索按钮开始扫描',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _scanResults.length,
                          itemBuilder: (context, index) {
                            final result = _scanResults[index];
                            return DeviceTile(
                              scanResult: result,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => DeviceDetailScreen(
                                      device: result.device,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class DeviceTile extends StatelessWidget {
  final ScanResult scanResult;
  final VoidCallback onTap;

  const DeviceTile({
    super.key,
    required this.scanResult,
    required this.onTap,
  });

  String _getDeviceName() {
    return scanResult.device.platformName.isNotEmpty
        ? scanResult.device.platformName
        : 'Unknown Device';
  }

  String _getDeviceId() {
    return scanResult.device.remoteId.toString();
  }

  int _getRssi() {
    return scanResult.rssi;
  }

  Color _getRssiColor(int rssi) {
    if (rssi >= -50) return Colors.green;
    if (rssi >= -70) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: Icon(
          Icons.bluetooth,
          color: _getRssiColor(_getRssi()),
        ),
        title: Text(
          _getDeviceName(),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ID: ${_getDeviceId()}'),
            Row(
              children: [
                Icon(
                  Icons.signal_cellular_alt,
                  size: 16,
                  color: _getRssiColor(_getRssi()),
                ),
                const SizedBox(width: 4),
                Text(
                  '${_getRssi()} dBm',
                  style: TextStyle(color: _getRssiColor(_getRssi())),
                ),
              ],
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class DeviceDetailScreen extends StatefulWidget {
  final BluetoothDevice device;

  const DeviceDetailScreen({super.key, required this.device});

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  List<BluetoothService> _services = [];
  bool _isDiscovering = false;

  @override
  void initState() {
    super.initState();
    _listenToConnectionState();
  }

  void _listenToConnectionState() {
    widget.device.connectionState.listen((state) {
      setState(() {
        _connectionState = state;
      });
      if (state == BluetoothConnectionState.connected) {
        _discoverServices();
      }
    });
  }

  Future<void> _connect() async {
    try {
      await widget.device.connect();
      _showSnackBar('连接成功');
    } catch (e) {
      _showSnackBar('连接失败: $e');
    }
  }

  Future<void> _disconnect() async {
    try {
      await widget.device.disconnect();
      _showSnackBar('已断开连接');
    } catch (e) {
      _showSnackBar('断开连接失败: $e');
    }
  }

  Future<void> _discoverServices() async {
    setState(() {
      _isDiscovering = true;
    });

    try {
      List<BluetoothService> services = await widget.device.discoverServices();
      setState(() {
        _services = services;
        _isDiscovering = false;
      });
    } catch (e) {
      setState(() {
        _isDiscovering = false;
      });
      _showSnackBar('发现服务失败: $e');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.platformName.isNotEmpty
            ? widget.device.platformName
            : 'Device Details'),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: _connectionState == BluetoothConnectionState.connected
                ? Colors.green[100]
                : Colors.grey[200],
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '连接状态: ${_connectionState.toString().split('.').last}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID: ${widget.device.remoteId}',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connectionState == BluetoothConnectionState.connected
                      ? _disconnect
                      : _connect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _connectionState == BluetoothConnectionState.connected
                        ? Colors.red
                        : Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  child: Text(
                    _connectionState == BluetoothConnectionState.connected
                        ? '断开'
                        : '连接',
                  ),
                ),
              ],
            ),
          ),
          if (_isDiscovering)
            const LinearProgressIndicator(),
          Expanded(
            child: _connectionState == BluetoothConnectionState.connected
                ? _services.isEmpty
                    ? const Center(child: Text('未发现服务'))
                    : ListView.builder(
                        itemCount: _services.length,
                        itemBuilder: (context, index) {
                          return ServiceTile(service: _services[index]);
                        },
                      )
                : const Center(
                    child: Text('请先连接设备'),
                  ),
          ),
        ],
      ),
    );
  }
}

class ServiceTile extends StatelessWidget {
  final BluetoothService service;

  const ServiceTile({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text('Service: ${service.uuid}'),
      subtitle: Text('${service.characteristics.length} characteristics'),
      children: service.characteristics.map((characteristic) {
        return CharacteristicTile(characteristic: characteristic);
      }).toList(),
    );
  }
}

class CharacteristicTile extends StatefulWidget {
  final BluetoothCharacteristic characteristic;

  const CharacteristicTile({super.key, required this.characteristic});

  @override
  State<CharacteristicTile> createState() => _CharacteristicTileState();
}

class _CharacteristicTileState extends State<CharacteristicTile> {
  List<int> _value = [];
  bool _isReading = false;

  @override
  void initState() {
    super.initState();
    _readValue();
    _listenToNotifications();
  }

  void _listenToNotifications() {
    widget.characteristic.lastValueStream.listen((value) {
      setState(() {
        _value = value;
      });
    });
  }

  Future<void> _readValue() async {
    setState(() {
      _isReading = true;
    });
    try {
      List<int> value = await widget.characteristic.read();
      setState(() {
        _value = value;
        _isReading = false;
      });
    } catch (e) {
      setState(() {
        _isReading = false;
      });
      _showSnackBar('读取失败: $e');
    }
  }

  Future<void> _writeValue() async {
    // 示例：写入一个简单的值
    try {
      await widget.characteristic.write([0x01, 0x02, 0x03], withoutResponse: false);
      _showSnackBar('写入成功');
    } catch (e) {
      _showSnackBar('写入失败: $e');
    }
  }

  Future<void> _subscribe() async {
    try {
      await widget.characteristic.setNotifyValue(true);
      _showSnackBar('已订阅通知');
    } catch (e) {
      _showSnackBar('订阅失败: $e');
    }
  }


  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _getValueString() {
    if (_value.isEmpty) return 'No value';
    try {
      return utf8.decode(_value);
    } catch (e) {
      return _value.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canRead = widget.characteristic.properties.read;
    final canWrite = widget.characteristic.properties.write ||
        widget.characteristic.properties.writeWithoutResponse;
    final canNotify = widget.characteristic.properties.notify ||
        widget.characteristic.properties.indicate;

    return ListTile(
      title: Text('Characteristic: ${widget.characteristic.uuid}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Value: ${_getValueString()}'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              if (canRead)
                ElevatedButton.icon(
                  onPressed: _isReading ? null : _readValue,
                  icon: _isReading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.read_more, size: 16),
                  label: const Text('读取'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              if (canWrite)
                ElevatedButton.icon(
                  onPressed: _writeValue,
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('写入'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              if (canNotify)
                ElevatedButton.icon(
                  onPressed: _subscribe,
                  icon: const Icon(Icons.notifications, size: 16),
                  label: const Text('订阅'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
            ],
          ),
        ],
      ),
      isThreeLine: true,
    );
  }
}
