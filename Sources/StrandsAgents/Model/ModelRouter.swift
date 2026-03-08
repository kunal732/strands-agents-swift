import Foundation

/// Selects which `ModelProvider` should handle a given request.
///
/// The router enables hybrid execution between local (MLX) and cloud (Bedrock) models.
/// Developers can implement custom routing logic or use built-in policies.
public protocol ModelRouter: Sendable {
    /// Select a model provider for the given context.
    func route(context: RoutingContext) async throws -> any ModelProvider
}

/// Context provided to the router for making routing decisions.
public struct RoutingContext: Sendable {
    public var messages: [Message]
    public var toolSpecs: [ToolSpec]?
    public var systemPrompt: String?
    public var hints: RoutingHints
    public var deviceCapabilities: DeviceCapabilities

    public init(
        messages: [Message],
        toolSpecs: [ToolSpec]? = nil,
        systemPrompt: String? = nil,
        hints: RoutingHints = RoutingHints(),
        deviceCapabilities: DeviceCapabilities = .current
    ) {
        self.messages = messages
        self.toolSpecs = toolSpecs
        self.systemPrompt = systemPrompt
        self.hints = hints
        self.deviceCapabilities = deviceCapabilities
    }
}

/// Developer-provided hints that influence routing decisions.
public struct RoutingHints: Sendable {
    /// Prefer low-latency provider.
    public var preferLowLatency: Bool
    /// Content contains privacy-sensitive data.
    public var privacySensitive: Bool
    /// Require high reasoning capability.
    public var requiresDeepReasoning: Bool
    /// Force a specific provider (bypass routing logic).
    public var forceProvider: ProviderPreference?

    public init(
        preferLowLatency: Bool = false,
        privacySensitive: Bool = false,
        requiresDeepReasoning: Bool = false,
        forceProvider: ProviderPreference? = nil
    ) {
        self.preferLowLatency = preferLowLatency
        self.privacySensitive = privacySensitive
        self.requiresDeepReasoning = requiresDeepReasoning
        self.forceProvider = forceProvider
    }
}

public enum ProviderPreference: Sendable {
    case local
    case cloud
}

/// Information about the current device's capabilities.
public struct DeviceCapabilities: Sendable {
    public var hasNeuralEngine: Bool
    public var availableMemoryGB: Double
    public var isPluggedIn: Bool
    public var thermalState: ThermalState

    public init(
        hasNeuralEngine: Bool = false,
        availableMemoryGB: Double = 0,
        isPluggedIn: Bool = true,
        thermalState: ThermalState = .nominal
    ) {
        self.hasNeuralEngine = hasNeuralEngine
        self.availableMemoryGB = availableMemoryGB
        self.isPluggedIn = isPluggedIn
        self.thermalState = thermalState
    }

    public enum ThermalState: Sendable {
        case nominal, fair, serious, critical
    }

    /// Query the current device capabilities.
    public static var current: DeviceCapabilities {
        #if canImport(Darwin)
        return DeviceCapabilities(
            hasNeuralEngine: true,
            availableMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            isPluggedIn: true,
            thermalState: mapThermalState(ProcessInfo.processInfo.thermalState)
        )
        #else
        return DeviceCapabilities()
        #endif
    }

    #if canImport(Darwin)
    private static func mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
    #endif
}

/// A routing decision record, emitted for observability.
public struct RoutingDecision: Sendable {
    public var selectedProvider: String
    public var reason: String
    public var evaluatedPolicies: [String]
    public var fallback: Bool

    public init(selectedProvider: String, reason: String, evaluatedPolicies: [String] = [], fallback: Bool = false) {
        self.selectedProvider = selectedProvider
        self.reason = reason
        self.evaluatedPolicies = evaluatedPolicies
        self.fallback = fallback
    }
}

// MARK: - Built-in Routers

/// A router that always uses a single provider. Used when no routing is needed.
public struct SingleProviderRouter: ModelRouter {
    private let provider: any ModelProvider

    public init(provider: any ModelProvider) {
        self.provider = provider
    }

    public func route(context: RoutingContext) async throws -> any ModelProvider {
        provider
    }
}

/// A router that supports hybrid local/cloud execution with configurable policies.
public struct HybridRouter: ModelRouter {
    public let localProvider: (any ModelProvider)?
    public let cloudProvider: any ModelProvider
    public let policy: any RoutingPolicy

    public init(
        local: (any ModelProvider)? = nil,
        cloud: any ModelProvider,
        policy: any RoutingPolicy = AlwaysCloudPolicy()
    ) {
        self.localProvider = local
        self.cloudProvider = cloud
        self.policy = policy
    }

    public func route(context: RoutingContext) async throws -> any ModelProvider {
        // Respect force overrides
        if let pref = context.hints.forceProvider {
            switch pref {
            case .local:
                guard let local = localProvider else {
                    throw StrandsError.routingFailed(reason: "Local provider not configured")
                }
                return local
            case .cloud:
                return cloudProvider
            }
        }

        // Evaluate policy
        if let local = localProvider, policy.shouldUseLocal(context: context) {
            return local
        }
        return cloudProvider
    }
}

/// Policy that determines whether local inference should be used.
public protocol RoutingPolicy: Sendable {
    func shouldUseLocal(context: RoutingContext) -> Bool
}

/// Always route to cloud.
public struct AlwaysCloudPolicy: RoutingPolicy {
    public init() {}
    public func shouldUseLocal(context: RoutingContext) -> Bool { false }
}

/// Always route to local (MLX).
public struct AlwaysLocalPolicy: RoutingPolicy {
    public init() {}
    public func shouldUseLocal(context: RoutingContext) -> Bool { true }
}

/// Prefer local when privacy-sensitive or low-latency is requested.
public struct LatencySensitivePolicy: RoutingPolicy {
    public init() {}
    public func shouldUseLocal(context: RoutingContext) -> Bool {
        context.hints.preferLowLatency || context.hints.privacySensitive
    }
}

/// Try local first, fall back to cloud on failure.
public struct FallbackPolicy: RoutingPolicy {
    public init() {}
    public func shouldUseLocal(context: RoutingContext) -> Bool {
        !context.hints.requiresDeepReasoning
            && context.deviceCapabilities.thermalState != .critical
    }
}
