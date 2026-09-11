//
//  ServerMasterTests.swift
//  ServerMasterTests
//
//  Created by Heorhii on 28.08.26.
//

import Testing
@testable import ServerMaster

struct ServerMasterTests {

    @Test func versionParserAcceptsTwoAndThreeComponents() {
        #expect(UpdateChecker.parseVersion("2.0") == "2.0")
        #expect(UpdateChecker.parseVersion("2.0.0\n") == "2.0.0")
    }

    @Test func equivalentVersionFormatsDoNotTriggerAnUpdate() {
        #expect(!UpdateChecker.isNewer("2.0.0", than: "2.0"))
        #expect(!UpdateChecker.isNewer("2.0", than: "2.0.0"))
    }

    @Test func threeComponentVersionIsNewerThanVersionOne() {
        #expect(UpdateChecker.isNewer("2.0.0", than: "1.0"))
    }

}
