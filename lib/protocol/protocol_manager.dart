import 'protocol_handler.dart';
import 'gimbal_protocol_handler.dart';

/// 协议管理器
/// 负责管理协议处理器的创建、切换和事件分发
class ProtocolManager {
  static final ProtocolManager _instance = ProtocolManager._internal();
  factory ProtocolManager() => _instance;
  ProtocolManager._internal();

  ProtocolHandler? _currentHandler;
  final List<ProtocolEventListener> _globalListeners = [];

  /// 获取当前协议处理器
  ProtocolHandler? get currentHandler => _currentHandler;

  /// 初始化协议处理器
  /// [protocolType] 协议类型，默认为 'gimbal'
  void initialize({String protocolType = 'gimbal'}) {
    switch (protocolType) {
      case 'gimbal':
        _currentHandler = GimbalProtocolHandler();
        break;
      // 可以在这里添加其他协议类型
      // case 'custom':
      //   _currentHandler = CustomProtocolHandler();
      //   break;
      default:
        throw ArgumentError('未知的协议类型: $protocolType');
    }
  }

  /// 切换协议处理器
  void switchProtocol(String protocolType) {
    initialize(protocolType: protocolType);
  }

  /// 添加全局事件监听器
  void addGlobalListener(ProtocolEventListener listener) {
    _globalListeners.add(listener);
    
    // 如果当前处理器支持监听器，也添加到处理器中
    if (_currentHandler is GimbalProtocolHandler) {
      (_currentHandler as GimbalProtocolHandler).addListener(listener);
    }
  }

  /// 移除全局事件监听器
  void removeGlobalListener(ProtocolEventListener listener) {
    _globalListeners.remove(listener);
    
    if (_currentHandler is GimbalProtocolHandler) {
      (_currentHandler as GimbalProtocolHandler).removeListener(listener);
    }
  }

  /// 解析接收到的数据
  ProtocolPacket? parseReceivedData(List<int> data) {
    if (_currentHandler == null) {
      throw StateError('协议处理器未初始化，请先调用 initialize()');
    }
    return _currentHandler!.parseReceivedData(data);
  }

  /// 构建发送数据包
  List<int> buildSendPacket({
    required int cmd,
    required List<int> payload,
  }) {
    if (_currentHandler == null) {
      throw StateError('协议处理器未初始化，请先调用 initialize()');
    }
    return _currentHandler!.buildSendPacket(cmd: cmd, payload: payload);
  }
}

