package com.leadaxe.lxbox.vpn

import io.nekohasekai.libbox.Libbox

/** Optional SPEC 143 API. The published AAR can predate these additive methods. */
internal object TailscaleAwgBridge {
    private val capabilityMethod by lazy {
        runCatching { Libbox::class.java.getMethod("tailscaleAWGSupported") }.getOrNull()
    }

    fun coreCapabilities(): Map<String, Boolean> = mapOf(
        "with_tailscale_awg" to (
            runCatching { capabilityMethod?.invoke(null) as? Boolean }.getOrNull() == true
        ),
    )

    /** No profile values or reflection exceptions are written to the log. */
    fun transport(endpoint: Any): Map<String, Any>? = runCatching {
        val transport = endpoint.javaClass.getMethod("getTransport").invoke(endpoint)
            ?: return@runCatching null
        fun string(name: String): String =
            transport.javaClass.getMethod(name).invoke(transport) as? String ?: ""
        mapOf(
            "configured_mode" to string("getConfiguredMode"),
            "applied_mode" to string("getAppliedMode"),
            "profile_id" to string("getProfileID"),
            "profile_fingerprint" to string("getProfileFingerprint"),
            "applied" to (transport.javaClass.getMethod("getApplied").invoke(transport) == true),
            "last_error" to string("getLastError"),
        )
    }.getOrNull()
}
