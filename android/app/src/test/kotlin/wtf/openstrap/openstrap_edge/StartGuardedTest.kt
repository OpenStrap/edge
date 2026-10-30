package wtf.openstrap.openstrap_edge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * TaskerReceiver and BootReceiver start the tracking service from a broadcast.
 * On API 31+ that start throws when the app has no background FGS exemption,
 * and an exception escaping onReceive crashes the process. The guarded start
 * must swallow the refusal and report it.
 */
class StartGuardedTest {
    @Test
    fun refusedStartIsReportedNotThrown() {
        val refused = mutableListOf<Exception>()
        val ok = EdgeTrackingService.startGuarded({
            throw IllegalStateException("startForegroundService() not allowed")
        }) { refused.add(it) }
        assertFalse(ok)
        assertEquals(1, refused.size)
    }

    @Test
    fun successfulStartReturnsTrue() {
        var started = false
        val ok = EdgeTrackingService.startGuarded({ started = true }) {
            throw AssertionError("onRefused must not run")
        }
        assertTrue(ok)
        assertTrue(started)
    }
}
