import Flutter
import Network

public class NativeUdpPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?
  private var sockets: [Int: UdpSocket] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "native_udp", binaryMessenger: registrar.messenger())
    let instance = NativeUdpPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "INVALID_ARGS", message: "Expected map", details: nil))
      return
    }

    switch call.method {
    case "bind":
      handleBind(args: args, result: result)
    case "send":
      handleSend(args: args, result: result)
    case "close":
      handleClose(args: args, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleBind(args: [String: Any], result: @escaping FlutterResult) {
    let id = args["id"] as! Int
    let port = args["port"] as! Int

    let socket = UdpSocket(id: id, port: UInt16(port), channel: channel!)
    sockets[id] = socket
    // Return immediately — local port is assigned when the connection starts.
    result(["port": port])
  }

  private func handleSend(args: [String: Any], result: @escaping FlutterResult) {
    let id = args["id"] as! Int
    let data = (args["data"] as! FlutterStandardTypedData).data
    let host = args["host"] as! String
    let port = args["port"] as! Int

    guard let socket = sockets[id] else {
      result(FlutterError(code: "NOT_FOUND", message: "Socket not found", details: nil))
      return
    }

    socket.send(data: data, host: host, port: UInt16(port)) { bytesSent in
      result(bytesSent)
    }
  }

  private func handleClose(args: [String: Any], result: @escaping FlutterResult) {
    let id = args["id"] as! Int
    sockets[id]?.close()
    sockets.removeValue(forKey: id)
    result(nil)
  }
}

/// UDP socket backed by a single NWConnection for both send and receive.
/// Uses NWConnection as a bidirectional UDP flow — the correct pattern for
/// a UDP client on iOS. Works on both WiFi and cellular without needing
/// to specify interface types.
private class UdpSocket {
  let id: Int
  let requestedPort: UInt16
  let channel: FlutterMethodChannel

  private var connection: NWConnection?
  private let queue = DispatchQueue(label: "native_udp", qos: .userInteractive)
  private var closed = false

  init(id: Int, port: UInt16, channel: FlutterMethodChannel) {
    self.id = id
    self.requestedPort = port
    self.channel = channel
  }

  func send(data: Data, host: String, port: UInt16, completion: @escaping (Int) -> Void) {
    if closed {
      completion(0)
      return
    }

    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!
    )

    // Create connection lazily on first send.
    if connection == nil {
      let params = NWParameters.udp
      params.allowLocalEndpointReuse = true
      if #available(iOS 14.0, *) {
        params.prohibitConstrainedPaths = false
      }
      // Bind to requested local port if specified.
      if requestedPort != 0 {
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
          host: .ipv4(.any),
          port: NWEndpoint.Port(rawValue: requestedPort)!
        )
      }

      let conn = NWConnection(to: endpoint, using: params)
      connection = conn

      conn.stateUpdateHandler = { [weak self] state in
        guard let self = self else { return }
        switch state {
        case .ready:
          self.receiveLoop()
        case .failed:
          self.connection = nil
        default:
          break
        }
      }

      conn.start(queue: queue)
    }

    // Queue the send — NWConnection buffers until ready.
    connection?.send(content: data, completion: .contentProcessed { error in
      completion(error == nil ? data.count : 0)
    })
  }

  private func receiveLoop() {
    guard let conn = connection, !closed else { return }

    conn.receiveMessage { [weak self] data, _, _, error in
      guard let self = self, let data = data, error == nil, !self.closed else { return }

      var host = ""
      var port = 0
      if case .hostPort(let h, let p) = conn.currentPath?.remoteEndpoint {
        switch h {
        case .ipv4(let addr):
          host = "\(addr)"
        case .ipv6(let addr):
          host = "\(addr)"
        default:
          break
        }
        port = Int(p.rawValue)
      }

      DispatchQueue.main.async {
        self.channel.invokeMethod("onDatagram", arguments: [
          "id": self.id,
          "data": FlutterStandardTypedData(bytes: data),
          "host": host,
          "port": port,
        ])
      }

      // Continue receiving.
      self.receiveLoop()
    }
  }

  func close() {
    closed = true
    connection?.cancel()
    connection = nil
  }
}
