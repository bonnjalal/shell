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

        function checkAvail(): void {
            // console.log("[Howdy] checkAvail called.") // Debug log removed for brevity
            if (!available || !Config.lock.enableHowdy || !root.lock.secure) {
                abort();
                return;
            }
            tries = 0;
            errorTries = 0;
            if (root.screenIsIdle) {
                // console.log("[Howdy] checkAvail: Screen is IDLE, not starting Howdy.") // Debug log removed for brevity
                return;
            }
            // console.log("[Howdy] checkAvail: Screen is ACTIVE, starting Howdy.") // Debug log removed for brevity
            start();
        }

        config: "howdy"
        configDirectory: Quickshell.shellDir + "/assets/pam.d"

        onCompleted: res => {
            // console.log("[Howdy] onCompleted. Result:", res) // Debug log removed for brevity
            if (!available)
                return;
            if (res === PamResult.Success) {
                // console.log("[Howdy] onCompleted: Success.") // Debug log removed for brevity
                return root.lock.unlock();
            }
            if (res === PamResult.Error) {
                // console.log("[Howdy] onCompleted: Error.") // Debug log removed for brevity
                root.howdyState = "error";
                errorTries++;
                if (errorTries < 5) {
                    abort();
                    howdyErrorRetry.restart();
                }
            } else if (res === PamResult.MaxTries || res === PamResult.Failed) {
                // console.log("[Howdy] onCompleted: Failed or MaxTries.") // Debug log removed for brevity
                tries++;
                root.howdyState = "fail";
                if (!root.screenIsIdle) {
                    // console.log("[Howdy] onCompleted: Screen is ACTIVE, restarting Howdy.") // Debug log removed for brevity
                    start();
                } else
                // console.log("[Howdy] onCompleted: Screen is IDLE, NOT restarting Howdy.") // Debug log removed for brevity
                {}
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
            // console.log("[Howdy] howdyAvailProc exited with code:", code) // Debug log removed for brevity
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
        onTriggered: howdy.start()
    }
    Timer {
        id: howdyStateReset
        interval: 4000
        onTriggered: {
            root.howdyState = "";
            howdy.errorTries = 0;
        }
    }

    // NEW: Timer to delay the start of Howdy
    Timer {
        id: howdyStartDelayTimer
        interval: 2000 // 2 seconds
        repeat: false
        onTriggered: {
            console.log("[Pam] Howdy start delay timer triggered. Running availability check.");
            howdyAvailProc.running = true;
        }
    }

    Connections {
        target: root.lock
        function onSecureChanged(): void {
            // console.log("[Pam] onSecureChanged. Secure:", root.lock.secure) // Debug log removed for brevity
            if (root.lock.secure) {
                availProc.running = true;

                // MODIFIED: Don't start Howdy immediately. Start the delay timer instead.
                // howdyAvailProc.running = true; // <-- Old line
                console.log("[Pam] Screen locked. Starting 2-second delay for Howdy.");
                howdyStartDelayTimer.start(); // <-- New line

                root.buffer = "";
                root.state = "";
                root.fprintState = "";
                root.howdyState = "";
                root.lockMessage = "";
            } else {
                // console.log("[Pam] Unlocked, resetting screenIsIdle to false.") // Debug log removed for brevity
                root.screenIsIdle = false;

                // MODIFIED: Stop the timer if we unlock before it fires
                howdyStartDelayTimer.stop();
            }
        }
        function onUnlock(): void {
            // console.log("[Pam] onUnlock triggered.") // Debug log removed for brevity

            // MODIFIED: Stop the timer if we unlock (e.g., with password)
            howdyStartDelayTimer.stop();

            if (fprint.active)
                fprint.abort();
            if (howdy.active)
                howdy.abort();
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
    // NEW: Connection to self to watch for screenIsIdle changes
    Connections {
        target: root
        function onScreenIsIdleChanged() {
            console.log("--------------------------------------------------");
            console.log("[Pam] onScreenIsIdleChanged triggered. New value:", root.screenIsIdle);
            console.log("--------------------------------------------------");
            if (root.screenIsIdle) {
                // Screen just went idle. Abort Howdy.
                // MODIFIED: Added more detailed logging
                console.log("[Pam] Screen idle detected. Checking Howdy state. (Available:", howdy.available, "Active:", howdy.active + ")");
                if (howdy.available && howdy.active) {
                    console.log("[Pam] Howdy is active, aborting Howdy.");
                    howdy.abort();
                } else {
                    console.log("[Pam] Howdy is available but NOT active, no need to abort.");
                }
            } else {
                // Screen just woke up.
                console.log("[Pam] Screen wake detected. Checking Howdy state. (Available:", howdy.available, "Secure:", root.lock.secure, "Active:", howdy.active + ")"); // MODIFIED: Added log
                if (howdy.available && root.lock.secure && !howdy.active) {
                    console.log("[Pam] Screen wake detected, starting Howdy via checkAvail.");
                    howdy.checkAvail();
                } else {
                    console.log("[Pam] Screen wake detected, but NOT starting Howdy."); // MODIFIED: Simplified log
                }
            }
        }
    }
    Connections {
        target: root
        function onScreenIsIdleChanged() {
            // console.log("--------------------------------------------------") // Debug log removed for brevity
            // console.log("[Pam] onScreenIsIdleChanged triggered. New value:", root.screenIsIdle) // Debug log removed for brevity
            // console.log("--------------------------------------------------") // Debug log removed for brevity
            if (root.screenIsIdle) {
                // console.log("[Pam] Screen idle detected. Checking Howdy state. (Available:", howdy.available, "Active:", howdy.active + ")") // Debug log removed for brevity
                if (howdy.available && howdy.active) {
                    // console.log("[Pam] Howdy is active, aborting Howdy.") // Debug log removed for brevity
                    howdy.abort();
                } else
                // console.log("[Pam] Howdy is available but NOT active, no need to abort.") // Debug log removed for brevity
                {}
            } else {
                // console.log("[Pam] Screen wake detected. Checking Howdy state. (Available:", howdy.available, "Secure:", root.lock.secure, "Active:", howdy.active + ")") // Debug log removed for brevity
                if (howdy.available && root.lock.secure && !howdy.active) {
                    // console.log("[Pam] Screen wake detected, starting Howdy via checkAvail.") // Debug log removed for brevity
                    howdy.checkAvail();
                } else
                // console.log("[Pam] Screen wake detected, but NOT starting Howdy.") // Debug log removed for brevity
                {}
            }
        }
    }
}
