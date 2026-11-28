/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

package io.github.beakthoven.TrickyStoreOSS.interceptors

import android.os.ServiceSpecificException
import java.lang.invoke.MethodHandle
import java.lang.invoke.MethodHandles
import java.lang.invoke.MethodType
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Security
import java.security.Signature
import javax.crypto.Cipher
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test

/**
 * F47: RSA input longer than the key ends a software operation with KM_ERROR_INVALID_INPUT_LENGTH
 * (IKeyMintOperation.aidl): from update() once it exceeds the key size, from finish() once it exceeds what
 * finish() can consume (key size - 11 for undigested PKCS#1 v1.5 signing). The engines are file-private
 * classes of SoftwareOperationBinder.kt and are reached through method handles.
 */
class RsaInputLimitTest {
    companion object {
        private const val KM_ERROR_INVALID_INPUT_LENGTH = -21 // KeymasterDefs
        private const val KEY_BYTES = 256 // 2048-bit test key
        private const val PKG = "io.github.beakthoven.TrickyStoreOSS.interceptors."
        private lateinit var keyPair: KeyPair

        @BeforeClass
        @JvmStatic
        fun setUp() {
            Security.removeProvider(BouncyCastleProvider.PROVIDER_NAME)
            Security.addProvider(BouncyCastleProvider())
            keyPair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        }

        private fun lookup(name: String): Pair<Class<*>, MethodHandles.Lookup> {
            val cls = Class.forName(PKG + name)
            return cls to MethodHandles.privateLookupIn(cls, MethodHandles.lookup())
        }

        private fun limit(updateMax: Int, finishMax: Int): Any {
            val (cls, l) = lookup("RsaInputLimit")
            return l.findConstructor(cls, MethodType.methodType(Void.TYPE, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType))
                .invokeWithArguments(updateMax, finishMax)
        }

        private class Engine(val obj: Any, val update: MethodHandle, val finish: MethodHandle)

        private fun engine(name: String, vararg args: Any): Engine {
            val (cls, l) = lookup(name)
            val types = args.map {
                when (it) {
                    is Boolean -> Boolean::class.javaPrimitiveType!!
                    is Signature -> Signature::class.java
                    is Cipher -> Cipher::class.java
                    else -> it.javaClass
                }
            }
            val obj = l.findConstructor(cls, MethodType.methodType(Void.TYPE, types)).invokeWithArguments(*args)
            val update = l.findVirtual(cls, "update", MethodType.methodType(ByteArray::class.java, ByteArray::class.java))
            val finish = l.findVirtual(cls, "finish",
                MethodType.methodType(ByteArray::class.java, ByteArray::class.java, ByteArray::class.java))
            return Engine(obj, update, finish)
        }

        private fun expectInvalidInputLength(what: String, call: () -> Any?) {
            try {
                call()
            } catch (e: ServiceSpecificException) {
                assertEquals("$what: error code", KM_ERROR_INVALID_INPUT_LENGTH, e.errorCode)
                return
            } catch (e: Throwable) {
                fail("$what: ${e.javaClass.name}: ${e.message}, expected KM_ERROR_INVALID_INPUT_LENGTH")
            }
            fail("$what: accepted, expected KM_ERROR_INVALID_INPUT_LENGTH")
        }

        private fun signer() = Signature.getInstance("NONEwithRSA").apply { initSign(keyPair.private) }
    }

    @Test
    fun undigestedSignUpdateRejectsMoreThanTheKey() {
        val e = engine("SignatureEngine", signer(), false, limit(KEY_BYTES, KEY_BYTES - 11))
        e.update.invokeWithArguments(e.obj, ByteArray(200))
        expectInvalidInputLength("update past the key size") { e.update.invokeWithArguments(e.obj, ByteArray(KEY_BYTES - 199)) }
    }

    @Test
    fun undigestedPkcs1SignFinishRejectsMoreThanKeyMinusEleven() {
        val e = engine("SignatureEngine", signer(), false, limit(KEY_BYTES, KEY_BYTES - 11))
        e.update.invokeWithArguments(e.obj, ByteArray(KEY_BYTES - 11))
        expectInvalidInputLength("finish past key size - 11") { e.finish.invokeWithArguments(e.obj, ByteArray(1), null) }
    }

    @Test
    fun undigestedPkcs1SignWithinTheLimitSigns() {
        val e = engine("SignatureEngine", signer(), false, limit(KEY_BYTES, KEY_BYTES - 11))
        e.update.invokeWithArguments(e.obj, ByteArray(KEY_BYTES - 12))
        val sig = e.finish.invokeWithArguments(e.obj, ByteArray(1), null) as ByteArray
        assertEquals(KEY_BYTES, sig.size)
    }

    @Test
    fun rsaDecryptUpdateRejectsMoreThanTheKey() {
        // BouncyCastle's RSA cipher throws ArrayIndexOutOfBoundsException from update() for such input
        val cipher = Cipher.getInstance("RSA/ECB/OAEPPadding", BouncyCastleProvider.PROVIDER_NAME)
            .apply { init(Cipher.DECRYPT_MODE, keyPair.private) }
        val e = engine("CipherEngine", cipher, limit(KEY_BYTES, KEY_BYTES))
        expectInvalidInputLength("decrypt update past the key size") { e.update.invokeWithArguments(e.obj, ByteArray(KEY_BYTES + 44)) }
    }
}
