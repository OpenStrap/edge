package wtf.openstrap.openstrap_edge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A wall-clock change is not a reboot; only the boot counter (or a counter reset) is. */
class PhoneStepClockJumpTest {
    private val hour = 3_600_000L
    private val boot = 1_000_000_000_000L

    @Test
    fun clockJumpWithSameBootCountIsNotReboot() {
        // clock stepped back 3 h, register kept rising
        assertFalse(stepCounterRebooted(800f, 500f, 7, 7, boot - 3 * hour, boot))
        assertFalse(stepCounterRebooted(800f, 500f, 7, 7, boot + 3 * hour, boot))
    }

    @Test
    fun bootCountChangeOrCounterResetIsReboot() {
        assertTrue(stepCounterRebooted(900f, 500f, 8, 7, boot, boot))
        assertTrue(stepCounterRebooted(10f, 500f, 7, 7, boot, boot))
    }

    @Test
    fun oldPrefsFallBackToBootTime() {
        assertTrue(stepCounterRebooted(800f, 500f, 7, -1, boot + hour, boot))
        assertFalse(stepCounterRebooted(800f, 500f, 7, -1, boot + 1_000, boot))
        assertFalse(stepCounterRebooted(800f, -1f, 7, -1, boot + hour, boot))
    }

    @Test
    fun noBootCounterUsesUptimeNotClock() {
        // uptime kept rising, boot time within slack: not a reboot
        assertFalse(stepCounterRebooted(800f, 500f, -1, -1, boot + 1_000, boot, 9 * hour, 8 * hour))
        // clock stepped back, uptime kept rising: not a reboot
        assertFalse(stepCounterRebooted(800f, 500f, -1, -1, boot - hour, boot, 9 * hour, 8 * hour))
        // uptime went backwards, register kept rising: reboot
        assertTrue(stepCounterRebooted(900f, 500f, -1, -1, boot, boot, hour, 8 * hour))
        // boot time moved later (a long-off reboot looks the same as a forward clock set): reboot
        assertTrue(stepCounterRebooted(800f, 500f, -1, -1, boot + hour, boot, 9 * hour, 8 * hour))
        assertTrue(stepCounterRebooted(800f, 500f, -1, -1, boot + hour, boot))
    }

    @Test
    fun deltaStartFollowsTheClockChange() {
        val last = boot + 5 * hour
        // clock moved back 3 h: the last sample now sits 3 h earlier too
        assertEquals(last - 3 * hour, stepDeltaFrom(last - 2 * hour, last, boot - 3 * hour, boot))
        assertEquals(last, stepDeltaFrom(last + 60_000, last, boot, boot))
        assertEquals(42L, stepDeltaFrom(42L, 0L, boot, boot))
    }
}
