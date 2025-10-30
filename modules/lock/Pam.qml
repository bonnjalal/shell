import qs.config
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import QtQuick

Scope {
    id: root

    required property WlSessionLock lock

    readonly property alias passwd: passwd
    readonly property alias fprint: fprint
    readonly property alias howdy: howdy
    property string lockMessage
    property string state
    property string fprintState
    property string howdyState
    property string buffer

    // NEW: This property will be controlled by IdleMonitors.qml
    property bool screenIsIdle: false

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
            // No illegal characters (you are insane if you use unicode in your password)
            buffer += event.text;
        }
    }

    PamContext {
        id: passwd
        // ... (no changes to passwd) ...
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
        // ... (no changes to fprint) ...
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
                // Isn't actually the real max tries as pam only reports completed
                // when max tries is reached.
                tries++;
                if (tries < Config.lock.maxFprintTries) {
                    // Restart if not actually real max tries
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

        function checkAvail(): void {
            if (!available || !Config.lock.enableHowdy || !root.lock.secure) {
                abort();
                return;
            }

            tries = 0;
            errorTries = 0;

            // MODIFIED: Do not start Howdy if the screen is idle
            if (root.screenIsIdle) {
                // console.log("Screen is idle, not starting Howdy.")
                return;
            }

            // console.log("Screen is active, starting Howdy.")
            start();
        }

        config: "howdy"
        configDirectory: Quickshell.shellDir + "/assets/pam.d"

        onCompleted: res => {
            if (!available)
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

                // MODIFIED: Only restart if the screen is not idle
                if (!root.screenIsIdle) {
                    start();
                } else
                // console.log("Howdy failed, not restarting as screen is idle.")
                {}
            }

            root.flashMsg();
            howdyStateReset.restart();
        }
    }
    Process {
        id: availProc
        // ... (no changes) ...
        command: ["sh", "-c", "fprintd-list $USER"]
        onExited: code => {
            fprint.available = code === 0;
            fprint.checkAvail();
        }
    }
    Process {
        id: howdyAvailProc
        // ... (no changes) ...
        command: ["sh", "-c", "command -v howdy"]
        onExited: code => {
            howdy.available = code === 0;
            howdy.checkAvail();
        }
    }

    Timer {
        id: errorRetry
        // ... (no changes) ...
        interval: 800
        onTriggered: fprint.start()
    }

    Timer {
        id: stateReset
        // ... (no changes) ...
        interval: 4000
        onTriggered: {
            if (root.state !== "max")
                root.state = "";
        }
    }

    Timer {
        id: fprintStateReset
        // ... (no changes) ...
        interval: 4000
        onTriggered: {
            root.fprintState = "";
            fprint.errorTries = 0;
        }
    }

    Timer {
        id: howdyErrorRetry
        // ... (no changes) ...
        interval: 800
        onTriggered: howdy.start()
    }

    Timer {
        id: howdyStateReset
        // ... (no changes) ...
        interval: 4000
        onTriggered: {
            root.howdyState = "";
            howdy.errorTries = 0;
        }
    }

    Connections {
        target: root.lock
        // ... (no changes) ...
        function onSecureChanged(): void {
            if (root.lock.secure) {
                availProc.running = true;
                howdyAvailProc.running = true; // This will call howdy.checkAvail()
                root.buffer = "";
                root.state = "";
                root.fprintState = "";
                root.howdyState = "";
                root.lockMessage = "";
            } else {
                // NEW: When unlocked, reset idle state just in case
                root.screenIsIdle = false;
            }
        }

        function onUnlock(): void {
            if (fprint.active)
                fprint.abort();

            if (howdy.active)
                howdy.abort();
        }
    }

    Connections {
        target: Config.lock
        // ... (no changes) ...
        function onEnableFprintChanged(): void {
            fprint.checkAvail();
        }

        function onEnableHowdyChanged(): void {
            howdy.checkAvail();
        }
    }

    // NEW: Connection to self to watch for screenIsIdle changes
    Connections {
        target: root

        function onScreenIsIdleChanged() {
            if (root.screenIsIdle) {
                // Screen just went idle. Abort Howdy.
                if (howdy.available && howdy.active) {
                    // console.log("Screen idle detected, aborting Howdy.")
                    howdy.abort();
                }
            } else {
                // Screen just woke up.
                // Start Howdy (checkAvail will handle all conditions)
                if (howdy.available && root.lock.secure && !howdy.active) {
                    // console.log("Screen wake detected, starting Howdy.")
                    howdy.checkAvail();
                }
            }
        }
    }
}
