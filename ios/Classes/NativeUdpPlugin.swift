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

    socket.bind { localPort in
      if let localPort = localPort {
        result(["port": localPort])
      } else {
        result(FlutterError(code: "BIND_FAILED", message: "Failed to bind UDP socket", details: nil))
      }
    }
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

/// UDP socket backed by Network.framework NWListener + NWConnection.
/// Uses NWListener to receive datagrams and NWConnection to send.
/// Properly handles iOS cellular network interface selection.
private class UdpSocket {
  let id: Int
  let requestedPort: UInt16
  let channel: FlutterMethodChannel

  private var listener: NWListener?
  private var sendConnection: NWConnection?
  private let queue = DispatchQueue(label: "native_udp", qos: .userInteractive)
  private var localPort: UInt16 = 0

  init(id: Int, port: UInt16, channel: FlutterMethodChannel) {
    self.id = id
    self.requestedPort = port
    self.channel = channel
  }

  func bind(completion: @escaping (Int?) -> Void) {
    let params = NWParameters.udp
    params.allowLocalEndpointReuse = true
    // Require IPv4 to match mosh's behavior.
    params.requiredInterfaceType = .other
    if #available(iOS 14.0, *) {
      params.prohibitConstrainedPaths = false
    }

    let port: NWEndpoint.Port
    if requestedPort == 0 {
      port = .any
    } else {
      port = NWEndpoint.Port(rawValue: requestedPort)!
    }

    do {
      listener = try NWListener(using: params, on: port)
    } catch {
      completion(nil)
      return
    }

    listener?.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        if let port = self?.listener?.port {
          self?.localPort = port.rawValue
          completion(Int(port.rawValue))
        }
      case .failed:
        completion(nil)
      default:
        break
      }
    }

    listener?.newConnectionHandler = { [weak self] connection in
      self?.handleIncoming(connection)
    }

    listener?.start(queue: queue)
  }

  private func handleIncoming(_ connection: NWConnection) {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.receiveLoop(connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func receiveLoop(_ connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self = self, let data = data, error == nil else { return }

      var host = ""
      var port = 0
      if case .hostPort(let h, let p) = connection.currentPath?.remoteEndpoint {
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
      self.receiveLoop(connection)
    }
  }

  func send(data: Data, host: String, port: UInt16, completion: @escaping (Int) -> Void) {
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!
    )

    // Create or reuse connection for this destination.
    if sendConnection == nil || sendConnection?.state == .cancelled {
      let params = NWParameters.udp
      params.allowLocalEndpointReuse = true
      if requestedPort != 0 || localPort != 0 {
        let bindPort = localPort != 0 ? localPort : requestedPort
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
          host: .ipv4(.any),
          port: NWEndpoint.Port(rawValue: bindPort)!
        )
      }
      sendConnection = NWConnection(to: endpoint, using: params)
      sendConnection?.start(queue: queue)
    }

    sendConnection?.send(content: data, completion: .contentProcessed { error in
      completion(error == nil ? data.count : 0)
    })
  }

  func close() {
    listener?.cancel()
    sendConnection?.cancel()
    listener = nil
    sendConnection = nil
  }
}
