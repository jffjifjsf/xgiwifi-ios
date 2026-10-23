import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'app_network_identity.dart';

typedef SourceBoundSocketStarter =
    Future<ConnectionTask<Socket>> Function(
      Object host,
      int port, {
      Object? sourceAddress,
    });
typedef SourceBoundSecureSocket =
    Future<Socket> Function(Future<Socket> socket, String host);

Future<ConnectionTask<Socket>> _startSocket(
  Object host,
  int port, {
  Object? sourceAddress,
}) => Socket.startConnect(host, port, sourceAddress: sourceAddress);

Future<Socket> _secureSocket(Future<Socket> socketFuture, String host) async {
  final socket = await socketFuture;
  try {
    return await SecureSocket.secure(socket, host: host);
  } on Object {
    socket.destroy();
    rethrow;
  }
}

/// 判断异常是不是“本机源地址绑不上”。
///
/// Windows 报 WSAEADDRNOTAVAIL(10049)，Linux/Android 报 EADDRNOTAVAIL(99)。
/// 触发场景通常是：网卡刚从 DHCP 换过地址、Wi-Fi 掉线重连、选了另一张网卡的
/// 地址，或者开发者用了 /32 之外不可绑定的地址。此时请求根本发不出去，
/// 只能退回让系统按路由自己挑出口。
bool isSourceBindFailure(Object error) {
  if (error is! SocketException) {
    return false;
  }
  final code = error.osError?.errorCode;
  if (code == 10049 || code == 99 || code == 49) {
    return true;
  }
  final message = error.message.toLowerCase();
  return message.contains('bind failed') ||
      message.contains('cannot assign requested address');
}

Future<ConnectionTask<Socket>> startSourceBoundConnection({
  required Uri uri,
  InternetAddress? sourceAddress,
  String? proxyHost,
  int? proxyPort,
  SourceBoundSocketStarter socketStarter = _startSocket,
  SourceBoundSecureSocket secureSocket = _secureSocket,
}) async {
  final rawTask = await socketStarter(
    proxyHost ?? uri.host,
    proxyPort ?? uri.port,
    sourceAddress: sourceAddress,
  );
  if (proxyHost != null || uri.scheme.toLowerCase() != 'https') {
    return rawTask;
  }

  Socket? activeSocket;
  final trackedRawSocket = rawTask.socket.then<Socket>((Socket socket) {
    activeSocket = socket;
    return socket;
  });
  final securedSocket = secureSocket(trackedRawSocket, uri.host).then<Socket>((
    Socket socket,
  ) {
    activeSocket = socket;
    return socket;
  });
  return ConnectionTask.fromSocket<Socket>(securedSocket, () {
    activeSocket?.destroy();
    rawTask.cancel();
  });
}

http.Client createSourceBoundHttpClient(
  String sourceIpv4, {
  void Function(String message)? onWarning,
}) {
  final normalizedSourceIpv4 = sourceIpv4.trim();
  if (!isUsableIpv4Address(normalizedSourceIpv4)) {
    throw FormatException('无效的网卡 IPv4 地址: $sourceIpv4');
  }

  final sourceAddress = InternetAddress(normalizedSourceIpv4);
  final innerClient = HttpClient();
  innerClient.findProxy = (_) => 'DIRECT';
  innerClient.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
    try {
      return await startSourceBoundConnection(
        uri: uri,
        sourceAddress: sourceAddress,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      );
    } on Object catch (error) {
      if (!isSourceBindFailure(error)) {
        rethrow;
      }
      // 绑不上就别硬绑：网关看的是报文里的源 IP，payload 里的 userIp 照样是对的，
      // 让系统按路由表挑出口还有机会登录成功（有线/无线同时在线时可能挑错网卡，
      // 但那也比直接失败强，用户能换网卡再试）。
      onWarning?.call(
        '无法绑定本机地址 $normalizedSourceIpv4，已改用系统默认路由重试（$error）',
      );
      return startSourceBoundConnection(
        uri: uri,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      );
    }
  };

  return IOClient(innerClient);
}
