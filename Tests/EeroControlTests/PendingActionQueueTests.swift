import XCTest
@testable import EeroControl

final class PendingActionQueueTests: XCTestCase {
    func testEnqueueAndRemove() async {
        let fileName = "queued-actions-test-\(UUID().uuidString).json"
        let queue = PendingActionQueue(fileName: fileName)

        let action = EeroAction(
            kind: .setGuestNetwork,
            networkID: "network-1",
            endpoint: "/2.2/networks/network-1/guestnetwork",
            method: .put,
            payload: ["enabled": .bool(true)],
            label: "Toggle guest network",
            riskLevel: .low,
            queueEligible: true
        )

        await queue.enqueue(action)
        let all = await queue.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.action.networkID, "network-1")

        await queue.remove(id: action.id)
        let removed = await queue.all()
        XCTAssertTrue(removed.isEmpty)
    }
}
