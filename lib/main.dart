import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';
import 'protocol/protocol_manager.dart';
import 'protocol/protocol_handler.dart';
import 'protocol/gimbal_protocol_handler.dart';
import 'device/device_manager.dart';

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
  List<ScanResult> _scanResults = []; // M302设备列表
  List<ScanResult> _allScanResults = []; // 所有扫描到的设备列表
  bool _isScanning = false;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  Map<DeviceIdentifier, BluetoothDevice> _connectedDevices = {};
  int _selectedTabIndex = 0;
  final DeviceManager _deviceManager = DeviceManager();
  final Set<String> _autoConnectingDevices = {}; // 正在自动连接的设备ID集合

  @override
  void initState() {
    super.initState();
    _initializeDeviceManager();
    _checkBluetoothState();
    _listenToScanResults();
    _listenToConnectedDevices();
  }

  Future<void> _initializeDeviceManager() async {
    await _deviceManager.initialize();
    // 监听设备管理器中的连接状态变化
    _refreshConnectedDevices();
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
      if (mounted) {
        // 保存所有扫描结果
        setState(() {
          _allScanResults = results;
        });
        
        // 过滤出M302设备
        final m302Devices = results.where((result) {
          final deviceName = result.device.platformName;
          return deviceName == 'M302';
        }).toList();
        
        setState(() {
          _scanResults = m302Devices;
        });
        
        // 更新扫描到的设备的RSSI信息
        for (var result in results) {
          final deviceId = result.device.remoteId.toString();
          _deviceManager.updateDeviceInfo(deviceId, rssi: result.rssi);
        }
        
        // 自动连接M302设备
        _autoConnectM302Devices(m302Devices);
      }
    });
  }

  /// 自动连接M302设备
  Future<void> _autoConnectM302Devices(List<ScanResult> m302Devices) async {
    for (var result in m302Devices) {
      final device = result.device;
      final deviceId = device.remoteId.toString();
      
      // 如果设备已连接，跳过
      if (_connectedDevices.containsKey(device.remoteId)) {
        continue;
      }
      
      // 如果正在连接中，跳过
      if (_autoConnectingDevices.contains(deviceId)) {
        continue;
      }
      
      // 标记为正在连接
      _autoConnectingDevices.add(deviceId);
      
      try {
        // 使用设备管理器连接（会自动保存为配对设备）
        final connected = await _deviceManager.connectDevice(device);
        
        if (connected) {
          // 连接成功，添加到已连接列表
          setState(() {
            _connectedDevices[device.remoteId] = device;
          });
          
          // 刷新连接状态
          _refreshConnectedDevices();
          
          // 显示提示
          if (mounted) {
            _showSnackBar('已自动连接: ${device.platformName}');
          }
        }
      } catch (e) {
        print('自动连接M302设备失败: $e');
      } finally {
        // 移除连接标记
        _autoConnectingDevices.remove(deviceId);
      }
    }
  }

  void _listenToConnectedDevices() {
    // 初始化时获取已连接的设备
    _refreshConnectedDevices();
    
    // 定期刷新已连接的设备列表（每2秒刷新一次）
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        _refreshConnectedDevices();
      }
    });
  }

  void _refreshConnectedDevices() {
    try {
      final devices = FlutterBluePlus.connectedDevices;
      if (mounted) {
        setState(() {
          _connectedDevices = {
            for (var device in devices) device.remoteId: device
          };
        });
      }
      
      // 同时更新设备管理器中的连接状态
      final managerDevices = _deviceManager.connectedDevices;
      for (var device in devices) {
        final deviceId = device.remoteId.toString();
        if (!managerDevices.containsKey(deviceId)) {
          // 设备已连接但不在管理器中，添加到管理器
          _deviceManager.addPairedDevice(device);
        }
      }
    } catch (e) {
      // 忽略错误
    }
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
          if (_selectedTabIndex == 1 || _selectedTabIndex == 2)
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
                // Tab 选择器
                Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  margin: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildTabButton(
                          0,
                          '已连接',
                          Icons.bluetooth_connected,
                          _connectedDevices.length,
                        ),
                      ),
                      Expanded(
                        child: _buildTabButton(
                          1,
                          '目标设备',
                          Icons.search,
                          _scanResults.length,
                        ),
                      ),
                      Expanded(
                        child: _buildTabButton(
                          2,
                          '全部设备',
                          Icons.devices,
                          _allScanResults.length,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isScanning && (_selectedTabIndex == 1 || _selectedTabIndex == 2))
                  const LinearProgressIndicator(),
                Expanded(
                  child: _selectedTabIndex == 0
                      ? _buildConnectedTab()
                      : _selectedTabIndex == 1
                          ? _buildScanTab()
                          : _buildAllDevicesTab(),
                ),
              ],
            ),
    );
  }

  Widget _buildTabButton(int index, String label, IconData icon, int count) {
    final isSelected = _selectedTabIndex == index;
    return InkWell(
      onTap: () {
        setState(() {
          _selectedTabIndex = index;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.white : Colors.grey[700],
              size: 20,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey[700],
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white.withValues(alpha: 0.3) : Colors.blue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildScanTab() {
    if (_scanResults.isEmpty) {
      return Center(
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
                  ? '正在扫描设备...\n(仅显示设备名为"M302"的设备)'
                  : '点击搜索按钮开始扫描\n(仅显示设备名为"M302"的设备)',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey[600],
              ),
            ),
            if (_connectedDevices.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '已连接 ${_connectedDevices.length} 台设备',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.green[700],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _scanResults.length,
      itemBuilder: (context, index) {
        final result = _scanResults[index];
        final isConnected = _connectedDevices.containsKey(result.device.remoteId);
        return DeviceTile(
          scanResult: result,
          isConnected: isConnected,
          isM302: true, // 目标设备Tab中都是M302设备
          onTap: () async {
            // 如果已连接，直接打开详情页
            if (isConnected) {
              final device = _connectedDevices[result.device.remoteId]!;
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DeviceDetailScreen(
                    device: device,
                    autoConnect: false,
                  ),
                ),
              );
              // 刷新已连接设备列表
              _refreshConnectedDevices();
              return;
            }

            // 停止扫描以加快连接速度
            if (_isScanning) {
              _stopScan();
            }
            
            // 使用设备管理器连接设备（会自动保存为配对设备）
            final connected = await _deviceManager.connectDevice(result.device);
            if (connected) {
              _refreshConnectedDevices();
              // 打开详情页
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DeviceDetailScreen(
                    device: result.device,
                    autoConnect: false,
                  ),
                ),
              );
              _refreshConnectedDevices();
            } else {
              _showSnackBar('连接失败');
              if (mounted) {
                _startScan();
              }
            }
          },
        );
      },
    );
  }

  Widget _buildConnectedTab() {
    final connectedDevices = _connectedDevices.values.toList();
    final pairedDevices = _deviceManager.pairedDevices;
    
    if (connectedDevices.isEmpty && pairedDevices.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.bluetooth_disabled,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            const Text(
              '暂无已连接的设备',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'BLE 最多可同时连接 7 台设备\n已配对设备开机后会自动连接',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      );
    }

    // 合并已连接设备和已配对设备
    final allDevices = <String, DeviceInfo>{};
    
    // 添加已连接的设备
    for (var device in connectedDevices) {
      final deviceId = device.remoteId.toString();
      final deviceInfo = pairedDevices[deviceId] ?? DeviceInfo(
        deviceId: deviceId,
        name: device.platformName.isNotEmpty ? device.platformName : 'Unknown Device',
        address: device.remoteId.toString(),
      );
      allDevices[deviceId] = deviceInfo;
    }
    
    // 添加已配对但未连接的设备
    for (var entry in pairedDevices.entries) {
      if (!allDevices.containsKey(entry.key)) {
        allDevices[entry.key] = entry.value;
      }
    }

    return ListView.builder(
      itemCount: allDevices.length,
      itemBuilder: (context, index) {
        final deviceInfo = allDevices.values.elementAt(index);
        // 查找对应的已连接设备
        BluetoothDevice? device;
        bool isConnected = false;
        for (var entry in _connectedDevices.entries) {
          if (entry.key.toString() == deviceInfo.deviceId) {
            device = entry.value;
            isConnected = true;
            break;
          }
        }
        
        return DeviceInfoTile(
          deviceInfo: deviceInfo,
          device: device,
          isConnected: isConnected,
          onTap: device != null ? () async {
            final connectedDevice = device!;
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => DeviceDetailScreen(
                  device: connectedDevice,
                  autoConnect: false,
                ),
              ),
            );
            _refreshConnectedDevices();
          } : null,
          onDisconnect: device != null ? () async {
            try {
              final connectedDevice = device!;
              await _deviceManager.disconnectDevice(connectedDevice);
              _showSnackBar('已断开连接');
              _refreshConnectedDevices();
            } catch (e) {
              _showSnackBar('断开失败: $e');
            }
          } : null,
          onRemove: () async {
            await _deviceManager.removePairedDevice(deviceInfo.deviceId);
            _refreshConnectedDevices();
            _showSnackBar('已移除配对设备');
          },
        );
      },
    );
  }

  Widget _buildAllDevicesTab() {
    if (_allScanResults.isEmpty) {
      return Center(
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
                  ? '正在扫描设备...\n(显示所有扫描到的设备)'
                  : '点击搜索按钮开始扫描\n(显示所有扫描到的设备)',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey[600],
              ),
            ),
            if (_connectedDevices.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '已连接 ${_connectedDevices.length} 台设备',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.green[700],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _allScanResults.length,
      itemBuilder: (context, index) {
        final result = _allScanResults[index];
        final isConnected = _connectedDevices.containsKey(result.device.remoteId);
        final isM302 = result.device.platformName == 'M302';
        
        return DeviceTile(
          scanResult: result,
          isConnected: isConnected,
          isM302: isM302,
          onTap: () async {
            // 如果已连接，直接打开详情页
            if (isConnected) {
              final device = _connectedDevices[result.device.remoteId]!;
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DeviceDetailScreen(
                    device: device,
                    autoConnect: false,
                  ),
                ),
              );
              _refreshConnectedDevices();
              return;
            }

            // 停止扫描以加快连接速度
            if (_isScanning) {
              _stopScan();
            }
            
            // 使用设备管理器连接（会自动保存为配对设备）
            final connected = await _deviceManager.connectDevice(result.device);
            if (connected) {
              _refreshConnectedDevices();
              // 打开详情页
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DeviceDetailScreen(
                    device: result.device,
                    autoConnect: false,
                  ),
                ),
              );
              _refreshConnectedDevices();
            } else {
              _showSnackBar('连接失败');
              if (mounted) {
                _startScan();
              }
            }
          },
        );
      },
    );
  }
}

