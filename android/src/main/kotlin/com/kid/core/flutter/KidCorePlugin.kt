package com.kid.core.flutter

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.os.Bundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.google.android.gms.tasks.Task
import com.google.android.play.agesignals.AgeSignalsAccessRequest
import com.google.android.play.agesignals.AgeSignalsManagerFactory
import com.google.android.play.agesignals.AgeSignalsRequest
import com.google.android.play.agesignals.model.AgeRangeSource
import com.google.android.play.agesignals.model.AgeSignalsStatus
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.math.BigInteger
import java.security.GeneralSecurityException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.ProviderException
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val KEYSTORE = "AndroidKeyStore"
// The Android SDK's alias, so an app that moves between the SDKs keeps its device key.
private const val DPOP_ALIAS = "com.k-id.core.dpop"
private const val ATTESTATION_ALIAS = "com.k-id.core.attestation"

/** The native half of k_id_core: the device key, Key Attestation, Google Play Age Signals and the app id. */
class KidCorePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var packageName: String? = null
    private var activity: Activity? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        packageName = binding.applicationContext.packageName
        channel = MethodChannel(binding.binaryMessenger, "com.k-id.core/flutter")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "appId" -> result.success(packageName)
            "publicJwk" -> background(result) { DeviceKeys.key().publicJwk }
            "sign" -> {
                val data = call.argument<ByteArray>("data") ?: return result.error("invalid", "data is required", null)
                background(result) { DeviceKeys.key().sign(data) }
            }
            "keyAttestationChain" -> {
                val challenge = call.argument<ByteArray>("challenge")
                    ?: return result.error("invalid", "challenge is required", null)
                background(result) { keyAttestationChain(challenge) }
            }
            "countryNames" -> {
                val display = Locale.forLanguageTag(call.argument<String>("locale") ?: "en")
                val codes = call.argument<List<String>>("codes") ?: emptyList()
                result.success(
                    codes.associateWith { Locale.Builder().setRegion(it).build().getDisplayCountry(display) }
                        .filter { (code, name) -> name.isNotEmpty() && name != code },
                )
            }
            "isAgeRangeSupported" -> result.success(true)
            "requestAgeRange" -> scope.launch { result.success(playAgeSignal()) }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        scope.launch {
            try {
                result.success(withContext(Dispatchers.IO) { work() })
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                result.error("failed", error.message, null)
            }
        }
    }

    // Play takes an app's age gates from Play Console, not the request.
    private suspend fun playAgeSignal(): Map<String, Any?>? {
        val activity = activity?.takeIf { it.isInForeground() } ?: return null
        return try {
            val manager = AgeSignalsManagerFactory.create(activity.applicationContext)
            val access = manager.requestAgeSignalsAccess(AgeSignalsAccessRequest.builder().setActivity(activity).build())
                .awaitUnlessBlocked(activity)
            if (access?.ageSignalsStatus() != AgeSignalsStatus.SHARED) return null
            val result = manager.checkAgeSignals(AgeSignalsRequest.builder().build()).await()
            val ageLow = result.ageLower() ?: return null
            mapOf(
                "name" to "google-play",
                "ageLow" to ageLow,
                "ageHigh" to (result.ageUpper() ?: -1),
                "declarationType" to ageRangeSources[result.ageRangeSource()],
            )
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            null
        }
    }
}

private val ageRangeSources = mapOf(
    AgeRangeSource.TIER_A to "TIER_A",
    AgeRangeSource.TIER_B to "TIER_B",
    AgeRangeSource.TIER_C to "TIER_C",
    AgeRangeSource.TIER_D to "TIER_D",
)

private fun base64URL(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)

private fun unsignedFixed(value: BigInteger, size: Int): ByteArray {
    val bytes = value.toByteArray()
    return when {
        bytes.size == size -> bytes
        bytes.size > size -> bytes.copyOfRange(bytes.size - size, bytes.size)
        else -> ByteArray(size - bytes.size) + bytes
    }
}

