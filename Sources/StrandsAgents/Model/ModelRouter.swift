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
    /// Full conversation history including the latest user message.
    public var messages: [Message]
    /// Tool specs available to this invocation (nil if no tools registered).
    public var toolSpecs: [ToolSpec]?
    /// The agent's system prompt.
    public var systemPrompt: String?
    /// Developer-provided hints that influence the routing decision.
    public var hints: RoutingHints
    /// Live device state at the time of this request.
    public var deviceCapabilities: DeviceCapabilities
    /// Latency of the previous model call in this conversation (nil on first call).
    public var lastInferenceLatencyMs: Int?

    public init(
        messages: [Message],
        toolSpecs: [ToolSpec]? = nil,
        systemPrompt: String? = nil,
        hints: RoutingHints = RoutingHints(),
        deviceCapabilities: DeviceCapabilities = .current,
        lastInferenceLatencyMs: Int? = nil
    ) {
        self.messages = messages
        self.toolSpecs = toolSpecs
        self.systemPrompt = systemPrompt
        self.hints = hints
        self.deviceCapabilities = deviceCapabilities
        self.lastInferenceLatencyMs = lastInferenceLatencyMs
    }

    /// Rough token estimate for the current conversation (character count / 4).
    /// Useful for policies that want to avoid sending long contexts to local models.
    public var estimatedPromptTokens: Int {
        let text = messages.compactMap(\.textContent).joined(separator: " ")
        return max(1, text.count / 4)
    }
}

/// Developer-provided hints that influence routing decisions.
public struct RoutingHints: Sendable {
    /// Prefer the fastest available provider, even at the cost of capability.
    public var preferLowLatency: Bool
    /// The prompt contains data that should not leave the device.
    public var privacySensitive: Bool
    /// The task requires strong multi-step reasoning -- prefer a capable cloud model.
    public var requiresDeepReasoning: Bool
    /// Bypass the policy and hard-route to a specific provider.
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

/// Live device state passed to every routing decision.
public struct DeviceCapabilities: Sendable {
    /// True on Apple Silicon (arm64). Intel Macs and simulators return false.
    public var hasNeuralEngine: Bool
    /// RAM currently free and available to allocate, in gigabytes.
    public var availableMemoryGB: Double
    /// Whether the device is connected to external power.
    /// Set `DeviceCapabilities.isPluggedInProvider` in your app to read the real value.
    public var isPluggedIn: Bool
    /// Current thermal throttling state from the OS.
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

    // MARK: - Power source hook

    /// Override this closure in your app to provide real power source information.
    ///
    /// On iOS, read from `UIDevice.current.batteryState`. On macOS, read from IOKit.
    /// If not set, `isPluggedIn` defaults to `true` (conservative: assume plugged in).
    ///
    /// ```swift
    /// // In your AppDelegate or @main:
    /// UIDevice.current.isBatteryMonitoringEnabled = true
    /// DeviceCapabilities.isPluggedInProvider = {
    ///     UIDevice.current.batteryState != .unplugged
    /// }
    /// ```
    public nonisolated(unsafe) static var isPluggedInProvider: (@Sendable () -> Bool)?

    // MARK: - Live snapshot

    /// Query the current device state. Called once per routing decision.
    public static var current: DeviceCapabilities {
        #if canImport(Darwin)
        return DeviceCapabilities(
            hasNeuralEngine: _hasNeuralEngine,
            availableMemoryGB: _availableMemoryGB(),
            isPluggedIn: isPluggedInProvider?() ?? true,
            thermalState: _mapThermalState(ProcessInfo.processInfo.thermalState)
        )
        #else
        return DeviceCapabilities()
        #endif
    }

    // MARK: - Private helpers

    #if canImport(Darwin)

    /// True on arm64 Darwin (Apple Silicon Mac, iPhone, iPad).
    private static var _hasNeuralEngine: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Available memory in GB using vm_statistics64. Falls back to half of
    /// physical RAM if the kernel call fails.
    private static func _availableMemoryGB() -> Double {
        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<Int32>.stride
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &vmStat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return Double(ProcessInfo.processInfo.physicalMemory) / 2_147_483_648
        }
        // free_count + speculative_count = memory the OS can give out immediately
        let freePages = UInt64(vmStat.free_count) + UInt64(vmStat.speculative_count)
        // Use sysctl to get page size -- avoids the global mutable vm_page_size
        var pageSize: Int = 4096
        var mib: [Int32] = [CTL_HW, HW_PAGESIZE]
        var size = MemoryLayout<Int>.size
        sysctl(&mib, 2, &pageSize, &size, nil, 0)
        return Double(freePages) * Double(pageSize) / 1_073_741_824
    }

