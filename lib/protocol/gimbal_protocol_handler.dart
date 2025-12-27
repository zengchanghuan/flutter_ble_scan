import 'protocol_handler.dart';

/// 云台协议处理器
/// 基于 vip云台协议V1.0.5
class GimbalProtocolHandler implements ProtocolHandler {
  @override
  String get protocolName => 'VIP云台协议V1.0.5';

  // 协议常量
  static const List<int> protocolHeader = [0x55, 0x55];
  static const int crcPolynomial = 0x8d;
  static const int crcWidth = 8;

  // 命令定义
  static const int cmdShutterClick = 0xa1;
  static const int cmdSwitchMode = 0xa2;
  static const int cmdSwitchCamera = 0xa3;
  static const int cmdZoom = 0xa4;
  static const int cmdPanoramaPhoto = 0xa5;
  static const int cmdTriggerButton = 0xa6;
  static const int cmdTemplateAction = 0xa7;
  static const int cmdWheelClick = 0xa8;
  static const int cmdGimbalVersion = 0xa9;
  static const int cmdBatteryInfo = 0xaa;
  static const int cmdTracking = 0xd1;
  static const int cmdStartPanorama = 0xd2;
  static const int cmdStopPanorama = 0xd3;
  static const int cmdZoomFocus = 0xd4;
  static const int cmdGetAllSettings = 0xd5;
  static const int cmdAppForeground = 0xd6;
  static const int cmdAITemplateMode = 0xd7;
  static const int cmdExecuteTemplate = 0xd8;
  static const int cmdFirmwareUpdate = 0xC9;

  // 事件监听器列表
  final List<ProtocolEventListener> _listeners = [];

  /// 添加事件监听器
  void addListener(ProtocolEventListener listener) {
    _listeners.add(listener);
  }

  /// 移除事件监听器
  void removeListener(ProtocolEventListener listener) {
    _listeners.remove(listener);
  }

  /// 通知所有监听器
  void _notifyListeners(ProtocolEvent event) {
    for (var listener in _listeners) {
      listener(event);
    }
  }

  @override
  ProtocolPacket? parseReceivedData(List<int> data) {
    // 确保数据长度至少包含基本协议头
    if (data.length < 5) {
      return null;
    }

    // 验证协议头
    if (data[0] != protocolHeader[0] || data[1] != protocolHeader[1]) {
      return null;
    }

    final length = data[2];
    final cmd = data[3];
    
    // length包含cmd和payload，但不包含header和length本身
    // 所以payload长度 = length - 1 (减去cmd)
    final payloadLength = length - 1;
    final dataEndIndex = 4 + payloadLength;

    if (data.length < dataEndIndex + 1) {
      return null; // 数据长度不匹配
    }

    final payload = data.sublist(4, dataEndIndex);
    final crc = data[dataEndIndex];

    final packet = ProtocolPacket(
      header: protocolHeader,
      length: length,
      cmd: cmd,
      payload: payload,
      crc: crc,
    );

    // 验证CRC
    if (!verifyCRC(data)) {
      return null;
    }

    // 处理接收到的命令并触发事件
    _handleReceivedCommand(packet);

    return packet;
  }

  @override
  List<int> buildSendPacket({
    required int cmd,
    required List<int> payload,
  }) {
    // length = cmd(1) + payload.length
    final length = 1 + payload.length;
    
    final packet = [
      ...protocolHeader,
      length,
      cmd,
      ...payload,
    ];

    // 计算并添加CRC
    final crc = calculateCRC(packet, packet.length);
    packet.add(crc);

    return packet;
  }

  @override
  bool verifyCRC(List<int> data) {
    if (data.isEmpty) return false;
    
    final calculatedCRC = calculateCRC(data, data.length - 1);
    final receivedCRC = data[data.length - 1];
    
    return calculatedCRC == receivedCRC;
  }

  @override
  int calculateCRC(List<int> data, int length) {
    final topbit = 1 << (crcWidth - 1);
    int crc = 0;

    for (int i = 0; i < length; i++) {
      crc ^= data[i];
      for (int j = 0; j < 8; j++) {
        if ((crc & topbit) != 0) {
          crc = ((crc << 1) ^ crcPolynomial) & 0xFF;
        } else {
          crc = (crc << 1) & 0xFF;
        }
      }
    }

    return crc & 0xFF;
  }

