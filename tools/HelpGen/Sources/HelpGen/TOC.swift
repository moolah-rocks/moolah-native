import Foundation

struct TOC: Decodable {
  let version: String
  let entries: [Entry]

  struct Entry: Decodable {
    let slug: String
    let title: String
    let parent: String?
  }
}
