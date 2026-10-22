import BuddyCore

/// Runs the user's Claude Code: the Quick lane (warm Haiku in the home folder, plus a spare),
/// the Deep lane (Opus per trusted project folder, started on handoff), stream-json in and out.
///
/// - `LaunchSpec`, `LaunchEnvironment`: the command line, PATH and `claude` lookup.
/// - `ProcessTransport` / `ReplayTransport`: a real process, or recorded stream-json.
/// - `StreamEvent`: one parsed stream-json line.
/// - `ClaudeSession`: one process, one session, one turn at a time, as `TurnEvent`s.
/// - `QuickLane`, `DeepLane`, `DeepPolicy`, `FolderTrust`, `RestartPolicy`.
/// - `StatusMapper`, `BuddyBlockExtractor`, `SayStreamExtractor`.
public enum BuddyBridge {}
