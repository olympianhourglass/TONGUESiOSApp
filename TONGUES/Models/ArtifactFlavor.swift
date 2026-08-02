import Foundation

// A "dial" the learner can spin at generation time to flavor a Story /
// Conversation / News Article artifact. Each dial is a single-select dropdown
// in the generate screen; the chosen option is woven into the generation
// prompt as a style direction. Option labels are English (they double as the
// prompt text); the UI localizes them through `L(...)` for display only.
enum ArtifactDial: String, CaseIterable, Identifiable {
    case vibe
    case voice
    case register
    case world
    case format
    case practice
    case wildcard
    case newsTone
    case relationship
    case situation

    var id: String { rawValue }

    // Row label shown next to the dropdown.
    var title: String {
        switch self {
        case .vibe:         return "Vibe"
        case .voice:        return "Voice"
        case .register:     return "Register"
        case .world:        return "World"
        case .format:       return "Format"
        case .practice:     return "Practice"
        case .wildcard:     return "Wildcard"
        case .newsTone:     return "News style"
        case .relationship: return "Who's talking"
        case .situation:    return "Situation"
        }
    }

    // The dials offered for each artifact kind, in display order. Kinds not
    // listed (songs / poems / jokes) get no flavor dials.
    static func dials(for kind: ContentGenerationKind) -> [ArtifactDial] {
        switch kind {
        case .story:
            return [.vibe, .voice, .register, .world, .format, .practice, .wildcard]
        case .conversation:
            return [.relationship, .situation, .register, .vibe, .practice]
        case .newsArticle:
            return [.newsTone, .register, .world, .format, .practice]
        case .songs, .poems, .jokes:
            return []
        }
    }

    // How a chosen option is phrased into the generation prompt.
    func directive(for option: String) -> String {
        switch self {
        case .vibe:         return "Tone / genre: \(option)."
        case .voice:        return "Narration / point of view: \(option)."
        case .register:     return "Register (level of formality): \(option)."
        case .world:        return "Setting: \(option)."
        case .format:       return "Structure / format: \(option)."
        case .practice:     return "Deliberately feature \(option.lowercased()) — keep it natural and level-appropriate — so the learner gets practice with it."
        case .wildcard:     return "Creative twist: \(option)."
        case .newsTone:     return "News style: \(option)."
        case .relationship: return "The speakers' relationship: \(option)."
        case .situation:    return "The scene / situation: \(option)."
        }
    }

    var options: [String] {
        switch self {
        case .vibe:
            return ["Horror", "Comedy", "Irony", "Fairy tale", "Noir", "Romance",
                    "Sci-fi", "Mystery", "Thriller", "Telenovela", "Satire",
                    "Absurdist", "Epic myth", "Tragedy", "Slice of life", "Adventure",
                    "Western", "Cyberpunk", "Magical realism", "Ghost story", "Cozy",
                    "Gothic", "Deadpan", "Whimsical", "Suspenseful", "Heartwarming",
                    "Bittersweet", "Uplifting", "Eerie"]
        case .voice:
            return ["First person", "Second person", "Diary entry", "A letter",
                    "All dialogue", "Unreliable narrator", "A child's voice",
                    "An object's point of view", "A pet's point of view",
                    "Stream of consciousness", "Told as gossip"]
        case .register:
            return ["Street slang", "Casual / texting", "Neutral", "Formal",
                    "Poetic", "Old-timey", "Corporate-speak", "Very polite", "Blunt"]
        case .world:
            return ["Medieval era", "The 1920s", "Victorian era", "Far future",
                    "Post-apocalyptic", "Present day", "Around a local holiday",
                    "A specific season", "Big-city street life", "A countryside village",
                    "Somewhere the language is natively spoken"]
        case .format:
            return ["As a recipe", "As text messages", "As a to-do list",
                    "As instructions", "Twist ending", "Cliffhanger ending",
                    "Told in reverse", "With a moral", "As an interview",
                    "Rhyming", "Alliterative"]
        case .practice:
            return ["Past tense", "Future tense", "Conditionals", "The subjunctive",
                    "Commands / imperatives", "Lots of questions", "Comparisons",
                    "Idioms & expressions", "High-frequency words only",
                    "Repetitive patterns", "Dialogue-heavy", "Description-heavy"]
        case .wildcard:
            return ["Something mundane treated as epic", "Everyone speaks in proverbs",
                    "An adult bedtime story", "A fever dream", "The villain's side of the tale",
                    "A product review of a feeling", "Told by a very tired narrator",
                    "A myth explaining an everyday thing"]
        case .newsTone:
            return ["Serious / factual", "Satirical", "Breaking news", "Human interest",
                    "Weird but true", "Sports", "Gossip / tabloid", "Weather report",
                    "Obituary", "Editorial / opinion", "Investigative", "Sensational",
                    "Dry & factual"]
        case .relationship:
            return ["Strangers", "Old friends", "Flirting", "A couple arguing",
                    "Boss & employee", "Customer & clerk", "Siblings",
                    "A reunion after years", "Teacher & student", "Parent & child"]
        case .situation:
            return ["Ordering food", "Haggling at a market", "Asking for directions",
                    "Making a complaint", "A job interview", "Small talk",
                    "An awkward misunderstanding", "Gossiping", "Making plans",
                    "Checking into a hotel", "At the doctor", "Saying goodbye"]
        }
    }
}

// The learner's chosen flavor for one artifact generation. Keyed by dial so it
// survives kind changes and only the applicable dials are ever read back out.
struct ArtifactFlavor: Equatable {
    // dial rawValue → selected option label. Absent = "Any" (unset).
    private var selections: [String: String] = [:]

    func option(for dial: ArtifactDial) -> String? {
        selections[dial.rawValue]
    }

    mutating func set(_ option: String?, for dial: ArtifactDial) {
        if let option, !option.isEmpty {
            selections[dial.rawValue] = option
        } else {
            selections.removeValue(forKey: dial.rawValue)
        }
    }

    // The prompt block for the dials that apply to `kind`, or "" if none chosen.
    func promptDirectives(for kind: ContentGenerationKind) -> String {
        let lines: [String] = ArtifactDial.dials(for: kind).compactMap { dial in
            guard let option = option(for: dial), !option.isEmpty else { return nil }
            return "• " + dial.directive(for: option)
        }
        return lines.joined(separator: "\n")
    }
}
