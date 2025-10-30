import qs.config
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import QtQuick

Scope {
    id: root

    required property WlSessionLock lock
    required property bool screenActive // NEW: Pass screen state from IdleMonitors

    readonly property alias passwd: passwd
    readonly property alias fprint: fprint
    readonly property alias howdy: howdy
    property string lockMessage
    property string state
    property string fprintState
    property string howdyState
    property string buffer

    signal flashMsg

    function handleKey(event: KeyEvent): void {
        if (passwd.active || state === "max")
            return;

        if (event.key === Qt.Key_Enter || event.key === Qt.Key_Return) {
            passwd.start();
        } else if (event.key === Qt.Key_Backspace) {
            if (event.modifiers & Qt.ControlModifier) {
                buffer = "";
            } else {
                buffer = buffer.slice(0, -1);
            }
        } else if (" abcdefghijklmnopqrstuvwxyz1234567890`~!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?".includes(event.text.toLowerCase())) {
            buffer += event.text;
        }
    }

    PamContext {
        id: passwd

        config: "passwd"
        configDirectory: Quickshell.shellDir + "/assets/pam.d"

        onMessageChanged: {
            if (message.startsWith("The account is locked"))
                root.lockMessage = message;
            else if (root.lockMessage && message.endsWith(" left to unlock)"))
                root.lockMessage += "\n" + message;
        }

        onResponseRequiredChanged: {
            if (!responseRequired)
                return;

            respond(root.buffer);
            root.buffer = "";
        }

        onCompleted: res => {
            if (res === PamResult.Success)
                return root.lock.unlock();

            if (res === PamResult.Error)
                root.state = "error";
            else if (res === PamResult.MaxTries)
                root.state = "max";
            else if (res === PamResult.Failed)
                root.state = "fail";

            root.flashMsg();
            stateReset.restart();
        }
    }

    PamContext {
        id: fprint

        property bool available
        property int tries
        property int errorTries

        function checkAvail(): void {
            if (!available || !Config.lock.enableFprint || !root.lock.secure) {
                abort();
                return;
            }

            tries = 0;
            errorTries = 0;
            start();
        }

        config: "fprint"
        configDirectory: Quickshell.shellDir + "/assets/pam.d"

        onCompleted: res => {
            if (!available)
                return;

            if (res === PamResult.Success)
                return root.lock.unlock();

            if (res === PamResult.Error) {
                root.fprintState = "error";
                errorTries++;
                if (errorTries < 5) {
                    abort();
                    errorRetry.restart();
                }
            } else if (res === PamResult.MaxTries) {
                tries++;
                if (tries < Config.lock.maxFprintTries) {
                    root.fprintState = "fail";
                    start();
                } else {
                    root.fprintState = "max";
                    abort();
                }
            }

            root.flashMsg();
            fprintStateReset.start();
        }
    }

    PamContext {
        id: howdy

        property bool available
        property int tries
        property int errorTries
        property bool shouldBeRunning: false // NEW: Track if Howdy should be running

        function checkAvail(): void {
            if (!available || !Config.lock.enableHowdy || !root.lock.secure) {
                shouldBeRunning = false;
                abort();
                return;
            }

            // NEW: Add delay to prevent accidental unlock right after locking
            howdyStartDelay.restart();
        }

        function startIfNeeded(): void {
            // NEW: Only start if screen is active and should be running
            if (shouldBeRunning && root.screenActive && !active) {
                tries = 0;
                errorTries = 0;
                start();
            }
        }

        function stopIfNeeded(): void {
            // NEW: Stop Howdy when screen goes inactive
            if (active) {
                abort();
            }
        }

        config: "howdy"
        configDirectory: Quickshell.shellDir + "/assets/pam.d"

        onCompleted: res => {
            if (!available || !shouldBeRunning)
                return;

            if (res === PamResult.Success)
                return root.lock.unlock();

            if (res === PamResult.Error) {
                root.howdyState = "error";
                errorTries++;
                if (errorTries < 5) {
                    abort();
                    howdyErrorRetry.restart();
                }
            } else if (res === PamResult.MaxTries || res === PamResult.Failed) {
                tries++;
                root.howdyState = "fail";
                // NEW: Continuous loop - restart immediately if screen is active
                if (root.screenActive && shouldBeRunning) {
                    howdyRetryDelay.restart();
                }
            }

            root.flashMsg();
            howdyStateReset.restart();
        }
    }

    Process {
        id: availProc

        command: ["sh", "-c", "fprintd-list $USER"]
        onExited: code => {
            fprint.available = code === 0;
            fprint.checkAvail();
        }
    }

    Process {
        id: howdyAvailProc

        command: ["sh", "-c", "command -v howdy"]
        onExited: code => {
            howdy.available = code === 0;
            howdy.checkAvail();
        }
    }

    Timer {
        id: errorRetry

        interval: 800
        onTriggered: fprint.start()
    }

    Timer {
        id: stateReset

        interval: 4000
        onTriggered: {
            if (root.state !== "max")
                root.state = "";
        }
    }

    Timer {
        id: fprintStateReset

        interval: 4000
        onTriggered: {
            root.fprintState = "";
            fprint.errorTries = 0;
        }
    }

    Timer {
        id: howdyErrorRetry

        interval: 800
        onTriggered: howdy.startIfNeeded()
    }

    Timer {
        id: howdyStateReset

        interval: 4000
        onTriggered: {
            root.howdyState = "";
            howdy.errorTries = 0;
        }
    }

    // NEW: Delay before starting Howdy to prevent accidental unlock
    Timer {
        id: howdyStartDelay

        interval: Config.lock.howdyStartDelay ?? 2000 // Default 2 seconds
        onTriggered: {
            howdy.shouldBeRunning = true;
            howdy.startIfNeeded();
        }
    }

    // NEW: Small delay between Howdy retry attempts
    Timer {
        id: howdyRetryDelay

        interval: 500
        onTriggered: howdy.startIfNeeded()
    }

    // NEW: Monitor screen active state changes
    onScreenActiveChanged: {
        if (screenActive) {
            // Screen woke up - restart Howdy if it should be running
            howdy.startIfNeeded();
        } else {
            // Screen went idle/dim - stop Howdy
            howdy.stopIfNeeded();
        }
    }

    Connections {
        target: root.lock

        function onSecureChanged(): void {
            if (root.lock.secure) {
                availProc.running = true;
                howdyAvailProc.running = true;
                root.buffer = "";
                root.state = "";
                root.fprintState = "";
                root.howdyState = "";
                root.lockMessage = "";
            } else {
                // NEW: Stop Howdy when unlocking
                howdy.shouldBeRunning = false;
                howdy.stopIfNeeded();
            }
        }

        function onUnlock(): void {
            if (fprint.active)
                fprint.abort();

            if (howdy.active)
                howdy.abort();

            // NEW: Reset Howdy state
            howdy.shouldBeRunning = false;
        }
    }

    Connections {
        target: Config.lock

        function onEnableFprintChanged(): void {
            fprint.checkAvail();
        }

        function onEnableHowdyChanged(): void {
            howdy.checkAvail();
        }
    }
}
