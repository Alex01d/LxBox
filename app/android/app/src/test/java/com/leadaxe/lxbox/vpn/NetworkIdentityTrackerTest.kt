package com.leadaxe.lxbox.vpn

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkIdentityTrackerTest {
    @Test
    fun replacementWithSameInterfaceResetsOnce() {
        val tracker = NetworkIdentityTracker()

        assertFalse(tracker.observe(113, "wlan0")) // first attach
        assertTrue(tracker.observe(145, "wlan0")) // replacement, same Linux interface
        assertFalse(tracker.observe(145, "wlan0")) // capabilities/link-properties duplicate
    }

    @Test
    fun disconnectAndMissingInterfacePreserveBaseline() {
        val tracker = NetworkIdentityTracker()

        assertFalse(tracker.observe(113, "wlan0"))
        assertFalse(tracker.observe(0, "")) // no usable LinkProperties
        tracker.disconnect()
        assertTrue(tracker.observe(145, "wlan0")) // reconnect after transient gap
    }

    @Test
    fun interfaceSwitchOnSameNetworkStillResets() {
        val tracker = NetworkIdentityTracker()

        assertFalse(tracker.observe(113, "wlan0"))
        assertTrue(tracker.observe(113, "rmnet_data0"))
        assertFalse(tracker.observe(113, "rmnet_data0"))
    }

    @Test
    fun synchronousSeedDoesNotOverwriteCallbackBaseline() {
        val tracker = NetworkIdentityTracker()

        assertFalse(tracker.observe(145, "wlan0"))
        tracker.seedIfAbsent(113, "wlan0")
        assertFalse(tracker.observe(145, "wlan0"))
        assertTrue(tracker.observe(146, "wlan0"))
    }

    @Test
    fun stopClearsBaselineAndNextAttachDoesNotReset() {
        val tracker = NetworkIdentityTracker()

        assertFalse(tracker.observe(113, "wlan0"))
        tracker.clear()
        assertFalse(tracker.observe(145, "wlan0"))
    }
}
