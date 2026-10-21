import Foundation
import Hummingbird
import MCP

import struct HTTPTypes.HTTPField

struct MCPHTTPMiddleware {
  let policy: MCPRequestPolicy
  let checkAccess: @Sendable (MCP.HTTPRequest) async -> MCP.HTTPResponse?
  let respond: @Sendable (MCP.HTTPRequest) async throws -> MCP.HTTPResponse
}

extension MCPHTTPMiddleware: RouterMiddleware {
  typealias Context = BasicRequestContext

  func handle(
    _ request: Request,
    context: Context,
    next: (Request, Context) async throws -> Response
  ) async throws -> Response {
    let incoming = makeRequest(request, body: nil)
    if let rejection = policy.rejection(for: incoming) {
      return makeResponse(rejection)
    }
    if let rejection = await checkAccess(incoming) {
      return makeResponse(rejection)
    }
    guard request.method == .post else {
      return Response(status: .methodNotAllowed, headers: [.allow: "POST"])
    }
    do {
      let buffer = try await request.body.collect(upTo: MCPLoopbackHost.maximumBodyBytes)
      let data = Data(buffer.readableBytesView)
      let response = try await respond(makeRequest(request, body: data))
      guard (response.bodyData?.count ?? 0) <= MCPLoopbackHost.maximumBodyBytes else {
        return makeResponse(.error(statusCode: 500, .internalError("Response limit exceeded")))
      }
      return makeResponse(response)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as any HTTPResponseError {
      return Response(status: error.status)
    } catch {
      return makeResponse(.error(statusCode: 500, .internalError("Request failed")))
    }
  }
}

extension MCPHTTPMiddleware {
  private func makeRequest(_ request: Request, body: Data?) -> MCP.HTTPRequest {
    var headers: [String: String] = [:]
    for field in request.headers {
      let name = field.name.canonicalName.lowercased()
      if let existing = headers[name] {
        headers[name] = existing + ", " + field.value
      } else {
        headers[name] = field.value
      }
    }
    if let authority = request.head.authority {
      headers["host"] = headers["host"].map { $0 + ", " + authority } ?? authority
    }
    // The raw-target channel guard rejects absolute-form targets before normalization.
    return MCP.HTTPRequest(
      method: request.method.rawValue,
      headers: headers,
      body: body,
      path: request.uri.string
    )
  }

  private func makeResponse(_ response: MCP.HTTPResponse) -> Response {
    var result = Response(status: .init(code: response.statusCode))
    for (name, value) in response.headers {
      if let field = HTTPField.Name(name) { result.headers[field] = value }
    }
    result.headers[.cacheControl] = "no-store"
    if let data = response.bodyData { result.body = .init(byteBuffer: .init(bytes: data)) }
    return result
  }
}
