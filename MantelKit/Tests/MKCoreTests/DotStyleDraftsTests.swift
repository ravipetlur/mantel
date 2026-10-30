import Foundation
import Testing

@testable import MKCore

@Suite("Dot style drafts", .timeLimit(.minutes(1)))
struct DotStyleDraftsTests {
    @Test func theImageStyleIsCompleteOnceBothLightPicturesExist() {
        var draft = DotImageDraft()
        #expect(draft.style == nil)
        draft.hiddenDark = "a-dark.png"
        draft.alwaysDark = "b-dark.png"
        #expect(draft.style == nil, "dark pictures alone aren't enough")
        draft.hiddenLight = "a.png"
        #expect(draft.style == nil, "one light picture isn't enough")
        draft.alwaysLight = "b.png"
        #expect(draft.style == .image(hiddenLight: "a.png", hiddenDark: "a-dark.png", alwaysLight: "b.png", alwaysDark: "b-dark.png"))
        draft.hiddenDark = nil
        #expect(draft.style == .image(hiddenLight: "a.png", hiddenDark: nil, alwaysLight: "b.png", alwaysDark: "b-dark.png"))
    }

    @Test func aDraftStartsFromTheSavedImageStyleOnly() {
        let saved = DotGlyphStyle.image(hiddenLight: "a.png", hiddenDark: nil, alwaysLight: "b.png", alwaysDark: "b-dark.png")
        let draft = DotImageDraft(saved)
        #expect(draft.hiddenLight == "a.png")
        #expect(draft.hiddenDark == nil)
        #expect(draft.alwaysLight == "b.png")
        #expect(draft.alwaysDark == "b-dark.png")
        #expect(draft.style == saved)
        #expect(DotImageDraft(.dots) == DotImageDraft())
        #expect(DotImageDraft(.symbol(hidden: "circle.fill", always: "circle")) == DotImageDraft())
    }

    @Test func anEmptySymbolFieldGoesBackAndSavesNothing() {
        #expect(DotSymbolName.commit(typed: "", saved: "circle.fill") == .init(text: "circle.fill", save: nil))
        #expect(DotSymbolName.commit(typed: "  \n ", saved: "circle.fill") == .init(text: "circle.fill", save: nil))
    }

    @Test func aSymbolNameIsTrimmedAndSavedOnlyWhenItChanged() {
        #expect(DotSymbolName.commit(typed: "  star.fill ", saved: "circle.fill") == .init(text: "star.fill", save: "star.fill"))
        #expect(DotSymbolName.commit(typed: "circle.fill", saved: "circle.fill") == .init(text: "circle.fill", save: nil))
        #expect(DotSymbolName.commit(typed: " circle.fill ", saved: "circle.fill") == .init(text: "circle.fill", save: nil), "the same name with spaces saves nothing")
        #expect(DotSymbolName.commit(typed: "no.such.symbol", saved: "circle.fill").save == "no.such.symbol", "saved whether or not the system has it")
    }
}
