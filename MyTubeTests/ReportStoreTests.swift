import XCTest
@testable import MyTube

final class ReportStoreTests: XCTestCase {
    @MainActor
    func testIngestReportStoresOutboundReport() async throws {
        let persistence = PersistenceController(inMemory: true)
        let store = ReportStore(persistence: persistence)
        let now = Date()

        let message = ReportMessage(
            videoId: UUID().uuidString,
            subjectChild: "npubsubjectkey",
            reason: ReportReason.inappropriate.rawValue,
            note: "Inappropriate content",
            by: "npubreporter",
            timestamp: now
        )

        let stored = try await store.ingestReportMessage(
            message,
            isOutbound: true,
            createdAt: now,
            action: .reportOnly
        )

        await store.refresh()

        let reports = store.allReports()
        XCTAssertTrue(reports.contains(where: { $0.id == stored.id }))
        XCTAssertTrue(stored.isOutbound)
        XCTAssertEqual(stored.reason, .inappropriate)
    }
}
