package dev.andmon.receiver

import java.util.concurrent.atomic.AtomicReference

class SessionLockManager {
    private val activeSession = AtomicReference<Any?>(null)

    fun acquireLock(session: Any): Boolean {
        return activeSession.compareAndSet(null, session) || activeSession.get() === session
    }

    fun releaseLock(session: Any) {
        activeSession.compareAndSet(session, null)
    }

    fun isLockedBy(session: Any): Boolean {
        return activeSession.get() === session
    }

    fun clear() {
        activeSession.set(null)
    }
}
