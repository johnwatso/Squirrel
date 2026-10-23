import XCTest
@testable import Squirrel

final class PowerScheduleTests: XCTestCase {
    @MainActor
    func testReadsSystemPairAndLeavesOneTimeEventsOutsideRecurringRules() throws {
        let text = """
        Repeating power events:
          wakepoweron at 7:00AM weekdays only
          shutdown at 11:00PM every day
        Scheduled power events:
         [0] wake at 10/25/26 12:00:00 by 'com.apple.alarm'
        """
        let rules = try PowerScheduleService.parse(text)
        XCTAssertEqual(rules.map(\.minutes), [420, 1380])
        XCTAssertEqual(try RepeatingPowerSchedule.arguments(for: rules),
                       ["repeat", "wakeorpoweron", "MTWRF", "07:00:00", "shutdown", "MTWRFSU", "23:00:00"])
    }

    @MainActor
    func testCustomDayMaskRequiresMatchingBackingSnapshot() throws {
        let text = "Repeating power events:\n  wake at 0:15AM Some days\n"
        let backing: [String: Any] = ["RepeatingPowerOn": ["eventtype": "wake", "time": 15, "weekdays": 5]]
        let rules = try PowerScheduleService.parse(text, backing: backing)
        XCTAssertEqual(rules.first?.days, 5)
        XCTAssertEqual(rules.first?.dayArguments, "MW")
        XCTAssertThrowsError(try PowerScheduleService.parse(text, backing: [:]))
        XCTAssertThrowsError(try PowerScheduleService.parse(text, backing: ["RepeatingPowerOn": ["eventtype": "wake", "time": 16, "weekdays": 5]]))
    }

    @MainActor
    func testUnknownOutputCannotBeMistakenForAnEmptySystemSchedule() {
        XCTAssertThrowsError(try PowerScheduleService.parse("A future unrecognised schedule format"))
        XCTAssertEqual(try PowerScheduleService.parse("No scheduled events."), [])
    }

    func testCannotCreateCompetingOffRulesOrInvalidCommands() {
        let shutdown = RepeatingPowerSchedule(action: .shutdown, minutes: 1380, days: 127)
        let restart = RepeatingPowerSchedule(action: .restart, minutes: 180, days: 64)
        XCTAssertThrowsError(try RepeatingPowerSchedule.arguments(for: [shutdown, restart]))
        XCTAssertThrowsError(try RepeatingPowerSchedule.arguments(for: [.init(action: .sleep, minutes: -1, days: 127)]))
        XCTAssertThrowsError(try RepeatingPowerSchedule.arguments(for: [.init(action: .wake, minutes: 420, days: 0)]))
    }

    func testDisablingOnlyCancelsRecurringEvents() throws {
        XCTAssertEqual(try RepeatingPowerSchedule.arguments(for: [.init(action: .shutdown, minutes: 1380, days: 127, enabled: false)]), ["repeat", "cancel"])
    }

    @MainActor
    func testProtectionSelectionIsExclusiveAndInvalidSelectionPreservesIt() throws {
        let suite = "SquirrelTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var first = UPSDevice(displayName: "First", host: "localhost", upsName: "first")
        var second = UPSDevice(displayName: "Second", host: "localhost", upsName: "second")
        first.publishesToSystem = true
        second.publishesToSystem = true
        settings.upsert(first)
        settings.upsert(second)
        XCTAssertEqual(settings.devices.filter(\.publishesToSystem).count, 1)
        XCTAssertEqual(settings.systemDevice?.id, second.id)
        settings.setProtectionDevice(first.id)
        XCTAssertEqual(settings.systemDevice?.id, first.id)
        settings.setProtectionDevice(UUID())
        XCTAssertEqual(settings.systemDevice?.id, first.id)
        XCTAssertEqual(settings.devices.count, 2)
    }

    @MainActor
    func testExternalScheduleChangesRejectStaleDraftWithoutWriting() async throws {
        var output = "Repeating power events:\n  wake at 7:00AM weekdays only\n"
        var writes = 0
        let service = PowerScheduleService(reader: { _ in output }, writer: { _, _ in writes += 1 })
        service.refresh()
        let baseline = service.baseline
        let draft = [RepeatingPowerSchedule(action: .wake, minutes: 480, days: 31)]
        output = "Repeating power events:\n  wake at 9:00AM weekdays only\n"
        service.refresh() // An app-activation refresh must not bless a stale draft.
        let saved = await service.apply(draft, expectedBaseline: baseline)
        XCTAssertFalse(saved)
        XCTAssertEqual(writes, 0)
        XCTAssertNotNil(service.lastError)
    }