    private static func _mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    #endif
}

/// A routing decision record emitted for observability.
public struct RoutingDecision: Sendable {
    public var selectedProvider: String
    public var reason: String
    public var evaluatedPolicies: [String]
    public var fallback: Bool

    public init(
        selectedProvider: String,
        reason: String,
        evaluatedPolicies: [String] = [],
        fallback: Bool = false
    ) {
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
///
/// ```swift
/// let agent = Agent(
///     router: HybridRouter(
///         local: MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit"),
///         cloud: BedrockProvider(...),
///         policy: FallbackPolicy()
///     )
/// )
/// ```
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
        // Hard override takes priority over any policy
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

        if let local = localProvider, policy.shouldUseLocal(context: context) {
            return local
        }
        return cloudProvider
    }
}

// MARK: - RoutingPolicy protocol

/// Policy that decides whether a request should go to the local provider.
public protocol RoutingPolicy: Sendable {
    func shouldUseLocal(context: RoutingContext) -> Bool
}

// MARK: - Built-in Policies

/// Always use the cloud provider. Default when no policy is specified.
public struct AlwaysCloudPolicy: RoutingPolicy {
    public init() {}
    public func shouldUseLocal(context: RoutingContext) -> Bool { false }
}

/// Always use the local provider.
public struct AlwaysLocalPolicy: RoutingPolicy {
    public init() {}
    public func shouldUseLocal(context: RoutingContext) -> Bool { true }
}

/// Route to local when the request is privacy-sensitive, low-latency is preferred,
/// or the device is on battery with enough free memory. Falls back to cloud for
/// deep reasoning tasks or when the device is thermally constrained.
///
/// This is the recommended general-purpose policy for most apps.
public struct LatencySensitivePolicy: RoutingPolicy {
    /// Minimum available RAM (GB) required before running locally on battery.
    public let minimumMemoryGBOnBattery: Double
    /// Maximum prompt token estimate for local routing (larger prompts go to cloud).
    public let maxLocalPromptTokens: Int

    public init(minimumMemoryGBOnBattery: Double = 2.0, maxLocalPromptTokens: Int = 2000) {
        self.minimumMemoryGBOnBattery = minimumMemoryGBOnBattery
        self.maxLocalPromptTokens = maxLocalPromptTokens
    }

    public func shouldUseLocal(context: RoutingContext) -> Bool {
        let dev = context.deviceCapabilities

        // Never route locally if device is critically throttled
        if dev.thermalState == .critical { return false }

        // Explicit privacy request: always local regardless of other signals
        if context.hints.privacySensitive { return true }

        // Deep reasoning requested: cloud handles it better
        if context.hints.requiresDeepReasoning { return false }

        // Long context: local models struggle with very long prompts
        if context.estimatedPromptTokens > maxLocalPromptTokens { return false }

        // On battery: require enough free memory for inference
        if !dev.isPluggedIn && dev.availableMemoryGB < minimumMemoryGBOnBattery { return false }

        // Low latency preference: route locally
        if context.hints.preferLowLatency { return true }

        // If plugged in and thermal is fine: prefer local for short prompts
        if dev.isPluggedIn && dev.thermalState == .nominal { return true }

        return false
    }
}

/// Route to local by default unless the task requires deep reasoning,
/// the device is thermally constrained, or the previous inference was slow.
///
/// Good for apps where local is the primary choice and cloud is the safety net.
public struct FallbackPolicy: RoutingPolicy {
    /// If the last local inference exceeded this threshold (ms), route to cloud.
    public let slowInferenceThresholdMs: Int
    /// Minimum free memory (GB) required to attempt local inference.
    public let minimumMemoryGB: Double

    public init(slowInferenceThresholdMs: Int = 5000, minimumMemoryGB: Double = 1.5) {
        self.slowInferenceThresholdMs = slowInferenceThresholdMs
        self.minimumMemoryGB = minimumMemoryGB
    }

    public func shouldUseLocal(context: RoutingContext) -> Bool {
        let dev = context.deviceCapabilities

        // Thermal safety: serious or critical throttling means local inference will be slow
        if dev.thermalState == .serious || dev.thermalState == .critical { return false }

        // Not enough free memory to load / run a local model
        if dev.availableMemoryGB < minimumMemoryGB { return false }

        // Task explicitly needs a strong model
        if context.hints.requiresDeepReasoning { return false }

        // Previous inference was too slow — the local model is struggling
        if let latency = context.lastInferenceLatencyMs, latency > slowInferenceThresholdMs {
            return false
        }

        return true
    }
}
