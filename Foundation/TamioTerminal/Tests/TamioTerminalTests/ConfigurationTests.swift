import XCTest
@testable import TamioTerminal

final class ConfigurationTests: XCTestCase {
    func testCatalogCoversEverySettingExactlyOnce() {
        let catalog = ConfigCatalog.shared
        XCTAssertEqual(catalog.registry.count, 200)
        XCTAssertEqual(catalog.themes.count, 633)
        let ids = catalog.navigation.flatMap(\.settingIDs)
        XCTAssertEqual(Set(ids), Set(catalog.registry.keys))
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(catalog.registry["quitAfterLastWindowClosed"]?.defaultValue, .scalar("false"))
    }
    func testSettingsLayoutShowsEveryAppliedSettingOnce() {
        let keys = ConfigLayout.categories.flatMap(\.keys)
        XCTAssertEqual(keys.count, Set(keys).count, "a setting appears in two places")
        XCTAssertEqual(Set(keys), ConfigCatalog.tamioKeys, "Settings and the applied keys disagree")
        for key in keys {
            XCTAssertNotNil(ConfigCatalog.shared.setting(key: key), "\(key) is not in the catalog")
        }
        XCTAssertEqual(ConfigLayout.categories.map(\.id).count, Set(ConfigLayout.categories.map(\.id)).count)
    }
    func testShortcutsReadAsKeyCaps() {
        XCTAssertEqual(KeybindingNames.step("super+shift+k"), "⇧⌘K")
        XCTAssertEqual(KeybindingNames.step("super+physical:four"), "⌘4")
        XCTAssertEqual(KeybindingNames.step("ctrl+alt+arrow_left"), "⌃⌥←")
        XCTAssertEqual(KeybindingNames.step("super+equal"), "⌘=")
        XCTAssertEqual(KeybindingNames.summary(ConfigKeybinding("super+equal=increase_font_size:1")), "Make Text Bigger (1 pt)")
        XCTAssertEqual(KeybindingNames.summary(ConfigKeybinding("super+backspace=text:\\x15")), "Delete to Start of Line")
        XCTAssertEqual(KeybindingNames.summary(ConfigKeybinding("alt+arrow_left=esc:b")), "Move Back a Word")
        XCTAssertFalse(KeybindingNames.applies(ConfigKeybinding("super+t=new_tab")))
        XCTAssertTrue(KeybindingNames.applies(ConfigKeybinding("super+k=clear_screen")))
    }
    func testCodepointMappingRoundTrip() {
        let mapping = CodepointMapping("U+E000-U+F8FF,U+F0000-U+FFFFD=Symbols Nerd Font")
        XCTAssertEqual(mapping?.family, "Symbols Nerd Font")
        XCTAssertEqual(CodepointRangeSet.describe(mapping?.ranges ?? ""), "Nerd Font icons")
        XCTAssertEqual(mapping?.rendered, "U+E000-U+F8FF,U+F0000-U+FFFFD=Symbols Nerd Font")
        XCTAssertEqual(CodepointRangeSet.describe("U+1234"), "U+1234")
    }
    @MainActor func testInstalledFontsComeFromCoreText() {
        XCTAssertTrue(FontLibrary.isMonospaced("Menlo"))
        XCTAssertFalse(FontLibrary.styles(of: "Menlo").isEmpty)
        XCTAssertFalse(FontLibrary.families.contains { $0.name.hasPrefix(".") })
    }
    func testEditorShowsTamioRuntimeDefaults() {
        let document = ConfigDocument()
        // Ghostty's built-in size differs per platform.
        #if os(macOS)
            XCTAssertEqual(document.text("font-size"), "14")
        #else
            XCTAssertEqual(document.text("font-size"), "10")
        #endif
        XCTAssertEqual(document.text("font-thicken"), "true")
        XCTAssertEqual(document.text("cursor-style-blink"), "true")
        XCTAssertEqual(document.text("minimum-contrast"), ConfigCatalog.shared.setting(key: "minimum-contrast")?.defaultValue.text)
    }
    func testImportMergePaletteRepeatableAndScalar() throws {
        var draft = ConfigDocument()
        try draft.merge("font-size = 17\nfont-family = Mono\nfont-family = 日本語\npalette = 2=#112233\nkeybind = ctrl+k=text:a=b:c")
        try draft.merge("font-size = 19\npalette = 3=#334455\nfont-family = Other\nkeybind = ctrl+x=ignore")
        XCTAssertEqual(draft.text("font-size"), "19")
        XCTAssertEqual(draft.values("font-family"), ["Other"])
        XCTAssertEqual(draft.paletteOverrides, [2: "#112233", 3: "#334455"])
        XCTAssertEqual(Array(draft.values("keybind").suffix(2)), ["ctrl+k=text:a=b:c", "ctrl+x=ignore"])
        let original = draft
        XCTAssertThrowsError(try draft.merge("font-size = 22\npalette = broken"))
        XCTAssertEqual(original, draft)
    }
    func testThemesDoNotContaminateDiffAndExplicitColorsWin() throws {
        var draft = ConfigDocument()
        draft.set("theme", ["light:3024 Day,dark:3024 Night"])
        XCTAssertEqual(draft.effectiveColor("background", dark: false), "#f7f7f7")
        XCTAssertEqual(draft.effectiveColor("background", dark: true), "#090300")
        XCTAssertFalse(draft.serialized().contains("background ="))
        draft.set("background", ["#123456"])
        XCTAssertEqual(draft.effectiveColor("background", dark: true), "#123456")
        draft.setPalette(255, color: "#010203")
        XCTAssertTrue(draft.serialized().contains("palette = 255=#010203"))
        draft.setPalette(255, color: nil)
        XCTAssertFalse(draft.serialized().contains("palette ="))
    }
    func testUnicodeSharingAndLargeFallback() throws {
        var draft = ConfigDocument()
        try draft.merge("font-family = 日本語\nkeybind = ctrl++=text:a=b:c\nfuture-key = one\nfuture-key = two")
        let url = try XCTUnwrap(draft.shareURL())
        XCTAssertFalse(url.contains("=="))
        var imported = ConfigDocument()
        try imported.merge(url)
        XCTAssertEqual(imported, draft)
        draft.set("title", [String(repeating: "大", count: 1000)])
        XCTAssertNil(draft.shareURL())
        XCTAssertThrowsError(try ConfigDocument.decodeShareOrText("https://ghostty.zerebos.com/#share=%%%"))
    }