    @MainActor
    func testReadbackVerifiesSystemPairAndDisabledDraftsSurviveServiceRecreation() async throws {
        let suite = "SquirrelTests.Schedule.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var output = "Repeating power events:\n  wake at 7:00AM weekdays only\n  shutdown at 11:00PM every day\n"
        var received: [String] = []
        let service = PowerScheduleService(defaults: defaults, reader: { _ in output }, writer: { arguments, baseline in
            XCTAssertEqual(baseline, output)
            received = arguments
            output = "Repeating power events:\n  wake at 7:00AM weekdays only\n"
        })
        service.refresh()
        var draft = service.schedules
        draft[1].enabled = false
        let saved = await service.apply(draft, expectedBaseline: service.baseline)
        XCTAssertTrue(saved)
        XCTAssertEqual(received, ["repeat", "wake", "MTWRF", "07:00:00"])
        let reopened = PowerScheduleService(defaults: defaults, reader: { _ in output }, writer: { _, _ in XCTFail("Readback must never write") })
        reopened.refresh()
        XCTAssertEqual(reopened.schedules.count, 2)
        XCTAssertFalse(try XCTUnwrap(reopened.schedules.first { !$0.action.isOn }).enabled)
    }

    func testHistoryDoesNotPresentPreparationAsCompletedShutdown() {
        XCTAssertEqual(PowerEventKind.systemShutdown.title, "Mac preparing to shut down")
        XCTAssertTrue(PowerEventKind.scheduleChanged.provenance.contains("unverified"))
        XCTAssertTrue(PowerEventKind.systemWake.provenance.contains("Cause unverified"))
    }

    func testEditorPreservesOtherSlotAndRejectsConflictingActions() {
        let wake = RepeatingPowerSchedule(action: .wake, minutes: 420, days: 31)
        let sleep = RepeatingPowerSchedule(action: .sleep, minutes: 1380, days: 127)
        let add = ScheduleEditorSession(rule: nil, schedules: [wake], baseline: "snapshot")
        XCTAssertEqual(add.initialRule.action, .sleep)
        XCTAssertFalse(add.allows(.poweron))
        XCTAssertFalse(add.allows(.wakeorpoweron))
        XCTAssertTrue(add.allows(.shutdown))
        let edit = ScheduleEditorSession(rule: sleep, schedules: [wake, sleep], baseline: "snapshot")
        let restart = RepeatingPowerSchedule(action: .restart, minutes: 60, days: 96)
        XCTAssertEqual(edit.replacing(with: restart), [wake, restart])
        XCTAssertFalse(edit.allows(.wake))
        XCTAssertTrue(edit.allows(.restart))
        XCTAssertEqual(ScheduleEditorSession(rule: wake, schedules: [wake], baseline: "").initialRule.action, .wake)
    }

    func testRepeatPresetsAndCustomDaysMapToMacOSWeekdayTokens() throws {
        XCTAssertEqual(ScheduleRepeatPreset.everyDay.days, 127)
        XCTAssertEqual(ScheduleRepeatPreset.weekdays.days, 31)
        XCTAssertEqual(ScheduleRepeatPreset.weekends.days, 96)
        XCTAssertNil(ScheduleRepeatPreset.custom.days)
        XCTAssertEqual(ScheduleRepeatPreset(days: 5), .custom)
        XCTAssertEqual(ScheduleRepeatPreset(days: 31), .weekdays)
        let custom = RepeatingPowerSchedule(action: .wake, minutes: 0, days: 1 | 8 | 64, enabled: false)
        XCTAssertEqual(custom.dayArguments, "MRU")
        XCTAssertEqual(custom.recurrenceText, "Mon, Thu, Sun")
        XCTAssertFalse(custom.timeText.isEmpty)
        XCTAssertEqual(try RepeatingPowerSchedule.arguments(for: [.init(action: .sleep, minutes: 1439, days: 96)]),
                       ["repeat", "sleep", "SU", "23:59:00"])
    }