/** Java signs ECDSA as an ASN.1 `SEQUENCE { r, s }`; JWS wants the two integers concatenated. */
private fun derToRawSignature(der: ByteArray): ByteArray {
    var offset = 2
    if (der[1].toInt() and 0x80 != 0) offset += der[1].toInt() and 0x7f
    fun integer(): BigInteger {
        require(der[offset].toInt() == 0x02) { "not an ASN.1 integer" }
        val length = der[offset + 1].toInt()
        val value = BigInteger(1, der.copyOfRange(offset + 2, offset + 2 + length))
        offset += 2 + length
        return value
    }
    val r = integer()
    val s = integer()
    return unsignedFixed(r, 32) + unsignedFixed(s, 32)
}

private class DeviceKey(private val privateKey: PrivateKey, publicKey: ECPublicKey) {
    val publicJwk: Map<String, String> = mapOf(
        "kty" to "EC",
        "crv" to "P-256",
        "x" to base64URL(unsignedFixed(publicKey.w.affineX, 32)),
        "y" to base64URL(unsignedFixed(publicKey.w.affineY, 32)),
    )

    fun sign(data: ByteArray): ByteArray {
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey)
        signature.update(data)
        return derToRawSignature(signature.sign())
    }
}

/** The install's Keystore key, created once and kept; a device without a usable Keystore gets a key for this launch. */
private object DeviceKeys {
    private var cached: DeviceKey? = null

    @Synchronized
    fun key(): DeviceKey = cached ?: load().also { cached = it }

    private fun load(): DeviceKey = try {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val entry = keyStore.getEntry(DPOP_ALIAS, null) as? KeyStore.PrivateKeyEntry
        if (entry != null) {
            DeviceKey(entry.privateKey, entry.certificate.publicKey as ECPublicKey)
        } else {
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
            generator.initialize(
                KeyGenParameterSpec.Builder(DPOP_ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build(),
            )
            val pair = generator.generateKeyPair()
            DeviceKey(pair.private, pair.public as ECPublicKey)
        }
    } catch (_: GeneralSecurityException) {
        softwareKey()
    } catch (_: ProviderException) {
        softwareKey()
    }

    private fun softwareKey(): DeviceKey {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        return DeviceKey(pair.private, pair.public as ECPublicKey)
    }
}

/** A throwaway Keystore key per mint, since Key Attestation binds its challenge when the key is made. */
private fun keyAttestationChain(challenge: ByteArray): List<ByteArray>? = try {
    val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
    generator.initialize(
        KeyGenParameterSpec.Builder(ATTESTATION_ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setAttestationChallenge(challenge)
            .build(),
    )
    generator.generateKeyPair()
    val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
    val chain = keyStore.getCertificateChain(ATTESTATION_ALIAS)?.map { it.encoded }
    keyStore.deleteEntry(ATTESTATION_ALIAS)
    chain
} catch (_: GeneralSecurityException) {
    null
} catch (_: ProviderException) {
    null
}

private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
    addOnCompleteListener(Runnable::run) { task ->
        val error = task.exception
        if (error == null) continuation.resume(task.result) else continuation.resumeWithException(error)
    }
}

// Android silently blocks Play's consent screen from opening in the background, and the access request then never
// completes. Play posts its answer before the activity can resume from that screen, so access still open when the
// activity resumes after a stop was blocked.
private suspend fun <T> Task<T>.awaitUnlessBlocked(activity: Activity): T? = coroutineScope {
    val answer = async { await() }
    val returned = async { activity.returnsFromStop() }
    select<T?> {
        answer.onAwait { it }
        returned.onAwait { if (isComplete) answer.await() else null }
    }.also { coroutineContext.cancelChildren() }
}

private suspend fun Activity.returnsFromStop(): Unit = suspendCancellableCoroutine { continuation ->
    val callbacks = object : Application.ActivityLifecycleCallbacks {
        private var stopped = false

        private fun end() {
            unregisterActivityLifecycleCallbacks(this)
            continuation.resume(Unit)
        }

        override fun onActivityStopped(activity: Activity) {
            stopped = true
        }

        override fun onActivityResumed(activity: Activity) {
            if (stopped) end()
        }

        override fun onActivityDestroyed(activity: Activity) = unregisterActivityLifecycleCallbacks(this)

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    }
    registerActivityLifecycleCallbacks(callbacks)
    continuation.invokeOnCancellation { unregisterActivityLifecycleCallbacks(callbacks) }
}

private fun Activity.isInForeground(): Boolean {
    if (isFinishing || isDestroyed) return false
    val process = ActivityManager.RunningAppProcessInfo()
    ActivityManager.getMyMemoryState(process)
    return process.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
}
