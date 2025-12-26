# Flutter BLE Scanner

一个使用 `flutter_blue_plus` 库开发的蓝牙低功耗（BLE）扫描应用，界面类似 nRF Connect。

## 功能特性

- ✅ **BLE 设备扫描**
  - 扫描附近的 BLE 设备
  - 显示设备名称、MAC 地址、RSSI 信号强度
  - 实时更新扫描结果

- ✅ **设备连接**
  - 点击设备列表项查看详细信息
  - 连接/断开 BLE 设备
  - 显示连接状态

- ✅ **服务和特征发现**
  - 自动发现设备的 GATT 服务
  - 显示所有特征（Characteristics）
  - 显示特征属性（读/写/通知）

- ✅ **特征操作**
  - 读取特征值
  - 写入特征值
  - 订阅通知（Notifications）

## 技术栈

- **Flutter**: 跨平台 UI 框架
- **flutter_blue_plus**: BLE 功能库
- **Material Design 3**: 现代化 UI 设计

## 项目结构

```
lib/
  └── main.dart          # 主应用代码
    ├── ScannerScreen    # 扫描界面
    ├── DeviceDetailScreen  # 设备详情界面
    ├── ServiceTile      # 服务列表项
    └── CharacteristicTile   # 特征列表项
```

## 权限配置

### Android
已在 `android/app/src/main/AndroidManifest.xml` 中配置：
- `BLUETOOTH`
- `BLUETOOTH_ADMIN`
- `BLUETOOTH_SCAN`
- `BLUETOOTH_CONNECT`
- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`

### iOS
已在 `ios/Runner/Info.plist` 中配置：
- `NSBluetoothAlwaysUsageDescription`
- `NSBluetoothPeripheralUsageDescription`
- `NSLocationWhenInUseUsageDescription`

## 运行项目

### 前置要求
- Flutter SDK (3.9.2+)
- Android Studio / Xcode
- 真机设备（支持 BLE）

### 安装依赖
```bash
flutter pub get
```

### 运行到 Android 设备
```bash
flutter run
```

### 运行到 iOS 设备
```bash
flutter run
```

## 使用说明

1. **启动应用**
   - 确保设备蓝牙已开启
   - 如果蓝牙未开启，应用会提示打开蓝牙

2. **扫描设备**
   - 点击右上角的搜索图标开始扫描
   - 扫描结果会实时显示在列表中
   - 点击停止图标结束扫描

3. **查看设备详情**
   - 点击列表中的设备项
   - 进入设备详情页面

4. **连接设备**
   - 在设备详情页面点击"连接"按钮
   - 连接成功后会自动发现服务

5. **操作特征**
   - 展开服务查看特征列表
   - 根据特征属性进行读取/写入/订阅操作

## 界面预览

### 扫描界面
- 设备列表显示设备名称、ID 和 RSSI
- RSSI 颜色指示信号强度（绿色=强，橙色=中，红色=弱）
- 实时扫描进度指示

### 设备详情界面
- 连接状态显示
- 服务列表（可展开）
- 特征列表（可操作）

## 依赖包

```yaml
dependencies:
  flutter_blue_plus: ^1.35.0
```

## 注意事项

1. **Android 权限**
   - Android 6.0+ 需要位置权限才能扫描 BLE 设备
   - 需要在运行时请求位置权限

2. **iOS 权限**
   - iOS 需要蓝牙和位置权限
   - 首次使用会弹出权限请求

3. **设备兼容性**
   - 确保设备支持 BLE（蓝牙 4.0+）
   - 某些功能可能需要 Android 5.0+ 或 iOS 8.0+

## 开发计划

- [ ] 添加设备过滤功能
- [ ] 添加 RSSI 图表显示
- [ ] 添加日志记录功能
- [ ] 支持设备绑定（Bonding）
- [ ] 添加数据导出功能

## 许可证

MIT License

## 参考

- [flutter_blue_plus 文档](https://pub.dev/packages/flutter_blue_plus)
- [nRF Connect](https://www.nordicsemi.com/Software-and-tools/Development-Tools/nRF-Connect-for-mobile)
