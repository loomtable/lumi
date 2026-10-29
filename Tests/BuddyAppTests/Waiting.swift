/// How long a test in this target waits for a condition before it fails. A ceiling, not a budget:
/// every wait here returns as soon as its condition holds, so a passing test is as fast as before.
/// 2 s was missed under load (load average 60–158 with parallel builds): tests failed, and a test
/// that then indexed what it waited for crashed the whole run ("Index out of range").
/// Waits that check something does *not* happen stay short and don't use this.
let waitCeiling: Duration = .seconds(30)
