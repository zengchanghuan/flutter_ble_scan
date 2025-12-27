# 协议层架构说明

## 概述

这是一个可插拔的协议层架构，允许您轻松切换不同的BLE协议实现。当前实现了 **VIP云台协议V1.0.5**。

## 架构设计

### 核心组件

1. **ProtocolHandler** (接口)
   - 定义所有协议实现必须遵循的接口
   - 包含数据解析、数据构建、CRC校验等方法

2. **ProtocolManager** (管理器)
   - 单例模式，管理当前使用的协议处理器
   - 提供协议切换功能
   - 统一的事件分发机制

3. **GimbalProtocolHandler** (云台协议实现)
   - 基于 vip云台协议V1.0.5
   - 实现了所有协议命令的解析和构建

## 使用方法

### 1. 初始化协议

```dart
final protocolManager = ProtocolManager();
protocolManager.initialize(protocolType: 'gimbal');
```

### 2. 添加事件监听

```dart
protocolManager.addGlobalListener((event) {
  switch (event.type) {
    case ProtocolEventType.batteryInfo:
      print('电量: ${event.data!['batteryLevel']}%');
      break;
    case ProtocolEventType.gimbalVersion:
      print('版本信息: ${event.data}');
      break;
    // ... 其他事件
  }
});
```

### 3. 解析接收到的数据

```dart
final packet = protocolManager.parseReceivedData(receivedBytes);
if (packet != null) {
  // 数据解析成功，事件已通过监听器处理
}
```

### 4. 发送协议命令

```dart
if (protocolManager.currentHandler is GimbalProtocolHandler) {
  final handler = protocolManager.currentHandler as GimbalProtocolHandler;
  
  // 发送获取所有设置命令
  final data = handler.buildGetAllSettingsCommand();
  await characteristic.write(data, withoutResponse: true);
  
  // 发送跟踪指令
  final trackingData = handler.buildTrackingCommand(
    centerX: 100,
    centerY: 200,
    state: 1, // 1=正常跟踪
    isFront: true,
  );
  await characteristic.write(trackingData, withoutResponse: true);
}
```

## 切换协议

### 添加新的协议实现

1. 创建新的协议处理器类，实现 `ProtocolHandler` 接口：

```dart
class CustomProtocolHandler implements ProtocolHandler {
  @override
  String get protocolName => '自定义协议V1.0';
  
  @override
  ProtocolPacket? parseReceivedData(List<int> data) {
    // 实现解析逻辑
  }
  
  @override
  List<int> buildSendPacket({
    required int cmd,
    required List<int> payload,
  }) {
    // 实现构建逻辑
  }
  
  // ... 实现其他必需方法
}
```

2. 在 `ProtocolManager` 中添加新协议类型：

```dart
void initialize({String protocolType = 'gimbal'}) {
  switch (protocolType) {
    case 'gimbal':
      _currentHandler = GimbalProtocolHandler();
      break;
    case 'custom':  // 新增
      _currentHandler = CustomProtocolHandler();
      break;
    default:
      throw ArgumentError('未知的协议类型: $protocolType');
  }
}
```

3. 使用时切换协议：

```dart
protocolManager.switchProtocol('custom');
```

## 协议事件类型

### 云台->APP 命令（接收）

- `shutterClick` - 拍照或录像 (0xa1)
- `switchMode` - 切换拍照、录像 (0xa2)
- `switchCamera` - 切换前后置 (0xa3)
- `zoom` - 变焦 (0xa4)
- `panoramaPhoto` - 全景拍照进度 (0xa5)
- `triggerButton` - 板机键（开启跟踪）(0xa6)
- `templateAction` - 模板拍摄动作 (0xa7)
- `wheelClick` - 点击波轮 (0xa8)
- `gimbalVersion` - 云台版本 (0xa9)
- `batteryInfo` - 云台电量信息 (0xaa)

### APP->云台 命令（发送）

- `tracking` - 目标跟踪 (0xd1)
- `startPanorama` - 开启全景拍照 (0xd2)
- `stopPanorama` - 停止全景拍照 (0xd3)
- `zoomFocus` - 变焦对焦 (0xd4)
- `getAllSettings` - 获取云台所有设置 (0xd5)
- `appForeground` - 告诉云台app在前台 (0xd6)
- `aiTemplateMode` - app进入和退出ai模板界面 (0xd7)
- `executeTemplate` - 通知云台执行模板动作 (0xd8)

## 注意事项

1. **CRC校验**: 所有数据包都包含CRC校验，确保数据完整性
2. **数据分包**: 如果数据包超过20字节，需要分包发送
3. **事件监听**: 建议在连接成功后立即添加事件监听器
4. **协议切换**: 切换协议时，需要重新订阅BLE特征值通知

## 示例代码

完整示例请参考 `lib/main.dart` 中的 `DeviceDetailScreen` 类。

