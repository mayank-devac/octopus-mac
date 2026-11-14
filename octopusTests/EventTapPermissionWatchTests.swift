import Testing
@testable import octopus

@MainActor
struct EventTapPermissionWatchTests {
    @Test func removesTheTapAndRecoversOnceAndOnlyAfterTrustIsLost() {
        var trusted = true
        var revoked = 0
        var recovered = 0
        let watch = EventTapPermissionWatch(isTrusted: { trusted }, recover: { recovered += 1 })
        watch.start { revoked += 1 }

        watch.check()
        #expect(revoked == 0)
        #expect(recovered == 0)

        trusted = false
        watch.check()
        watch.check()
        #expect(revoked == 1)
        #expect(recovered == 1)
    }
}
