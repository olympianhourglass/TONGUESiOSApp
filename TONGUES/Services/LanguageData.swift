import Foundation

// MARK: - Levels per language

func levels(for language: String) -> [String] {
    switch language {
    case "Chinese (Mandarin)":
        return ["HSK 1", "HSK 2", "HSK 3", "HSK 4", "HSK 5", "HSK 6", "HSK 7", "HSK 8", "HSK 9"]
    case "Chinese (Cantonese)":
        return ["Beginner", "Lower Intermediate", "Intermediate", "Upper Intermediate", "Advanced"]
    case "Japanese":
        return ["JLPT N5", "JLPT N4", "JLPT N3", "JLPT N2", "JLPT N1"]
    case "Korean":
        return ["TOPIK 1", "TOPIK 2", "TOPIK 3", "TOPIK 4", "TOPIK 5", "TOPIK 6"]
    case "Hebrew":
        return ["Alef (א)", "Bet (ב)", "Gimel (ג)", "Dalet (ד)", "Heh (ה)", "Vav (ו)"]
    case "Russian":
        return ["TEU (Elementary)", "TBU (Basic)", "TORFL-1", "TORFL-2", "TORFL-3", "TORFL-4"]
    case "Arabic":
        return ["A1", "A2", "B1", "B2", "C1", "C2", "ALPT Novice", "ALPT Intermediate", "ALPT Advanced", "ALPT Superior"]
    case "Thai":
        return ["CU-TFL Beginner", "CU-TFL Elementary", "CU-TFL Intermediate", "CU-TFL Advanced", "CU-TFL Superior"]
    case "Vietnamese":
        return ["Bậc 1", "Bậc 2", "Bậc 3", "Bậc 4", "Bậc 5", "Bậc 6"]
    case "Indonesian":
        return ["UKBI Sangat Unggul", "UKBI Unggul", "UKBI Madya", "UKBI Semenjana", "UKBI Marginal", "UKBI Terbatas"]
    case "Filipino":
        return ["FSI 0", "FSI 1", "FSI 2", "FSI 3", "FSI 4", "FSI 5"]
    case "Latin", "Sanskrit", "Ancient Greek", "Esperanto":
        return ["Beginner", "Intermediate", "Advanced"]
    case "Hindi", "Urdu", "Bengali", "Tamil", "Telugu", "Kannada", "Malayalam",
         "Marathi", "Gujarati", "Punjabi", "Nepali", "Sinhala", "Pashto":
        return ["A1", "A2", "B1", "B2", "C1", "C2"]
    default:
        return ["A1", "A2", "B1", "B2", "C1", "C2"]
    }
}

// MARK: - Language encodings (ISO 639 + BCP-47)

struct LanguageEncoding {
    let iso: String       // ISO 639-1 where available, else 639-2/3
    let bcp47: String     // BCP-47 locale for AVSpeechSynthesizer
}

