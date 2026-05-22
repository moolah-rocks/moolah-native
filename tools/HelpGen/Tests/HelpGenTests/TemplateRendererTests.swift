import Foundation
import Testing

@testable import HelpGen

@Suite("TemplateRenderer")
struct TemplateRendererTests {
  @Test("substitutes a single token")
  func substitutesSingleToken() throws {
    let rendered = try TemplateRenderer.render(
      template: "Hello, {{name}}!",
      tokens: ["name": "world"]
    )
    #expect(rendered == "Hello, world!")
  }

  @Test("substitutes multiple tokens")
  func substitutesMultiple() throws {
    let rendered = try TemplateRenderer.render(
      template: "<title>{{title}}</title><body>{{body}}</body>",
      tokens: ["title": "Welcome", "body": "<p>Hi</p>"]
    )
    #expect(rendered == "<title>Welcome</title><body><p>Hi</p></body>")
  }

  @Test("substitutes the same token multiple times")
  func substitutesRepeated() throws {
    let rendered = try TemplateRenderer.render(
      template: "{{x}}-{{x}}-{{x}}",
      tokens: ["x": "a"]
    )
    #expect(rendered == "a-a-a")
  }

  @Test("throws on unknown token in template")
  func throwsOnUnknownToken() {
    #expect(throws: TemplateRenderer.RenderError.self) {
      try TemplateRenderer.render(
        template: "Hello, {{name}}!",
        tokens: [:]
      )
    }
  }

  @Test("preserves text with no tokens")
  func preservesPlainText() throws {
    let rendered = try TemplateRenderer.render(
      template: "no tokens here",
      tokens: [:]
    )
    #expect(rendered == "no tokens here")
  }

  @Test("preserves unclosed braces verbatim")
  func preservesUnclosedBrace() throws {
    let rendered = try TemplateRenderer.render(
      template: "hello {{ world",
      tokens: [:]
    )
    #expect(rendered == "hello {{ world")
  }
}
