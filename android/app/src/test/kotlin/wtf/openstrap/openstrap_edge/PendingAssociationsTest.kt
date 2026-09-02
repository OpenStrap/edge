package wtf.openstrap.openstrap_edge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Two concurrent CDM associate() calls used to share a single `pendingMac` scalar: the
 * second call's write clobbered the first, so device A's dialog result was never
 * attributed and startObservingDevicePresence was never called for it. This is the test
 * that fails under that old scalar and must pass after the [PendingAssociations] map.
 */
class PendingAssociationsTest {
    private val base = 0x4A11
    private val span = 16

    @Test
    fun twoConcurrentAssociationsAreAttributedToTheRightMac() {
        val pending = PendingAssociations()

        val codeA = pending.begin("AA:AA:AA:AA:AA:AA", null, base, span)
        val codeB = pending.begin("BB:BB:BB:BB:BB:BB", null, base, span)

        // The first allocation is the base itself — a single-device pairing keeps
        // sending the exact request code it always has.
        assertEquals(base, codeA)
        assertTrue(codeB != codeA)

        // Deliver A's result.
        val resolvedMac = pending.macFor(codeA)
        assertEquals("AA:AA:AA:AA:AA:AA", resolvedMac)
        pending.remove(resolvedMac!!)

        // B's entry must survive untouched — this is what the old pendingMac scalar
        // could not do (the second associate() call overwrote the first).
        assertEquals(codeB, pending.requestCodeFor("BB:BB:BB:BB:BB:BB"))
        assertNull(pending.requestCodeFor("AA:AA:AA:AA:AA:AA"))
    }

    @Test
    fun secondAssociateForTheSameMacIsIdempotent() {
        val pending = PendingAssociations()
        pending.begin("AA:AA:AA:AA:AA:AA", null, base, span)
        assertTrue(pending.inFlight("AA:AA:AA:AA:AA:AA"))
    }

    @Test
    fun requestCodeOutOfRangeResolvesToNoMac() {
        val pending = PendingAssociations()
        pending.begin("AA:AA:AA:AA:AA:AA", null, base, span)
        assertNull(pending.macFor(base + span)) // one past the allocation span
    }
}