  /// 处理接收到的命令
  void _handleReceivedCommand(ProtocolPacket packet) {
    ProtocolEventType? eventType;
    Map<String, dynamic>? eventData;

    // 根据命令类型解析事件
    switch (packet.cmd) {
      case cmdShutterClick:
        eventType = ProtocolEventType.shutterClick;
        break;
      case cmdSwitchMode:
        eventType = ProtocolEventType.switchMode;
        break;
      case cmdSwitchCamera:
        eventType = ProtocolEventType.switchCamera;
        break;
      case cmdZoom:
        eventType = ProtocolEventType.zoom;
        if (packet.payload.isNotEmpty) {
          eventData = {
            'value': packet.payload[0],
            'action': _parseZoomAction(packet.payload[0]),
          };
        }
        break;
      case cmdPanoramaPhoto:
        eventType = ProtocolEventType.panoramaPhoto;
        if (packet.payload.length >= 2) {
          eventData = {
            'currentCount': packet.payload[0],
            'totalCount': packet.payload[1],
          };
        }
        break;
      case cmdTriggerButton:
        eventType = ProtocolEventType.triggerButton;
        break;
      case cmdTemplateAction:
        eventType = ProtocolEventType.templateAction;
        eventData = {'data': packet.payload};
        break;
      case cmdWheelClick:
        eventType = ProtocolEventType.wheelClick;
        if (packet.payload.isNotEmpty) {
          eventData = {
            'function': packet.payload[0], // 0:变焦, 1:对焦
          };
        }
        break;
      case cmdGimbalVersion:
        eventType = ProtocolEventType.gimbalVersion;
        if (packet.payload.length >= 2) {
          eventData = {
            'firmware1': packet.payload[0],
            'firmware4': packet.payload[1],
          };
        }
        break;
      case cmdBatteryInfo:
        eventType = ProtocolEventType.batteryInfo;
        if (packet.payload.isNotEmpty) {
          final rawValue = packet.payload[0]; // 0-4
          eventData = {
            'rawValue': rawValue,
            'batteryLevel': _convertBatteryRawValue(rawValue),
          };
        }
        break;
      case cmdFirmwareUpdate:
        eventType = ProtocolEventType.firmwareUpdate;
        eventData = {'data': packet.payload};
        break;
      default:
        // 未知命令，不触发事件
        return;
    }

    // eventType 在 switch 中已赋值，不会为 null
    _notifyListeners(ProtocolEvent(
      type: eventType,
      packet: packet,
      data: eventData,
    ));
  }

  /// 解析变焦动作
  String _parseZoomAction(int value) {
    const deadzone = 5;
    const center = 150;
    
    if (value < center - deadzone) {
      return 'zoomIn'; // 放大
    } else if (value > center + deadzone) {
      return 'zoomOut'; // 缩小
    } else {
      return 'stop'; // 停止
    }
  }

  /// 转换电池原始值到百分比
  int _convertBatteryRawValue(int rawValue) {
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

  // MARK: - 发送命令方法

  /// 发送跟踪指令 (0xd1)
  /// [centerX] 水平方向中心点偏移
  /// [centerY] 垂直方向中心点偏移
  /// [state] 跟踪状态：1=正常，4=退出
  /// [isFront] 是否前置摄像头
  List<int> buildTrackingCommand({
    required int centerX,
    required int centerY,
    required int state,
    required bool isFront,
  }) {
    const trackingScale = 3;
    
    int adjustedCenterX;
    int adjustedCenterY;
    
    if (isFront) {
      adjustedCenterX = 10000 + centerX ~/ trackingScale;
      adjustedCenterY = 10000 + centerY ~/ trackingScale;
    } else {
      adjustedCenterX = 10000 - centerX ~/ trackingScale;
      adjustedCenterY = 10000 - centerY ~/ trackingScale;
    }
    
    final payload = [
      state,
      adjustedCenterX & 0xFF,
      (adjustedCenterX >> 8) & 0xFF,
      adjustedCenterY & 0xFF,
      (adjustedCenterY >> 8) & 0xFF,
    ];
    
    return buildSendPacket(cmd: cmdTracking, payload: payload);
  }

  /// 开启全景拍照 (0xd2)
  /// [mode] 1=120度, 2=影分身, 3=九宫格, 0=拍照成功移动到下个位置
  List<int> buildStartPanoramaCommand(int mode) {
    return buildSendPacket(cmd: cmdStartPanorama, payload: [mode]);
  }

  /// 停止全景拍照 (0xd3)
  List<int> buildStopPanoramaCommand() {
    return buildSendPacket(cmd: cmdStopPanorama, payload: []);
  }

  /// 变焦对焦 (0xd4)
  /// [function] 0=变焦, 1=对焦
  List<int> buildZoomFocusCommand(int function) {
    return buildSendPacket(cmd: cmdZoomFocus, payload: [function]);
  }

  /// 获取云台所有设置 (0xd5)
  List<int> buildGetAllSettingsCommand() {
    return buildSendPacket(cmd: cmdGetAllSettings, payload: []);
  }

  /// 告诉云台app在前台 (0xd6)
  List<int> buildAppForegroundCommand() {
    return buildSendPacket(cmd: cmdAppForeground, payload: []);
  }

  /// app进入和退出ai模板界面 (0xd7)
  /// [mode] 0=退出ai模板, 1=进入ai模版
  List<int> buildAITemplateModeCommand(int mode) {
    return buildSendPacket(cmd: cmdAITemplateMode, payload: [mode]);
  }

  /// 通知云台执行模板动作 (0xd8)
  /// [axis] 动作轴：0=pitch, 1=roll, 2=yaw
  /// [angles] 角度数组（包含初始角度）
  /// [times] 时间数组（每个片段的时间*10）
  List<int> buildExecuteTemplateCommand({
    required int axis,
    required List<int> angles,
    required List<int> times,
  }) {
    if (angles.length != times.length + 1) {
      throw ArgumentError('angles长度应比times多1（包含初始角度）');
    }
    
    final payload = [axis, ...angles, ...times];
    return buildSendPacket(cmd: cmdExecuteTemplate, payload: payload);
  }
}

