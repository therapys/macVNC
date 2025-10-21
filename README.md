[![CI](https://github.com/LibVNC/macVNC/actions/workflows/ci.yml/badge.svg)](https://github.com/LibVNC/macVNC/actions/workflows/ci.yml)

# About

macVNC is a simple command-line VNC server for macOS.

It is [based on the macOS server example from LibVNCServer](https://github.com/LibVNC/libvncserver/commits/6e5f96e3ea53bf85cec7d985b120daf1c91ce0d9/examples/mac.c?browsing_rename_history=true&new_path=examples/server/mac.c&original_branch=master)
which in turn is based on OSXvnc by Dan McGuirk which again is based on the original VNC
GPL dump by AT&T Cambridge.

## Features

* Fully multi-threaded.
* Double-buffering for framebuffer updates.
* Window-only capture (stream a single selected window).
* Mouse input and keyboard typing (printable keys) only.
* Built-in window lister (`-listwindows`) to discover `windowid`s.

# Building

You'll need LibVNCServer for building macVNC; the easiest way of installing this is via a package manager:
If using Homebrew, you can install via `brew install libvncserver`; if using MacPorts, use `sudo port
install LibVNCServer`.

macVNC uses CMake, thus after installing build dependencies it's:

    mkdir build
    cd build
    cmake ..
    cmake --build .
    cmake --install .

# Running

As you might have Apple's Remote Desktop Server already running (which occupies port 5900),
you can run macVNC on another port.

1) List on-screen windows to find the target `windowid`:

    ./macVNC.app/Contents/MacOS/macVNC -listwindows

2) Start streaming a specific window (mandatory):

    ./macVNC.app/Contents/MacOS/macVNC -windowid <id> -rfbport 5901

## Recovery Behavior

macVNC can be configured to handle silent ScreenCaptureKit stream failures in two ways:

- **Exit mode** (default, `-exit-on-stream-failure`): Exit the process with code 2 when the stream stops unexpectedly. This allows external watchdog processes to detect the failure and restart macVNC with proper cleanup.

- **Restart mode** (`-restart-on-stream-failure`): Attempt internal restarts when the stream stops. This is the legacy behavior but may lead to resource exhaustion under certain conditions.

Example with explicit exit mode:

    ./macVNC.app/Contents/MacOS/macVNC -windowid <id> -exit-on-stream-failure -rfbport 5901

## Permissions
- Screen Recording: required to capture the window.
- Accessibility: required to post mouse/keyboard input.

If launched from Terminal, the permission dialogs may show 'Terminal' instead of 'macVNC'.

Note that setting a password is mandatory in case you want to access the server using MacOS's built-in Screen Sharing app.
You can do so via the `-passwd` commandline argument.

# Exit Codes

macVNC uses specific exit codes to indicate different failure scenarios:

- **Exit code 0**: Normal shutdown
- **Exit code 1**: Configuration or initialization error (missing permissions, invalid arguments, etc.)
- **Exit code 2**: Silent ScreenCaptureKit stream failure (window closed, minimized, display sleep, etc.)

When exit code 2 is returned, the ScreenCaptureKit stream stopped unexpectedly without providing an error.
This typically happens when the target window loses focus, is minimized, or other system events interrupt capture.
External watchdog processes can monitor for this exit code and automatically restart macVNC for recovery.

# License

As its predecessors, macVNC is licensed under the GPL version 2. See [COPYING](COPYING) for more information.




