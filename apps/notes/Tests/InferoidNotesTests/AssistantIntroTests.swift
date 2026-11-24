import XCTest
@testable import InferoidNotesKit

final class AssistantIntroTests: XCTestCase {
    func testIntroCollectsNameAndUserAndPicksOwnEmoji() {
        var profile = AssistantProfile()
        let afterName = AssistantIntro.answer("I'll call you Nova", profile: &profile)
        XCTAssertEqual(profile.assistantName, "Nova")
        XCTAssertTrue(AssistantIntro.emojis.contains(profile.emoji))
        XCTAssertTrue(afterName.contains("who are you"))
        _ = AssistantIntro.answer("I'm Sara Lee, call me Sara", profile: &profile)
        XCTAssertEqual(profile.callMe, "Sara")
        _ = AssistantIntro.answer("I run a design studio.", profile: &profile)
        let last = AssistantIntro.answer("Short and direct.", profile: &profile, saved: ["Think Again", "Hawaii", "Q1 planning"])
        XCTAssertTrue(profile.isOnboarded)
        XCTAssertTrue(last.contains("Think Again") && last.contains("1 more"))
        XCTAssertTrue(profile.systemPromptSection.contains("Nova"))
        XCTAssertTrue(profile.systemPromptSection.contains("emoji"))
    }

    func testEmptyBrainInvitesTheUserToAddThings() {
        var profile = AssistantProfile(step: 3)
        let last = AssistantIntro.answer("short, no emojis", profile: &profile)
        XCTAssertTrue(last.contains("Library"))
        XCTAssertEqual(profile.useEmoji, false)
        XCTAssertTrue(profile.systemPromptSection.contains("Never use emojis"))
    }

    func testEmojiPreferenceAndAboutMeDetection() {
        XCTAssertEqual(AssistantIntro.emojiPreference(in: "please stop using emojis"), false)
        XCTAssertEqual(AssistantIntro.emojiPreference(in: "you can use emojis again"), true)
        XCTAssertNil(AssistantIntro.emojiPreference(in: "what did Dana say?"))
        XCTAssertEqual(AssistantIntro.callName(from: "Mehran"), "Mehran")
        XCTAssertTrue(ChatStore.asksAboutUser("what do you know about me so far?"))
        XCTAssertTrue(ChatStore.asksAboutUser("Who am I?"))
        XCTAssertFalse(ChatStore.asksAboutUser("What happened with the budget?"))
    }
}
