/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

package io.github.beakthoven.TrickyStoreOSS

import java.io.StringReader
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.util.Date
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.openssl.PEMKeyPair
import org.bouncycastle.openssl.PEMParser
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** F46: an EC keybox key in SEC1 form without its optional public key is accepted (public key derived). */
class CertificateUtilsTest {
    @Test
    fun sec1EcKeyWithoutPublicKeyIsAccepted() {
        // SEC1 ECPrivateKey with the named curve but without the optional public key (openssl ec -no_public),
        // PEM-armoured at runtime
        val kp = KeyPairGenerator.getInstance("EC", "SunEC").apply { initialize(256) }.generateKeyPair()
        val sec1 = org.bouncycastle.asn1.sec.ECPrivateKey(
            256, (kp.private as java.security.interfaces.ECPrivateKey).s, org.bouncycastle.asn1.sec.SECObjectIdentifiers.secp256r1,
        )
        val pem = java.io.StringWriter().also { w ->
            org.bouncycastle.util.io.pem.PemWriter(w).use { it.writeObject(org.bouncycastle.util.io.pem.PemObject("EC PRIVATE KEY", sec1.encoded)) }
        }.toString()
        val raw = PEMParser(StringReader(pem)).use { it.readObject() }
        assertTrue("fixture is not a SEC1 key pair: $raw", raw is PEMKeyPair)
        assertNull("fixture SEC1 key carries a public key", (raw as PEMKeyPair).publicKeyInfo)

        val parsed = CertificateUtils.convertPemToKeyPair(CertificateUtils.parseKeyPair(pem).getOrThrow())
        assertEquals((kp.public as ECPublicKey).w, (parsed.public as ECPublicKey).w)
        assertEquals(
            (kp.private as java.security.interfaces.ECPrivateKey).s,
            (parsed.private as java.security.interfaces.ECPrivateKey).s,
        )

        // and the keybox entry built from it loads
        val name = X500Name("CN=test keybox")
        val cert = JcaX509CertificateConverter().getCertificate(
            JcaX509v3CertificateBuilder(name, BigInteger.ONE, Date(0), Date(4_000_000_000_000L), name, kp.public)
                .build(JcaContentSignerBuilder("SHA256withECDSA").build(kp.private))
        )
        val m = KeyBoxUtils::class.java.getDeclaredMethod("storeKeybox", String::class.java, String::class.java, List::class.java)
        m.isAccessible = true
        val (algorithm, _) = m.invoke(KeyBoxUtils, "ecdsa", pem, listOf(KeyBoxUtilsTest.pem(cert))) as Pair<*, *>
        assertEquals("EC", algorithm)
    }
}
