pragma ComponentBehavior: Bound

import "lock"
import qs.config
import qs.services
import Caelestia.Internal
import Quickshell
import Quickshell.Wayland

Scope {
    id: root

    required property Lock lock
    readonly property bool enabled: !Config.general.idle.inhibitWhenAudio || !Players.list.some(p => p.isPlaying)

    function handleIdleAction(action: var): void {
        if (!action)
            return;

        if (action === "lock")
            lock.lock.locked = true;
        else if (action === "unlock")
            lock.lock.locked = false;
        else if (typeof action === "string")
            Hypr.dispatch(action);
        else
            Quickshell.execDetached(action);
    }

    LogindManager {
        onAboutToSleep: {
            if (Config.general.idle.lockBeforeSleep)
                root.lock.lock.locked = true;
        }
        onLockRequested: root.lock.locked = true
        onUnlockRequested: root.lock.unlock()
    }

    Variants {
        model: Config.general.idle.timeouts

        IdleMonitor {
            required property var modelData

            enabled: root.enabled && (modelData.enabled ?? true)
            timeout: modelData.timeout
            respectInhibitors: modelData.respectInhibitors ?? true

            // MODIFIED: This is the hook
            onIsIdleChanged: {
                console.log("[IdleMonitor] onIsIdleChanged triggered. isIdle:", isIdle);

                // Run the original action
                root.handleIdleAction(isIdle ? modelData.idleAction : modelData.returnAction);

                // --- NEW LOGIC ---
                let idleActionString = "";
                if (typeof modelData.idleAction === "string")
                    idleActionString = modelData.idleAction;
                else if (Array.isArray(modelData.idleAction))
                    idleActionString = modelData.idleAction.join(" ");

                console.log("[IdleMonitor] Checking idleAction string:", idleActionString);

                if (idleActionString.includes("dpms off")) {
                    console.log("[IdleMonitor] 'dpms off' string FOUND. Setting screenIsIdle to:", isIdle);

                    if (root.lock.pam) {
                        console.log("[IdleMonitor] pam object is valid. Setting screenIsIdle.");
                        root.lock.pam.screenIsIdle = isIdle;
                    } else {
                        console.error("[IdleMonitor] CRITICAL: root.lock.pam is still undefined! (Did you apply the fix to Lock.qml?)");
                    }
                } else {
                    console.log("[IdleMonitor] 'dpms off' string NOT found.");
                }
                // --- END NEW LOGIC ---
            }
        }
    }
}
