import NIOCore
import NIOHTTP1

/// Runs after NIO's HTTP decoder, before its request-target normalization.
final class MCPRequestTargetGuard: Sendable {}

extension MCPRequestTargetGuard: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if case .head(let head) = unwrapInboundIn(data), head.uri != "/mcp" {
      context.close(promise: nil)
      return
    }
    context.fireChannelRead(data)
  }
}

extension MCPRequestTargetGuard: RemovableChannelHandler {}
