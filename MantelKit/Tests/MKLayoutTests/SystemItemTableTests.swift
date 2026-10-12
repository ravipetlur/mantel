import Testing

@testable import MKLayout

@Suite("System item table", .timeLimit(.minutes(1)))
struct SystemItemTableTests {
    @Test func numbersMatchMeasuredTable() {
        #expect(SystemItemTable.numbers == ["battery": 0, "bluetooth": 1, "clock": 2, "sound": 5, "wifi": 6, "controlcenter": 8])
        #expect(SystemItemTable.number(of: "battery") == 0)
        #expect(SystemItemTable.number(of: "bluetooth") == 1)
        #expect(SystemItemTable.number(of: "clock") == 2)
        #expect(SystemItemTable.number(of: "sound") == 5)
        #expect(SystemItemTable.number(of: "wifi") == 6)
        #expect(SystemItemTable.number(of: "controlcenter") == 8)
        #expect(SystemItemTable.unmovable == ["clock", "controlcenter"])

        #expect(SystemItemTable.title(of: "battery") == "Battery")
        #expect(SystemItemTable.title(of: "bluetooth") == "Bluetooth")
        #expect(SystemItemTable.title(of: "clock") == "Clock")
        #expect(SystemItemTable.title(of: "sound") == "Sound")
        #expect(SystemItemTable.title(of: "wifi") == "Wi-Fi")
        #expect(SystemItemTable.title(of: "controlcenter") == "Control Center")

        // Every module that has a number has a title.
        for module in SystemItemTable.numbers.keys {
            #expect(SystemItemTable.title(of: module) != nil)
        }
        #expect(SystemItemTable.unmovable.isSubset(of: Set(SystemItemTable.numbers.keys)))
    }

    @Test func unknownModuleHasNoNumber() {
        // AirDrop is on the bar but macOS's allowlist has no number for it.
        #expect(SystemItemTable.number(of: "airdrop") == nil)
        #expect(SystemItemTable.title(of: "airdrop") == nil)
        #expect(SystemItemTable.number(of: "") == nil)
        // Modules are spelled as macOS spells them.
        #expect(SystemItemTable.number(of: "WiFi") == nil)
        #expect(SystemItemTable.number(of: "controlCenter") == nil)
    }
}
