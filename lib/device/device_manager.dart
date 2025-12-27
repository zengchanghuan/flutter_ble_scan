import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';

/// 设备信息模型
class DeviceInfo {
  final String deviceId;
  final String name;
  final String address;
  int? rssi;
  int? batteryLevel;
  DateTime? lastConnectedTime;
  bool autoConnect;

  DeviceInfo({
    required this.deviceId,
    required this.name,
    required this.address,
    this.rssi,
    this.batteryLevel,
    this.lastConnectedTime,
    this.autoConnect = true,
  });

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'name': name,
      'address': address,
      'rssi': rssi,
      'batteryLevel': batteryLevel,
      'lastConnectedTime': lastConnectedTime?.toIso8601String(),
      'autoConnect': autoConnect,
    };
  }

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    return DeviceInfo(
      deviceId: json['deviceId'] as String,
      name: json['name'] as String,
      address: json['address'] as String,
      rssi: json['rssi'] as int?,
      batteryLevel: json['batteryLevel'] as int?,
      lastConnectedTime: json['lastConnectedTime'] != null
          ? DateTime.parse(json['lastConnectedTime'] as String)
          : null,
      autoConnect: json['autoConnect'] as bool? ?? true,
    );
  }

  DeviceInfo copyWith({
    String? deviceId,
    String? name,
    String? address,
    int? rssi,
    int? batteryLevel,
    DateTime? lastConnectedTime,
    bool? autoConnect,
  }) {
    return DeviceInfo(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      address: address ?? this.address,
      rssi: rssi ?? this.rssi,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      lastConnectedTime: lastConnectedTime ?? this.lastConnectedTime,
      autoConnect: autoConnect ?? this.autoConnect,
    );
  }
}

/// 设备管理器
/// 负责管理已配对设备、自动重连等功能
class DeviceManager {
  static final DeviceManager _instance = DeviceManager._internal();
  factory DeviceManager() => _instance;
  DeviceManager._internal();

  static const String _prefsKey = 'paired_devices';
  final Map<String, DeviceInfo> _pairedDevices = {};
  final Map<String, BluetoothDevice> _connectedDevices = {};
  final Map<String, StreamSubscription> _connectionSubscriptions = {};
  bool _isAutoConnecting = false;

  /// 获取已配对的设备列表
  Map<String, DeviceInfo> get pairedDevices => Map.unmodifiable(_pairedDevices);

  /// 获取已连接的设备列表
  Map<String, BluetoothDevice> get connectedDevices => Map.unmodifiable(_connectedDevices);

  /// 初始化 - 加载已保存的设备
  Future<void> initialize() async {
    await _loadPairedDevices();
    _startAutoReconnect();
  }