class DeviceTile extends StatelessWidget {
  final ScanResult scanResult;
  final VoidCallback onTap;
  final bool isConnected;
  final bool isM302;

  const DeviceTile({
    super.key,
    required this.scanResult,
    required this.onTap,
    this.isConnected = false,
    this.isM302 = false,
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
          isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
          color: isConnected ? Colors.green : _getRssiColor(_getRssi()),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                _getDeviceName(),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (isM302)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'M302',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            if (isConnected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  '已连接',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
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
  final bool autoConnect;

  const DeviceDetailScreen({
    super.key,
    required this.device,
    this.autoConnect = false,
  });

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  List<BluetoothService> _services = [];
  bool _isDiscovering = false;
  
  // 协议相关
  final ProtocolManager _protocolManager = ProtocolManager();
  BluetoothCharacteristic? _writeCharacteristic;
  List<ProtocolEvent> _protocolEvents = [];
  String? _batteryLevel;
  String? _gimbalVersion;

  @override
  void initState() {
    super.initState();
    _initializeProtocol();
    _listenToConnectionState();
    // 如果设置了自动连接，立即尝试连接
    if (widget.autoConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _connect();
      });
    }
  }

  void _initializeProtocol() {
    // 初始化协议管理器
    _protocolManager.initialize(protocolType: 'gimbal');
    
    // 添加协议事件监听器
    _protocolManager.addGlobalListener((event) {
      if (mounted) {
        setState(() {
          _protocolEvents.insert(0, event); // 新事件插入到前面
          if (_protocolEvents.length > 50) {
            _protocolEvents = _protocolEvents.take(50).toList(); // 只保留最近50条
          }
        });
        
        // 处理特定事件
        _handleProtocolEvent(event);
      }
    });
  }

  void _handleProtocolEvent(ProtocolEvent event) {
    switch (event.type) {
      case ProtocolEventType.batteryInfo:
        if (event.data != null) {
          _batteryLevel = '${event.data!['batteryLevel']}%';
        }
        break;
      case ProtocolEventType.gimbalVersion:
        if (event.data != null) {
          _gimbalVersion = '固件1: ${event.data!['firmware1']}, 固件4: ${event.data!['firmware4']}';
        }
        break;
      default:
        break;
    }
  }

  void _listenToConnectionState() {
    widget.device.connectionState.listen((state) {
      if (mounted) {
        setState(() {
          _connectionState = state;
        });
        if (state == BluetoothConnectionState.connected) {
          _discoverServices();
        }
      }
    });
  }

  Future<void> _connect() async {
    if (!mounted) return;
    
    try {
      // 设置连接超时为1秒，不使用自动连接（autoConnect=false 连接更快）
      // 如果设备已经连接，直接返回
      if (_connectionState == BluetoothConnectionState.connected) {
        _showSnackBar('已连接');
        return;
      }
      
      // 使用1秒超时，快速连接
      await widget.device.connect(
        timeout: const Duration(seconds: 1),
        autoConnect: false,
      );
      
      if (mounted) {
        _showSnackBar('连接成功');
        // 返回 true 表示连接成功
        Navigator.of(context).maybePop(true);
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('连接失败: $e');
        // 返回 false 表示连接失败，让调用者知道
        Navigator.of(context).maybePop(false);
      }
    }
  }

  Future<void> _disconnect() async {
    if (!mounted) return;
    
    try {
      await widget.device.disconnect();
      if (mounted) {
        _showSnackBar('已断开连接');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('断开连接失败: $e');
      }
    }
  }

  Future<void> _discoverServices() async {
    if (!mounted) return;
    
    setState(() {
      _isDiscovering = true;
    });

    try {
      List<BluetoothService> services = await widget.device.discoverServices();
      if (mounted) {
        setState(() {
          _services = services;
          _isDiscovering = false;
        });
        
        // 查找用于协议通信的特征值
        _findProtocolCharacteristics(services);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDiscovering = false;
        });
        _showSnackBar('发现服务失败: $e');
      }
    }
  }

  void _findProtocolCharacteristics(List<BluetoothService> services) {
    // 查找标准的BLE服务和特征值
    // 通常协议通信使用标准的服务UUID，这里需要根据实际设备调整
    for (var service in services) {
      for (var characteristic in service.characteristics) {
        // 查找可写的特征值（用于发送数据）
        if (characteristic.properties.write || 
            characteristic.properties.writeWithoutResponse) {
          _writeCharacteristic = characteristic;
        }
        
        // 查找可通知的特征值（用于接收数据）
        if (characteristic.properties.notify || 
            characteristic.properties.indicate) {
          _subscribeToNotifications(characteristic);
        }
      }
    }
    
    // 如果连接成功，发送获取所有设置的命令
    if (_writeCharacteristic != null) {
      _sendGetAllSettings();
    }
  }

  void _subscribeToNotifications(BluetoothCharacteristic characteristic) async {
    try {
      await characteristic.setNotifyValue(true);
      
      // 监听特征值变化
      characteristic.lastValueStream.listen((value) {
        if (value.isNotEmpty) {
          _handleReceivedData(value);
        }
      });
    } catch (e) {
      _showSnackBar('订阅通知失败: $e');
    }
  }

  void _handleReceivedData(List<int> data) {
    // 使用协议管理器解析数据
    final packet = _protocolManager.parseReceivedData(data);
    if (packet != null) {
      // 事件已通过监听器处理
    }
  }

  Future<void> _sendProtocolData(List<int> data) async {
    if (_writeCharacteristic == null) {
      _showSnackBar('未找到可写的特征值');
      return;
    }
    
    try {
      // 如果数据包较大，可能需要分包发送
      if (data.length <= 20) {
        // 使用 writeWithoutResponse 提高性能
        await _writeCharacteristic!.write(data, withoutResponse: true);
      } else {
        // 分包发送
        for (int i = 0; i < data.length; i += 20) {
          final chunk = data.sublist(
            i,
            i + 20 > data.length ? data.length : i + 20,
          );
          await _writeCharacteristic!.write(chunk, withoutResponse: true);
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }
    } catch (e) {
      _showSnackBar('发送数据失败: $e');
    }
  }

  void _sendGetAllSettings() {
    if (_protocolManager.currentHandler is GimbalProtocolHandler) {
      final handler = _protocolManager.currentHandler as GimbalProtocolHandler;
      final data = handler.buildGetAllSettingsCommand();
      _sendProtocolData(data);
    }
  }

  Widget _buildProtocolTab() {
    return Column(
      children: [
        // 协议信息卡片
        if (_batteryLevel != null || _gimbalVersion != null)
          Card(
            margin: const EdgeInsets.all(8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_batteryLevel != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.battery_charging_full, color: Colors.green),
                          const SizedBox(width: 8),
                          Text('电量: $_batteryLevel'),
                        ],
                      ),
                    ),
                  if (_gimbalVersion != null)
                    Row(
                      children: [
                        const Icon(Icons.info, color: Colors.blue),
                        const SizedBox(width: 8),
                        Expanded(child: Text('版本: $_gimbalVersion')),
                      ],
                    ),
                ],
              ),
            ),
          ),
        
        // 协议控制按钮
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: _writeCharacteristic == null ? null : () {
                  _sendGetAllSettings();
                },
                icon: const Icon(Icons.settings),
                label: const Text('获取设置'),
              ),
              ElevatedButton.icon(
                onPressed: _writeCharacteristic == null ? null : () {
                  if (_protocolManager.currentHandler is GimbalProtocolHandler) {
                    final handler = _protocolManager.currentHandler as GimbalProtocolHandler;
                    final data = handler.buildAppForegroundCommand();
                    _sendProtocolData(data);
                  }
                },
                icon: const Icon(Icons.notifications_active),
                label: const Text('App前台'),
              ),
            ],
          ),
        ),
        
        // 协议事件列表
        Expanded(
          child: _protocolEvents.isEmpty
              ? const Center(
                  child: Text(
                    '暂无协议事件\n连接设备后会自动接收协议数据',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: _protocolEvents.length,
                  itemBuilder: (context, index) {
                    final event = _protocolEvents[index];
                    return _buildProtocolEventItem(event);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildProtocolEventItem(ProtocolEvent event) {
    String eventName = event.type.toString().split('.').last;
    String eventDescription = _getEventDescription(event);
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: Icon(
          _getEventIcon(event.type),
          color: _getEventColor(event.type),
        ),
        title: Text(
          eventName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(eventDescription),
            const SizedBox(height: 4),
            Text(
              'CMD: 0x${event.packet.cmd.toRadixString(16).toUpperCase()}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }

  String _getEventDescription(ProtocolEvent event) {
    if (event.data == null) return '无数据';
    
    switch (event.type) {
      case ProtocolEventType.batteryInfo:
        return '电量: ${event.data!['batteryLevel']}% (原始值: ${event.data!['rawValue']})';
      case ProtocolEventType.gimbalVersion:
        return '固件1: ${event.data!['firmware1']}, 固件4: ${event.data!['firmware4']}';
      case ProtocolEventType.zoom:
        return '动作: ${event.data!['action']}, 值: ${event.data!['value']}';
      case ProtocolEventType.panoramaPhoto:
        return '进度: ${event.data!['currentCount']}/${event.data!['totalCount']}';
      case ProtocolEventType.wheelClick:
        return '功能: ${event.data!['function'] == 0 ? '变焦' : '对焦'}';
      default:
        return event.data.toString();
    }
  }

  IconData _getEventIcon(ProtocolEventType type) {
    switch (type) {
      case ProtocolEventType.batteryInfo:
        return Icons.battery_charging_full;
      case ProtocolEventType.gimbalVersion:
        return Icons.info;
      case ProtocolEventType.shutterClick:
        return Icons.camera;
      case ProtocolEventType.zoom:
        return Icons.zoom_in;
      case ProtocolEventType.panoramaPhoto:
        return Icons.panorama;
      default:
        return Icons.bluetooth;
    }
  }

  Color _getEventColor(ProtocolEventType type) {
    switch (type) {
      case ProtocolEventType.batteryInfo:
        return Colors.green;
      case ProtocolEventType.gimbalVersion:
        return Colors.blue;
      case ProtocolEventType.shutterClick:
        return Colors.orange;
      default:
        return Colors.grey;
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
                ? DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        TabBar(
                          tabs: const [
                            Tab(text: '服务', icon: Icon(Icons.bluetooth)),
                            Tab(text: '协议', icon: Icon(Icons.code)),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              // 服务列表
                              _services.isEmpty
                                  ? const Center(child: Text('未发现服务'))
                                  : ListView.builder(
                                      itemCount: _services.length,
                                      itemBuilder: (context, index) {
                                        return ServiceTile(service: _services[index]);
                                      },
                                    ),
                              // 协议信息
                              _buildProtocolTab(),
                            ],
                          ),
                        ),
                      ],
                    ),
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

class DeviceInfoTile extends StatelessWidget {
  final DeviceInfo deviceInfo;
  final BluetoothDevice? device;
  final bool isConnected;
  final VoidCallback? onTap;
  final VoidCallback? onDisconnect;
  final VoidCallback? onRemove;

  const DeviceInfoTile({
    super.key,
    required this.deviceInfo,
    this.device,
    required this.isConnected,
    this.onTap,
    this.onDisconnect,
    this.onRemove,
  });

  Color _getRssiColor(int? rssi) {
    if (rssi == null) return Colors.grey;
    if (rssi >= -50) return Colors.green;
    if (rssi >= -70) return Colors.orange;
    return Colors.red;
  }

  String _getBatteryIcon(int? batteryLevel) {
    if (batteryLevel == null) return '🔋';
    if (batteryLevel >= 75) return '🔋';
    if (batteryLevel >= 50) return '🔋';
    if (batteryLevel >= 25) return '🔋';
    return '🔋';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: Icon(
          isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
          color: isConnected ? Colors.green : Colors.grey,
          size: 32,
        ),
        title: Text(
          deviceInfo.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            // 地址
            Row(
              children: [
                const Icon(Icons.location_on, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '地址: ${deviceInfo.address}',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 信号强度和电量
            Row(
              children: [
                // 信号强度
                if (deviceInfo.rssi != null) ...[
                  Icon(
                    Icons.signal_cellular_alt,
                    size: 14,
                    color: _getRssiColor(deviceInfo.rssi),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${deviceInfo.rssi} dBm',
                    style: TextStyle(
                      fontSize: 12,
                      color: _getRssiColor(deviceInfo.rssi),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                // 电量
                if (deviceInfo.batteryLevel != null) ...[
                  Text(
                    _getBatteryIcon(deviceInfo.batteryLevel),
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${deviceInfo.batteryLevel}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
            // 连接状态
            const SizedBox(height: 4),
            Text(
              isConnected ? '● 已连接' : '○ 未连接',
              style: TextStyle(
                fontSize: 12,
                color: isConnected ? Colors.green : Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onRemove != null)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.grey),
                onPressed: onRemove,
                tooltip: '移除配对',
              ),
            if (isConnected && onDisconnect != null)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red),
                onPressed: onDisconnect,
                tooltip: '断开连接',
              ),
            if (onTap != null) const Icon(Icons.chevron_right),
          ],
        ),
        onTap: onTap,
      ),
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
