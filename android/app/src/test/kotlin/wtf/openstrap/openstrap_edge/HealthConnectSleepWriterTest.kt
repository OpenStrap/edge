package wtf.openstrap.openstrap_edge

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectSleepWriterTest {
    private val berlin = ZoneId.of("Europe/Berlin")

    private fun localInstant(year: Int, month: Int, day: Int, hour: Int, minute: Int): Instant =
        ZonedDateTime.of(year, month, day, hour, minute, 0, 0, berlin).toInstant()

    @Test
    fun cleanupRangeIncludesLegacyFragmentThatStartsBeforeRecomputedSession() {
        val sessionStart = localInstant(2026, 8, 6, 1, 36)
        val sessionEnd = localInstant(2026, 8, 6, 8, 20)
        val staleFragmentStart = localInstant(2026, 8, 5, 23, 34)

        val range = sleepCleanupRange(sessionStart, sessionEnd, berlin)

        assertEquals(localInstant(2026, 8, 5, 12, 0), range.start)
        assertEquals(localInstant(2026, 8, 6, 12, 0), range.end)
        assertTrue(!staleFragmentStart.isBefore(range.start))
        assertTrue(staleFragmentStart.isBefore(range.end))
    }

    @Test
    fun cleanupRangeStartsAfterPreviousNightThatWokeAfterNoon() {
        val sessionStart = localInstant(2026, 8, 5, 23, 30)
        val sessionEnd = localInstant(2026, 8, 6, 7, 0)
        val previousWake = localInstant(2026, 8, 5, 14, 0)

        val range = sleepCleanupRange(sessionStart, sessionEnd, berlin, previousWake)

        assertEquals(previousWake.plusSeconds(1), range.start)
        assertEquals(localInstant(2026, 8, 6, 12, 0), range.end)
        // A morning wake is outside the window and changes nothing.
        val morning = sleepCleanupRange(
            sessionStart, sessionEnd, berlin, localInstant(2026, 8, 5, 7, 0),
        )
        assertEquals(localInstant(2026, 8, 5, 12, 0), morning.start)
    }

    @Test
    fun cleanupRangeUsesLocalNoonAcrossDstTransition() {
        val sessionStart = localInstant(2026, 10, 25, 1, 30)
        val sessionEnd = localInstant(2026, 10, 25, 9, 0)

        val range = sleepCleanupRange(sessionStart, sessionEnd, berlin)

        assertEquals(localInstant(2026, 10, 24, 12, 0), range.start)
        assertEquals(localInstant(2026, 10, 25, 12, 0), range.end)
        assertEquals(25, Duration.between(range.start, range.end).toHours())
    }
}
