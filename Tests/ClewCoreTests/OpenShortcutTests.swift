import ClewCore
import ClewDomain
import Foundation
import Testing

@Suite struct OpenShortcutTests {
    let store = FakeStore()
    var clew: Clew { Clew(store: store, clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)), zones: FixedZone("UTC")) }

    @Test func commandPeriodIsTheDefaultAndDisplaysAsSuch() {
        #expect(OpenShortcut.default.keyCode == 47)
        #expect(OpenShortcut.default.command)
        #expect(!OpenShortcut.default.shift)
        #expect(!OpenShortcut.default.option)
        #expect(!OpenShortcut.default.control)
        #expect(OpenShortcut.default.glyph == ".")
        #expect(OpenShortcut.default.display == "⌘.")
        #expect(OpenShortcut.default.isAllowed)
    }

    @Test func missingSettingUsesTheDefaultAndItIsSwitchable() throws {
        #expect(try clew.openListShortcut() == .default)
        let other = OpenShortcut(keyCode: 40, command: true, shift: true, option: false, control: false, glyph: "K")
        try clew.setOpenListShortcut(other)
        #expect(try clew.openListShortcut() == other)
        try clew.setOpenListShortcut(nil)
        #expect(try clew.openListShortcut() == nil)
        try clew.setOpenListShortcut(.default)
        #expect(try clew.openListShortcut() == .default)
    }

    @Test func aClearedShortcutStaysCleared() throws {
        try store.write { try $0.saveSetting("openListShortcut", json: "null", updatedAt: Date()) }
        #expect(try clew.openListShortcut() == nil)
    }

    @Test func anUnknownValueFallsBackToTheDefault() throws {
        try store.write { try $0.saveSetting("openListShortcut", json: "\"ring\"", updatedAt: Date()) }
        #expect(try clew.openListShortcut() == .default)
    }

    @Test func aShortcutNeedsAStrongModifierAndMustNotBeReserved() {
        let bare = OpenShortcut(keyCode: 47, command: false, shift: false, option: false, control: false, glyph: ".")
        let shiftOnly = OpenShortcut(keyCode: 47, command: false, shift: true, option: false, control: false, glyph: ".")
        let quit = OpenShortcut(keyCode: 12, command: true, shift: false, option: false, control: false, glyph: "Q")
        let hide = OpenShortcut(keyCode: 4, command: true, shift: false, option: false, control: false, glyph: "H")
        let optionL = OpenShortcut(keyCode: 37, command: false, shift: false, option: true, control: false, glyph: "L")
        #expect(!bare.isAllowed)
        #expect(!shiftOnly.isAllowed)
        #expect(!quit.isAllowed)
        #expect(!hide.isAllowed)
        #expect(optionL.isAllowed)
    }

    @Test func reservedLettersFollowTheGlyphNotTheQWERTYKeyCode() {
        // On Dvorak, Q is hardware key code 7, not ANSI 12.
        let dvorakQuit = OpenShortcut(keyCode: 7, command: true, shift: false, option: false, control: false, glyph: "Q")
        // The ANSI Q key types an apostrophe on Dvorak and must not be treated as Quit.
        let dvorakApostrophe = OpenShortcut(keyCode: 12, command: true, shift: false, option: false, control: false, glyph: "'")
        #expect(!dvorakQuit.isAllowed)
        #expect(dvorakApostrophe.isAllowed)
    }

    @Test func setOpenListShortcutIgnoresADisallowedShortcut() throws {
        try clew.setOpenListShortcut(.default)
        let quit = OpenShortcut(keyCode: 12, command: true, shift: false, option: false, control: false, glyph: "Q")
        try clew.setOpenListShortcut(quit)
        #expect(try clew.openListShortcut() == .default)
    }
}
