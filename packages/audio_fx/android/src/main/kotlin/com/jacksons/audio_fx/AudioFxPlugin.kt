package com.jacksons.audio_fx

import android.media.audiofx.DynamicsProcessing
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Audio effects on the player's audio session:
 *  - graphic EQ + preamp + loudness gain + limiter (DynamicsProcessing, API 28+)
 */
class AudioFxPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel

    // --- Equalizer / loudness ---
    private var dynamics: DynamicsProcessing? = null
    private var sessionId = 0
    private var frequencies = FloatArray(0) // band centres, Hz
    private var gains = FloatArray(0) // dB
    private var eqEnabled = false
    private var preamp = 0f
    private var loudness = 0f

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(binding.binaryMessenger, "audio_fx")
        methods.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        releaseDynamics()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isEqualizerSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                "attach" -> {
                    sessionId = call.argument<Int>("sessionId") ?: 0
                    frequencies = call.argument<List<Double>>("frequencies")!!
                        .map { it.toFloat() }.toFloatArray()
                    if (gains.size != frequencies.size) gains = FloatArray(frequencies.size)
                    rebuildDynamics()
                    result.success(dynamics != null)
                }
                "setEqualizer" -> {
                    eqEnabled = call.argument<Boolean>("enabled") ?: false
                    val g = call.argument<List<Double>>("gains") ?: emptyList()
                    gains = FloatArray(frequencies.size) { i -> g.getOrNull(i)?.toFloat() ?: 0f }
                    preamp = (call.argument<Double>("preamp") ?: 0.0).toFloat()
                    applyDynamics()
                    result.success(null)
                }
                "setLoudness" -> {
                    loudness = (call.argument<Double>("gain") ?: 0.0).toFloat()
                    applyDynamics()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("audio_fx", e.message, null)
        }
    }

    // ---------------------------------------------------------------------
    // DynamicsProcessing

    private fun rebuildDynamics() {
        releaseDynamics()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || sessionId == 0 || frequencies.isEmpty()) {
            return
        }
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
            2, // channels
            true, frequencies.size, // pre-EQ: our graphic EQ
            false, 0, // multi-band compressor
            false, 0, // post-EQ
            true, // limiter: keeps boosts from clipping
        ).build()
        dynamics = DynamicsProcessing(0, sessionId, config)
        applyDynamics()
    }

    private fun applyDynamics() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return
        val d = dynamics ?: return
        val n = frequencies.size
        val eq = DynamicsProcessing.Eq(true, true, n)
        for (i in 0 until n) {
            // Each band reaches up to the midpoint (log scale) with the next.
            val cutoff = if (i < n - 1) sqrt(frequencies[i] * frequencies[i + 1]) else 20000f
            eq.setBand(i, DynamicsProcessing.EqBand(true, cutoff, if (eqEnabled) gains[i] else 0f))
        }
        d.setPreEqAllChannelsTo(eq)

        // Leave headroom for boosts; the limiter catches what's left.
        val boost = if (eqEnabled) max(0f, gains.maxOrNull() ?: 0f) else 0f
        val input = (if (eqEnabled) preamp else 0f) + loudness - boost * 0.5f
        d.setInputGainAllChannelsTo(input)
        d.setLimiterAllChannelsTo(
            DynamicsProcessing.Limiter(
                true, true, 0,
                1f, // attack ms
                60f, // release ms
                10f, // ratio
                -1f, // threshold dB
                0f, // post gain
            )
        )
        d.enabled = eqEnabled || loudness != 0f
    }

    private fun releaseDynamics() {
        try {
            dynamics?.release()
        } catch (_: Exception) {
        }
        dynamics = null
    }
}