    func testLocalizationCoversEveryTamioSetting() throws {
        let path = try XCTUnwrap(Bundle.module.path(forResource: "zh-Hans", ofType: "lproj"))
        let zhBundle = try XCTUnwrap(Bundle(path: path))

        XCTAssertEqual(ConfigCatalog.tamioKeys.count, 66, "Exactly 66 settings should be in tamioKeys")

        for key in ConfigCatalog.tamioKeys {
            let englishTitle = ConfigLayout.englishTitle(key)
            let zhTitle = ConfigLayout.title(key, bundle: zhBundle)
            XCTAssertFalse(zhTitle.isEmpty, "Missing Chinese title for \(key)")
            XCTAssertNotEqual(zhTitle, englishTitle, "Chinese title for \(key) should not match English fallback")

            let englishSummary = ConfigLayout.englishSummary(key)
            let zhSummary = ConfigLayout.summary(key, bundle: zhBundle)
            XCTAssertFalse(zhSummary.isEmpty, "Missing Chinese summary for \(key)")
            XCTAssertNotEqual(zhSummary, englishSummary, "Chinese summary for \(key) should not match English fallback")
        }

        for category in ConfigLayout.categories {
            let zhCat = category.title(in: zhBundle)
            XCTAssertFalse(zhCat.isEmpty, "Empty title for category \(category.id)")
            if !["mcp", "about"].contains(category.id) {
                XCTAssertNotEqual(zhCat, category.englishTitle, "Category \(category.id) should be translated in Chinese")
            }
            for group in category.groups {
                let zhGroup = group.title(in: zhBundle)
                XCTAssertFalse(zhGroup.isEmpty, "Empty title for group \(group.id)")
                if !["Tamio", "ssh", "server"].contains(group.id) {
                    XCTAssertNotEqual(zhGroup, group.englishTitle, "Group \(group.id) should be translated in Chinese")
                }
            }
        }

        for (key, options) in ConfigLayout.optionNames {
            for (value, englishFallback) in options {
                let zhOpt = ConfigLayout.optionName(key, value: value, fallback: englishFallback, bundle: zhBundle)
                XCTAssertFalse(zhOpt.isEmpty, "Empty option for \(key).\(value)")
                XCTAssertNotEqual(zhOpt, englishFallback, "Option \(key).\(value) should be translated in Chinese")
            }
        }

        XCTAssertEqual(KeybindingNames.groupTitle("Clipboard", bundle: zhBundle), "剪贴板")
        XCTAssertEqual(KeybindingNames.action("clear_screen", bundle: zhBundle), "清屏")
        XCTAssertEqual(KeybindingNames.key("space", bundle: zhBundle), "空格")
        XCTAssertEqual(ConfigDuration.unitName("ms", bundle: zhBundle), "毫秒")
    }

    func testPseudolocalizationTransformsAllSettingStrings() {
        ConfigLayout.pseudolocalize = true
        defer { ConfigLayout.pseudolocalize = false }

        XCTAssertEqual(ConfigCatalog.tamioKeys.count, 66)

        for key in ConfigCatalog.tamioKeys {
            let title = ConfigLayout.title(key)
            let summary = ConfigLayout.summary(key)

            XCTAssertTrue(title.hasPrefix("⟦") && title.hasSuffix("⟧"), "Title for \(key) should be pseudolocalized: \(title)")
            XCTAssertTrue(summary.hasPrefix("⟦") && summary.hasSuffix("⟧"), "Summary for \(key) should be pseudolocalized: \(summary)")

            let englishTitle = ConfigLayout.englishTitle(key)
            if englishTitle.contains(where: { "aeiouAEIOU".contains($0) }) {
                XCTAssertNotEqual(title, "⟦" + englishTitle + "⟧")
            }
        }

        for category in ConfigLayout.categories {
            let catTitle = category.title
            XCTAssertTrue(catTitle.hasPrefix("⟦") && catTitle.hasSuffix("⟧"), "Category \(category.id) should be pseudolocalized: \(catTitle)")
            for group in category.groups {
                let grpTitle = group.title
                XCTAssertTrue(grpTitle.hasPrefix("⟦") && grpTitle.hasSuffix("⟧"), "Group \(group.id) should be pseudolocalized: \(grpTitle)")
            }
        }

        for (key, options) in ConfigLayout.optionNames {
            for (value, fallback) in options {
                let opt = ConfigLayout.optionName(key, value: value, fallback: fallback)
                XCTAssertTrue(opt.hasPrefix("⟦") && opt.hasSuffix("⟧"), "Option \(key).\(value) should be pseudolocalized: \(opt)")
            }
        }
    }
}
