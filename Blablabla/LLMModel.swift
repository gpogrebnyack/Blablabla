import Foundation

/// Cleanup models selectable in Settings. All are 4-bit MLX builds that
/// mlx-swift-lm can load; switching unloads the current one and loads (or
/// downloads) the new one.
enum LLMModel: String, CaseIterable, Identifiable {
    case qwen35_4b
    case qwen35_2b
    case gemma4_e4b
    case gemma4_e2b

    static let storageKey = "blabla.llm.model"
    static let `default`: LLMModel = .qwen35_4b

    static var stored: LLMModel {
        UserDefaults.standard.string(forKey: storageKey).flatMap(LLMModel.init(rawValue:)) ?? .default
    }

    var id: String { rawValue }

    /// Hugging Face repo id.
    var repoId: String {
        switch self {
        case .qwen35_4b:  return "mlx-community/Qwen3.5-4B-MLX-4bit"
        case .qwen35_2b:  return "mlx-community/Qwen3.5-2B-MLX-4bit"
        case .gemma4_e4b: return "mlx-community/gemma-4-e4b-it-4bit"
        case .gemma4_e2b: return "mlx-community/gemma-4-e2b-it-4bit"
        }
    }

    var label: String {
        switch self {
        case .qwen35_4b:  return "Qwen3.5 4B"
        case .qwen35_2b:  return "Qwen3.5 2B"
        case .gemma4_e4b: return "Gemma 4 E4B"
        case .gemma4_e2b: return "Gemma 4 E2B"
        }
    }

    /// Download size, for buttons and the disk-space advisor.
    var downloadGB: Double {
        switch self {
        case .qwen35_4b:  return 3.1
        case .qwen35_2b:  return 1.8
        case .gemma4_e4b: return 5.2
        case .gemma4_e2b: return 3.6
        }
    }

    var formattedSize: String { String(format: "~%.1f GB", downloadGB) }

    var detail: String {
        switch self {
        case .qwen35_4b:  return "Default. The model the cleanup prompt was tuned on."
        case .qwen35_2b:  return "About twice as fast as 4B; may miss subtler fixes."
        case .gemma4_e4b: return "Google, strong multilingual. Larger download (bundles vision/audio weights)."
        case .gemma4_e2b: return "Smaller Gemma 4 — faster, lighter on RAM."
        }
    }
}
