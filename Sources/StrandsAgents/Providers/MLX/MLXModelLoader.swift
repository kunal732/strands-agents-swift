import Foundation
import MLXLMCommon

/// Manages loading and caching of MLX models.
actor MLXModelLoader {
    /// Shared singleton loader.
    static let shared = MLXModelLoader()

    private var cache: [String: ModelContainer] = [:]

    /// Load a model by HuggingFace model ID, using cache if available.
    /// - Parameter onProgress: optional closure called with 0.0→1.0 during download.
    func load(
        modelId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelContainer {
        if let cached = cache[modelId] {
            return cached
        }

        let container = try await loadModelContainer(id: modelId) { progress in
            onProgress?(progress.fractionCompleted)
        }
        cache[modelId] = container
        return container
    }

    /// Evict a model from cache to free memory.
    func evict(modelId: String) {
        cache.removeValue(forKey: modelId)
    }

    /// Evict all cached models.
    func evictAll() {
        cache.removeAll()
    }
}
