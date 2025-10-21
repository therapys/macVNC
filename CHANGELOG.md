# macVNC Changelog

## [Unreleased] - 2025-10-21

### Added

- **Runtime flags for stream failure behavior**: New command-line flags to control recovery behavior:
  - `-exit-on-stream-failure` (default): Exit process with code 2 on silent stream failure
  - `-restart-on-stream-failure`: Attempt internal restart (legacy behavior)

### Changed

- **Default stream failure handling**: macVNC now exits the process (exit code 2) by default when ScreenCaptureKit stream stops silently without an error. This behavior can be reverted to internal restarts using `-restart-on-stream-failure`.

### Technical Details

When the ScreenCaptureKit stream stops unexpectedly without providing an error code (common scenarios: window loses focus, minimizes, display sleep, system events), macVNC now:

1. Logs diagnostic information about the stream state
2. Exits with code 2 to signal a silent stream failure
3. Relies on external process watchdog for recovery

This change enables more reliable recovery through the Flask server's `ProcessWatchdog`, which monitors the macVNC process and performs full restarts with proper resource cleanup.

### Benefits

- More reliable recovery from silent stream failures
- Prevents resource exhaustion from repeated internal restart attempts
- Better integration with external monitoring systems
- Clearer separation of concerns: macVNC focuses on streaming, watchdog handles process lifecycle

### Exit Codes

- **0**: Normal shutdown
- **1**: Configuration/initialization error (permissions, invalid args)
- **2**: Silent ScreenCaptureKit stream failure (new)

### Files Modified

- `src/ScreenCapturer.h`: Added `exitOnStreamFailure` parameter to initializer
- `src/ScreenCapturer.m`: Added property and conditional logic in `didStopWithError`
- `src/mac.m`: Added command-line flag parsing for `-exit-on-stream-failure` and `-restart-on-stream-failure`
- `README.md`: Added recovery behavior documentation and exit codes
- `../server/src/services/vnc_manager.py`: Updated to use `-exit-on-stream-failure` flag explicitly

