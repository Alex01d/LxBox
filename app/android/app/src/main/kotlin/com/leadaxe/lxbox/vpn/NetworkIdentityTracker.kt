package com.leadaxe.lxbox.vpn

/** Tracks the underlying Android network used to detect stale connections. */
internal class NetworkIdentityTracker {
    private data class Identity(val networkHandle: Long, val interfaceName: String)

    private var current: Identity? = null

    @Synchronized
    fun observe(networkHandle: Long, interfaceName: String): Boolean {
        if (interfaceName.isEmpty()) return false
        val previous = current
        current = Identity(networkHandle, interfaceName)
        return previous != null &&
            (previous.networkHandle != networkHandle || previous.interfaceName != interfaceName)
    }

    /** Seeds the synchronous initial notification without replacing a newer callback. */
    @Synchronized
    fun seedIfAbsent(networkHandle: Long, interfaceName: String) {
        if (interfaceName.isEmpty() || current != null) return
        current = Identity(networkHandle, interfaceName)
    }

    /** Disconnect is transient; retain the last usable network identity. */
    @Synchronized
    fun disconnect() = Unit

    @Synchronized
    fun clear() {
        current = null
    }
}