// Single source of truth for language codes used by any TTS / speech vendor.
// `iso` is what ElevenLabs accepts as `language_code`. `bcp47` is what
// AVSpeechSynthesisVoice(language:) consumes. iOS may not have a voice
// installed for every BCP-47 here; the synthesizer fuzzy-matches.
private let languageEncodings: [String: LanguageEncoding] = [
    "Afrikaans":            .init(iso: "af",  bcp47: "af-ZA"),
    "Albanian":             .init(iso: "sq",  bcp47: "sq-AL"),
    "Amharic":              .init(iso: "am",  bcp47: "am-ET"),
    "Arabic":               .init(iso: "ar",  bcp47: "ar-SA"),
    "Armenian":             .init(iso: "hy",  bcp47: "hy-AM"),
    "Assamese":             .init(iso: "as",  bcp47: "as-IN"),
    "Azerbaijani":          .init(iso: "az",  bcp47: "az-AZ"),
    "Basque":               .init(iso: "eu",  bcp47: "eu-ES"),
    "Belarusian":           .init(iso: "be",  bcp47: "be-BY"),
    "Bengali":              .init(iso: "bn",  bcp47: "bn-IN"),
    "Bosnian":              .init(iso: "bs",  bcp47: "bs-BA"),
    "Bulgarian":            .init(iso: "bg",  bcp47: "bg-BG"),
    "Burmese":              .init(iso: "my",  bcp47: "my-MM"),
    "Catalan":              .init(iso: "ca",  bcp47: "ca-ES"),
    "Cebuano":              .init(iso: "ceb", bcp47: "ceb-PH"),
    "Chichewa":             .init(iso: "ny",  bcp47: "ny-MW"),
    "Chinese (Cantonese)":  .init(iso: "yue", bcp47: "yue-HK"),
    "Chinese (Mandarin)":   .init(iso: "zh",  bcp47: "zh-CN"),
    "Corsican":             .init(iso: "co",  bcp47: "co-FR"),
    "Croatian":             .init(iso: "hr",  bcp47: "hr-HR"),
    "Czech":                .init(iso: "cs",  bcp47: "cs-CZ"),
    "Danish":               .init(iso: "da",  bcp47: "da-DK"),
    "Dutch":                .init(iso: "nl",  bcp47: "nl-NL"),
    "English":              .init(iso: "en",  bcp47: "en-US"),
    "Esperanto":            .init(iso: "eo",  bcp47: "eo"),
    "Estonian":             .init(iso: "et",  bcp47: "et-EE"),
    "Filipino":             .init(iso: "fil", bcp47: "fil-PH"),
    "Finnish":              .init(iso: "fi",  bcp47: "fi-FI"),
    "French":               .init(iso: "fr",  bcp47: "fr-FR"),
    "Frisian":              .init(iso: "fy",  bcp47: "fy-NL"),
    "Galician":             .init(iso: "gl",  bcp47: "gl-ES"),
    "Georgian":             .init(iso: "ka",  bcp47: "ka-GE"),
    "German":               .init(iso: "de",  bcp47: "de-DE"),
    "Greek":                .init(iso: "el",  bcp47: "el-GR"),
    "Gujarati":             .init(iso: "gu",  bcp47: "gu-IN"),
    "Haitian Creole":       .init(iso: "ht",  bcp47: "ht-HT"),
    "Hausa":                .init(iso: "ha",  bcp47: "ha-NG"),
    "Hawaiian":             .init(iso: "haw", bcp47: "haw-US"),
    "Hebrew":               .init(iso: "he",  bcp47: "he-IL"),
    "Hindi":                .init(iso: "hi",  bcp47: "hi-IN"),
    "Hmong":                .init(iso: "hmn", bcp47: "hmn"),
    "Hungarian":            .init(iso: "hu",  bcp47: "hu-HU"),
    "Icelandic":            .init(iso: "is",  bcp47: "is-IS"),
    "Igbo":                 .init(iso: "ig",  bcp47: "ig-NG"),
    "Indonesian":           .init(iso: "id",  bcp47: "id-ID"),
    "Irish":                .init(iso: "ga",  bcp47: "ga-IE"),
    "Italian":              .init(iso: "it",  bcp47: "it-IT"),
    "Japanese":             .init(iso: "ja",  bcp47: "ja-JP"),
    "Javanese":             .init(iso: "jv",  bcp47: "jv-ID"),
    "Kannada":              .init(iso: "kn",  bcp47: "kn-IN"),
    "Kazakh":               .init(iso: "kk",  bcp47: "kk-KZ"),
    "Khmer":                .init(iso: "km",  bcp47: "km-KH"),
    "Kinyarwanda":          .init(iso: "rw",  bcp47: "rw-RW"),
    "Korean":               .init(iso: "ko",  bcp47: "ko-KR"),
    "Kurdish":              .init(iso: "ku",  bcp47: "ku-TR"),
    "Kyrgyz":               .init(iso: "ky",  bcp47: "ky-KG"),
    "Lao":                  .init(iso: "lo",  bcp47: "lo-LA"),
    "Latin":                .init(iso: "la",  bcp47: "la"),
    "Latvian":              .init(iso: "lv",  bcp47: "lv-LV"),
    "Lithuanian":           .init(iso: "lt",  bcp47: "lt-LT"),
    "Luxembourgish":        .init(iso: "lb",  bcp47: "lb-LU"),
    "Macedonian":           .init(iso: "mk",  bcp47: "mk-MK"),
    "Malagasy":             .init(iso: "mg",  bcp47: "mg-MG"),
    "Malay":                .init(iso: "ms",  bcp47: "ms-MY"),
    "Malayalam":            .init(iso: "ml",  bcp47: "ml-IN"),
    "Maltese":              .init(iso: "mt",  bcp47: "mt-MT"),
    "Maori":                .init(iso: "mi",  bcp47: "mi-NZ"),
    "Marathi":              .init(iso: "mr",  bcp47: "mr-IN"),
    "Mongolian":            .init(iso: "mn",  bcp47: "mn-MN"),
    "Nepali":               .init(iso: "ne",  bcp47: "ne-NP"),
    "Norwegian":            .init(iso: "no",  bcp47: "nb-NO"),
    "Odia":                 .init(iso: "or",  bcp47: "or-IN"),
    "Pashto":               .init(iso: "ps",  bcp47: "ps-AF"),
    "Persian":              .init(iso: "fa",  bcp47: "fa-IR"),
    "Polish":               .init(iso: "pl",  bcp47: "pl-PL"),
    "Portuguese":           .init(iso: "pt",  bcp47: "pt-BR"),
    "Punjabi":              .init(iso: "pa",  bcp47: "pa-IN"),
    "Quechua":              .init(iso: "qu",  bcp47: "qu-PE"),
    "Romanian":             .init(iso: "ro",  bcp47: "ro-RO"),
    "Russian":              .init(iso: "ru",  bcp47: "ru-RU"),
    "Samoan":               .init(iso: "sm",  bcp47: "sm-WS"),
    "Sanskrit":             .init(iso: "sa",  bcp47: "sa-IN"),
    "Scots Gaelic":         .init(iso: "gd",  bcp47: "gd-GB"),
    "Serbian":              .init(iso: "sr",  bcp47: "sr-RS"),
    "Sesotho":              .init(iso: "st",  bcp47: "st-LS"),
    "Shona":                .init(iso: "sn",  bcp47: "sn-ZW"),
    "Sindhi":               .init(iso: "sd",  bcp47: "sd-PK"),
    "Sinhala":              .init(iso: "si",  bcp47: "si-LK"),
    "Slovak":               .init(iso: "sk",  bcp47: "sk-SK"),
    "Slovenian":            .init(iso: "sl",  bcp47: "sl-SI"),
    "Somali":               .init(iso: "so",  bcp47: "so-SO"),
    "Spanish":              .init(iso: "es",  bcp47: "es-ES"),
    "Sundanese":            .init(iso: "su",  bcp47: "su-ID"),
    "Swahili":              .init(iso: "sw",  bcp47: "sw-KE"),
    "Swedish":              .init(iso: "sv",  bcp47: "sv-SE"),
    "Taiwanese":            .init(iso: "nan", bcp47: "nan-TW"),
    "Tajik":                .init(iso: "tg",  bcp47: "tg-TJ"),
    "Tamil":                .init(iso: "ta",  bcp47: "ta-IN"),
    "Tatar":                .init(iso: "tt",  bcp47: "tt-RU"),
    "Telugu":               .init(iso: "te",  bcp47: "te-IN"),
    "Thai":                 .init(iso: "th",  bcp47: "th-TH"),
    "Tibetan":              .init(iso: "bo",  bcp47: "bo-CN"),
    "Tigrinya":             .init(iso: "ti",  bcp47: "ti-ER"),
    "Turkish":              .init(iso: "tr",  bcp47: "tr-TR"),
    "Turkmen":              .init(iso: "tk",  bcp47: "tk-TM"),
    "Ukrainian":            .init(iso: "uk",  bcp47: "uk-UA"),
    "Urdu":                 .init(iso: "ur",  bcp47: "ur-PK"),
    "Uyghur":               .init(iso: "ug",  bcp47: "ug-CN"),
    "Uzbek":                .init(iso: "uz",  bcp47: "uz-UZ"),
    "Vietnamese":           .init(iso: "vi",  bcp47: "vi-VN"),
    "Welsh":                .init(iso: "cy",  bcp47: "cy-GB"),
    "Xhosa":                .init(iso: "xh",  bcp47: "xh-ZA"),
    "Yiddish":              .init(iso: "yi",  bcp47: "yi"),
    "Yoruba":               .init(iso: "yo",  bcp47: "yo-NG"),
    "Zulu":                 .init(iso: "zu",  bcp47: "zu-ZA")
]

