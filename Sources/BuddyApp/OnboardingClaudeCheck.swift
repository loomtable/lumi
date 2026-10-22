import BuddyCompanion
import Foundation

/// Onboarding step 2's check, through the same service Settings › Claude Code uses, so both
/// always show the same measured status. The first look joins a check already running (the one
/// launch starts); later looks ("Check again", the re-check) always run a new one. Starting the engine once Claude Code
/// turns up is the runtime's job (`ClaudeCodeService.onChecked`).
public final class OnboardingClaudeCheck: ClaudeCodeChecking {
    private let service: ClaudeCodeService
    private var looked = false

    public init(service: ClaudeCodeService) {
        self.service = service
    }

    public func check() async -> ClaudeCodeStatus {
        if looked {
            await service.checkAfresh()
        } else {
            looked = true
            await service.refresh()
        }
        return service.status
    }
}
