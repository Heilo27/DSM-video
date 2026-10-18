import Foundation
import Testing
@testable import DSM_Video

// MARK: - The profile-name rule against the server's vector (TASK-1023 · FRD-002 FR-203)
//
// docs/test-vectors/profile-name.json is asserted here AND by the Go server
// (backend/cmd/dsvideo-backend/profiles_name_vector_test.go). The server trims with
// strings.TrimSpace; Foundation's `.whitespacesAndNewlines` also trims U+200B (zero-width space), so a
// name wrapped in it was counted short here and long there. Add a case to the vector, never to one side.

struct ProfileNameVectorTests {

  private struct Vector: Decodable {
    struct Case: Decodable {
      let label: String
      let raw: String
      let trimmed: String
      let valid: Bool
    }
    let maxLength: Int
    let cases: [Case]
  }

  private static let vectorURL: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()           // DS Video cloneTests
    .deletingLastPathComponent()           // DS Video clone
    .deletingLastPathComponent()           // repository root
    .appendingPathComponent("docs/test-vectors/profile-name.json")

  private func loadVector() throws -> Vector {
    try JSONDecoder().decode(Vector.self, from: Data(contentsOf: Self.vectorURL))
  }

  @Test func theLimitIsTheVectorsLimit() throws {
    #expect(try loadVector().maxLength == ProfileNameRules.maxLength)
  }

  @Test func trimmedIsExactlyWhatTheServerKeeps() throws {
    let vector = try loadVector()
    #expect(!vector.cases.isEmpty)
    for c in vector.cases {
      #expect(ProfileNameRules.trimmed(c.raw) == c.trimmed, "\(c.label)")
    }
  }

  @Test func validityIsExactlyWhatTheServerDecides() throws {
    for c in try loadVector().cases {
      #expect(ProfileNameRules.isValid(c.raw) == c.valid, "\(c.label)")
    }
  }
}
