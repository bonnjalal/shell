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
        onLockRequested: root.lock.lock.locked = true
        onUnlockRequested: root.lock.lock.unlock()
    }

    Variants {
        model: Config.general.idle.timeouts

        IdleMonitor {
            required property var modelData

            enabled: root.enabled && (modelData.enabled ?? true)
            timeout: modelData.timeout
            respectInhibitors: modelData.respectInhibitors ?? true
            onIsIdleChanged: {
                root.handleIdleAction(isIdle ? modelData.idleAction : modelData.returnAction);

                if (isIdle) {
                    // Screen is now idle (DPMS on)
                    // Tell Pam.qml to stop looping
                    lock.pam.isScreenActive = false;

                    // Also abort the *current* scan, just in case
                    if (lock.pam.howdy.active) {
                        lock.pam.howdy.abort();
                    }
                } else {
                    // Screen is no longer idle (e.g., mouse moved, DPMS off)
                    // Tell Pam.qml it's allowed to loop again
                    lock.pam.isScreenActive = true;

                    // And if we're still locked, kick-start the loop
                    if (lock.lock.locked && lock.lock.secure) {
                        lock.pam.howdy.checkAvail();
                    }
                }
            }
        }
    }
}
