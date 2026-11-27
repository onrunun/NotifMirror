@testable import NotifMirror
import XCTest

final class FileTransferSanitizationTests: XCTestCase {

    @MainActor
    func testTraversalAndSpecialFilenamesAreSanitized() {
        XCTAssertEqual(FileTransferCenter.sanitizeFileName("../../.zshrc"), "zshrc")
        XCTAssertEqual(FileTransferCenter.sanitizeFileName("..\\..\\evil.sh"), "evil.sh")
        XCTAssertEqual(FileTransferCenter.sanitizeFileName("/etc/passwd"), "passwd")
        XCTAssertEqual(FileTransferCenter.sanitizeFileName(".."), "file.bin")
        XCTAssertEqual(FileTransferCenter.sanitizeFileName("."), "file.bin")
        XCTAssertEqual(FileTransferCenter.sanitizeFileName("   "), "file.bin")
        XCTAssertEqual(FileTransferCenter.sanitizeFileName(".hidden"), "hidden")
        XCTAssertEqual(FileTransferCenter.sanitizeFileName("report:2026\0.pdf"), "report_2026_.pdf")
        XCTAssertEqual(FileTransferCenter.sanitizeFileName("Fatura 2026.pdf"), "Fatura 2026.pdf")
    }

    @MainActor
    func testUniqueDestinationNeverEscapesInbox() {
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("notifmirror-test-\(UUID().uuidString)", isDirectory: true)
        let prefix = inbox.standardizedFileURL.path + "/"

        let candidates = ["../../.zshrc", "../outside.txt", "/tmp/hijack", "..\\win.bat", "safe.png"]
        for raw in candidates {
            let dest = FileTransferCenter.uniqueDestination(in: inbox, name: raw)
            XCTAssertTrue(
                dest.standardizedFileURL.path.hasPrefix(prefix),
                "Destination escaped inbox for input '\(raw)': \(dest.path)"
            )
        }
    }
}
