import XCTest
import SquirrelCore
@testable import Squirrel

final class ConnectionEditorTests: XCTestCase {
    @MainActor
    func testProbeDoesNotSaveAndSavePreservesDeviceIdentityAndPresentation() async throws {
        let fixture = try EditorFixture()
        defer { fixture.cleanUp() }
        let original = fixture.device
        fixture.credentials.setPassword("old-secret", forAccount: original.keychainAccount)
        var saves = 0
        let editor = ConnectionEditorModel(device: original, settings: fixture.settings, probe: { configuration in
            XCTAssertEqual(configuration.host, "new.local")
            return [fixture.candidate]
        }, onSave: { saves += 1 })
        editor.host = " new.local "
        editor.password = "new-secret"
        XCTAssertFalse(editor.canSave)
        await editor.testConnection()
        XCTAssertTrue(editor.canSave)
        XCTAssertEqual(fixture.settings.device(id: original.id), original)
        XCTAssertEqual(fixture.credentials.password(forAccount: original.keychainAccount), "old-secret")
        // A concurrent rename/picture/role change must survive the connection edit.
        var renamed = original
        renamed.displayName = "Renamed while editing"
        renamed.illustrationOverride = "rack"
        renamed.publishesToSystem = true
        fixture.settings.upsert(renamed)
        XCTAssertTrue(editor.save())
        let saved = try XCTUnwrap(fixture.settings.device(id: original.id))
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.displayName, renamed.displayName)
        XCTAssertEqual(saved.illustrationOverride, renamed.illustrationOverride)
        XCTAssertTrue(saved.publishesToSystem)
        XCTAssertEqual(saved.pollInterval, original.pollInterval)
        XCTAssertEqual(saved.host, "new.local")
        XCTAssertEqual(fixture.credentials.password(forAccount: saved.keychainAccount), "new-secret")
        XCTAssertNil(fixture.credentials.password(forAccount: original.keychainAccount))
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(fixture.settings.devices.count, 1)
    }

    @MainActor
    func testFailureAndFieldEditsCannotSaveAnUntestedDraft() async throws {
        let fixture = try EditorFixture()
        defer { fixture.cleanUp() }
        let failed = ConnectionEditorModel(device: fixture.device, settings: fixture.settings, probe: { _ in throw NUTError.accessDenied })
        failed.host = "new.local"
        await failed.testConnection()
        XCTAssertFalse(failed.canSave)
        XCTAssertFalse(failed.save())
        XCTAssertNotNil(failed.error)
        let editor = ConnectionEditorModel(device: fixture.device, settings: fixture.settings, probe: { _ in [fixture.candidate] })
        editor.host = "new.local"
        await editor.testConnection()
        XCTAssertTrue(editor.canSave)
        editor.password = "changed after testing"
        XCTAssertFalse(editor.canSave)
        XCTAssertFalse(editor.hasTested)
        XCTAssertEqual(fixture.settings.device(id: fixture.device.id), fixture.device)
    }

    @MainActor
    func testMissingConfiguredUPSRequiresExplicitSelectionAndAReading() async throws {
        let fixture = try EditorFixture()
        defer { fixture.cleanUp() }
        let another = UPSCandidate(name: "other", serverDescription: nil, reading: fixture.candidate.reading)
        let unavailable = UPSCandidate(name: "offline", serverDescription: nil, reading: nil)
        let editor = ConnectionEditorModel(device: fixture.device, settings: fixture.settings, probe: { _ in [another, unavailable] })
        await editor.testConnection()
        XCTAssertNil(editor.selectedUPSName)
        XCTAssertFalse(editor.canSave)
        editor.selectedUPSName = "offline"
        XCTAssertFalse(editor.canSave)
        editor.selectedUPSName = "other"
        XCTAssertTrue(editor.canSave)
    }

    @MainActor
    func testSingleUPSIsSelectedAutomaticallyButStillNeedsAReadingToSave() async throws {
        let fixture = try EditorFixture()
        defer { fixture.cleanUp() }
        for readable in [false, true] {
            let sole = UPSCandidate(name: "only-ups", serverDescription: nil, reading: readable ? fixture.candidate.reading : nil)
            let editor = ConnectionEditorModel(device: fixture.device, settings: fixture.settings, probe: { _ in [sole] })
            await editor.testConnection()
            XCTAssertEqual(editor.selectedUPSName, "only-ups")
            XCTAssertEqual(editor.canSave, readable)
            // Testing alone must not change the saved target.
            XCTAssertEqual(fixture.settings.device(id: fixture.device.id)?.upsName, "rack")
        }
    }

    @MainActor
    func testLateResultAfterEditOrCancelCannotEnableSave() async throws {
        let fixture = try EditorFixture()
        defer { fixture.cleanUp() }
        for cancel in [false, true] {
            var pending: CheckedContinuation<[UPSCandidate], Error>?
            let editor = ConnectionEditorModel(device: fixture.device, settings: fixture.settings, probe: { _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            })
            editor.host = "new.local"
            let task = Task { await editor.testConnection() }
            while pending == nil { await Task.yield() }
            if cancel { editor.cancel() } else { editor.host = "different.local" }
            pending?.resume(returning: [fixture.candidate])
            await task.value
            XCTAssertFalse(editor.canSave)
            XCTAssertFalse(editor.hasTested)
            XCTAssertEqual(fixture.settings.device(id: fixture.device.id), fixture.device)
        }
    }

    @MainActor
    func testInvalidFieldsUnchangedConnectionAndEmptyServer() async throws {
        let fixture = try EditorFixture()
        defer { fixture.cleanUp() }
        let editor = ConnectionEditorModel(device: fixture.device, settings: fixture.settings, probe: { _ in [fixture.candidate] })
        await editor.testConnection()
        XCTAssertFalse(editor.canSave)
        editor.port = "65536"
        await editor.testConnection()
        XCTAssertNotNil(editor.error)
        XCTAssertFalse(editor.canSave)
        editor.port = "0"
        XCTAssertNil(editor.configuration)
        editor.port = "3493"
        editor.host = "   "
        await editor.testConnection()
        XCTAssertNotNil(editor.error)
        let empty = ConnectionEditorModel(device: fixture.device, settings: fixture.settings, probe: { _ in [] })
        empty.host = "empty.local"
        await empty.testConnection()
        XCTAssertNotNil(empty.error)
        XCTAssertFalse(empty.canSave)
    }

    @MainActor
    func testRemovedChangedAndDuplicateDevicesRejectSave() async throws {
        for mode in ["removed", "changed", "duplicate"] {
            let fixture = try EditorFixture()
            defer { fixture.cleanUp() }
            let editor = ConnectionEditorModel(device: fixture.device, settings: fixture.settings, probe: { _ in [fixture.candidate] })
            editor.host = "new.local"
            await editor.testConnection()
            switch mode {
            case "removed": fixture.settings.remove(id: fixture.device.id)
            case "changed":
                var changed = fixture.device
                changed.host = "changed.local"
                fixture.settings.upsert(changed)
            default:
                fixture.settings.upsert(UPSDevice(displayName: "Already here", host: "new.local", upsName: "rack", publishesToSystem: false))
            }
            let before = fixture.settings.devices
            XCTAssertFalse(editor.save())
            XCTAssertNotNil(editor.error)
            XCTAssertEqual(fixture.settings.devices, before)
        }
    }
}

@MainActor
private struct EditorFixture {
    let suite = "SquirrelTests.ConnectionEditor.\(UUID())"
    let defaults: UserDefaults
    let credentials = EditorCredentials()
    let settings: SettingsStore
    let device: UPSDevice
    let candidate = UPSCandidate(name: "rack", serverDescription: nil, reading: UPSReading(upsName: "rack", variables: ["ups.status": "OL"]))

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = SettingsStore(defaults: defaults, credentialStore: credentials)
        device = UPSDevice(displayName: "My UPS", host: "old.local", upsName: "rack", username: "monitor", publishesToSystem: false, pollInterval: 12)
        settings.upsert(device)
    }
    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

private final class EditorCredentials: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func password(forAccount account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }
    func setPassword(_ password: String?, forAccount account: String) {
        lock.lock(); defer { lock.unlock() }
        values[account] = password
    }
}