// Common shorthand names that show up in user input or AI-generated
// suggestions (e.g. Claude returning "Mandarin" instead of "Chinese
// (Mandarin)"). Mapped to the canonical TONGUES language name so the
// encoding lookup still finds a match.
private let languageAliases: [String: String] = [
    "Mandarin":            "Chinese (Mandarin)",
    "Chinese":             "Chinese (Mandarin)",
    "Cantonese":           "Chinese (Cantonese)",
    "Farsi":               "Persian",
    "Tagalog":             "Filipino",
    "Castilian":           "Spanish",
    "Brazilian Portuguese": "Portuguese",
    "BCS":                 "Serbian"
]

func canonicalLanguageName(_ language: String) -> String {
    if languageEncodings[language] != nil { return language }
    return languageAliases[language] ?? language
}

func languageISOCode(for language: String) -> String? {
    languageEncodings[canonicalLanguageName(language)]?.iso
}

func appleSpeechLocale(for language: String) -> String? {
    languageEncodings[canonicalLanguageName(language)]?.bcp47
}

// MARK: - Total speakers per language

// Approximate total-speakers counts (L1 + L2, rounded to nearest million)
// for the top ~50 most-spoken languages, plus a few additional languages
// the Explore tab is likely to surface via geolocation. Source: World
// Almanac / Ethnologue 2024 best-effort rounding. Used by the "Languages
// Based on Where You Are" cards.
private let totalSpeakersByLanguage: [String: Int] = [
    "English": 1_500_000_000,
    "Chinese (Mandarin)": 1_100_000_000,
    "Hindi": 610_000_000,
    "Spanish": 560_000_000,
    "French": 310_000_000,
    "Arabic": 380_000_000,
    "Bengali": 270_000_000,
    "Portuguese": 270_000_000,
    "Russian": 250_000_000,
    "Urdu": 240_000_000,
    "Indonesian": 200_000_000,
    "German": 135_000_000,
    "Japanese": 125_000_000,
    "Nigerian Pidgin": 120_000_000,
    "Marathi": 99_000_000,
    "Telugu": 96_000_000,
    "Turkish": 90_000_000,
    "Tamil": 86_000_000,
    "Yue Chinese": 85_000_000,
    "Chinese (Cantonese)": 85_000_000,
    "Vietnamese": 86_000_000,
    "Wu Chinese": 82_000_000,
    "Tagalog": 83_000_000,
    "Filipino": 83_000_000,
    "Korean": 82_000_000,
    "Iranian Persian": 78_000_000,
    "Persian": 78_000_000,
    "Hausa": 75_000_000,
    "Swahili": 72_000_000,
    "Javanese": 68_000_000,
    "Italian": 68_000_000,
    "Punjabi": 67_000_000,
    "Gujarati": 62_000_000,
    "Thai": 60_000_000,
    "Kannada": 59_000_000,
    "Amharic": 58_000_000,
    "Burmese": 43_000_000,
    "Polish": 41_000_000,
    "Yoruba": 46_000_000,
    "Sindhi": 41_000_000,
    "Romanian": 24_000_000,
    "Dutch": 25_000_000,
    "Czech": 11_000_000,
    "Hungarian": 13_000_000,
    "Greek": 13_500_000,
    "Hebrew": 9_000_000,
    "Catalan": 10_000_000,
    "Ukrainian": 33_000_000,
    "Swedish": 10_000_000,
    "Norwegian": 5_300_000,
    "Danish": 6_000_000,
    "Finnish": 5_400_000,
    "Slovak": 5_200_000,
    "Bulgarian": 8_000_000,
    "Serbian": 12_000_000,
    "Croatian": 6_800_000,
    "Slovenian": 2_500_000,
    "Estonian": 1_100_000,
    "Latvian": 1_700_000,
    "Lithuanian": 3_000_000,
    "Icelandic": 360_000,
    "Welsh": 750_000,
    "Irish": 1_900_000,
    "Basque": 750_000,
    "Albanian": 7_500_000,
    "Macedonian": 1_700_000,
    "Georgian": 4_000_000,
    "Armenian": 6_700_000,
    "Khmer": 17_000_000,
    "Lao": 30_000_000,
    "Malay": 290_000_000,
    "Sinhala": 17_000_000,
    "Nepali": 32_000_000,
    "Pashto": 60_000_000,
    "Mongolian": 5_700_000,
    "Tibetan": 6_000_000
]

// Conservative floor used when a language isn't in the static table, so
// the Explore language cards always have a speaker line to render (and a
// stable height). 1M reads as a safe "at least a million speakers" for
// any real language we surface but haven't hard-coded yet.
let defaultSpeakerEstimate = 1_000_000

// Looks up a single-number "X speakers" estimate for a language. Always
// returns a positive number — the static table for known languages, or
// `defaultSpeakerEstimate` for the long tail — so callers can always
// show the speaker line without the card height collapsing.
func totalSpeakers(for language: String) -> Int {
    let canonical = canonicalLanguageName(language)
    if let count = totalSpeakersByLanguage[canonical] { return count }
    return totalSpeakersByLanguage[language] ?? defaultSpeakerEstimate
}

// MARK: - Speaker count formatting

