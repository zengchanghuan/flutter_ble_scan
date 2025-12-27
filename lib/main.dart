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
  List<ScanResult> _scanResults = []; // M302和VIP设备列表
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
    
    // 延迟启动扫描，等待蓝牙适配器状态初始化完成
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && _adapterState == BluetoothAdapterState.on) {
          _startScan();
        }
      });
    });
  }

  Future<void> _initializeDeviceManager() async {
    await _deviceManager.initialize();
    // 监听设备管理器中的连接状态变化
    _refreshConnectedDevices();
  }

  void _checkBluetoothState() {
    FlutterBluePlus.adapterState.listen((state) {
      if (mounted) {
        setState(() {
          _adapterState = state;
        });
        
        // 当蓝牙开启时，自动开始扫描
        if (state == BluetoothAdapterState.on && !_isScanning) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted && _adapterState == BluetoothAdapterState.on && !_isScanning) {
              _startScan();
            }
          });
        }
      }
    });
  }

  void _listenToScanResults() {
    FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        // 保存所有扫描结果
        setState(() {
          _allScanResults = results;
        });
        
        // 调试：打印所有扫描到的设备信息
        for (var result in results) {
          final deviceName = result.device.platformName;
          final deviceId = result.device.remoteId.toString();
          print('扫描到设备: 名称="$deviceName", ID=$deviceId, RSSI=${result.rssi}');
          
          // 检查是否是目标MAC地址或设备ID
          final deviceIdUpper = deviceId.toUpperCase();
          final deviceIdClean = deviceIdUpper.replaceAll(RegExp(r'[-:]'), '');
          
          if (deviceIdUpper.contains('A1:B2:C3:92:40:6B') || 
              deviceIdUpper.contains('A1B2C392406B') ||
              deviceIdClean.contains('A1B2C392406B')) {
            print('找到目标设备 MAC: $deviceId, 名称: $deviceName');
          }
          
          // 检查是否是A40000000AE3设备
          if (deviceIdClean.contains('A40000000AE3') || 
              deviceIdUpper.contains('A40000000AE3')) {
            print('找到目标设备 ID: $deviceId, 名称: $deviceName');
          }
        }
        
        // 过滤出M302和VIP设备（不考虑连接状态和信号强度）
        final targetDevices = results.where((result) {
          final deviceName = result.device.platformName;
          final deviceId = result.device.remoteId.toString();
          
          // 匹配逻辑：支持精确匹配和去除空格后的匹配
          final deviceNameTrimmed = deviceName.trim();
          final isM302 = deviceNameTrimmed == 'M302' || deviceNameTrimmed.toUpperCase() == 'M302';
          final isVip = deviceNameTrimmed.toLowerCase() == 'vip';
          final isMatch = isM302 || isVip;
          
          // 详细诊断日志 - 对所有M302和VIP设备
          if (isM302 || isVip || deviceId.toUpperCase().contains('A40000000AE3')) {
            print('🔍 [诊断] 发现目标设备:');
            print('   - 设备ID: $deviceId');
            print('   - 设备名称(原始): "$deviceName"');
            print('   - 设备名称(去除空格): "$deviceNameTrimmed"');
            print('   - 名称是否为空: ${deviceName.isEmpty}');
            print('   - 名称长度: ${deviceName.length}');
            print('   - 是否匹配M302(精确): ${deviceNameTrimmed == "M302"}');
            print('   - 是否匹配M302(忽略大小写): ${deviceNameTrimmed.toUpperCase() == "M302"}');
            print('   - 是否匹配VIP: ${deviceNameTrimmed.toLowerCase() == "vip"}');
            print('   - 最终匹配结果: $isMatch');
            print('   - RSSI: ${result.rssi}');
            
            if (isMatch) {
              print('✅ [诊断] 设备被识别为目标设备，将尝试自动连接');
            } else {
              print('❌ [诊断] 设备未被识别为目标设备');
            }
          }
          
          return isMatch;
        }).toList();
        
        setState(() {
          _scanResults = targetDevices;
        });
        
        // 更新扫描到的设备的RSSI信息
        for (var result in results) {
          final deviceId = result.device.remoteId.toString();
          _deviceManager.updateDeviceInfo(deviceId, rssi: result.rssi);
        }
        
        // 自动连接M302和VIP设备
        _autoConnectTargetDevices(targetDevices);
      }
    });
  }

  /// 自动连接目标设备（M302和VIP）- 优化版，支持并行连接多个设备
  Future<void> _autoConnectTargetDevices(List<ScanResult> targetDevices) async {
    print('🔗 [自动连接] 开始处理 ${targetDevices.length} 个目标设备');
    
    if (targetDevices.isEmpty) {
      print('🔗 [自动连接] 没有目标设备，退出');
      return;
    }
    
    // 过滤出需要连接的设备（排除已连接和正在连接的）
    final devicesToConnect = <ScanResult>[];
    for (var result in targetDevices) {
      final device = result.device;
      final deviceId = device.remoteId.toString();
      final deviceName = device.platformName;
      final deviceNameTrimmed = deviceName.trim();
      
      // 判断设备类型
      final isM302 = deviceNameTrimmed == 'M302' || deviceNameTrimmed.toUpperCase() == 'M302';
      final isVip = deviceNameTrimmed.toLowerCase() == 'vip';
      final isA400Device = deviceId.toUpperCase().contains('A40000000AE3');
      
      // 如果设备已连接，跳过
      if (_connectedDevices.containsKey(device.remoteId)) {
        if (isM302) {
          print('🔗 [诊断] M302设备已连接，跳过: $deviceName ($deviceId)');
        } else if (isVip) {
          print('🔗 [诊断] VIP设备已连接，跳过: $deviceName ($deviceId)');
        } else if (isA400Device) {
          print('🔗 [诊断] A40000000AE3设备已连接，跳过');
        }
        continue;
      }
      
      // 如果正在连接中，跳过
      if (_autoConnectingDevices.contains(deviceId)) {
        if (isM302) {
          print('🔗 [诊断] M302设备正在连接中，跳过: $deviceName ($deviceId)');
        } else if (isVip) {
          print('🔗 [诊断] VIP设备正在连接中，跳过: $deviceName ($deviceId)');
        } else if (isA400Device) {
          print('🔗 [诊断] A40000000AE3设备正在连接中，跳过');
        }
        continue;
      }
      
      // 详细日志
      if (isM302) {
        print('🔗 [诊断] M302设备将被添加到连接队列');
        print('   - 设备ID: $deviceId');
        print('   - 设备名称: "$deviceName"');
        print('   - 已连接设备数: ${_connectedDevices.length}');
        print('   - 正在连接设备数: ${_autoConnectingDevices.length}');
      } else if (isVip) {
        print('🔗 [诊断] VIP设备将被添加到连接队列');
        print('   - 设备ID: $deviceId');
        print('   - 设备名称: "$deviceName"');
      } else if (isA400Device) {
        print('🔗 [诊断] A40000000AE3设备将被添加到连接队列');
        print('   - 设备ID: $deviceId');
        print('   - 设备名称: "$deviceName"');
        print('   - 已连接设备数: ${_connectedDevices.length}');
        print('   - 正在连接设备数: ${_autoConnectingDevices.length}');
      }
      
      devicesToConnect.add(result);
    }
    
    if (devicesToConnect.isEmpty) {
      print('🔗 [自动连接] 没有需要连接的设备（可能都已连接或正在连接）');
      return;
    }
    
    print('🔗 [自动连接] 准备连接 ${devicesToConnect.length} 个设备');
    
    // 并行连接所有需要连接的设备
    final connectionFutures = devicesToConnect.map((result) async {
      final device = result.device;
      final deviceId = device.remoteId.toString();
      final deviceName = device.platformName;
      final deviceNameTrimmed = deviceName.trim();
      final isM302 = deviceNameTrimmed == 'M302' || deviceNameTrimmed.toUpperCase() == 'M302';
      final isVip = deviceNameTrimmed.toLowerCase() == 'vip';
      final isA400Device = deviceId.toUpperCase().contains('A40000000AE3');
      
      // 标记为正在连接
      if (mounted) {
        setState(() {
          _autoConnectingDevices.add(deviceId);
        });
      }
      
      try {
        if (isM302) {
          print('🔗 [诊断] 开始连接M302设备');
          print('   - 设备ID: $deviceId');
          print('   - 设备名称: "$deviceName"');
          print('   - 连接前状态检查:');
          print('     * 是否在已连接列表: ${_connectedDevices.containsKey(device.remoteId)}');
          print('     * 是否在正在连接列表: ${_autoConnectingDevices.contains(deviceId)}');
        } else if (isVip) {
          print('🔗 [诊断] 开始连接VIP设备');
          print('   - 设备ID: $deviceId');
          print('   - 设备名称: "$deviceName"');
        } else if (isA400Device) {
          print('🔗 [诊断] 开始连接A40000000AE3设备');
          print('   - 设备ID: $deviceId');
          print('   - 设备名称: "$deviceName"');
          print('   - 连接前状态检查:');
          print('     * 是否在已连接列表: ${_connectedDevices.containsKey(device.remoteId)}');
          print('     * 是否在正在连接列表: ${_autoConnectingDevices.contains(deviceId)}');
        }
        
        print('🔗 [自动连接] 开始连接设备: $deviceName ($deviceId)');
        
        // 使用设备管理器连接（会自动保存为配对设备）
        final connectStartTime = DateTime.now();
        final connected = await _deviceManager.connectDevice(device);
        final connectDuration = DateTime.now().difference(connectStartTime);
        
        if (isM302 || isVip || isA400Device) {
          print('🔗 [诊断] 设备连接结果:');
          print('   - 设备类型: ${isM302 ? "M302" : (isVip ? "VIP" : "其他")}');
          print('   - 连接返回: $connected');
          print('   - 连接耗时: ${connectDuration.inMilliseconds}ms');
        }
        
        if (connected) {
          // 连接成功，添加到已连接列表
          if (mounted) {
            setState(() {
              _connectedDevices[device.remoteId] = device;
            });
            
            // 刷新连接状态
            _refreshConnectedDevices();
            
            // 显示提示
            final displayName = isVip ? 'VIP' : deviceName;
            _showSnackBar('已自动连接: $displayName');
            
            print('✅ [自动连接] 连接成功: $displayName ($deviceId)');
            
            if (isM302) {
              print('✅ [诊断] M302设备连接成功！');
              print('   - 连接后已连接设备数: ${_connectedDevices.length}');
            } else if (isVip) {
              print('✅ [诊断] VIP设备连接成功！');
            } else if (isA400Device) {
              print('✅ [诊断] A40000000AE3设备连接成功！');
              print('   - 连接后已连接设备数: ${_connectedDevices.length}');
            }
          }
        } else {
          print('❌ [自动连接] 连接失败: $deviceName ($deviceId) - 连接返回false');
          
          if (isM302) {
            print('❌ [诊断] M302设备连接失败原因: connectDevice返回false');
            print('   - 可能原因:');
            print('     1. 设备不在范围内');
            print('     2. 设备拒绝连接');
            print('     3. 连接超时');
            print('     4. 蓝牙适配器问题');
          } else if (isVip) {
            print('❌ [诊断] VIP设备连接失败原因: connectDevice返回false');
          } else if (isA400Device) {
            print('❌ [诊断] A40000000AE3设备连接失败原因: connectDevice返回false');
            print('   - 可能原因:');
            print('     1. 设备不在范围内');
            print('     2. 设备拒绝连接');
            print('     3. 连接超时');
            print('     4. 蓝牙适配器问题');
          }
        }
      } catch (e, stackTrace) {
        print('❌ [自动连接] 连接异常: $deviceName ($deviceId)');
        print('   错误: $e');
        
        if (isM302) {
          print('❌ [诊断] M302设备连接异常:');
          print('   - 异常类型: ${e.runtimeType}');
          print('   - 异常信息: $e');
          print('   - 堆栈跟踪:');
          print(stackTrace);
        } else if (isVip) {
          print('❌ [诊断] VIP设备连接异常:');
          print('   - 异常类型: ${e.runtimeType}');
          print('   - 异常信息: $e');
        } else if (isA400Device) {
          print('❌ [诊断] A40000000AE3设备连接异常:');
          print('   - 异常类型: ${e.runtimeType}');
          print('   - 异常信息: $e');
          print('   - 堆栈跟踪:');
          print(stackTrace);
        }
      } finally {
        // 移除连接标记
        if (mounted) {
          setState(() {
            _autoConnectingDevices.remove(deviceId);
          });
        }
      }
    }).toList();
    
    // 等待所有连接任务完成（不阻塞，允许并行执行）
    await Future.wait(connectionFutures, eagerError: false);
    
    print('所有自动连接任务完成，已连接设备数: ${_connectedDevices.length}');
  }

  void _listenToConnectedDevices() {
    // 初始化时获取已连接的设备
    _refreshConnectedDevices();
    
    // 定期刷新已连接的设备列表（每2秒刷新一次），以便更新电量等信息
    _startPeriodicRefresh();
  }

  // 定期刷新已连接设备列表，以便更新电量等信息
  void _startPeriodicRefresh() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _selectedTabIndex == 0) {
        _refreshConnectedDevices();
        _startPeriodicRefresh(); // 递归调用，持续刷新
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
                // 目标设备和全部设备Tab显示扫描按钮
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
                          _scanResults.where((r) => _connectedDevices.containsKey(r.device.remoteId)).length,
                        ),
                      ),
                      Expanded(
                        child: _buildTabButton(
                          1,
                          '目标设备(M302/VIP)',
                          Icons.search,
                          _scanResults.length,
                        ),
                      ),
                      Expanded(
                        child: _buildTabButton(
                          2,
                          '全部设备',
                          Icons.devices,
                          _allScanResults.where((r) => r.rssi >= -70).length,
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
        // 切换到已连接Tab时，刷新设备列表以更新电量等信息
        if (index == 0) {
          _refreshConnectedDevices();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.white : Colors.grey[700],
              size: 20,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[700],
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
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
                  ? '正在扫描设备...\n(显示所有设备名为"M302"和"VIP"的设备，不考虑连接状态)'
                  : '点击搜索按钮开始扫描\n(显示所有设备名为"M302"和"VIP"的设备，不考虑连接状态)',
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
        final deviceId = result.device.remoteId.toString();
        final isConnecting = _autoConnectingDevices.contains(deviceId);
        
        return DeviceTile(
          scanResult: result,
          isConnected: isConnected,
          isConnecting: isConnecting,
          isM302: result.device.platformName == 'M302', // 判断是否为M302设备
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
    // 从目标设备（M302和VIP）中筛选出已连接的设备
    final targetDeviceIds = _scanResults.map((r) => r.device.remoteId.toString()).toSet();
    final connectedTargetDevices = _connectedDevices.values.where((device) {
      return targetDeviceIds.contains(device.remoteId.toString());
    }).toList();
    
    if (connectedTargetDevices.isEmpty) {
      return Column(
        children: [
          // 空状态内容
          Expanded(
            child: Center(
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
                    '暂无已连接的目标设备',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '已连接Tab显示目标设备（M302和VIP）中已连接的设备',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 固定在底部的复位按钮（即使没有设备也显示）
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: ElevatedButton.icon(
              onPressed: () async {
                // 显示确认对话框
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('确认清除'),
                    content: const Text('确定要清除所有已连接的设备吗？\n这将断开所有连接并移除所有配对设备。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                );
                
                if (confirmed == true && mounted) {
                  await _clearAllConnectedDevices();
                }
              },
              icon: const Icon(Icons.refresh),
              label: const Text('复位 - 清除所有设备'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // 获取已连接目标设备的详细信息
    final allDevices = <String, DeviceInfo>{};
    final pairedDevices = _deviceManager.pairedDevices;
    
    for (var device in connectedTargetDevices) {
      final deviceId = device.remoteId.toString();
      // 优先使用已配对设备的信息（包含电量），如果没有则创建新的
      final deviceInfo = pairedDevices[deviceId] ?? DeviceInfo(
        deviceId: deviceId,
        name: device.platformName.isNotEmpty ? device.platformName : 'Unknown Device',
        address: device.remoteId.toString(),
      );
      allDevices[deviceId] = deviceInfo;
    }

    return Column(
      children: [
        // 设备列表，可滚动
        Expanded(
          child: ListView.builder(
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
          ),
        ),
        // 固定在底部的复位按钮
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: ElevatedButton.icon(
            onPressed: () async {
              // 显示确认对话框
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('确认清除'),
                  content: const Text('确定要清除所有已连接的设备吗？\n这将断开所有连接并移除所有配对设备。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                      child: const Text('确定'),
                    ),
                  ],
                ),
              );
              
              if (confirmed == true && mounted) {
                await _clearAllConnectedDevices();
              }
            },
            icon: const Icon(Icons.refresh),
            label: const Text('复位 - 清除所有设备'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 清除所有已连接的设备
  Future<void> _clearAllConnectedDevices() async {
    try {
      // 断开所有已连接的设备
      final devicesToDisconnect = List<BluetoothDevice>.from(_connectedDevices.values);
      for (var device in devicesToDisconnect) {
        try {
          await _deviceManager.disconnectDevice(device);
        } catch (e) {
          print('断开设备失败: $e');
        }
      }
      
      // 移除所有配对设备
      final pairedDevices = _deviceManager.pairedDevices;
      for (var deviceId in pairedDevices.keys) {
        try {
          await _deviceManager.removePairedDevice(deviceId);
        } catch (e) {
          print('移除配对设备失败: $e');
        }
      }
      
      // 清空已连接设备列表
      setState(() {
        _connectedDevices.clear();
      });
      
      // 刷新连接状态
      _refreshConnectedDevices();
      
      if (mounted) {
        _showSnackBar('已清除所有设备');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('清除设备失败: $e');
      }
    }
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
                  ? '正在扫描设备...\n(只显示信号强度≥-70dBm的设备)'
                  : '点击搜索按钮开始扫描\n(只显示信号强度≥-70dBm的设备)',
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

    // 只展示信号强度大于等于-70dBm的设备（RSSI >= -70，信号较好的设备）
    final filteredResults = _allScanResults.where((result) {
      return result.rssi >= -70;
    }).toList();

    return ListView.builder(
      itemCount: filteredResults.length,
      itemBuilder: (context, index) {
        final result = filteredResults[index];
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
  final bool isConnecting;
  final bool isM302;

  const DeviceTile({
    super.key,
    required this.scanResult,
    required this.onTap,
    this.isConnected = false,
    this.isConnecting = false,
    this.isM302 = false,
  });

  String _getDeviceName() {
    final name = scanResult.device.platformName;
    // 如果设备没有名称，显示设备ID（MAC地址格式）
    if (name.isEmpty) {
      final deviceId = _getDeviceId();
      // 尝试格式化为MAC地址格式
      return _formatDeviceIdAsMac(deviceId);
    }
    // 优化'vip'设备名称显示
    if (name.toLowerCase() == 'vip') {
      return 'VIP';
    }
    return name;
  }

  /// 将设备ID格式化为MAC地址格式（如果可能）
  String _formatDeviceIdAsMac(String deviceId) {
    // 移除常见的分隔符
    String cleaned = deviceId.replaceAll(RegExp(r'[-:]'), '').toUpperCase();
    
    // 如果是12位十六进制字符，格式化为MAC地址
    if (cleaned.length == 12 && RegExp(r'^[0-9A-F]{12}$').hasMatch(cleaned)) {
      return '${cleaned.substring(0, 2)}:${cleaned.substring(2, 4)}:${cleaned.substring(4, 6)}:'
          '${cleaned.substring(6, 8)}:${cleaned.substring(8, 10)}:${cleaned.substring(10, 12)}';
    }
    
    // 否则返回原始ID
    return deviceId;
  }

  bool _isVipDevice() {
    return scanResult.device.platformName.toLowerCase() == 'vip';
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
    // 优化M302和VIP设备的卡片样式
    final isTargetDevice = isM302 || _isVipDevice();
    final cardColor = isTargetDevice 
        ? (isConnected 
            ? Colors.green.withOpacity(0.1) 
            : Colors.blue.withOpacity(0.05))
        : null;
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: cardColor,
      elevation: isTargetDevice ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isTargetDevice && isConnected
            ? const BorderSide(color: Colors.green, width: 2)
            : isTargetDevice
                ? BorderSide(color: Colors.blue.withOpacity(0.3), width: 1.5)
                : BorderSide.none,
      ),
      child: ListTile(
        leading: isConnecting
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                color: isConnected 
                    ? Colors.green 
                    : isTargetDevice 
                        ? Colors.blue 
                        : _getRssiColor(_getRssi()),
                size: isTargetDevice ? 28 : 24,
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
            if (_isVipDevice())
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.purple, Colors.pink],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.purple.withOpacity(0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.star,
                      size: 12,
                      color: Colors.white,
                    ),
                    SizedBox(width: 2),
                    Text(
                      'VIP',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            if (isConnecting)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    SizedBox(width: 4),
                    Text(
                      '连接中',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              )
            else if (isConnected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, size: 12, color: Colors.white),
                    SizedBox(width: 2),
                    Text(
                      '已连接',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
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
  
  // 标准BLE Battery Service相关
  static const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb'; // Battery Service
  static const String batteryLevelCharUuid = '00002a19-0000-1000-8000-00805f9b34fb'; // Battery Level
  int? _standardBatteryLevel; // 从标准BLE服务读取的电量（0-100%）
  int? _protocolBatteryRaw; // 从协议层读取的原始电量值（0-4）

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
        // 暂时不处理电量信息
        // if (event.data != null) {
        //   // 优先使用 batteryLevel（已转换的百分比），如果没有则使用 rawValue 转换
        //   int? batteryRaw;
        //   int batteryLevel;
        //   
        //   if (event.data!.containsKey('batteryLevel')) {
        //     batteryLevel = event.data!['batteryLevel'] as int;
        //     // 如果 batteryLevel 是百分比（0-100），需要反推原始值
        //     if (batteryLevel <= 100) {
        //       batteryRaw = _convertPercentToBatteryRaw(batteryLevel);
        //     }
        //   } else if (event.data!.containsKey('rawValue')) {
        //     batteryRaw = event.data!['rawValue'] as int;
        //     batteryLevel = _convertBatteryRawToPercent(batteryRaw);
        //   } else {
        //     print('电量数据格式错误: ${event.data}');
        //     break;
        //   }
        //   
        //   _protocolBatteryRaw = batteryRaw;
        //   _batteryLevel = '$batteryLevel%';
        //   
        //   print('收到电量信息: 原始值=$batteryRaw, 百分比=$batteryLevel%');
        //   
        //   // 同步电量信息到设备管理器（优先使用标准BLE电量，如果没有则使用协议电量）
        //   final deviceId = widget.device.remoteId.toString();
        //   final finalBatteryLevel = _standardBatteryLevel ?? batteryLevel;
        //   DeviceManager().updateDeviceInfo(deviceId, batteryLevel: finalBatteryLevel);
        //   
        //   if (mounted) {
        //     setState(() {});
        //   }
        // }
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
        
        // 暂时不获取电量
        // _readStandardBatteryLevel(services);
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
    
    // 暂时不获取电量
    // 如果连接成功，发送获取所有设置的命令（这会触发设备返回电量等信息）
    // if (_writeCharacteristic != null) {
    //   // 延迟一下，确保服务发现完成
    //   Future.delayed(const Duration(milliseconds: 500), () {
    //     if (mounted) {
    //       print('发送获取所有设置命令（0xd5）以获取电量信息');
    //       _sendGetAllSettings();
    //     }
    //   });
    // }
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
      // 如果收到电量信息，回复0xd6告诉设备app在前台
      if (packet.cmd == 0xaa) {
        _sendAppForegroundCommand();
      }
    }
  }

  /// 发送app前台命令（0xd6），告诉设备app在前台
  void _sendAppForegroundCommand() {
    if (_protocolManager.currentHandler is GimbalProtocolHandler) {
      final handler = _protocolManager.currentHandler as GimbalProtocolHandler;
      final data = handler.buildAppForegroundCommand();
      _sendProtocolData(data);
      print('已发送app前台命令（0xd6）');
    }
  }

  /// 读取标准BLE Battery Service的电量（暂时禁用）
  @pragma('vm:prefer-inline')
  Future<void> _readStandardBatteryLevel(List<BluetoothService> services) async {
    // 暂时不获取电量
    // 原代码已注释，如需恢复请取消注释
    /*
    try {
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == batteryServiceUuid) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toLowerCase() == batteryLevelCharUuid) {
              // 读取电量值
              if (characteristic.properties.read) {
                try {
                  final value = await characteristic.read();
                  if (value.isNotEmpty) {
                    final batteryLevel = value[0];
                    if (batteryLevel >= 0 && batteryLevel <= 100) {
                      _standardBatteryLevel = batteryLevel;
                      
                      // 同步到设备管理器
                      final deviceId = widget.device.remoteId.toString();
                      DeviceManager().updateDeviceInfo(deviceId, batteryLevel: batteryLevel);
                      
                      if (mounted) {
                        setState(() {});
                      }
                      print('从标准BLE Battery Service读取电量: $batteryLevel%');
                    }
                  }
                } catch (e) {
                  print('读取标准BLE电量失败: $e');
                }
              }
              
              // 订阅电量通知（如果支持）
              if (characteristic.properties.notify || characteristic.properties.indicate) {
                try {
                  await characteristic.setNotifyValue(true);
                  characteristic.lastValueStream.listen((value) {
                    if (value.isNotEmpty) {
                      final batteryLevel = value[0];
                      if (batteryLevel >= 0 && batteryLevel <= 100) {
                        _standardBatteryLevel = batteryLevel;
                        
                        // 同步到设备管理器
                        final deviceId = widget.device.remoteId.toString();
                        DeviceManager().updateDeviceInfo(deviceId, batteryLevel: batteryLevel);
                        
                        if (mounted) {
                          setState(() {});
                        }
                        print('标准BLE电量更新: $batteryLevel%');
                      }
                    }
                  });
                } catch (e) {
                  print('订阅标准BLE电量通知失败: $e');
                }
              }
              return;
            }
          }
        }
      }
    } catch (e) {
      print('查找标准BLE Battery Service失败: $e');
    }
    */
    try {
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == batteryServiceUuid) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toLowerCase() == batteryLevelCharUuid) {
              // 读取电量值
              if (characteristic.properties.read) {
                try {
                  final value = await characteristic.read();
                  if (value.isNotEmpty) {
                    final batteryLevel = value[0];
                    if (batteryLevel >= 0 && batteryLevel <= 100) {
                      _standardBatteryLevel = batteryLevel;
                      
                      // 同步到设备管理器
                      final deviceId = widget.device.remoteId.toString();
                      DeviceManager().updateDeviceInfo(deviceId, batteryLevel: batteryLevel);
                      
                      if (mounted) {
                        setState(() {});
                      }
                      print('从标准BLE Battery Service读取电量: $batteryLevel%');
                    }
                  }
                } catch (e) {
                  print('读取标准BLE电量失败: $e');
                }
              }
              
              // 订阅电量通知（如果支持）
              if (characteristic.properties.notify || characteristic.properties.indicate) {
                try {
                  await characteristic.setNotifyValue(true);
                  characteristic.lastValueStream.listen((value) {
                    if (value.isNotEmpty) {
                      final batteryLevel = value[0];
                      if (batteryLevel >= 0 && batteryLevel <= 100) {
                        _standardBatteryLevel = batteryLevel;
                        
                        // 同步到设备管理器
                        final deviceId = widget.device.remoteId.toString();
                        DeviceManager().updateDeviceInfo(deviceId, batteryLevel: batteryLevel);
                        
                        if (mounted) {
                          setState(() {});
                        }
                        print('标准BLE电量更新: $batteryLevel%');
                      }
                    }
                  });
                } catch (e) {
                  print('订阅标准BLE电量通知失败: $e');
                }
              }
              return;
            }
          }
        }
      }
    } catch (e) {
      print('查找标准BLE Battery Service失败: $e');
    }
  }

  /// 将协议原始电量值（0-4）转换为百分比（0-100%）
  int _convertBatteryRawToPercent(int rawValue) {
    switch (rawValue) {
      case 0:
        return 0;
      case 1:
        return 25;
      case 2:
        return 50;
      case 3:
        return 75;
      case 4:
        return 100;
      default:
        return 0;
    }
  }

  /// 将百分比（0-100%）转换为协议原始值（0-4）
  int? _convertPercentToBatteryRaw(int percent) {
    if (percent >= 100) return 4;
    if (percent >= 75) return 3;
    if (percent >= 50) return 2;
    if (percent >= 25) return 1;
    if (percent > 0) return 1;
    return 0;
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
                  if (_batteryLevel != null || _standardBatteryLevel != null || _protocolBatteryRaw != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _standardBatteryLevel != null 
                                    ? Icons.battery_full 
                                    : Icons.battery_charging_full,
                                color: _standardBatteryLevel != null ? Colors.green : Colors.orange,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '电量: ${_standardBatteryLevel ?? _batteryLevel ?? "未知"}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                            ],
                          ),
                          if (_standardBatteryLevel != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '✓ 标准BLE电量: $_standardBatteryLevel%',
                              style: const TextStyle(fontSize: 12, color: Colors.green),
                            ),
                          ],
                          if (_protocolBatteryRaw != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '协议电量: 原始值=$_protocolBatteryRaw (${_convertBatteryRawToPercent(_protocolBatteryRaw!)}%)',
                              style: const TextStyle(fontSize: 12, color: Colors.orange),
                            ),
                          ],
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

  IconData _getBatteryIcon(int? batteryLevel) {
    if (batteryLevel == null) return Icons.battery_unknown;
    if (batteryLevel >= 75) return Icons.battery_full;
    if (batteryLevel >= 50) return Icons.battery_5_bar;
    if (batteryLevel >= 25) return Icons.battery_3_bar;
    return Icons.battery_1_bar;
  }

  Color _getBatteryColor(int? batteryLevel) {
    if (batteryLevel == null) return Colors.grey;
    if (batteryLevel >= 50) return Colors.green; // 50-100% 绿色
    if (batteryLevel >= 20) return Colors.amber; // 20-49% 黄色
    return Colors.red; // 0-19% 红色
  }

  String _getDisplayName(String name) {
    if (name.toLowerCase() == 'vip') {
      return 'VIP';
    }
    return name;
  }

  bool _isVipDevice(String name) {
    return name.toLowerCase() == 'vip';
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
        title: Row(
          children: [
            Expanded(
              child: Text(
                _getDisplayName(deviceInfo.name),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (_isVipDevice(deviceInfo.name))
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.purple, Colors.pink],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.purple.withOpacity(0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.star,
                      size: 12,
                      color: Colors.white,
                    ),
                    SizedBox(width: 2),
                    Text(
                      'VIP',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
          ],
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
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                // 信号强度
                if (deviceInfo.rssi != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                    ],
                  ),
                // 电量
                if (deviceInfo.batteryLevel != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _getBatteryIcon(deviceInfo.batteryLevel),
                        size: 14,
                        color: _getBatteryColor(deviceInfo.batteryLevel),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${deviceInfo.batteryLevel}%',
                        style: TextStyle(
                          fontSize: 12,
                          color: _getBatteryColor(deviceInfo.batteryLevel),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  )
                else if (isConnected)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        '获取电量中...',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
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
