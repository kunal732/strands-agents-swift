import Foundation

/// Manages long-running agent tasks with support for iOS background execution.
///
/// When the app enters the background, the task manager can:
/// - Cancel running tasks
/// - Serialize state for later resumption
/// - Escalate remaining work to a cloud provider
public actor AgentTaskManager {
    private var activeTasks: [UUID: AgentTaskState] = [:]

    public init() {}

    /// Begin tracking a new agent task.
    public func beginTask(id: UUID = UUID(), backgroundPolicy: BackgroundPolicy = .cancelOnBackground) -> AgentTaskHandle {
        let state = AgentTaskState(id: id, backgroundPolicy: backgroundPolicy, status: .running)
        activeTasks[id] = state
        return AgentTaskHandle(id: id)
    }

    /// Mark a task as complete.
    public func completeTask(_ handle: AgentTaskHandle) {
        activeTasks[handle.id]?.status = .completed
    }

    /// Mark a task as failed.
    public func failTask(_ handle: AgentTaskHandle, error: Error) {
        activeTasks[handle.id]?.status = .failed(error.localizedDescription)
    }

    /// Serialize task state for background persistence.
    public func serializeState(for handle: AgentTaskHandle) throws -> Data? {
        guard let state = activeTasks[handle.id] else { return nil }
        return try JSONEncoder().encode(state.serializableState)
    }

    /// Handle app entering background.
    public func handleBackgroundTransition() -> [BackgroundAction] {
        var actions: [BackgroundAction] = []
        for (id, state) in activeTasks where state.status.isRunning {
            switch state.backgroundPolicy {
            case .cancelOnBackground:
                activeTasks[id]?.status = .cancelled
                actions.append(.cancelled(id))
            case .escalateToCloud:
                actions.append(.escalate(id))
            case .serializeAndResume:
                actions.append(.serialize(id))
            }
        }
        return actions
    }

    /// Check the status of a task.
    public func status(for handle: AgentTaskHandle) -> TaskStatus? {
        activeTasks[handle.id]?.status
    }
}

// MARK: - Types

/// Handle to a tracked agent task.
public struct AgentTaskHandle: Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

/// What to do when the app enters the background.
public enum BackgroundPolicy: Sendable, Codable {
    case cancelOnBackground
    case escalateToCloud
    case serializeAndResume
}

/// Status of a tracked task.
public enum TaskStatus: Sendable {
    case running
    case completed
    case failed(String)
    case cancelled
    case serialized

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Action taken when transitioning to background.
public enum BackgroundAction: Sendable {
    case cancelled(UUID)
    case escalate(UUID)
    case serialize(UUID)
}

// MARK: - Internal

private struct AgentTaskState {
    var id: UUID
    var backgroundPolicy: BackgroundPolicy
    var status: TaskStatus

    var serializableState: SerializableTaskState {
        SerializableTaskState(id: id, backgroundPolicy: backgroundPolicy)
    }
}

struct SerializableTaskState: Codable {
    var id: UUID
    var backgroundPolicy: BackgroundPolicy
}
