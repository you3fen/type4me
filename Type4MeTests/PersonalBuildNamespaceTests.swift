import Foundation
import XCTest
import Type4MeIntelliSenseCore
@testable import Type4Me

final class PersonalBuildNamespaceTests: XCTestCase {
    func testPersonalIdentityIsIndependentOfDataNamespace() {
        #if TYPE4ME_PERSONAL_BUILD
        XCTAssertTrue(AppDataNamespace.isPersonal)
        #else
        XCTAssertFalse(AppDataNamespace.isPersonal)
        #endif
    }

    #if TYPE4ME_PERSONAL_BUILD
    @MainActor
    func testPersonalBuildBlocksUpstreamDownloadAndInstall() throws {
        let release = try JSONDecoder().decode(UpdateInfo.self, from: Data(
            #"{"version":"999.0.0","date":"2099-01-01","notes":"synthetic","cloud_dmg_url":"https://example.invalid/update.dmg"}"#.utf8
        ))
        let downloader = AppUpdater()
        downloader.downloadUpdate(release: release)
        guard case .failed = downloader.state else {
            return XCTFail("Personal builds must reject upstream downloads immediately")
        }
        XCTAssertNil(downloader.downloadedVersion)
        let installer = AppUpdater()
        installer.installAndRestart()
        guard case .failed = installer.state else {
            return XCTFail("Personal builds must reject upstream installation immediately")
        }
    }
    #endif

    func testBuildUsesExpectedDataAndKeychainNamespace() {
        #if TYPE4ME_PERSONAL_BUILD && !TYPE4ME_DEV_BUILD
        let expectedDirectory = "Type4Me Personal"
        XCTAssertEqual(AppDataNamespace.keychainPrefix, "com.you3fen.type4me.personal")
        #else
        let expectedDirectory = "Type4Me"
        XCTAssertEqual(AppDataNamespace.keychainPrefix, "com.type4me")
        #endif
        XCTAssertEqual(AppDataNamespace.directoryName, expectedDirectory)
        let expectedRoot = AppDataLocation.profileDirectory
        XCTAssertEqual(expectedRoot.lastPathComponent, "Type4MeTests")
        XCTAssertEqual(HotwordStorage.userFileURL, expectedRoot.appendingPathComponent("hotwords.json"))
        XCTAssertEqual(SnippetStorage.userFileURL, expectedRoot.appendingPathComponent("snippets.json"))
        XCTAssertEqual(DataBackupManager.dataDirectory, expectedRoot)
        XCTAssertEqual(DataBackupManager.backupRoot, expectedRoot.deletingLastPathComponent()
            .appendingPathComponent("Type4MeTests Backups", isDirectory: true))
    }
}
