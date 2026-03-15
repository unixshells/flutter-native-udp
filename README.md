# native_udp

Native UDP sockets for Flutter. Uses Apple's Network.framework on iOS
for reliable cellular support. Falls back to Dart's built-in
`RawDatagramSocket` on Android.

## Why

Dart's `RawDatagramSocket` silently fails on iOS cellular networks.
TCP works fine, but UDP datagrams never leave the device. This is a
known issue with Dart's socket implementation on iOS.

This plugin uses `NWConnection` (Network.framework) on iOS, which
properly handles cellular interface selection and works on all
network types.

## Usage

```dart
import 'package:native_udp/native_udp.dart';

final socket = await NativeUdpSocket.bind(0); // ephemeral port

// Send
await socket.send(data, InternetAddress('1.2.3.4'), 12345);

// Receive
socket.receive.listen((datagram) {
  print('${datagram.address}:${datagram.port} -> ${datagram.data}');
});

// Close
await socket.close();
```

## Platform behavior

| Platform | Implementation |
|----------|---------------|
| iOS | Network.framework (NWConnection / NWListener) |
| Android | Dart RawDatagramSocket (passthrough) |

## License

MIT
