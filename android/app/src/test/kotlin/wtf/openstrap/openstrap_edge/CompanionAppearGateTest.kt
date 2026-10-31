package wtf.openstrap.openstrap_edge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A CompanionDeviceManager association outlives an unpair, so the OS keeps
 * reporting the forgotten band as "appeared". Only a paired user whose tracking
 * service is down should get the service started.
 */
class CompanionAppearGateTest {
    @Test
    fun forgottenBandDoesNotStartService() {
        assertFalse(EdgeCompanionService.shouldStartOnAppear(running = false, paired = false))
    }

    @Test
    fun pairedBandStartsStoppedService() {
        assertTrue(EdgeCompanionService.shouldStartOnAppear(running = false, paired = true))
    }

    @Test
    fun runningServiceIsNotRestarted() {
        assertFalse(EdgeCompanionService.shouldStartOnAppear(running = true, paired = true))
        assertFalse(EdgeCompanionService.shouldStartOnAppear(running = true, paired = false))
    }
}
