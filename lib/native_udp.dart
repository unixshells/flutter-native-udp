import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// A UDP socket that uses native platform APIs on iOS (Network.framework)
/// and Dart's built-in RawDatagramSocket on Android.
///
/// Dart's RawDatagramSocket doesn't work on iOS cellular networks.
/// This plugin uses Apple's NWConnection which properly handles
/// cellular interface selection.
class NativeUdpSocket {
  static const _channel = MethodChannel('native_udp');
  static int _nextId = 0;
  static final _sockets = <int, NativeUdpSocket>{};
  static bool _handlerRegistered = false;

  final int _id;
  final int localPort;
  RawDatagramSocket? _dartSocket; // Used on Android
  StreamController<Datagram>? _receiveController;
  bool _closed = false;

  NativeUdpSocket._(this._id, this.localPort);

  static void _ensureHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDatagram') {
        final args = call.arguments as Map;
        final socketId = args['id'] as int;
        final data = args['data'] as Uint8List;
        final host = args['host'] as String;
        final port = args['port'] as int;
        final socket = _sockets[socketId];
        if (socket != null && !socket._closed) {
          socket._receiveController!.add(Datagram(
            data,
            InternetAddress(host),
            port,
          ));
        }
      }
    });
  }

  /// Bind a UDP socket to a local port (0 = ephemeral).
  /// On iOS, uses Network.framework. On Android, uses Dart's RawDatagramSocket.
  static Future<NativeUdpSocket> bind(int port) async {
    if (!Platform.isIOS) {
      // Android/other: use Dart's built-in socket.
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      final id = _nextId++;
      final wrapper = NativeUdpSocket._(id, socket.port);
      wrapper._dartSocket = socket;
      wrapper._receiveController = StreamController<Datagram>.broadcast();
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg != null) {
            wrapper._receiveController!.add(dg);
          }
        }
      });
      return wrapper;
    }

    // iOS: use native Network.framework.
    _ensureHandler();
    final id = _nextId++;
    final result = await _channel.invokeMethod<Map>('bind', {
      'id': id,
      'port': port,
    });
    final localPort = result!['port'] as int;
    final wrapper = NativeUdpSocket._(id, localPort);
    wrapper._receiveController = StreamController<Datagram>.broadcast();
    _sockets[id] = wrapper;

    return wrapper;
  }

  /// Send data to a remote address.
  Future<int> send(Uint8List data, InternetAddress address, int port) async {
    if (_closed) return 0;

    if (_dartSocket != null) {
      return _dartSocket!.send(data, address, port);
    }

    final result = await _channel.invokeMethod<int>('send', {
      'id': _id,
      'data': data,
      'host': address.address,
      'port': port,
    });
    return result ?? 0;
  }

  /// Stream of incoming datagrams.
  Stream<Datagram> get receive => _receiveController!.stream;

  /// Close the socket.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _receiveController?.close();
    _sockets.remove(_id);

    if (_dartSocket != null) {
      _dartSocket!.close();
      return;
    }

    await _channel.invokeMethod('close', {'id': _id});
  }
}