    @MainActor
    func testDisabledCreateEditAndDeleteStayLocalWithoutAuthorization() async throws {
        let suite = "SquirrelTests.Schedule.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let output = "Repeating power events:\n  wake at 7:00AM weekdays only\n"
        let service = PowerScheduleService(defaults: defaults, reader: { _ in output }, writer: { _, _ in
            XCTFail("Local-only changes must not request administrator privileges")
        })
        service.refresh()
        let wake = try XCTUnwrap(service.schedules.first)
        var disabled = RepeatingPowerSchedule(action: .sleep, minutes: 1380, days: 127, enabled: false)
        var saved = await service.apply([wake, disabled], expectedBaseline: output)
        XCTAssertTrue(saved)
        disabled.minutes = 1320
        saved = await service.apply([disabled, wake], expectedBaseline: output)
        XCTAssertTrue(saved)
        XCTAssertEqual(service.schedules.first { !$0.enabled }?.minutes, 1320)
        saved = await service.apply([wake], expectedBaseline: output)
        XCTAssertTrue(saved)
        service.refresh()
        XCTAssertEqual(service.schedules, [wake])
    }

    @MainActor
    func testFailedReadbackDoesNotCommitDisabledDraftChanges() async throws {
        let suite = "SquirrelTests.Schedule.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let output = "No scheduled events."
        let service = PowerScheduleService(defaults: defaults, reader: { _ in output }, writer: { _, _ in })
        service.refresh()
        let original = RepeatingPowerSchedule(action: .sleep, minutes: 1380, days: 127, enabled: false)
        let firstSave = await service.apply([original], expectedBaseline: output)
        XCTAssertTrue(firstSave)
        let wake = RepeatingPowerSchedule(action: .wake, minutes: 420, days: 31)
        let failedSave = await service.apply([wake], expectedBaseline: output)
        XCTAssertFalse(failedSave)
        XCTAssertNotNil(service.lastError)
        XCTAssertFalse(service.isApplying)
        let reopened = PowerScheduleService(defaults: defaults, reader: { _ in output })
        reopened.refresh()
        XCTAssertEqual(reopened.schedules, [original])
    }

    @MainActor
    func testCancelledAuthorizationKeepsSavedStateAndAllowsRetry() async throws {
        let suite = "SquirrelTests.Schedule.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var output = "No scheduled events."
        var cancel = true
        let service = PowerScheduleService(defaults: defaults, reader: { _ in output }, writer: { _, _ in
            if cancel { throw ScheduleError.authorizationCancelled }
            output = "Repeating power events:\n  wake at 7:00AM weekdays only\n"
        })
        service.refresh()
        let wake = RepeatingPowerSchedule(action: .wake, minutes: 420, days: 31)
        var saved = await service.apply([wake], expectedBaseline: service.baseline)
        XCTAssertFalse(saved)
        XCTAssertEqual(service.schedules, [])
        XCTAssertEqual(service.lastError, ScheduleError.authorizationCancelled.localizedDescription)
        XCTAssertFalse(service.isApplying)
        cancel = false
        saved = await service.apply([wake], expectedBaseline: service.baseline)
        XCTAssertTrue(saved)
        XCTAssertEqual(service.schedules, [wake])
        XCTAssertNil(service.lastError)
    }

    @MainActor
    func testDeletingActiveRulePreservesOtherSystemRule() async throws {
        let suite = "SquirrelTests.Schedule.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var output = "Repeating power events:\n  wake at 7:00AM weekdays only\n  shutdown at 11:00PM every day\n"
        let service = PowerScheduleService(defaults: defaults, reader: { _ in output }, writer: { arguments, _ in
            XCTAssertEqual(arguments, ["repeat", "wake", "MTWRF", "07:00:00"])
            output = "Repeating power events:\n  wake at 7:00AM weekdays only\n"
        })
        service.refresh()
        let wake = try XCTUnwrap(service.schedules.first { $0.action.isOn })
        let saved = await service.apply([wake], expectedBaseline: service.baseline)
        XCTAssertTrue(saved)
        XCTAssertEqual(service.schedules, [wake])
    }

    @MainActor
    func testExternalActiveRuleTakesPrecedenceOverDisabledDraft() async throws {
        let suite = "SquirrelTests.Schedule.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var output = "No scheduled events."
        let service = PowerScheduleService(defaults: defaults, reader: { _ in output })
        service.refresh()
        let disabled = RepeatingPowerSchedule(action: .sleep, minutes: 1380, days: 127, enabled: false)
        let saved = await service.apply([disabled], expectedBaseline: output)
        XCTAssertTrue(saved)
        output = "Repeating power events:\n  restart at 1:00AM weekends only\n"
        service.refresh()
        XCTAssertEqual(service.schedules, [.init(action: .restart, minutes: 60, days: 96)])
    }

}
