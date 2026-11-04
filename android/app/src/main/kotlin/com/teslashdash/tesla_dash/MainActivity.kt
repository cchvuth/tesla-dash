package com.teslashdash.tesla_dash

import android.Manifest
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.net.Uri
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Surface
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val cm by lazy { getSystemService(ConnectivityManager::class.java) }
    private val wm by lazy { applicationContext.getSystemService(WifiManager::class.java) }
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var channel: MethodChannel? = null

    /**
     * Tells the dash the phone's WiFi came on (look for the car now) or went
     * off (stop waiting out a retry: say so now).
     */
    private val wifiState = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (isInitialStickyBroadcast) return // the state at registration, not a change
            when (intent.getIntExtra(WifiManager.EXTRA_WIFI_STATE, -1)) {
                WifiManager.WIFI_STATE_ENABLED -> channel?.invokeMethod("wifiEnabled", null)
                WifiManager.WIFI_STATE_DISABLED -> channel?.invokeMethod("wifiDisabled", null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Killed while split beside Maps: the owner's rotation comes back now.
        if (!isInMultiWindowMode) releaseLandscape()
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        if (!isInMultiWindowMode) releaseLandscape()
    }

    /**
     * Split screen ignores the app's landscape lock and follows the phone's
     * rotation setting, which can be portrait. Before splitting, keep the
     * owner's setting and lock the landscape side the dash is on now.
     */
    private fun holdLandscape() {
        val r = contentResolver
        val kept = getSharedPreferences("rotation", MODE_PRIVATE)
        if (!kept.contains("auto")) {
            kept.edit()
                .putInt("auto", Settings.System.getInt(r, Settings.System.ACCELEROMETER_ROTATION, 1))
                .putInt("user", Settings.System.getInt(r, Settings.System.USER_ROTATION, Surface.ROTATION_0))
                .apply()
        }
        @Suppress("DEPRECATION")
        val now = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display?.rotation
            else windowManager.defaultDisplay.rotation
        Settings.System.putInt(r, Settings.System.ACCELEROMETER_ROTATION, 0)
        Settings.System.putInt(r, Settings.System.USER_ROTATION, now ?: Surface.ROTATION_90)
    }

    /** Puts back the rotation setting [holdLandscape] kept, if it holds one. */
    private fun releaseLandscape() {
        val kept = getSharedPreferences("rotation", MODE_PRIVATE)
        if (!kept.contains("auto") || !Settings.System.canWrite(this)) return
        val r = contentResolver
        Settings.System.putInt(r, Settings.System.USER_ROTATION, kept.getInt("user", Surface.ROTATION_0))
        Settings.System.putInt(r, Settings.System.ACCELEROMETER_ROTATION, kept.getInt("auto", 1))
        kept.edit().clear().apply()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val filter = IntentFilter(WifiManager.WIFI_STATE_CHANGED_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(wifiState, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(wifiState, filter)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tesla_dash/net")
            .also { channel = it }
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindWifi" -> bindWifi(
                        call.argument<String>("ssid"),
                        call.argument<String>("password"),
                        result,
                    )
                    "unbind" -> { unbind(); stopLook?.invoke(); result.success(null) }
                    "wifiOn" -> result.success(wm.isWifiEnabled)
                    "wifiNearby" -> wifiNearby(
                        call.argument<String>("ssid"),
                        call.argument<Int>("ms") ?: 3_000,
                        result,
                    )
                    // Android 12+ silently returns no scan results while
                    // Location services are off, even with permission granted.
                    "locationOn" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.P ||
                            getSystemService(LocationManager::class.java)?.isLocationEnabled == true
                    )
                    // setWifiEnabled is a no-op from Android 10; the settings
                    // panel is the only way to hand the user the toggle.
                    "openWifiPanel" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            startActivity(Intent(Settings.Panel.ACTION_WIFI))
                        }
                        result.success(null)
                    }
                    // Google Maps in the other half of the screen: launched
                    // adjacent, which also splits a full-screen app's screen
                    // (Android 12L and later), with the screen held landscape.
                    // "asked" while the owner has yet to allow that.
                    "openMaps" -> result.success(
                        if (!Settings.System.canWrite(this)) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS)
                                    .setData(Uri.parse("package:$packageName"))
                            )
                            "asked"
                        } else {
                            holdLandscape()
                            // Driving mode (navigation with no destination yet):
                            // the map and a slim search bar, where Maps' home
                            // screen fills half a screen with panels. Older
                            // Maps without it opens as usual.
                            val opened = listOf(
                                Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:/?free=1&mode=d&entry=fnls")),
                                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER),
                            ).any { maps ->
                                try {
                                    startActivity(
                                        maps.setPackage("com.google.android.apps.maps").addFlags(
                                            Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT or
                                                Intent.FLAG_ACTIVITY_NEW_TASK
                                        )
                                    )
                                    true
                                } catch (e: ActivityNotFoundException) {
                                    false
                                }
                            }
                            if (!opened) releaseLandscape()
                            if (opened) "opened" else "missing"
                        }
                    )
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Gets this app onto the OBD dongle's (internet-less) WiFi without the
     * phone routing everything else through it.
     *
     * Preferred path (Android 10+): request the SSID with a
     * WifiNetworkSpecifier. Android treats that as an app-scoped device
     * connection — one approval dialog, then remembered — and keeps mobile
     * data as the default network for everyone else. Below Android 10: bind
     * to whatever WiFi the user joined manually.
     *
     * ponytail: binds the whole process, which is fine while the app needs no
     * internet. If it ever does, call network.bindSocket() on the OBD socket
     * instead.
     */
    private fun bindWifi(ssid: String?, password: String?, result: MethodChannel.Result) {
        unbind()
        var replied = false
        fun reply(ok: Boolean) {
            if (replied) return
            replied = true
            runOnUiThread { result.success(ok) }
        }

        // A fresh builder each time: setNetworkSpecifier changes the one it
        // is called on, and the fallback must ask for any WiFi.
        fun base() = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)

        fun request(req: NetworkRequest, timeoutMs: Int, onFail: () -> Unit) {
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    cm.bindProcessToNetwork(network)
                    reply(true)
                }
                override fun onUnavailable() {
                    if (callback === this) callback = null
                    runCatching { cm.unregisterNetworkCallback(this) }
                    onFail()
                }
                override fun onLost(network: Network) {
                    cm.bindProcessToNetwork(null)
                }
            }
            callback = cb
            try {
                cm.requestNetwork(req, cb, timeoutMs)
            } catch (e: Exception) {
                callback = null
                onFail()
            }
        }

        val plain = { request(base().build(), 10_000) { reply(false) } }

        if (!ssid.isNullOrEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).apply {
                if (!password.isNullOrEmpty()) setWpa2Passphrase(password)
            }.build()
            // 60 s: the user has to tap the system dialog the first time.
            // No fallback after it: any-WiFi could take another saved network
            // in range, and the dash would step Bluetooth aside to say hello
            // into it. The dash retries instead.
            request(base().setNetworkSpecifier(spec).build(), 60_000) { reply(false) }
        } else {
            plain()
        }
    }

    /** Ends the look for the Commander's network that is waiting, if any: no. */
    private var stopLook: (() -> Unit)? = null

    /**
     * Whether the phone sees [ssid], so the app asks for the network (and
     * Android 10+ shows its "Searching for devices…" dialog) only once it is
     * there. Starts a scan (Android allows an app 4 in 2 minutes) and answers
     * yes on the first scan results that hold it, else whatever the latest
     * results say after [waitMs] (the dash's slider, 3 s by default): any
     * scan's results land in that broadcast. A longer wait holds Bluetooth
     * back longer: it starts no link while this runs. [waitMs] 0 is no limit:
     * it waits for results that hold the network however long that takes,
     * asking for a fresh scan every 30 s (about what the quota allows), and
     * answers no only when [stopLook] ends it. One look at a time. Below
     * Android 10 there is no dialog, and without location access results
     * cannot be read: yes, and the request decides.
     */
    private fun wifiNearby(ssid: String?, waitMs: Int, result: MethodChannel.Result) {
        stopLook?.invoke() // the one before is over: its answer is no longer wanted
        fun readable() = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.P ||
                getSystemService(LocationManager::class.java)?.isLocationEnabled == true)
        if (!readable() || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(true)
            return
        }
        @Suppress("DEPRECATION")
        fun seen() = runCatching { wm.scanResults }.getOrNull().orEmpty().any { it.SSID == ssid }
        val ui = Handler(Looper.getMainLooper())
        var answered = false
        var receiver: BroadcastReceiver? = null
        var timeout: Runnable? = null
        var again: Runnable? = null
        var stop: (() -> Unit)? = null
        fun finish(yes: Boolean) {
            if (answered) return
            answered = true
            receiver?.let { runCatching { unregisterReceiver(it) } }
            timeout?.let { ui.removeCallbacks(it) }
            again?.let { ui.removeCallbacks(it) }
            if (stopLook === stop) stopLook = null
            result.success(yes)
        }
        stop = { finish(false) }
        stopLook = stop
        @Suppress("DEPRECATION")
        val started = runCatching { wm.startScan() }.getOrDefault(false)
        // Refused: the latest results decide. With no limit only a yes counts;
        // a no waits for fresh results.
        if (!started && (waitMs > 0 || seen())) return finish(seen())
        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (seen()) finish(true)
            }
        }
        val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
        if (waitMs > 0) {
            val t = Runnable { finish(seen()) }
            timeout = t
            ui.postDelayed(t, waitMs.toLong())
        } else {
            val r = object : Runnable {
                override fun run() {
                    // Results can no longer be read (Location went off): the
                    // request decides, as at the start.
                    if (!readable()) return finish(true)
                    @Suppress("DEPRECATION")
                    runCatching { wm.startScan() }
                    ui.postDelayed(this, 30_000)
                }
            }
            again = r
            ui.postDelayed(r, 30_000)
        }
    }

    private fun unbind() {
        cm.bindProcessToNetwork(null)
        callback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        callback = null
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(wifiState) }
        stopLook?.invoke()
        channel = null
        unbind()
        releaseLandscape()
        super.onDestroy()
    }
}
