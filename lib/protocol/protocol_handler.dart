/// 协议处理器接口
/// 定义所有协议实现必须遵循的接口
abstract class ProtocolHandler {
  /// 协议名称
  String get protocolName;

  /// 解析接收到的数据
  /// 返回解析后的协议数据包，如果解析失败返回null
  ProtocolPacket? parseReceivedData(List<int> data);

  /// 构建发送数据包
  /// 根据命令和参数构建符合协议格式的数据包
  List<int> buildSendPacket({
    required int cmd,
    required List<int> payload,
  });

  /// 验证数据包CRC
  bool verifyCRC(List<int> data);

  /// 计算CRC校验值
  int calculateCRC(List<int> data, int length);
}

/// 协议数据包
class ProtocolPacket {
  final List<int> header;      // 协议头，通常是 [0x55, 0x55]
  final int length;            // 数据长度
  final int cmd;                // 命令字节
  final List<int> payload;     // 数据内容
  final int crc;                // CRC校验值

  ProtocolPacket({
    required this.header,
    required this.length,
    required this.cmd,
    required this.payload,
    required this.crc,
  });

  /// 获取完整的数据包（包含CRC）
  List<int> get fullPacket {
    return [
      ...header,
      length,
      cmd,
      ...payload,
      crc,
    ];
  }

  @override
  String toString() {
    return 'ProtocolPacket(cmd: 0x${cmd.toRadixString(16)}, '
        'length: $length, payload: ${payload.length} bytes)';
  }
}

/// 协议事件类型
enum ProtocolEventType {
  // 云台->APP 命令
  shutterClick,        // 0xa1 拍照或录像
  switchMode,          // 0xa2 切换拍照、录像
  switchCamera,        // 0xa3 切换前后置
  zoom,                // 0xa4 变焦
  panoramaPhoto,       // 0xa5 全景拍照
  triggerButton,       // 0xa6 板机键（开启跟踪）
  templateAction,      // 0xa7 模板拍摄动作
  wheelClick,          // 0xa8 点击波轮
  gimbalVersion,       // 0xa9 云台版本
  batteryInfo,         // 0xaa 云台电量信息
  
  // 固件升级相关
  firmwareUpdate,      // 0xC9 固件升级
}

/// 协议事件
class ProtocolEvent {
  final ProtocolEventType type;
  final ProtocolPacket packet;
  final Map<String, dynamic>? data;

  ProtocolEvent({
    required this.type,
    required this.packet,
    this.data,
  });
}

/// 协议事件监听器
typedef ProtocolEventListener = void Function(ProtocolEvent event);