  /// 加载已保存的配对设备
  Future<void> _loadPairedDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final devicesJson = prefs.getString(_prefsKey);
      if (devicesJson != null) {
        final List<dynamic> devicesList = json.decode(devicesJson);
        _pairedDevices.clear();
        for (var deviceJson in devicesList) {
          final device = DeviceInfo.fromJson(deviceJson as Map<String, dynamic>);
          _pairedDevices[device.deviceId] = device;
        }
      }
    } catch (e) {
      print('加载配对设备失败: $e');
    }
  }

  /// 保存配对设备
  Future<void> _savePairedDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final devicesList = _pairedDevices.values.map((d) => d.toJson()).toList();
      await prefs.setString(_prefsKey, json.encode(devicesList));
    } catch (e) {
      print('保存配对设备失败: $e');
    }
  }

  /// 添加配对设备
  Future<void> addPairedDevice(BluetoothDevice device, {bool autoConnect = true}) async {
    final deviceInfo = DeviceInfo(
      deviceId: device.remoteId.toString(),
      name: device.platformName.isNotEmpty ? device.platformName : 'Unknown Device',
      address: device.remoteId.toString(),
      autoConnect: autoConnect,
      lastConnectedTime: DateTime.now(),
    );
    
    _pairedDevices[deviceInfo.deviceId] = deviceInfo;
    await _savePairedDevices();
  }

  /// 移除配对设备
  Future<void> removePairedDevice(String deviceId) async {
    _pairedDevices.remove(deviceId);
    await _savePairedDevices();
  }

  /// 更新设备信息
  Future<void> updateDeviceInfo(String deviceId, {
    int? rssi,
    int? batteryLevel,
  }) async {
    final device = _pairedDevices[deviceId];
    if (device != null) {
      _pairedDevices[deviceId] = device.copyWith(
        rssi: rssi ?? device.rssi,
        batteryLevel: batteryLevel ?? device.batteryLevel,
        lastConnectedTime: DateTime.now(),
      );
      await _savePairedDevices();
    }
  }

  /// 开始自动重连
  void _startAutoReconnect() {
    // 监听扫描结果，自动连接已配对的设备
    FlutterBluePlus.scanResults.listen((results) {
      if (!_isAutoConnecting) {
        _autoConnectPairedDevices(results);
      }
    });
  }

  /// 自动连接已配对的设备
  Future<void> _autoConnectPairedDevices(List<ScanResult> scanResults) async {
    if (_isAutoConnecting) return;
    
    _isAutoConnecting = true;
    
    try {
      for (var result in scanResults) {
        final deviceId = result.device.remoteId.toString();
        final deviceInfo = _pairedDevices[deviceId];
        
        // 如果设备已配对且设置了自动连接，且当前未连接
        if (deviceInfo != null && 
            deviceInfo.autoConnect && 
            !_connectedDevices.containsKey(deviceId)) {
          
          // 更新RSSI
          await updateDeviceInfo(deviceId, rssi: result.rssi);
          
          // 尝试连接（使用autoConnect=true实现秒连）
          _connectDevice(result.device, deviceInfo);
        }
      }
    } finally {
      // 延迟重置标志，避免频繁连接
      Future.delayed(const Duration(seconds: 2), () {
        _isAutoConnecting = false;
      });
    }
  }

  /// 连接设备
  Future<void> _connectDevice(BluetoothDevice device, DeviceInfo deviceInfo) async {
    final deviceId = device.remoteId.toString();
    
    // 如果已经在连接中，跳过
    if (_connectionSubscriptions.containsKey(deviceId)) {
      return;
    }

    try {
      // 监听连接状态
      final subscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.connected) {
          _connectedDevices[deviceId] = device;
          updateDeviceInfo(deviceId, rssi: deviceInfo.rssi);
        } else if (state == BluetoothConnectionState.disconnected) {
          _connectedDevices.remove(deviceId);
          _connectionSubscriptions.remove(deviceId)?.cancel();
        }
      });

      _connectionSubscriptions[deviceId] = subscription;

      // 使用autoConnect=true实现快速自动连接
      await device.connect(
        timeout: const Duration(seconds: 1),
        autoConnect: true, // 关键：使用autoConnect实现秒连
      );
    } catch (e) {
      print('自动连接设备失败: $e');
      _connectionSubscriptions.remove(deviceId)?.cancel();
    }
  }

  /// 手动连接设备
  Future<bool> connectDevice(BluetoothDevice device) async {
    final deviceId = device.remoteId.toString();
    final deviceName = device.platformName;
    final isA400Device = deviceId.toUpperCase().contains('A40000000AE3');
    
    if (isA400Device) {
      print('🔧 [DeviceManager] 开始连接A40000000AE3设备');
      print('   - 设备ID: $deviceId');
      print('   - 设备名称: "$deviceName"');
      print('   - 当前连接状态: ${device.connectionState}');
      print('   - 是否已在连接列表: ${_connectedDevices.containsKey(deviceId)}');
    }
    
    try {
      print('🔧 [DeviceManager] 调用device.connect()');
      final connectStartTime = DateTime.now();
      
      // 先检查设备当前连接状态
      final currentState = device.connectionState;
      if (currentState == BluetoothConnectionState.connected) {
        print('🔧 [DeviceManager] 设备已连接，跳过连接操作');
        _connectedDevices[deviceId] = device;
        await addPairedDevice(device);
        return true;
      }
      
      // 增加超时时间到3秒，提高连接成功率
      await device.connect(
        timeout: const Duration(seconds: 3),
        autoConnect: false,
      );
      
      final connectDuration = DateTime.now().difference(connectStartTime);
      
      if (isA400Device) {
        print('🔧 [DeviceManager] device.connect()完成');
        print('   - 连接耗时: ${connectDuration.inMilliseconds}ms');
        print('   - 连接后状态: ${device.connectionState}');
      }
      
      // 添加到配对列表
      await addPairedDevice(device);
      
      if (isA400Device) {
        print('🔧 [DeviceManager] 设备已添加到配对列表');
      }
      
      _connectedDevices[deviceId] = device;
      
      if (isA400Device) {
        print('✅ [DeviceManager] A40000000AE3设备连接成功！');
        print('   - 已连接设备数: ${_connectedDevices.length}');
      }
      
      return true;
    } catch (e, stackTrace) {
      if (isA400Device) {
        print('❌ [DeviceManager] A40000000AE3设备连接失败:');
        print('   - 异常类型: ${e.runtimeType}');
        print('   - 异常信息: $e');
        print('   - 堆栈跟踪:');
        print(stackTrace);
        print('   - 可能原因:');
        print('     1. 连接超时（1秒内未连接成功）');
        print('     2. 设备不在范围内');
        print('     3. 设备拒绝连接');
        print('     4. 蓝牙适配器问题');
        print('     5. 设备已连接但状态未更新');
      } else {
        print('连接设备失败: $e');
      }
      return false;
    }
  }

  /// 断开设备
  Future<void> disconnectDevice(BluetoothDevice device) async {
    try {
      final deviceId = device.remoteId.toString();
      await device.disconnect();
      _connectedDevices.remove(deviceId);
      _connectionSubscriptions.remove(deviceId)?.cancel();
    } catch (e) {
      print('断开设备失败: $e');
    }
  }

  /// 获取设备信息（包含最新RSSI和电量）
  DeviceInfo? getDeviceInfo(String deviceId) {
    return _pairedDevices[deviceId];
  }

  /// 清理资源
  void dispose() {
    for (var subscription in _connectionSubscriptions.values) {
      subscription.cancel();
    }
    _connectionSubscriptions.clear();
  }
}

