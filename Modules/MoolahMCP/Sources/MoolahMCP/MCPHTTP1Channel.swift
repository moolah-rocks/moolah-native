import HummingbirdCore
import Logging
import NIOCore
import NIOHTTPTypesHTTP1

/// Retains Hummingbird's parser, flow control and lifecycle, adding a raw endpoint guard.
struct MCPHTTP1Channel {
  let responder: HTTPChannelHandler.Responder
}

extension MCPHTTP1Channel: ServerChildChannel {
  typealias Value = HTTP1Channel.Value

  func setup(channel: any Channel, logger: Logger) -> EventLoopFuture<Value> {
    makeChannel().setup(channel: channel, logger: logger).flatMap { value in
      channel.pipeline.handler(type: HTTP1ToHTTPServerCodec.self).flatMap { codec in
        channel.pipeline.addHandler(MCPRequestTargetGuard(), position: .before(codec)).map { value }
      }
    }
  }

  func handle(value: Value, logger: Logger) async {
    await makeChannel().handle(value: value, logger: logger)
  }
}

extension MCPHTTP1Channel {
  private func makeChannel() -> HTTP1Channel {
    HTTP1Channel(
      responder: responder,
      configuration: .init(
        idleTimeout: .seconds(15),
        httpDecoderConfiguration: .init(
          maxHeaderFieldSize: 8192, maxHeaderListSize: 16384, maxHeaderFieldCount: 32)))
  }
}
