import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct SubscriptionSnapshotTests {
    @Test func renewingSubscriptionUsesRenewalDate() throws {
        let value: [String: Any] = [
            "state": "success",
            "email": "owner@example.com",
            "plan": "pro",
            "activeUntil": "2026-09-17T10:30:00Z",
            "willRenew": true,
            "source": "subscription",
        ]
        let snapshot = try SubscriptionSnapshot(javaScriptValue: value)
        #expect(snapshot.planLabel == "pro")
        #expect(snapshot.dateKind == .renews)
        #expect(snapshot.activeUntil != nil)
    }

    @Test func unknownPlanAndMissingDateArePreserved() throws {
        let snapshot = try SubscriptionSnapshot(javaScriptValue: [
            "state": "success",
            "email": "owner@example.com",
            "plan": "future-plan",
            "source": "session",
        ])
        #expect(snapshot.planLabel == "future-plan")
        #expect(snapshot.activeUntil == nil)
        #expect(snapshot.dateKind == nil)
    }

    @Test func pricingCardRussianDateFillsMissingAPIDate() throws {
        let snapshot = try SubscriptionSnapshot(javaScriptValue: [
            "state": "success",
            "email": "owner@example.com",
            "plan": "plus",
            "source": "subscription",
            "activeUntilText": "до 30 сент. 2026 г.",
            "activeUntilLocale": "ru-RU",
        ])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 30))

        #expect(snapshot.activeUntil == expected)
        #expect(snapshot.dateKind == nil)
    }

    @Test func currentPricingCardEnrichesSubscriptionWithoutChangingPlan() throws {
        let snapshot = try SubscriptionSnapshot(javaScriptValue: [
            "state": "success",
            "email": "owner@example.com",
            "plan": "plus",
            "source": "subscription",
        ])
        let enriched = snapshot.addingPricingDetails(.init(
            activeUntilText: "до 30 сент. 2026 г.",
            localeIdentifier: "ru-RU"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 30))

        #expect(enriched.planLabel == "plus")
        #expect(enriched.activeUntil == expected)
        #expect(enriched.willRenew == nil)
    }

    @Test func rejectsSubscriptionDateMixedWithSessionPlan() {
        #expect(throws: (any Error).self) {
            try SubscriptionSnapshot(javaScriptValue: [
                "state": "success",
                "email": "owner@example.com",
                "plan": "plus",
                "activeUntil": "2026-09-17T10:30:00Z",
                "willRenew": true,
                "source": "session",
            ])
        }
    }
}
