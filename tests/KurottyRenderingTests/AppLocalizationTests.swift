import XCTest
@testable import KurottyApp

final class AppLocalizationTests: XCTestCase {
    func testExplicitPreferenceOverridesSystemLanguage() {
        XCTAssertEqual(
            AppLanguageResolver.resolve(preference: .japanese, preferredLanguages: ["ko-KR"]),
            .japanese
        )
    }

    func testSystemPreferenceUsesPrimarySystemLanguage() {
        XCTAssertEqual(
            AppLanguageResolver.resolve(preference: .system, preferredLanguages: ["ko-KR", "ja-JP"]),
            .korean
        )
    }

    func testUnsupportedSystemLanguagesFallBackToEnglish() {
        XCTAssertEqual(
            AppLanguageResolver.resolve(preference: .system, preferredLanguages: ["fr-FR", "ko-KR"]),
            .english
        )
    }

    func testAllSupportedLanguagesHaveEveryTranslation() {
        for language in AppLanguage.allCases {
            for key in L10nKey.allCases {
                XCTAssertTrue(
                    AppLocalization.hasTranslation(for: key, language: language),
                    "Missing \(language.rawValue) translation for \(key.rawValue)"
                )
            }
        }
    }

    func testRepresentativeMenuTranslations() {
        XCTAssertEqual(AppLocalization.string(.language, language: .english), "Language")
        XCTAssertEqual(AppLocalization.string(.language, language: .korean), "언어")
        XCTAssertEqual(AppLocalization.string(.language, language: .japanese), "言語")
    }
}
