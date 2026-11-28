/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

package io.github.beakthoven.TrickyStoreOSS

import java.io.StringWriter
import java.lang.reflect.InvocationTargetException
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.Security
import java.util.Date
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.openssl.jcajce.JcaPEMWriter
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test

/** F38 (6261aed): the keybox algorithm attribute is compared with the normalized key algorithm. */
class KeyBoxUtilsTest {
    companion object {
        private const val WARNING = "Keybox algorithm attribute disagrees with parsed key"

        @BeforeClass
        @JvmStatic
        fun registerBouncyCastle() {
            // as Main.kt does at daemon start
            Security.removeProvider(BouncyCastleProvider.PROVIDER_NAME)
            Security.addProvider(BouncyCastleProvider())
        }

        /** PEM private key (written at runtime) and a self-signed PEM certificate for a fresh [algorithm] key. */
        fun keyMaterial(algorithm: String): Pair<String, String> {
            val kp = KeyPairGenerator.getInstance(algorithm, BouncyCastleProvider.PROVIDER_NAME)
                .apply { initialize(if (algorithm == "EC") 256 else 2048) }
                .generateKeyPair()
            val name = X500Name("CN=test keybox")
            val holder = JcaX509v3CertificateBuilder(name, BigInteger.ONE, Date(0), Date(4_000_000_000_000L), name, kp.public)
                .build(JcaContentSignerBuilder(if (algorithm == "EC") "SHA256withECDSA" else "SHA256withRSA").build(kp.private))
            return pem(kp.private) to pem(JcaX509CertificateConverter().getCertificate(holder))
        }

        fun pem(o: Any): String = StringWriter().also { w -> JcaPEMWriter(w).use { it.writeObject(o) } }.toString()
    }

    @Before
    fun clearLog() {
        android.util.Log.lines.clear()
    }

    private fun store(attribute: String?, key: String, cert: String): Pair<*, *> {
        val m = KeyBoxUtils::class.java.getDeclaredMethod("storeKeybox", String::class.java, String::class.java, List::class.java)
        m.isAccessible = true
        return try {
            m.invoke(KeyBoxUtils, attribute, key, listOf(cert)) as Pair<*, *>
        } catch (e: InvocationTargetException) {
            throw e.cause ?: e
        }
    }

    private fun warned() = android.util.Log.lines.any { it.contains(WARNING) }

    @Test
    fun logLinesAreCaptured() {
        // the android.util.Log stand-in from the test sources is the one in use (android.jar's has no such field)
        assertTrue(android.util.Log::class.java.getDeclaredField("lines") != null)
        io.github.beakthoven.TrickyStoreOSS.logging.Logger.w("probe line")
        assertTrue(android.util.Log.lines.any { it.endsWith("probe line") })
    }

    @Test
    fun ecKeyboxWithEcdsaAttributeDoesNotWarn() {
        val (key, cert) = keyMaterial("EC")
        val (algorithm, keybox) = store("ecdsa", key, cert)
        assertEquals("EC", algorithm)
        // the premise of F38: BouncyCastle names the parsed key "ECDSA", not "EC"
        assertEquals("ECDSA", (keybox as CertificateGen.KeyBox).keyPair.private.algorithm)
        assertFalse("EC keybox declared as ecdsa logged a mismatch", warned())
    }

    @Test
    fun rsaKeyboxWithRsaAttributeDoesNotWarn() {
        val (key, cert) = keyMaterial("RSA")
        val (algorithm, _) = store("rsa", key, cert)
        assertEquals("RSA", algorithm)
        assertFalse(warned())
    }

    @Test
    fun realMismatchStillWarns() {
        val (key, cert) = keyMaterial("RSA")
        val (algorithm, _) = store("ecdsa", key, cert)
        assertEquals("RSA", algorithm)
        assertTrue("RSA key declared as ecdsa logged no mismatch", warned())
    }
}
