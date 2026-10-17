import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-917 · Profile screens against a stubbed server (FRD-002 §8, ProfilesAPI.md)
//
// The picker, PIN pad and management screens call only AppState's profile actions and show
// only ProfileText. These tests drive those against a URLProtocol stub that plays the
// server's documented answers, so a wrong PIN, a lockout, a refused fifth profile and a
// deleted remembered profile are each exercised end to end through the real APIClient.
// Expected values are literals taken from the spec, never recomputed from production code.

/// A server for `profiles.stub.test` only: every other host falls through to the network, so
/// registering it process-wide cannot disturb other suites.
nonisolated final class ProfileStubServer: URLProtocol, @unchecked Sendable {
  enum Reply {
    case json(Int, String)
    case unreachable
  }
  struct Recorded: Equatable {
    let method: String
    let path: String
    let body: String
    let profileHeader: String?
  }

  static let host = "profiles.stub.test"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var routes: [String: Reply] = [:]
  nonisolated(unsafe) private static var log: [Recorded] = []
  static let registered: Bool = {
    URLProtocol.registerClass(ProfileStubServer.self)
    return true
  }()

  /// Replaces every route and the request log. Keys are "METHOD /api/v1/path".
  static func reset(_ newRoutes: [String: Reply]) {
    _ = registered
    lock.lock(); defer { lock.unlock() }
    routes = newRoutes
    log = []
  }
  static var requests: [Recorded] {
    lock.lock(); defer { lock.unlock() }
    return log
  }
  /// Requests whose "METHOD path" equals `key`.
  static func count(_ key: String) -> Int {
    requests.filter { "\($0.method) \($0.path)" == key }.count
  }

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let req = request
    var body = ""
    if let stream = req.httpBodyStream {
      stream.open()
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
      }
      stream.close()
      body = String(decoding: data, as: UTF8.self)
    } else if let data = req.httpBody {
      body = String(decoding: data, as: UTF8.self)
    }
    let method = req.httpMethod ?? "GET"
    let path = req.url?.path ?? ""
    let reply: Reply
    Self.lock.lock()
    Self.log.append(Recorded(method: method, path: path, body: body,
                             profileHeader: req.value(forHTTPHeaderField: "X-DSVideo-Profile")))
    reply = Self.routes["\(method) \(path)"] ?? .json(404, #"{"error":"not_found"}"#)
    Self.lock.unlock()

    switch reply {
    case .unreachable:
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    case .json(let status, let text):
      let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                     headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(text.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}

@Suite("Profile screens against a stubbed server", .serialized)
@MainActor
struct ProfileScreensServerTests {
  // The account the stub serves: an owner with a PIN, a kid, and a teen with a PIN.
  private let ryan = #"{"id":"pf_ryan","name":"Ryan","avatar":"moon","maxAgeLevel":4,"hasPin":true,"isOwner":true}"#
  private let maya = #"{"id":"pf_maya","name":"Maya","avatar":"cat","maxAgeLevel":2,"hasPin":false,"isOwner":false}"#
  private let leo = #"{"id":"pf_leo","name":"Leo","avatar":"bolt","maxAgeLevel":3,"hasPin":true,"isOwner":false}"#
  private let zed = #"{"id":"pf_zed","name":"Zed","avatar":"fox","maxAgeLevel":1,"hasPin":false,"isOwner":false}"#

  private func list(_ profiles: [String], max: Int = 4) -> ProfileStubServer.Reply {
    .json(200, #"{"maxProfiles":\#(max),"activeProfileId":null,"profiles":[\#(profiles.joined(separator: ","))]}"#)
  }
  private func profile(_ id: String, _ name: String, hasPin: Bool = false, owner: Bool = false,
                       level: Int = 2) -> Profile {
    Profile(id: id, name: name, avatar: "cat", maxAgeLevel: level, hasPin: hasPin, isOwner: owner)
  }

  /// Runs `body` with a signed-in AppState pointed at the stub, then puts back every shared
  /// store it touched (active profile, cached list, LocalStore scope, address, Remember Me).
  ///
  /// Holds ProfileStateGate for the whole run: the stub's routes, ActiveProfileStore.shared and
  /// LocalStore.shared's scope are process-wide, and ProfileScopeFixTests uses them too.
  /// Internal (not private) so that suite can borrow it.
  func withAccount(
    cached: [Profile] = [], active: Profile? = nil,
    routes: [String: ProfileStubServer.Reply],
    _ body: (AppState) async -> Void
  ) async {
    await ProfileStateGate.shared.run {
      await runAccount(cached: cached, active: active, routes: routes, body)
    }
  }

  private func runAccount(
    cached: [Profile], active: Profile?,
    routes: [String: ProfileStubServer.Reply],
    _ body: (AppState) async -> Void
  ) async {
    let store = ActiveProfileStore.shared
    let savedActiveID = store.activeProfileID
    let savedCache = store.cachedProfiles
    let savedLevel = store.unrestrictedLevel
    let savedScope = await LocalStore.shared.activeScope
    let savedActiveProfile = savedCache.first { $0.id == savedActiveID }
    let state = AppState()
    let savedBase = state.baseURL, savedHTTPS = state.useHTTPS, savedRemember = state.rememberMe

    ProfileStubServer.reset(routes)
    store.setCachedProfiles(cached)
    store.setActive(active)
    state.rememberMe = false            // never write the stub token to the Keychain
    state.useHTTPS = false
    state.baseURL = ProfileStubServer.host
    state.sessionToken = "stub-token"
    await body(state)

    store.setActive(savedActiveProfile)
    store.setCachedProfiles(savedCache, unrestrictedLevel: savedLevel)
    await LocalStore.shared.setActiveProfile(savedScope)
    state.baseURL = savedBase
    state.useHTTPS = savedHTTPS
    state.rememberMe = savedRemember
  }

  private func failureMessage(_ result: Result<Void, Error>) -> String? {
    if case .failure(let error) = result { return ProfileText.pinFailure(error) }
    return nil
  }

  // MARK: AC-002-41 · wrong PIN, lockout, unreachable NAS

  /// OC: AC-002-41 · given Leo is PIN-protected and the server answers pin_incorrect with 3
  /// tries left, when the PIN is verified, then the pad says wrong PIN with the count.
  /// Red if: the attemptsRemaining decode, the wording, or the verify path is broken.
  @Test func wrongPinNamesTheTriesLeft() async {
    await withAccount(routes: [
      "POST /api/v1/profiles/pf_leo/pin/verify":
        .json(403, #"{"error":"pin_incorrect","attemptsRemaining":3}"#)
    ]) { state in
      let result = await state.verifyProfilePin(profile("pf_leo", "Leo", hasPin: true), pin: "1111")
      #expect(failureMessage(result) == "Incorrect PIN. 3 tries left before this profile locks.")
      let sent = ProfileStubServer.requests
      #expect(sent.count == 1, "exactly one verify call, never a silent retry (FR-215)")
      #expect(sent.first?.body == #"{"pin":"1111"}"#)
      #expect(sent.first?.profileHeader == nil, "profile routes send no X-DSVideo-Profile")
    }
  }

  /// OC: AC-002-41 · boundary tries: 1 left, 0 left, and a body with no count.
  /// Red if: singular/zero handling or the missing-count fallback regresses.
  @Test(arguments: [
    (#"{"error":"pin_incorrect","attemptsRemaining":1}"#,
     "Incorrect PIN. 1 try left before this profile locks."),
    (#"{"error":"pin_incorrect","attemptsRemaining":0}"#,
     "Incorrect PIN. No tries left, so PIN entry for this profile is locked for a while."),
    (#"{"error":"pin_incorrect"}"#, "Incorrect PIN."),
  ])
  func wrongPinBoundaries(body: String, expected: String) async {
    await withAccount(routes: ["POST /api/v1/profiles/pf_leo/pin/verify": .json(403, body)]) { state in
      let result = await state.verifyProfilePin(profile("pf_leo", "Leo", hasPin: true), pin: "2222")
      #expect(failureMessage(result) == expected)
    }
  }

  /// OC: AC-002-41 · given 5 failures, the server answers 429 pin_locked with 300 s; the pad
  /// shows the time remaining and does not claim a wrong PIN.
  /// Red if: retryAfterSeconds is not decoded or the minutes conversion changes.
  @Test func lockoutShowsTimeRemaining() async {
    await withAccount(routes: [
      "POST /api/v1/profiles/pf_leo/pin/verify":
        .json(429, #"{"error":"pin_locked","retryAfterSeconds":300}"#)
    ]) { state in
      let result = await state.verifyProfilePin(profile("pf_leo", "Leo", hasPin: true), pin: "3333")
      #expect(failureMessage(result) == "Too many incorrect PINs. Try again in 5 minutes.")
    }
  }

  /// OC: AC-002-41 · lockout boundaries: 1 s, 45 s, 60 s, 61 s (rounds UP, never promising an
  /// early unlock), 3600 s cap, and 0 / missing (no number invented).
  @Test(arguments: [
    (1, "Too many incorrect PINs. Try again in 1 second."),
    (45, "Too many incorrect PINs. Try again in 45 seconds."),
    (60, "Too many incorrect PINs. Try again in 1 minute."),
    (61, "Too many incorrect PINs. Try again in 2 minutes."),
    (3600, "Too many incorrect PINs. Try again in 60 minutes."),
    (0, "Too many incorrect PINs. Wait a few minutes and try again."),
  ])
  func lockoutBoundaries(seconds: Int, expected: String) async {
    await withAccount(routes: [
      "POST /api/v1/profiles/pf_leo/pin/verify":
        .json(429, #"{"error":"pin_locked","retryAfterSeconds":\#(seconds)}"#)
    ]) { state in
      let result = await state.verifyProfilePin(profile("pf_leo", "Leo", hasPin: true), pin: "4444")
      #expect(failureMessage(result) == expected)
    }
  }

  /// OC: AC-002-41 · an unreachable NAS is named as the cause, never reported as a wrong PIN.
  /// Red if: a transport failure is mapped to pin_incorrect wording.
  @Test func unreachableNasIsNamedNotBlamedOnThePin() async {
    await withAccount(routes: ["POST /api/v1/profiles/pf_leo/pin/verify": .unreachable]) { state in
      let result = await state.verifyProfilePin(profile("pf_leo", "Leo", hasPin: true), pin: "5555")
      #expect(failureMessage(result) == "Your NAS needs to be reachable to check this PIN.")
    }
  }

  /// OC: AC-002-41 · the server accepting a PIN is the only success.
  @Test func serverAcceptedPinSucceeds() async {
    await withAccount(routes: ["POST /api/v1/profiles/pf_leo/pin/verify": .json(200, #"{"ok":true}"#)]) { state in
      let result = await state.verifyProfilePin(profile("pf_leo", "Leo", hasPin: true), pin: "0420")
      if case .failure = result { Issue.record("accepted PIN reported as failure") }
      #expect(ProfileStubServer.requests.map(\.body) == [#"{"pin":"0420"}"#])
    }
  }

  // MARK: FR-266 · owner PIN gates management

  /// OC: AC-002-41 / FR-266 · given no (or a wrong) owner PIN, the server refuses a create with
  /// owner_pin_required; the message tells the user, and the list is NOT refreshed or changed.
  /// Red if: a refused create is treated as success, or refreshes/overwrites the list.
  @Test func createWithoutOwnerPinIsRefusedAndChangesNothing() async {
    let existing = [profile("pf_ryan", "Ryan", hasPin: true, owner: true, level: 4),
                    profile("pf_maya", "Maya")]
    await withAccount(cached: existing, routes: [
      "POST /api/v1/profiles": .json(403, #"{"error":"owner_pin_required"}"#)
    ]) { state in
      let result = await state.createProfile(ownerPin: "", name: "Zed", avatar: "fox",
                                             maxAgeLevel: 1, pin: nil)
      guard case .failure(let error) = result else { Issue.record("refused create reported success"); return }
      #expect(ProfileText.saveFailure(error) == "Enter the owner's PIN to manage profiles.")
      #expect(ProfileStubServer.count("GET /api/v1/profiles") == 0, "no refresh after a refusal")
      #expect(state.profiles.map(\.id) == ["pf_ryan", "pf_maya"], "list untouched")
      #expect(ProfileStubServer.requests.first?.body.contains(#""ownerPin":"""#) == true,
              "the owner PIN field is always sent")
    }
  }

  /// OC: FR-266 · a wrong owner PIN on a create reports the tries left, not a generic failure.
  @Test func wrongOwnerPinOnCreateSaysSo() async {
    await withAccount(routes: [
      "POST /api/v1/profiles": .json(403, #"{"error":"pin_incorrect","attemptsRemaining":4}"#)
    ]) { state in
      let result = await state.createProfile(ownerPin: "9999", name: "Zed", avatar: "fox",
                                             maxAgeLevel: 1, pin: nil)
      guard case .failure(let error) = result else { Issue.record("expected failure"); return }
      #expect(ProfileText.saveFailure(error) == "Incorrect PIN. 4 tries left before this profile locks.")
    }
  }

  /// OC: FR-211 · a create with the right owner PIN sends it, then re-reads the list so the
  /// new profile is shown from the server's answer (count 2 -> 3, existing ids stable).
  @Test func createWithOwnerPinAddsAndRefreshesFromServer() async {
    await withAccount(routes: [
      "POST /api/v1/profiles": .json(201, zed),
      "GET /api/v1/profiles": list([ryan, maya, zed]),
    ]) { state in
      let result = await state.createProfile(ownerPin: "0420", name: "Zed", avatar: "fox",
                                             maxAgeLevel: 1, pin: nil)
      guard case .success(let created) = result else { Issue.record("expected success"); return }
      #expect(created.id == "pf_zed")
      #expect(state.profiles.map(\.id) == ["pf_ryan", "pf_maya", "pf_zed"])
      let post = ProfileStubServer.requests.first { $0.method == "POST" }
      #expect(post?.body.contains(#""ownerPin":"0420""#) == true)
      #expect(post?.body.contains(#""pin":null"#) == true, "no PIN is sent as an explicit null")
    }
  }

  // MARK: FR-206 / AC-002-46 · delete with confirmation

  /// OC: AC-002-46 · the confirmation names exactly what is lost.
  /// Red if: the wording drops history, watchlist, permanence or the name.
  @Test func deleteConfirmationNamesWhatIsLost() {
    #expect(ProfileText.deleteConfirmation(name: "Maya")
      == "Maya's watch history, progress and watchlist will be permanently deleted. "
       + "Your videos and other profiles are not affected. This can't be undone.")
  }

  /// OC: FR-206 · a confirmed delete sends the owner PIN in the body, then the refreshed list
  /// has one fewer profile: the target is gone and both survivors remain, by id.
  /// Red if: the wrong id is deleted, the PIN is omitted, or the list is not re-read.
  @Test func deleteRemovesOnlyTheTargetAndRefreshes() async {
    let before = [profile("pf_ryan", "Ryan", hasPin: true, owner: true, level: 4),
                  profile("pf_maya", "Maya"), profile("pf_leo", "Leo", hasPin: true, level: 3)]
    await withAccount(cached: before, routes: [
      "DELETE /api/v1/profiles/pf_maya": .json(200, #"{"ok":true}"#),
      "GET /api/v1/profiles": list([ryan, leo]),
    ]) { state in
      #expect(state.profiles.count == 3, "precondition")
      let result = await state.deleteProfile(id: "pf_maya", ownerPin: "0420")
      if case .failure = result { Issue.record("delete reported failure") }
      #expect(state.profiles.map(\.id) == ["pf_ryan", "pf_leo"])
      #expect(ProfileStubServer.requests.first { $0.method == "DELETE" }?.body == #"{"ownerPin":"0420"}"#)
      #expect(ProfileStubServer.count("DELETE /api/v1/profiles/pf_maya") == 1)
    }
  }

  /// OC: FR-206 · a delete the server refuses (wrong owner PIN) leaves all three profiles and
  /// does not re-read the list. Red if a failure is treated as a deletion.
  @Test func refusedDeleteLeavesEveryProfile() async {
    let before = [profile("pf_ryan", "Ryan", hasPin: true, owner: true, level: 4),
                  profile("pf_maya", "Maya"), profile("pf_leo", "Leo", hasPin: true, level: 3)]
    await withAccount(cached: before, routes: [
      "DELETE /api/v1/profiles/pf_maya": .json(403, #"{"error":"pin_incorrect","attemptsRemaining":2}"#)
    ]) { state in
      let result = await state.deleteProfile(id: "pf_maya", ownerPin: "0000")
      guard case .failure(let error) = result else { Issue.record("expected failure"); return }
      #expect(ProfileText.saveFailure(error) == "Incorrect PIN. 2 tries left before this profile locks.")
      #expect(state.profiles.map(\.id) == ["pf_ryan", "pf_maya", "pf_leo"])
      #expect(ProfileStubServer.count("GET /api/v1/profiles") == 0)
    }
  }

  /// OC: FR-206 · the owner profile cannot be deleted; the server's refusal is explained.
  @Test func ownerProfileDeleteIsExplained() async {
    await withAccount(routes: [
      "DELETE /api/v1/profiles/pf_ryan": .json(409, #"{"error":"owner_profile_immutable"}"#)
    ]) { state in
      let result = await state.deleteProfile(id: "pf_ryan", ownerPin: "0420")
      guard case .failure(let error) = result else { Issue.record("expected failure"); return }
      #expect(ProfileText.saveFailure(error)
        == "The owner profile can't be deleted or given an age limit, and keeps its PIN while other profiles exist.")
    }
  }

  // MARK: FR-203 · the fifth profile

  /// OC: AC-002-40 (picker offers Add up to 4) · 0/1/max-1/max/max+1 profiles against a limit
  /// of 4: Add is offered below the limit and withdrawn at it and past it.
  /// Red if: the comparison becomes <=, or the limit stops coming from the server list.
  @Test(arguments: [(1, true), (3, true), (4, false), (5, false)])
  func addIsOfferedOnlyBelowTheLimit(count: Int, offered: Bool) async {
    let ids = ["pf_ryan", "pf_maya", "pf_leo", "pf_zed", "pf_extra"]
    let raw = [ryan, maya, leo, zed,
               #"{"id":"pf_extra","name":"Extra","avatar":"owl","maxAgeLevel":1,"hasPin":false,"isOwner":false}"#]
    await withAccount(routes: ["GET /api/v1/profiles": list(Array(raw.prefix(count)), max: 4)]) { state in
      await state.refreshProfiles()
      #expect(state.profiles.map(\.id) == Array(ids.prefix(count)))
      #expect(state.maxProfiles == 4)
      #expect(state.canAddProfile == offered)
    }
  }

  /// OC: FR-203 · with 4 profiles a create that reaches the server is refused with
  /// profile_limit_reached; the user is told, and the list stays at 4.
  @Test func fifthProfileIsRefusedByTheServer() async {
    await withAccount(routes: [
      "GET /api/v1/profiles": list([ryan, maya, leo, zed]),
      "POST /api/v1/profiles": .json(409, #"{"error":"profile_limit_reached"}"#),
    ]) { state in
      await state.refreshProfiles()
      #expect(state.profiles.count == 4)
      let result = await state.createProfile(ownerPin: "0420", name: "Fifth", avatar: "owl",
                                             maxAgeLevel: 1, pin: nil)
      guard case .failure(let error) = result else { Issue.record("fifth profile accepted"); return }
      #expect(ProfileText.saveFailure(error)
        == "This account already has the most profiles allowed. Delete one to add another.")
      #expect(state.profiles.count == 4)
      #expect(!state.canAddProfile)
    }
  }

  // MARK: AC-002-40 / 40a · picker routing from a fresh list (iOS target)

  /// OC: AC-002-40a · a remembered profile that the server no longer lists (deleted on another
  /// device) is dropped and the picker returns; LocalStore reads fall to the UNCHOSEN scope
  /// (TASK-936: fail closed at the most restricted cached ceiling, never the legacy scope the
  /// owner claims from).
  /// Red if: refreshProfiles keeps the dead id active or leaves needsProfilePicker false, or
  /// drops back to the legacy scope (isLegacy, ceiling 4, a header-less guess) instead of
  /// the unchosen one.
  @Test func deletedRememberedProfileBringsThePickerBack() async {
    let leoP = profile("pf_leo", "Leo", hasPin: true, level: 3)
    await withAccount(
      cached: [profile("pf_ryan", "Ryan", hasPin: true, owner: true, level: 4), leoP],
      active: leoP,
      routes: ["GET /api/v1/profiles": list([ryan, maya])]
    ) { state in
      #expect(!state.needsProfilePicker, "precondition: Leo is remembered, picker closed")
      await state.refreshProfiles()
      #expect(ActiveProfileStore.shared.activeProfileID == nil)
      #expect(state.needsProfilePicker)
      #expect(state.profiles.map(\.id) == ["pf_ryan", "pf_maya"])
      // The fresh list is Ryan (4) and Maya (2): the unchosen ceiling is the lowest, 2.
      let scope = await LocalStore.shared.activeScope
      #expect(scope.isUnchosen, "no stale kid scope left behind, and not legacy")
      #expect(scope.isLegacy == false)
      #expect(scope.headerValue == nil)
      #expect(scope.maxAgeLevel == 2)
    }
  }

  /// OC: AC-002-40a · negative: a remembered profile that is still listed opens straight in
  /// with no picker (iOS), and stays active. Red if the picker always shows.
  @Test func rememberedProfileStillListedSkipsThePicker() async {
    let mayaP = profile("pf_maya", "Maya")
    await withAccount(
      cached: [profile("pf_ryan", "Ryan", hasPin: true, owner: true, level: 4), mayaP],
      active: mayaP,
      routes: ["GET /api/v1/profiles": list([ryan, maya])]
    ) { state in
      await state.refreshProfiles()
      #expect(ActiveProfileStore.shared.activeProfileID == "pf_maya")
      #expect(!state.needsProfilePicker)
    }
  }

  /// OC: AC-002-40 · a multi-profile account with nothing remembered shows the picker.
  @Test func multiProfileAccountWithNoActiveProfileShowsThePicker() async {
    await withAccount(routes: ["GET /api/v1/profiles": list([ryan, maya])]) { state in
      await state.refreshProfiles()
      #expect(ActiveProfileStore.shared.activeProfileID == nil)
      #expect(state.needsProfilePicker)
    }
  }

  /// OC: AC-002-40 · given a single-profile account, the app enters its only profile and never
  /// shows the picker. Red if the owner is not auto-entered or the picker flag is raised.
  @Test func singleProfileAccountSkipsThePicker() async {
    await withAccount(routes: [
      "GET /api/v1/profiles": list([ryan], max: 4)
    ]) { state in
      await state.refreshProfiles()
      #expect(ActiveProfileStore.shared.activeProfileID == "pf_ryan")
      #expect(await LocalStore.shared.activeScope.id == "pf_ryan")
      #expect(!state.needsProfilePicker)
    }
  }

  /// OC: AC-002-40 · a deleted-down-to-one account: the remembered profile is gone, the one
  /// that remains is entered, and the picker does not appear.
  @Test func accountDownToOneProfileAutoEntersIt() async {
    let leoP = profile("pf_leo", "Leo", hasPin: true, level: 3)
    await withAccount(
      cached: [profile("pf_ryan", "Ryan", hasPin: true, owner: true, level: 4), leoP],
      active: leoP,
      routes: ["GET /api/v1/profiles": list([ryan])]
    ) { state in
      await state.refreshProfiles()
      #expect(ActiveProfileStore.shared.activeProfileID == "pf_ryan")
      #expect(!state.needsProfilePicker)
    }
  }
}