func formatSpeakers(_ count: Int) -> String {
    if count >= 1_000_000_000 {
        return String(format: "%.1fB speakers", Double(count) / 1_000_000_000)
    } else if count >= 10_000_000 {
        return "\(count / 1_000_000)M speakers"
    } else if count >= 1_000_000 {
        return String(format: "%.1fM speakers", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return "\(count / 1_000)K speakers"
    } else if count > 0 {
        return "\(count) speakers"
    } else {
        return ""
    }
}

// MARK: - Dialect speaker estimates

private let dialectSpeakerCounts: [String: [String: Int]] = [
    "Arabic": [
        "MSA": 400_000_000, "Egyptian": 100_000_000, "Levantine": 50_000_000,
        "Lebanese": 5_000_000, "Syrian": 22_000_000, "Palestinian": 7_000_000,
        "Jordanian": 10_000_000, "Gulf": 36_000_000, "Hijazi": 14_000_000,
        "Najdi": 13_000_000, "Yemeni": 30_000_000, "Iraqi": 40_000_000,
        "Sudanese": 32_000_000, "Maghrebi": 75_000_000, "Moroccan": 30_000_000,
        "Algerian": 40_000_000, "Tunisian": 12_000_000, "Libyan": 6_000_000,
        "Hassaniya": 3_000_000, "Chadian": 1_000_000
    ],
    "Chinese (Mandarin)": [
        "Standard (Putonghua)": 920_000_000, "Beijing": 11_000_000,
        "Northeastern": 100_000_000, "Taiwanese Mandarin": 23_000_000,
        "Singaporean Mandarin": 3_000_000, "Sichuanese": 80_000_000,
        "Lan-Yin": 17_000_000, "Jianghuai (Lower Yangtze)": 70_000_000
    ],
    "Chinese (Cantonese)": [
        "Standard (Guangzhou)": 67_000_000, "Hong Kong": 7_000_000,
        "Macanese": 500_000, "Taishanese": 5_000_000, "Malaysian Cantonese": 1_000_000
    ],
    "English": [
        "American (General)": 240_000_000, "British (RP)": 60_000_000,
        "Australian": 17_000_000, "Canadian": 20_000_000, "Irish": 4_000_000,
        "Scottish": 5_000_000, "South African": 5_000_000, "New Zealand": 4_000_000,
        "Indian": 130_000_000, "Singaporean": 4_000_000, "Caribbean": 4_000_000,
        "Nigerian": 60_000_000, "Welsh English": 3_000_000, "Cockney": 1_000_000,
        "Geordie": 500_000, "Scouse": 500_000, "AAVE": 30_000_000
    ],
    "Spanish": [
        "Castilian (Spain)": 47_000_000, "Andalusian": 8_000_000, "Canarian": 2_000_000,
        "Mexican": 130_000_000, "Caribbean": 30_000_000, "Cuban": 11_000_000,
        "Dominican": 10_000_000, "Puerto Rican": 3_000_000, "Central American": 47_000_000,
        "Colombian": 50_000_000, "Venezuelan": 28_000_000, "Andean": 30_000_000,
        "Chilean": 18_000_000, "Rioplatense (Argentine/Uruguayan)": 45_000_000,
        "Paraguayan": 7_000_000, "Equatoguinean": 1_000_000
    ],
    "French": [
        "Metropolitan (Standard)": 65_000_000, "Quebec": 7_000_000, "Acadian": 350_000,
        "Cajun (Louisiana)": 200_000, "Belgian": 4_000_000, "Swiss": 2_000_000,
        "African French": 120_000_000, "Maghrebi French": 30_000_000, "Lyonnais": 1_000_000
    ],
    "German": [
        "Standard (Hochdeutsch)": 80_000_000, "Austrian": 8_000_000, "Swiss German": 5_000_000,
        "Bavarian": 13_000_000, "Berlinese": 3_000_000, "Saxon": 5_000_000,
        "Low German (Plattdeutsch)": 6_000_000, "Alemannic": 10_000_000,
        "Franconian": 5_000_000, "Hessian": 6_000_000, "Palatine": 1_000_000
    ],
    "Portuguese": [
        "European (Lisbon)": 10_000_000, "Brazilian": 215_000_000, "Angolan": 15_000_000,
        "Mozambican": 13_000_000, "Cape Verdean": 500_000, "Macanese": 7_000,
        "East Timorese": 700_000
    ],
    "Italian": [
        "Standard": 60_000_000, "Tuscan": 3_000_000, "Roman": 3_000_000,
        "Neapolitan": 7_000_000, "Sicilian": 5_000_000, "Venetian": 4_000_000,
        "Lombard": 4_000_000, "Piedmontese": 2_000_000, "Ligurian": 500_000,
        "Emilian-Romagnol": 3_000_000, "Friulian": 600_000, "Sardinian": 1_000_000,
        "Calabrian": 2_000_000, "Apulian": 3_000_000
    ],
    "Hindi": [
        "Standard (Khari Boli)": 350_000_000, "Awadhi": 38_000_000, "Bhojpuri": 51_000_000,
        "Braj": 5_000_000, "Haryanvi": 13_000_000, "Marwari": 8_000_000, "Dakhini": 13_000_000
    ],
    "Urdu": [
        "Standard": 70_000_000, "Dakhini": 13_000_000, "Rekhta": 100_000,
        "Hyderabadi": 13_000_000, "Lucknowi": 5_000_000
    ],
    "Persian": [
        "Iranian (Standard Farsi)": 60_000_000, "Dari (Afghanistan)": 15_000_000,
        "Tajiki": 8_000_000, "Hazaragi": 2_000_000, "Bukhori": 50_000
    ],
    "Russian": [
        "Standard (Moscow)": 100_000_000, "Northern": 15_000_000, "Southern": 20_000_000,
        "Central": 10_000_000, "Siberian": 7_000_000
    ],
    "Bengali": [
        "Standard (Kolkata)": 100_000_000, "Dhaka": 75_000_000, "Sylheti": 11_000_000,
        "Chittagonian": 13_000_000, "Rangpuri": 15_000_000, "Manbhumi": 2_000_000
    ],
    "Tamil": [
        "Standard (Chennai)": 50_000_000, "Brahmin Tamil": 3_000_000, "Kongu": 12_000_000,
        "Madurai": 5_000_000, "Tirunelveli": 4_000_000, "Jaffna (Sri Lankan)": 3_000_000,
        "Batticaloa": 200_000, "Malaysian Tamil": 2_000_000, "Singaporean Tamil": 200_000
    ],
    "Korean": [
        "Standard (Seoul)": 50_000_000, "Gyeongsang": 13_000_000, "Jeolla": 5_000_000,
        "Chungcheong": 5_000_000, "Gangwon": 3_000_000, "Jeju": 5_000,
        "Pyongyang (North Korean)": 25_000_000
    ],
    "Japanese": [
        "Standard (Tokyo)": 65_000_000, "Kansai (Osaka/Kyoto)": 22_000_000,
        "Tohoku": 9_000_000, "Kyushu": 13_000_000, "Hokkaido": 5_000_000,
        "Hakata": 5_000_000, "Nagoya": 5_000_000, "Okinawan": 1_000_000
    ],
    "Dutch": [
        "Standard (Netherlands)": 17_000_000, "Flemish (Belgian)": 6_000_000,
        "Surinamese": 400_000, "Brabantian": 5_000_000, "Hollandic": 4_000_000,
        "Limburgish": 1_000_000
    ],
    "Greek": [
        "Standard Modern": 13_000_000, "Cypriot": 700_000, "Pontic": 500_000,
        "Cretan": 600_000, "Tsakonian": 1_200, "Griko": 20_000
    ],
    "Turkish": [
        "Istanbul Standard": 80_000_000, "Anatolian": 5_000_000,
        "Rumelian": 2_000_000, "Cypriot Turkish": 200_000
    ],
    "Polish": [
        "Standard": 38_000_000, "Silesian": 500_000, "Kashubian": 100_000,
        "Highlander (Góralski)": 200_000, "Mazurian": 50_000, "Greater Polish": 1_000_000
    ],
    "Vietnamese": [
        "Northern (Hanoi)": 30_000_000, "Central (Huế)": 18_000_000,
        "Southern (Saigon)": 42_000_000
    ],
    "Swedish": [
        "Standard (Rikssvenska)": 10_000_000, "Skånsk": 1_000_000, "Gotländska": 60_000,
        "Finland Swedish": 290_000, "Norrländska": 800_000, "Götamål": 500_000
    ],
    "Norwegian": [
        "Bokmål": 4_500_000, "Nynorsk": 700_000, "Trøndersk": 500_000,
        "Nordlandsk": 400_000, "Bergensk": 280_000
    ],
    "Danish": [
        "Standard (Rigsdansk)": 6_000_000, "Jutlandic": 600_000, "Bornholmsk": 30_000
    ],
    "Finnish": [
        "Standard": 5_500_000, "Western": 1_500_000, "Eastern": 1_500_000,
        "Tampere": 240_000, "Helsinki Slang": 600_000
    ],
    "Hungarian": [
        "Standard": 13_000_000, "Palóc": 300_000, "Székely": 700_000, "Csángó": 50_000
    ],
    "Czech": ["Standard": 10_000_000, "Moravian": 3_000_000, "Silesian": 50_000],
    "Slovak": [
        "Standard": 5_000_000, "Eastern": 700_000, "Central": 2_000_000, "Western": 1_000_000
    ],
    "Romanian": [
        "Standard": 24_000_000, "Moldovan": 2_500_000, "Aromanian": 250_000,
        "Megleno-Romanian": 5_000, "Istro-Romanian": 200
    ],
    "Bulgarian": [
        "Standard": 7_000_000, "Eastern": 2_000_000, "Western": 1_500_000, "Rup": 500_000
    ],
    "Ukrainian": [
        "Standard": 27_000_000, "Western": 5_000_000, "Northern": 3_000_000,
        "Southwestern": 4_000_000, "Southeastern": 8_000_000
    ],
    "Serbian": [
        "Štokavian (Standard)": 18_000_000, "Čakavian": 80_000,
        "Kajkavian": 1_500_000, "Torlakian": 1_500_000
    ],
    "Croatian": [
        "Štokavian (Standard)": 18_000_000, "Čakavian": 80_000,
        "Kajkavian": 1_500_000, "Torlakian": 1_500_000
    ],
    "Bosnian": [
        "Štokavian (Standard)": 18_000_000, "Čakavian": 80_000,
        "Kajkavian": 1_500_000, "Torlakian": 1_500_000
    ],
    "Albanian": ["Tosk": 3_000_000, "Gheg": 4_000_000, "Arbëresh": 100_000, "Arvanitika": 50_000],
    "Armenian": [
        "Eastern Armenian": 5_000_000, "Western Armenian": 2_000_000, "Karabakh": 150_000
    ],
    "Georgian": [
        "Standard": 3_700_000, "Imeretian": 700_000, "Kakhetian": 400_000, "Gurian": 150_000
    ],
    "Hebrew": [
        "Modern Israeli": 9_000_000, "Yemenite": 50_000, "Mizrahi": 200_000,
        "Ashkenazi": 100_000, "Sephardi": 100_000
    ],
    "Yiddish": [
        "Standard (Eastern)": 500_000, "Western": 1_000, "Litvish": 50_000,
        "Galitzianer": 100_000, "Poylish": 100_000, "Ukrainisher": 50_000
    ],
    "Swahili": [
        "Kiunguja (Zanzibar)": 5_000_000, "Kimvita (Mombasa)": 8_000_000,
        "Kingozi": 30_000, "Sheng (slang)": 5_000_000
    ],
    "Amharic": [
        "Standard (Addis Ababa)": 25_000_000, "Gondar": 5_000_000, "Gojjam": 7_000_000,
        "Shewa": 12_000_000, "Wollo": 5_000_000
    ],
    "Hausa": [
        "Standard (Kano)": 50_000_000, "Sokoto": 8_000_000,
        "Eastern Hausa": 10_000_000, "Western Hausa": 8_000_000
    ],
    "Yoruba": [
        "Standard": 25_000_000, "Oyo": 8_000_000, "Egba": 3_000_000,
        "Ijebu": 2_000_000, "Ekiti": 2_000_000, "Ondo": 2_000_000, "Lagos": 12_000_000
    ],
    "Igbo": [
        "Standard": 15_000_000, "Owerri": 5_000_000, "Onitsha": 3_000_000,
        "Aro": 1_000_000, "Nsukka": 2_000_000
    ],
    "Zulu": ["Standard": 12_000_000, "KwaZulu-Natal": 9_000_000],
    "Afrikaans": [
        "Standard": 6_000_000, "Cape Afrikaans": 1_000_000,
        "Orange River Afrikaans": 300_000, "Eastern Cape Afrikaans": 200_000
    ],
    "Thai": [
        "Standard (Central)": 25_000_000, "Northern (Lanna)": 6_000_000,
        "Isan (Northeastern)": 22_000_000, "Southern": 5_000_000
    ],
    "Burmese": [
        "Standard (Yangon)": 33_000_000, "Rakhine": 3_000_000,
        "Tavoyan": 400_000, "Intha": 90_000
    ],
    "Khmer": [
        "Standard (Phnom Penh)": 14_000_000, "Northern (Battambang)": 2_000_000,
        "Surin": 1_400_000, "Cardamom (Western)": 30_000
    ],
    "Lao": [
        "Vientiane (Standard)": 4_000_000, "Northern": 2_000_000, "Central": 500_000,
        "Southern": 1_000_000, "Northeastern": 22_000_000
    ],
    "Indonesian": [
        "Standard (Baku)": 200_000_000, "Jakartan (Betawi)": 5_000_000,
        "Riau": 3_000_000, "Medan": 2_000_000, "Surabayan": 9_000_000
    ],
    "Malay": [
        "Standard Malaysian": 23_000_000, "Singaporean": 1_000_000, "Bruneian": 250_000,
        "Sabah": 4_000_000, "Sarawak": 3_000_000, "Patani": 1_500_000
    ],
    "Filipino": [
        "Standard Filipino": 28_000_000, "Manila Tagalog": 13_000_000,
        "Batangas": 3_000_000, "Bulacan": 3_000_000, "Marinduque": 230_000
    ],
    "Welsh": [
        "Standard": 600_000, "North Welsh": 200_000, "South Welsh": 250_000,
        "Gwentian": 30_000, "Powys": 20_000
    ],
    "Irish": [
        "Standard (An Caighdeán)": 170_000, "Ulster": 50_000,
        "Connacht": 90_000, "Munster": 30_000
    ],
    "Scots Gaelic": [
        "Standard": 60_000, "Lewis": 15_000, "Skye": 5_000,
        "Argyll": 3_000, "Outer Hebrides": 15_000
    ],
    "Basque": [
        "Standard (Batua)": 750_000, "Biscayan": 270_000, "Gipuzkoan": 300_000,
        "Upper Navarrese": 50_000, "Lapurdian": 30_000, "Souletin": 8_000
    ],
    "Catalan": [
        "Standard": 5_000_000, "Valencian": 2_400_000, "Balearic": 600_000,
        "Roussillonese": 100_000, "Algherese": 20_000
    ],
    "Galician": [
        "Standard": 2_500_000, "Eastern": 700_000, "Central": 1_000_000, "Western": 800_000
    ],
    "Maltese": ["Standard": 500_000, "Rural Maltese": 50_000],
    "Mongolian": [
        "Khalkha (Standard)": 2_900_000, "Buryat": 300_000,
        "Oirat": 600_000, "Inner Mongolian (Chakhar)": 3_000_000
    ],
    "Nepali": [
        "Standard": 16_000_000, "Eastern": 2_000_000, "Western": 2_000_000, "Doteli": 800_000
    ],
    "Sinhala": ["Standard": 16_000_000, "Up-country": 5_000_000, "Low-country": 8_000_000],
    "Punjabi": [
        "Majhi (Standard)": 40_000_000, "Doabi": 8_000_000, "Malwai": 10_000_000,
        "Pothohari": 7_000_000, "Multani": 5_000_000, "Saraiki": 26_000_000
    ],
    "Marathi": [
        "Standard (Puneri)": 60_000_000, "Varhadi": 7_000_000,
        "Dakhini": 13_000_000, "Khandeshi": 2_000_000
    ],
    "Telugu": [
        "Standard (Coastal)": 35_000_000, "Telangana": 25_000_000,
        "Rayalaseema": 15_000_000, "Northern": 5_000_000, "Brahmin": 2_000_000
    ],
    "Kannada": [
        "Standard (Mysore)": 20_000_000, "Mangalore": 5_000_000, "Dharwad": 7_000_000,
        "Northern": 3_000_000, "Coastal": 4_000_000
    ],
    "Malayalam": [
        "Standard": 25_000_000, "Northern": 7_000_000, "Southern": 5_000_000, "Central": 3_000_000
    ],
    "Gujarati": [
        "Standard": 35_000_000, "Kathiyawadi": 10_000_000, "Charotari": 3_000_000, "Surati": 4_000_000
    ],
    "Pashto": [
        "Northern (Yusufzai)": 20_000_000, "Southern (Kandahari)": 15_000_000,
        "Central (Wazirwola)": 5_000_000
    ],
    "Kurdish": [
        "Kurmanji (Northern)": 20_000_000, "Sorani (Central)": 8_000_000,
        "Pehlewani (Southern)": 3_000_000, "Zazaki": 3_000_000, "Gorani": 500_000
    ],
    "Azerbaijani": [
        "Northern (Standard)": 10_000_000, "Southern (Iranian)": 13_000_000, "Tabrizi": 4_000_000
    ],
    "Kazakh": [
        "Standard": 13_000_000, "Northeastern": 2_000_000,
        "Southern": 2_000_000, "Western": 2_000_000
    ],
    "Uzbek": [
        "Standard (Tashkent)": 27_000_000, "Karluk": 3_000_000,
        "Kipchak": 2_000_000, "Oghuz": 1_000_000
    ],
    "Uyghur": ["Standard (Central)": 9_000_000, "Hotan": 1_000_000, "Lop": 50_000],
    "Berber": [
        "Tamazight": 5_000_000, "Tachelhit": 8_000_000, "Tarifit": 5_000_000,
        "Kabyle": 6_000_000, "Tuareg": 2_000_000
    ]
]

func dialectsDetailed(for language: String) -> [Dialect] {
    let speakers = dialectSpeakerCounts[language] ?? [:]
    return dialects(for: language).map { name in
        Dialect(name: name, speakers: speakers[name] ?? 0)
    }
}

// MARK: - Dialects per language

func dialects(for language: String) -> [String] {
    switch language {
    case "Arabic":
        return [
            "MSA", "Egyptian", "Levantine", "Lebanese", "Syrian", "Palestinian", "Jordanian",
            "Gulf", "Hijazi", "Najdi", "Yemeni", "Iraqi", "Sudanese",
            "Maghrebi", "Moroccan", "Algerian", "Tunisian", "Libyan",
            "Hassaniya", "Chadian", "Classical Arabic"
        ]
    case "Chinese (Mandarin)":
        return [
            "Standard (Putonghua)", "Beijing", "Northeastern", "Taiwanese Mandarin",
            "Singaporean Mandarin", "Sichuanese", "Lan-Yin", "Jianghuai (Lower Yangtze)"
        ]
    case "Chinese (Cantonese)":
        return ["Standard (Guangzhou)", "Hong Kong", "Macanese", "Taishanese", "Malaysian Cantonese"]
    case "English":
        return [
            "American (General)", "British (RP)", "Australian", "Canadian", "Irish",
            "Scottish", "South African", "New Zealand", "Indian", "Singaporean",
            "Caribbean", "Nigerian", "Welsh English", "Cockney", "Geordie", "Scouse", "AAVE"
        ]
    case "Spanish":
        return [
            "Castilian (Spain)", "Andalusian", "Canarian", "Mexican", "Caribbean",
            "Cuban", "Dominican", "Puerto Rican", "Central American", "Colombian",
            "Venezuelan", "Andean", "Chilean", "Rioplatense (Argentine/Uruguayan)",
            "Paraguayan", "Equatoguinean"
        ]
    case "French":
        return [
            "Metropolitan (Standard)", "Quebec", "Acadian", "Cajun (Louisiana)",
            "Belgian", "Swiss", "African French", "Maghrebi French", "Lyonnais"
        ]
    case "German":
        return [
            "Standard (Hochdeutsch)", "Austrian", "Swiss German", "Bavarian", "Berlinese",
            "Saxon", "Low German (Plattdeutsch)", "Alemannic", "Franconian", "Hessian",
            "Palatine"
        ]
    case "Portuguese":
        return [
            "European (Lisbon)", "Brazilian", "Angolan", "Mozambican",
            "Cape Verdean", "Macanese", "East Timorese"
        ]
    case "Italian":
        return [
            "Standard", "Tuscan", "Roman", "Neapolitan", "Sicilian", "Venetian",
            "Lombard", "Piedmontese", "Ligurian", "Emilian-Romagnol", "Friulian",
            "Sardinian", "Calabrian", "Apulian"
        ]
    case "Hindi":
        return ["Standard (Khari Boli)", "Awadhi", "Bhojpuri", "Braj", "Haryanvi", "Marwari", "Dakhini"]
    case "Urdu":
        return ["Standard", "Dakhini", "Rekhta", "Hyderabadi", "Lucknowi"]
    case "Persian":
        return ["Iranian (Standard Farsi)", "Dari (Afghanistan)", "Tajiki", "Hazaragi", "Bukhori"]
    case "Russian":
        return ["Standard (Moscow)", "Northern", "Southern", "Central", "Siberian"]
    case "Bengali":
        return ["Standard (Kolkata)", "Dhaka", "Sylheti", "Chittagonian", "Rangpuri", "Manbhumi"]
    case "Tamil":
        return [
            "Standard (Chennai)", "Brahmin Tamil", "Kongu", "Madurai", "Tirunelveli",
            "Jaffna (Sri Lankan)", "Batticaloa", "Malaysian Tamil", "Singaporean Tamil"
        ]
    case "Korean":
        return [
            "Standard (Seoul)", "Gyeongsang", "Jeolla", "Chungcheong",
            "Gangwon", "Jeju", "Pyongyang (North Korean)"
        ]
    case "Japanese":
        return [
            "Standard (Tokyo)", "Kansai (Osaka/Kyoto)", "Tohoku", "Kyushu",
            "Hokkaido", "Hakata", "Nagoya", "Okinawan"
        ]
    case "Dutch":
        return ["Standard (Netherlands)", "Flemish (Belgian)", "Surinamese", "Brabantian", "Hollandic", "Limburgish"]
    case "Greek":
        return ["Standard Modern", "Cypriot", "Pontic", "Cretan", "Tsakonian", "Griko"]
    case "Turkish":
        return ["Istanbul Standard", "Anatolian", "Rumelian", "Cypriot Turkish"]
    case "Polish":
        return ["Standard", "Silesian", "Kashubian", "Highlander (Góralski)", "Mazurian", "Greater Polish"]
    case "Vietnamese":
        return ["Northern (Hanoi)", "Central (Huế)", "Southern (Saigon)"]
    case "Swedish":
        return ["Standard (Rikssvenska)", "Skånsk", "Gotländska", "Finland Swedish", "Norrländska", "Götamål"]
    case "Norwegian":
        return ["Bokmål", "Nynorsk", "Trøndersk", "Nordlandsk", "Bergensk"]
    case "Danish":
        return ["Standard (Rigsdansk)", "Jutlandic", "Bornholmsk"]
    case "Finnish":
        return ["Standard", "Western", "Eastern", "Tampere", "Helsinki Slang"]
    case "Hungarian":
        return ["Standard", "Palóc", "Székely", "Csángó"]
    case "Czech":
        return ["Standard", "Moravian", "Silesian"]
    case "Slovak":
        return ["Standard", "Eastern", "Central", "Western"]
    case "Romanian":
        return ["Standard", "Moldovan", "Aromanian", "Megleno-Romanian", "Istro-Romanian"]
    case "Bulgarian":
        return ["Standard", "Eastern", "Western", "Rup"]
    case "Ukrainian":
        return ["Standard", "Western", "Northern", "Southwestern", "Southeastern"]
    case "Serbian", "Croatian", "Bosnian":
        return ["Štokavian (Standard)", "Čakavian", "Kajkavian", "Torlakian"]
    case "Albanian":
        return ["Tosk", "Gheg", "Arbëresh", "Arvanitika"]
    case "Armenian":
        return ["Eastern Armenian", "Western Armenian", "Karabakh"]
    case "Georgian":
        return ["Standard", "Imeretian", "Kakhetian", "Gurian"]
    case "Hebrew":
        return ["Modern Israeli", "Yemenite", "Mizrahi", "Ashkenazi", "Sephardi", "Tiberian (Biblical)"]
    case "Yiddish":
        return ["Standard (Eastern)", "Western", "Litvish", "Galitzianer", "Poylish", "Ukrainisher"]
    case "Swahili":
        return ["Kiunguja (Zanzibar)", "Kimvita (Mombasa)", "Kingozi", "Sheng (slang)"]
    case "Amharic":
        return ["Standard (Addis Ababa)", "Gondar", "Gojjam", "Shewa", "Wollo"]
    case "Hausa":
        return ["Standard (Kano)", "Sokoto", "Eastern Hausa", "Western Hausa"]
    case "Yoruba":
        return ["Standard", "Oyo", "Egba", "Ijebu", "Ekiti", "Ondo", "Lagos"]
    case "Igbo":
        return ["Standard", "Owerri", "Onitsha", "Aro", "Nsukka"]
    case "Zulu":
        return ["Standard", "KwaZulu-Natal"]
    case "Afrikaans":
        return ["Standard", "Cape Afrikaans", "Orange River Afrikaans", "Eastern Cape Afrikaans"]
    case "Thai":
        return ["Standard (Central)", "Northern (Lanna)", "Isan (Northeastern)", "Southern", "Royal/Court Thai"]
    case "Burmese":
        return ["Standard (Yangon)", "Rakhine", "Tavoyan", "Intha"]
    case "Khmer":
        return ["Standard (Phnom Penh)", "Northern (Battambang)", "Surin", "Cardamom (Western)"]
    case "Lao":
        return ["Vientiane (Standard)", "Northern", "Central", "Southern", "Northeastern"]
    case "Indonesian":
        return ["Standard (Baku)", "Jakartan (Betawi)", "Riau", "Medan", "Surabayan"]
    case "Malay":
        return ["Standard Malaysian", "Singaporean", "Bruneian", "Sabah", "Sarawak", "Patani"]
    case "Filipino":
        return ["Standard Filipino", "Manila Tagalog", "Batangas", "Bulacan", "Marinduque"]
    case "Welsh":
        return ["Standard", "North Welsh", "South Welsh", "Gwentian", "Powys"]
    case "Irish":
        return ["Standard (An Caighdeán)", "Ulster", "Connacht", "Munster"]
    case "Scots Gaelic":
        return ["Standard", "Lewis", "Skye", "Argyll", "Outer Hebrides"]
    case "Basque":
        return ["Standard (Batua)", "Biscayan", "Gipuzkoan", "Upper Navarrese", "Lapurdian", "Souletin"]
    case "Catalan":
        return ["Standard", "Valencian", "Balearic", "Roussillonese", "Algherese"]
    case "Galician":
        return ["Standard", "Eastern", "Central", "Western"]
    case "Maltese":
        return ["Standard", "Rural Maltese"]
    case "Mongolian":
        return ["Khalkha (Standard)", "Buryat", "Oirat", "Inner Mongolian (Chakhar)"]
    case "Nepali":
        return ["Standard", "Eastern", "Western", "Doteli"]
    case "Sinhala":
        return ["Standard", "Up-country", "Low-country"]
    case "Punjabi":
        return ["Majhi (Standard)", "Doabi", "Malwai", "Pothohari", "Multani", "Saraiki"]
    case "Marathi":
        return ["Standard (Puneri)", "Varhadi", "Dakhini", "Khandeshi"]
    case "Telugu":
        return ["Standard (Coastal)", "Telangana", "Rayalaseema", "Northern", "Brahmin"]
    case "Kannada":
        return ["Standard (Mysore)", "Mangalore", "Dharwad", "Northern", "Coastal"]
    case "Malayalam":
        return ["Standard", "Northern", "Southern", "Central"]
    case "Gujarati":
        return ["Standard", "Kathiyawadi", "Charotari", "Surati"]
    case "Pashto":
        return ["Northern (Yusufzai)", "Southern (Kandahari)", "Central (Wazirwola)"]
    case "Kurdish":
        return ["Kurmanji (Northern)", "Sorani (Central)", "Pehlewani (Southern)", "Zazaki", "Gorani"]
    case "Azerbaijani":
        return ["Northern (Standard)", "Southern (Iranian)", "Tabrizi"]
    case "Kazakh":
        return ["Standard", "Northeastern", "Southern", "Western"]
    case "Uzbek":
        return ["Standard (Tashkent)", "Karluk", "Kipchak", "Oghuz"]
    case "Uyghur":
        return ["Standard (Central)", "Hotan", "Lop"]
    case "Berber":
        return ["Tamazight", "Tachelhit", "Tarifit", "Kabyle", "Tuareg"]
    default:
        return ["Standard"]
    }
}
