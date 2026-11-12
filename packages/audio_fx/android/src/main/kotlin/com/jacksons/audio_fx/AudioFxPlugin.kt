package com.jacksons.audio_fx

import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.Visualizer
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Audio effects on the player's audio session:
 *  - graphic EQ + preamp + loudness gain + limiter (DynamicsProcessing, API 28+)
 *  - spectrum for the visualizer (Visualizer)
 */
class AudioFxPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())

    // --- Equalizer / loudness ---
    private var dynamics: DynamicsProcessing? = null
    private var sessionId = 0
    private var frequencies = FloatArray(0) // band centres, Hz
    private var gains = FloatArray(0) // dB
    private var eqEnabled = false
    private var preamp = 0f
    private var loudness = 0f

    // --- Visualizer ---
    private var visualizer: Visualizer? = null
    private var sink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(binding.binaryMessenger, "audio_fx")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "audio_fx/visualizer")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        stopVisualizer()
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

    // ---------------------------------------------------------------------
    // Visualizer

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val args = arguments as? Map<*, *>
        val session = (args?.get("sessionId") as? Number)?.toInt() ?: 0
        val bands = (args?.get("bands") as? Number)?.toInt() ?: 48
        try {
            startVisualizer(session, bands)
        } catch (e: Exception) {
            // Usually: RECORD_AUDIO not granted.
            events.error("visualizer", e.message, null)
        }
    }

    override fun onCancel(arguments: Any?) {
        stopVisualizer()
        sink = null
    }

    private fun startVisualizer(session: Int, bandCount: Int) {
        stopVisualizer()
        val v = Visualizer(session)
        val range = Visualizer.getCaptureSizeRange()
        v.captureSize = min(1024, range[1])
        val sampleRate = v.samplingRate / 1000f // milliHz -> Hz
        val size = v.captureSize
        val edges = logEdges(bandCount, 40f, min(16000f, sampleRate / 2))
        val out = DoubleArray(bandCount)

        v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
            override fun onWaveFormDataCapture(vis: Visualizer?, waveform: ByteArray?, rate: Int) {}

            override fun onFftDataCapture(vis: Visualizer?, fft: ByteArray?, rate: Int) {
                if (fft == null) return
                val bins = size / 2
                for (b in 0 until bandCount) {
                    val from = max(1, (edges[b] * size / sampleRate).toInt())
                    val to = max(from + 1, min(bins, (edges[b + 1] * size / sampleRate).toInt()))
                    var peak = 0.0
                    for (k in from until to) {
                        val re = fft[2 * k].toDouble()
                        val im = fft[2 * k + 1].toDouble()
                        peak = max(peak, hypot(re, im))
                    }
                    // ~0..45 dB range of the 8-bit FFT, mapped to 0..1.
                    out[b] = (20 * log10(peak + 1.0) / 45.0).coerceIn(0.0, 1.0)
                }
                val copy = out.toList()
                main.post { sink?.success(copy) }
            }
        }, Visualizer.getMaxCaptureRate(), false, true)
        v.enabled = true
        visualizer = v
    }

    private fun stopVisualizer() {
        try {
            visualizer?.enabled = false
            visualizer?.release()
        } catch (_: Exception) {
        }
        visualizer = null
    }

    private fun logEdges(count: Int, lo: Float, hi: Float): FloatArray =
        FloatArray(count + 1) { i -> lo * (hi / lo).pow(i / count.toFloat()) }
}
