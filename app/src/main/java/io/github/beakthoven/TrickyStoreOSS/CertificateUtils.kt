/*
 * Copyright 2026 Dakkshesh <beakthoven@gmail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

package io.github.beakthoven.TrickyStoreOSS

import android.security.keymaster.KeymasterDefs
import android.system.keystore2.KeyEntryResponse
import android.system.keystore2.KeyMetadata
import io.github.beakthoven.TrickyStoreOSS.logging.Logger
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.StringReader
import java.security.KeyPair
import java.security.cert.Certificate
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.CertificateParsingException
import java.security.cert.X509Certificate
import org.bouncycastle.asn1.ASN1Encodable
import org.bouncycastle.asn1.ASN1ObjectIdentifier
import org.bouncycastle.asn1.DEROctetString
import org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo
import org.bouncycastle.asn1.pkcs.RSAPrivateKey
import org.bouncycastle.asn1.pkcs.RSAPublicKey
import org.bouncycastle.asn1.sec.ECPrivateKey
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo
import org.bouncycastle.asn1.x9.ECNamedCurveTable
import org.bouncycastle.asn1.x9.X962Parameters
import org.bouncycastle.asn1.x9.X9ECParameters
import org.bouncycastle.asn1.x9.X9ObjectIdentifiers
import org.bouncycastle.openssl.PEMKeyPair
import org.bouncycastle.openssl.PEMParser
import org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter
import org.bouncycastle.util.io.pem.PemReader

object CertificateUtils {
    val certificateFactory: CertificateFactory by lazy {
        try {
            CertificateFactory.getInstance("X.509")
        } catch (t: Throwable) {
            Logger.e("Failed to initialize certificate factory", t)
            throw RuntimeException("Cannot initialize certificate factory", t)
        }
    }

    fun digestName(digest: Int, hyphenated: Boolean): String {
        val suffix =
            when (digest) {
                KeymasterDefs.KM_DIGEST_SHA1 -> "1"
                KeymasterDefs.KM_DIGEST_SHA_2_224 -> "224"
                KeymasterDefs.KM_DIGEST_SHA_2_256 -> "256"
                KeymasterDefs.KM_DIGEST_SHA_2_384 -> "384"
                KeymasterDefs.KM_DIGEST_SHA_2_512 -> "512"
                else -> "256"
            }
        return if (hyphenated) "SHA-$suffix" else "SHA$suffix"
    }

    fun ByteArray?.toCertificate(): X509Certificate? {
        return this?.let { bytes ->
            try {
                certificateFactory.generateCertificate(ByteArrayInputStream(bytes)) as? X509Certificate
            } catch (e: CertificateException) {
                Logger.w("Couldn't parse certificate in keystore", e)
                null
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    fun ByteArray?.toCertificates(): Collection<X509Certificate> {
        return this?.let { bytes ->
            try {
                certificateFactory.generateCertificates(ByteArrayInputStream(bytes)) as Collection<X509Certificate>
            } catch (e: CertificateException) {
                Logger.w("Couldn't parse certificates in keystore", e)
                emptyList()
            }
        } ?: emptyList()
    }

    fun Collection<Certificate>.toByteArray(): ByteArray? {
        val raw = runCatching {
            ByteArrayOutputStream().use { outputStream ->
                forEach { cert -> outputStream.write(cert.encoded) }
                outputStream.toByteArray()
            }
        }
        return raw.onFailure { Logger.w("Failed to convert certificates to byte array", it) }.getOrNull()
    }

    fun KeyEntryResponse?.getCertificateChain(): Array<Certificate>? {
        val metadata = this?.metadata ?: return null
        val leafCert = metadata.certificate?.toCertificate() ?: return null

        return when (val chainBytes = metadata.certificateChain) {
            null -> arrayOf(leafCert)
            else -> (listOf<Certificate>(leafCert) + chainBytes.toCertificates()).toTypedArray()
        }
    }

    // Certificate parsing utilities
    fun parseKeyPair(keyContent: String): Result<PEMKeyPair> = runCatching {
        PEMParser(StringReader(keyContent.trimLine())).use { parser ->
            var parsed = parser.readObject()
            // openssl ecparam -genkey writes an EC PARAMETERS block ahead of the key
            while (parsed is ASN1ObjectIdentifier || parsed is X9ECParameters) parsed = parser.readObject()
            when (parsed) {
                is PEMKeyPair -> parsed
                is PrivateKeyInfo -> pkcs8KeyPair(parsed)
                else -> throw IllegalStateException("Invalid PEM key pair format")
            }
        }
    }

    // PKCS#8 (BEGIN PRIVATE KEY) carries no public key we can rely on; derive it from the private key.
    private fun pkcs8KeyPair(info: PrivateKeyInfo): PEMKeyPair {
        val algorithm = info.privateKeyAlgorithm
        val publicKey =
            when (algorithm.algorithm) {
                X9ObjectIdentifiers.id_ecPublicKey -> {
                    val params = X962Parameters.getInstance(algorithm.parameters)
                    val curve =
                        if (params.isNamedCurve) {
                            ECNamedCurveTable.getByOID(ASN1ObjectIdentifier.getInstance(params.parameters))
                        } else {
                            X9ECParameters.getInstance(params.parameters)
                        } ?: throw IllegalStateException("Unsupported PKCS#8 EC curve")
                    val d = ECPrivateKey.getInstance(info.parsePrivateKey()).key
                    SubjectPublicKeyInfo(algorithm, curve.g.multiply(d).normalize().getEncoded(false))
                }
                PKCSObjectIdentifiers.rsaEncryption -> {
                    val rsa = RSAPrivateKey.getInstance(info.parsePrivateKey())
                    SubjectPublicKeyInfo(algorithm, RSAPublicKey(rsa.modulus, rsa.publicExponent))
                }
                else -> throw IllegalStateException("Unsupported PKCS#8 key algorithm")
            }
        return PEMKeyPair(publicKey, info)
    }

    fun parseCertificate(certContent: String): Result<Certificate> = runCatching {
        PemReader(StringReader(certContent.trimLine())).use { reader ->
            val pemObject = reader.readPemObject()
            certificateFactory.generateCertificate(ByteArrayInputStream(pemObject.content))
        }
    }

    fun convertPemToKeyPair(pemKeyPair: PEMKeyPair): KeyPair {
        return JcaPEMKeyConverter().getKeyPair(pemKeyPair)
    }

    @Throws(CertificateParsingException::class)
    fun getByteArrayFromAsn1(asn1Encodable: ASN1Encodable): ByteArray {
        return when (asn1Encodable) {
            is DEROctetString -> asn1Encodable.octets
            else -> throw CertificateParsingException("Expected DEROctetString, got ${asn1Encodable::class.simpleName}")
        }
    }
}

fun KeyMetadata.putCertificateChain(chain: Array<Certificate>): Result<Unit> {
    return runCatching {
        if (chain.isEmpty()) return@runCatching

        certificate = chain[0].encoded

        if (chain.size > 1) {
            ByteArrayOutputStream().use { output ->
                for (i in 1 until chain.size) {
                    output.write(chain[i].encoded)
                }
                certificateChain = output.toByteArray()
            }
        } else {
            certificateChain = null
        }
    }
}

fun KeyEntryResponse.putCertificateChain(chain: Array<Certificate>): Result<Unit> {
    return runCatching { metadata.putCertificateChain(chain).getOrThrow() }
}
