/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

package io.github.beakthoven.TrickyStoreOSS

import android.os.Build
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * F39 (910d472): while the probe result is UNAVAILABLE a re-probe is due 30 s after the last
 * UNAVAILABLE result, doubling per attempt, for six attempts; 178725e: never before keystore2.
 * Members are looked up by reflection so a tree without them fails here instead of not compiling.
 */
class AttestUtilsTest {
    private fun method(name: String, vararg types: Class<*>): Method =
        runCatching { AttestUtils::class.java.getMethod(name, *types) }.getOrNull()
            ?: throw AssertionError("AttestUtils.$name is missing")

    private fun field(name: String) = AttestUtils::class.java.getDeclaredField(name).apply { isAccessible = true }

    @After
    fun resetProbeCache() {
        field("cachedProbeResult").set(null, null)
    }

    @Test
    fun reprobeBackOffDoublesFromThirtySecondsForSixAttempts() {
        val due = method("reprobeDue", Int::class.javaPrimitiveType!!, Long::class.javaPrimitiveType!!)
        fun due(attempt: Int, elapsedMs: Long) = due.invoke(AttestUtils, attempt, elapsedMs) as Boolean
        for (attempt in 0 until 6) {
            val wait = 30_000L shl attempt
            assertFalse("attempt $attempt due after ${wait - 1} ms", due(attempt, wait - 1))
            assertTrue("attempt $attempt not due after $wait ms", due(attempt, wait))
        }
        assertFalse("a seventh attempt is due", due(6, Long.MAX_VALUE))
        assertFalse("a negative attempt is due", due(-1, Long.MAX_VALUE))
    }

    @Test
    fun noReprobeBeforeKeystore2() {
        // the unit-test android.jar reports SDK_INT 0: a pre-keystore2 level, where the legacy probe would
        // re-install the keystore provider
        assertTrue(Build.VERSION.SDK_INT < Build.VERSION_CODES.S)
        val request = method("requestReprobe")
        field("cachedProbeResult").set(null, AttestUtils.ProbeResult(AttestUtils.ProbeStatus.UNAVAILABLE))
        try {
            request.invoke(AttestUtils)
        } catch (e: InvocationTargetException) {
            // past the gate the back-off reads SystemClock, which the unit-test android.jar does not implement
            fail("requestReprobe went past the pre-keystore2 gate: ${e.cause}")
        }
        assertEquals("a re-probe attempt was counted", 0, field("reprobeAttempts").getInt(null))
        assertFalse("a re-probe is running", (field("reprobeRunning").get(null) as java.util.concurrent.atomic.AtomicBoolean).get())
    }
}
