#!/usr/bin/env bash
# 在 CI 环境里生成完整的 Android 工程源码
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PKG="app/src/main/java/com/deepseek/balancewidget"
mkdir -p "$PKG" \
         app/src/main/res/layout \
         app/src/main/res/values \
         app/src/main/res/xml \
         app/src/main/res/drawable \
         app/src/main/res/mipmap-anydpi-v26

# ------------------------------------------------------------------ Gradle

cat > settings.gradle.kts <<'EOF'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "DeepSeekBalanceWidget"
include(":app")
EOF

cat > build.gradle.kts <<'EOF'
plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}
EOF

cat > gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
org.gradle.parallel=true
org.gradle.caching=true
android.useAndroidX=true
android.nonTransitiveRClass=true
android.suppressUnsupportedCompileSdk=35
kotlin.code.style=official
EOF

cat > app/build.gradle.kts <<'EOF'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.deepseek.balancewidget"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.deepseek.balancewidget"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}
EOF

# ------------------------------------------------------------------ Manifest

cat > app/src/main/AndroidManifest.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

    <application
        android:allowBackup="false"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:roundIcon="@mipmap/ic_launcher_round"
        android:theme="@style/AppTheme"
        android:usesCleartextTraffic="false">

        <activity
            android:name=".SettingsActivity"
            android:exported="true"
            android:label="@string/app_name">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <receiver
            android:name=".BalanceWidgetProvider"
            android:exported="true">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
                <action android:name="com.deepseek.balancewidget.ACTION_REFRESH" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/widget_info" />
        </receiver>

        <receiver
            android:name=".BootReceiver"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
            </intent-filter>
        </receiver>
    </application>
</manifest>
EOF

# ------------------------------------------------------------------ Core.kt

cat > "$PKG/Core.kt" <<'EOF'
package com.deepseek.balancewidget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.math.BigDecimal
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.TimeUnit

// ============================ 数据模型 ============================

data class Balance(
    val currency: String,
    val total: BigDecimal,
    val granted: BigDecimal,
    val toppedUp: BigDecimal,
    val isAvailable: Boolean,
    val fetchedAt: Long
)

class ApiException(message: String, val retryable: Boolean = true) : Exception(message)

internal fun parseDecimal(text: String?): BigDecimal? {
    val trimmed = text?.trim().orEmpty()
    if (trimmed.isEmpty()) return null
    return try {
        BigDecimal(trimmed)
    } catch (e: NumberFormatException) {
        null
    }
}

// ============================ 接口层 ============================

object DeepSeekApi {

    private const val TIMEOUT_MS = 10_000

    suspend fun fetchBalance(
        apiKey: String,
        baseUrl: String,
        preferredCurrency: String
    ): Balance = withContext(Dispatchers.IO) {
        val key = apiKey.trim()
        if (key.isEmpty()) throw ApiException("未设置 API Key", retryable = false)

        val endpoint = URL(baseUrl.trim().trimEnd('/') + "/user/balance")
        val conn = endpoint.openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "GET"
            conn.connectTimeout = TIMEOUT_MS
            conn.readTimeout = TIMEOUT_MS
            conn.setRequestProperty("Authorization", "Bearer $key")
            conn.setRequestProperty("Accept", "application/json")
            conn.setRequestProperty("User-Agent", "deepseek-balance-widget/1.0")

            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()

            if (code !in 200..299) throw httpError(code, text)
            parseBalance(JSONObject(text), preferredCurrency)
        } catch (e: ApiException) {
            throw e
        } catch (e: java.net.SocketTimeoutException) {
            throw ApiException("请求超时（10 秒）")
        } catch (e: Exception) {
            throw ApiException("网络错误：${e.message ?: e.javaClass.simpleName}")
        } finally {
            conn.disconnect()
        }
    }

    private fun httpError(code: Int, body: String): ApiException {
        val detail = runCatching {
            JSONObject(body).optJSONObject("error")?.optString("message").orEmpty()
        }.getOrDefault("")
        val tail = if (detail.isBlank()) "" else "：$detail"
        return when {
            code == 401 || code == 403 ->
                ApiException("API Key 无效或已被撤销（HTTP $code）$tail", retryable = false)
            code == 402 ->
                ApiException("余额不足，服务端拒绝请求", retryable = false)
            code == 429 ->
                ApiException("请求过于频繁（HTTP 429）", retryable = true)
            else ->
                ApiException("服务端错误 HTTP $code$tail", retryable = code >= 500)
        }
    }

    fun parseBalance(root: JSONObject, preferredCurrency: String): Balance {
        val infos = root.optJSONArray("balance_infos")
            ?: throw ApiException("返回数据缺少 balance_infos", retryable = false)
        if (infos.length() == 0) {
            throw ApiException("balance_infos 为空", retryable = false)
        }

        val want = preferredCurrency.trim().uppercase(Locale.ROOT)
        val chosen: JSONObject = run {
            for (i in 0 until infos.length()) {
                val item = infos.optJSONObject(i) ?: continue
                if (item.optString("currency").uppercase(Locale.ROOT) == want) return@run item
            }
            infos.optJSONObject(0)
                ?: throw ApiException("balance_infos 内容异常", retryable = false)
        }

        val total = parseDecimal(chosen.optString("total_balance"))
            ?: throw ApiException("无法解析 total_balance", retryable = false)

        return Balance(
            currency = chosen.optString("currency").ifBlank { preferredCurrency }
                .uppercase(Locale.ROOT),
            total = total,
            granted = parseDecimal(chosen.optString("granted_balance")) ?: BigDecimal.ZERO,
            toppedUp = parseDecimal(chosen.optString("topped_up_balance")) ?: BigDecimal.ZERO,
            isAvailable = root.optBoolean("is_available", true),
            fetchedAt = System.currentTimeMillis()
        )
    }
}

// ============================ 存储层 ============================

class Prefs(context: Context) {

    private val sp: SharedPreferences =
        context.applicationContext.getSharedPreferences("deepseek_widget", Context.MODE_PRIVATE)

    var apiKey: String
        get() = sp.getString(KEY_API_KEY, "").orEmpty()
        set(value) = sp.edit().putString(KEY_API_KEY, value.trim()).apply()

    var baseUrl: String
        get() = sp.getString(KEY_BASE_URL, DEFAULT_BASE_URL).orEmpty()
        set(value) = sp.edit()
            .putString(KEY_BASE_URL, value.trim().ifBlank { DEFAULT_BASE_URL })
            .apply()

    var currency: String
        get() = sp.getString(KEY_CURRENCY, "CNY").orEmpty()
        set(value) = sp.edit()
            .putString(KEY_CURRENCY, value.trim().uppercase(Locale.ROOT).ifBlank { "CNY" })
            .apply()

    var warnBelow: BigDecimal
        get() = parseDecimal(sp.getString(KEY_WARN, null)) ?: DEFAULT_WARN
        set(value) = sp.edit().putString(KEY_WARN, value.toPlainString()).apply()

    var criticalBelow: BigDecimal
        get() = parseDecimal(sp.getString(KEY_CRITICAL, null)) ?: DEFAULT_CRITICAL
        set(value) = sp.edit().putString(KEY_CRITICAL, value.toPlainString()).apply()

    var lastTotal: String?
        get() = sp.getString(KEY_LAST_TOTAL, null)
        set(value) = sp.edit().putString(KEY_LAST_TOTAL, value).apply()

    var lastCurrency: String
        get() = sp.getString(KEY_LAST_CURRENCY, "").orEmpty()
        set(value) = sp.edit().putString(KEY_LAST_CURRENCY, value).apply()

    var lastGranted: String?
        get() = sp.getString(KEY_LAST_GRANTED, null)
        set(value) = sp.edit().putString(KEY_LAST_GRANTED, value).apply()

    var lastToppedUp: String?
        get() = sp.getString(KEY_LAST_TOPPED_UP, null)
        set(value) = sp.edit().putString(KEY_LAST_TOPPED_UP, value).apply()

    var lastAvailable: Boolean
        get() = sp.getBoolean(KEY_LAST_AVAILABLE, true)
        set(value) = sp.edit().putBoolean(KEY_LAST_AVAILABLE, value).apply()

    var lastUpdated: Long
        get() = sp.getLong(KEY_LAST_UPDATED, 0L)
        set(value) = sp.edit().putLong(KEY_LAST_UPDATED, value).apply()

    var lastError: String?
        get() = sp.getString(KEY_LAST_ERROR, null)
        set(value) = sp.edit().putString(KEY_LAST_ERROR, value).apply()

    var day: String
        get() = sp.getString(KEY_DAY, "").orEmpty()
        set(value) = sp.edit().putString(KEY_DAY, value).apply()

    var dayOpen: String?
        get() = sp.getString(KEY_DAY_OPEN, null)
        set(value) = sp.edit().putString(KEY_DAY_OPEN, value).apply()

    var failures: Int
        get() = sp.getInt(KEY_FAILURES, 0)
        set(value) = sp.edit().putInt(KEY_FAILURES, value).apply()

    fun applySuccess(balance: Balance) {
        val today = todayKey()
        val editor = sp.edit()
        if (day != today || parseDecimal(dayOpen) == null) {
            editor.putString(KEY_DAY, today)
            editor.putString(KEY_DAY_OPEN, balance.total.toPlainString())
        }
        editor.putString(KEY_LAST_TOTAL, balance.total.toPlainString())
        editor.putString(KEY_LAST_CURRENCY, balance.currency)
        editor.putString(KEY_LAST_GRANTED, balance.granted.toPlainString())
        editor.putString(KEY_LAST_TOPPED_UP, balance.toppedUp.toPlainString())
        editor.putBoolean(KEY_LAST_AVAILABLE, balance.isAvailable)
        editor.putLong(KEY_LAST_UPDATED, balance.fetchedAt)
        editor.putInt(KEY_FAILURES, 0)
        editor.remove(KEY_LAST_ERROR)
        editor.apply()
    }

    fun applyFailure(message: String) {
        sp.edit()
            .putString(KEY_LAST_ERROR, message)
            .putInt(KEY_FAILURES, failures + 1)
            .apply()
    }

    fun todayChange(): BigDecimal? {
        if (day != todayKey()) return null
        val open = parseDecimal(dayOpen) ?: return null
        val last = parseDecimal(lastTotal) ?: return null
        return open - last
    }

    companion object {
        private const val DEFAULT_BASE_URL = "https://api.deepseek.com"
        private val DEFAULT_WARN = BigDecimal("20")
        private val DEFAULT_CRITICAL = BigDecimal("5")

        private const val KEY_API_KEY = "api_key"
        private const val KEY_BASE_URL = "base_url"
        private const val KEY_CURRENCY = "currency"
        private const val KEY_WARN = "warn_below"
        private const val KEY_CRITICAL = "critical_below"
        private const val KEY_LAST_TOTAL = "last_total"
        private const val KEY_LAST_CURRENCY = "last_currency"
        private const val KEY_LAST_GRANTED = "last_granted"
        private const val KEY_LAST_TOPPED_UP = "last_topped_up"
        private const val KEY_LAST_AVAILABLE = "last_available"
        private const val KEY_LAST_UPDATED = "last_updated"
        private const val KEY_LAST_ERROR = "last_error"
        private const val KEY_DAY = "day"
        private const val KEY_DAY_OPEN = "day_open"
        private const val KEY_FAILURES = "failures"

        private fun todayKey(): String {
            val c = Calendar.getInstance()
            return String.format(
                Locale.US, "%04d-%02d-%02d",
                c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH)
            )
        }
    }
}

// ============================ 后台刷新 ============================

object Scheduler {

    private const val PERIODIC_WORK = "deepseek_balance_periodic"
    private const val ONE_SHOT_WORK = "deepseek_balance_oneshot"

    fun ensurePeriodic(context: Context) {
        val request = PeriodicWorkRequestBuilder<RefreshWorker>(30, TimeUnit.MINUTES)
            .setConstraints(networkConstraints())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniquePeriodicWork(
                PERIODIC_WORK, ExistingPeriodicWorkPolicy.UPDATE, request
            )
    }

    fun refreshNow(context: Context) {
        val request = OneTimeWorkRequestBuilder<RefreshWorker>()
            .setConstraints(networkConstraints())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniqueWork(ONE_SHOT_WORK, ExistingWorkPolicy.REPLACE, request)
    }

    private fun networkConstraints(): Constraints =
        Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
}

class RefreshWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val prefs = Prefs(applicationContext)

        if (prefs.apiKey.isBlank()) {
            prefs.applyFailure("未设置 API Key")
            BalanceWidgetProvider.refreshAll(applicationContext)
            return Result.success()
        }

        return try {
            val balance = DeepSeekApi.fetchBalance(prefs.apiKey, prefs.baseUrl, prefs.currency)
            prefs.applySuccess(balance)
            BalanceWidgetProvider.refreshAll(applicationContext)
            Result.success()
        } catch (e: ApiException) {
            prefs.applyFailure(e.message ?: "请求失败")
            BalanceWidgetProvider.refreshAll(applicationContext)
            if (e.retryable) Result.retry() else Result.failure()
        } catch (e: Exception) {
            prefs.applyFailure(e.message ?: "未知错误")
            BalanceWidgetProvider.refreshAll(applicationContext)
            Result.retry()
        }
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == Intent.ACTION_BOOT_COMPLETED) {
            Scheduler.ensurePeriodic(context.applicationContext)
            Scheduler.refreshNow(context.applicationContext)
        }
    }
}
EOF

# ------------------------------------------------------------------ Widget.kt

cat > "$PKG/BalanceWidgetProvider.kt" <<'EOF'
package com.deepseek.balancewidget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import java.math.BigDecimal
import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class BalanceWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        Scheduler.ensurePeriodic(context)
        val views = render(context)
        appWidgetIds.forEach { appWidgetManager.updateAppWidget(it, views) }
        Scheduler.refreshNow(context)
    }

    override fun onEnabled(context: Context) {
        Scheduler.ensurePeriodic(context)
        Scheduler.refreshNow(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) {
            val app = context.applicationContext
            refreshAll(app, refreshing = true)
            Scheduler.refreshNow(app)
        }
    }

    companion object {

        const val ACTION_REFRESH = "com.deepseek.balancewidget.ACTION_REFRESH"

        private const val COLOR_OK = 0xFF3DDC97.toInt()
        private const val COLOR_WARN = 0xFFF5C451.toInt()
        private const val COLOR_BAD = 0xFFFF6B6B.toInt()
        private const val COLOR_DIM = 0xFF8B95A7.toInt()
        private const val COLOR_LOADING = 0xFF5AA9FF.toInt()

        fun refreshAll(context: Context, refreshing: Boolean = false) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, BalanceWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            val views = render(context, refreshing)
            ids.forEach { manager.updateAppWidget(it, views) }
        }

        fun render(context: Context, refreshing: Boolean = false): RemoteViews {
            val prefs = Prefs(context)
            val views = RemoteViews(context.packageName, R.layout.widget_balance)

            val currency = prefs.lastCurrency.ifBlank { prefs.currency }
            val symbol = symbolOf(currency)
            val total = parseDecimal(prefs.lastTotal)
            val error = prefs.lastError

            val amountColor: Int
            val dotColor: Int
            when {
                refreshing -> {
                    dotColor = COLOR_LOADING
                    amountColor = COLOR_DIM
                }
                total == null -> {
                    dotColor = COLOR_BAD
                    amountColor = COLOR_DIM
                }
                !error.isNullOrBlank() -> {
                    dotColor = COLOR_WARN
                    amountColor = COLOR_DIM
                }
                !prefs.lastAvailable -> {
                    dotColor = COLOR_BAD
                    amountColor = COLOR_BAD
                }
                total <= prefs.criticalBelow -> {
                    dotColor = COLOR_BAD
                    amountColor = COLOR_BAD
                }
                total <= prefs.warnBelow -> {
                    dotColor = COLOR_WARN
                    amountColor = COLOR_WARN
                }
                else -> {
                    dotColor = COLOR_OK
                    amountColor = COLOR_OK
                }
            }

            views.setTextViewText(R.id.widget_dot, if (refreshing) "…" else "●")
            views.setTextColor(R.id.widget_dot, dotColor)

            views.setTextViewText(
                R.id.widget_amount,
                if (total != null) symbol + money(total) else "—"
            )
            views.setTextColor(R.id.widget_amount, amountColor)

            val detail = StringBuilder()
            if (!error.isNullOrBlank()) {
                detail.append("⚠ ").append(shorten(error))
                if (prefs.lastUpdated > 0) {
                    detail.append(" · 上次 ").append(clock(prefs.lastUpdated))
                }
            } else if (total != null) {
                val change = prefs.todayChange()
                if (change != null) {
                    if (change.signum() < 0) {
                        detail.append("今日充值 ").append(symbol).append(money(change.negate()))
                    } else {
                        detail.append("今日消耗 ").append(symbol).append(money(change))
                    }
                } else {
                    detail.append("今日暂无变化")
                }
                if (prefs.lastUpdated > 0) {
                    detail.append(" · ").append(clock(prefs.lastUpdated)).append(" 更新")
                }
            } else {
                detail.append(if (refreshing) "正在获取余额…" else "请打开 App 设置 API Key")
            }
            views.setTextViewText(R.id.widget_detail, detail.toString())
            views.setTextColor(
                R.id.widget_detail,
                if (error.isNullOrBlank()) COLOR_DIM else COLOR_WARN
            )

            val extra = when {
                !error.isNullOrBlank() -> ""
                total == null -> ""
                !prefs.lastAvailable -> "⚠ 余额不足，API 调用已被停用"
                else -> {
                    val topped = parseDecimal(prefs.lastToppedUp) ?: BigDecimal.ZERO
                    val granted = parseDecimal(prefs.lastGranted) ?: BigDecimal.ZERO
                    "现金 $symbol${money(topped)} · 赠送 $symbol${money(granted)}"
                }
            }
            views.setTextViewText(R.id.widget_extra, extra)

            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context, 100, Intent(context, SettingsActivity::class.java), flags
                )
            )

            val refreshIntent = Intent(context, BalanceWidgetProvider::class.java)
                .setAction(ACTION_REFRESH)
            views.setOnClickPendingIntent(
                R.id.widget_refresh,
                PendingIntent.getBroadcast(context, 101, refreshIntent, flags)
            )

            return views
        }

        private fun symbolOf(currency: String): String =
            when (currency.uppercase(Locale.ROOT)) {
                "CNY" -> "¥"
                "USD" -> "$"
                else -> if (currency.isBlank()) "" else "$currency "
            }

        private fun money(value: BigDecimal): String =
            NumberFormat.getNumberInstance(Locale.US).apply {
                minimumFractionDigits = 2
                maximumFractionDigits = 2
            }.format(value)

        private fun clock(millis: Long): String =
            SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(millis))

        private fun shorten(text: String, limit: Int = 40): String =
            if (text.length <= limit) text else text.substring(0, limit - 1) + "…"
    }
}
EOF

# ------------------------------------------------------------------ SettingsActivity.kt

cat > "$PKG/SettingsActivity.kt" <<'EOF'
package com.deepseek.balancewidget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import java.math.BigDecimal
import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class SettingsActivity : AppCompatActivity() {

    private lateinit var prefs: Prefs
    private lateinit var keyInput: EditText
    private lateinit var warnInput: EditText
    private lateinit var criticalInput: EditText
    private lateinit var statusView: TextView

    private val handler = Handler(Looper.getMainLooper())
    private val ticker = object : Runnable {
        override fun run() {
            renderStatus()
            handler.postDelayed(this, 1000L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)

        keyInput = findViewById(R.id.input_key)
        warnInput = findViewById(R.id.input_warn)
        criticalInput = findViewById(R.id.input_critical)
        statusView = findViewById(R.id.status)

        keyInput.setText(prefs.apiKey)
        warnInput.setText(prefs.warnBelow.toPlainString())
        criticalInput.setText(prefs.criticalBelow.toPlainString())

        findViewById<Button>(R.id.btn_save).setOnClickListener { save() }
        findViewById<Button>(R.id.btn_refresh).setOnClickListener {
            Scheduler.ensurePeriodic(this)
            Scheduler.refreshNow(this)
            toast("已发起查询，1~3 秒后更新")
        }
        findViewById<Button>(R.id.btn_pin).setOnClickListener { pinWidget() }
        findViewById<Button>(R.id.btn_battery).setOnClickListener { requestIgnoreBattery() }
        findViewById<Button>(R.id.btn_autostart).setOnClickListener { openAutostartSettings() }
    }

    override fun onResume() {
        super.onResume()
        handler.post(ticker)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(ticker)
    }

    private fun save() {
        val key = keyInput.text.toString().trim()
        prefs.apiKey = key
        prefs.warnBelow = parseDecimal(warnInput.text.toString()) ?: BigDecimal("20")
        prefs.criticalBelow = parseDecimal(criticalInput.text.toString()) ?: BigDecimal("5")

        BalanceWidgetProvider.refreshAll(this)
        Scheduler.ensurePeriodic(this)
        Scheduler.refreshNow(this)

        if (key.isNotEmpty() && !key.startsWith("sk-")) {
            toast("已保存，但这串不像 DeepSeek 的 Key（应以 sk- 开头）")
        } else {
            toast("已保存")
        }
    }

    private fun renderStatus() {
        val total = parseDecimal(prefs.lastTotal)
        val currency = prefs.lastCurrency.ifBlank { prefs.currency }
        val symbol = when (currency.uppercase(Locale.ROOT)) {
            "CNY" -> "¥"
            "USD" -> "$"
            else -> ""
        }

        val sb = StringBuilder()
        if (total != null) {
            sb.append("当前余额：").append(symbol).append(fmt(total)).append("\n")
            prefs.todayChange()?.let { change ->
                sb.append(if (change.signum() < 0) "今日充值：" else "今日消耗：")
                    .append(symbol).append(fmt(change.abs())).append("\n")
            }
            if (prefs.lastUpdated > 0) {
                sb.append("更新时间：").append(
                    SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault())
                        .format(Date(prefs.lastUpdated))
                ).append("\n")
            }
            if (!prefs.lastAvailable) {
                sb.append("注意：账户余额不足，API 调用已被服务端停用\n")
            }
        } else {
            sb.append("还没有数据。填好 Key 后点「保存并查询」。\n")
        }
        prefs.lastError?.takeIf { it.isNotBlank() }?.let {
            sb.append("最近一次错误：").append(it)
        }
        statusView.text = sb.toString().trim()
    }

    private fun pinWidget() {
        val manager = AppWidgetManager.getInstance(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.isRequestPinAppWidgetSupported) {
            val provider = ComponentName(this, BalanceWidgetProvider::class.java)
            if (manager.requestPinAppWidget(provider, null, null)) return
        }
        toast("请长按桌面空白处 → 添加小部件 → 找到「DeepSeek 余额」")
    }

    private fun requestIgnoreBattery() {
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName"))
            )
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (e2: Exception) {
                toast("请手动到 设置 → 应用管理 → 本应用 → 省电策略 → 无限制")
            }
        }
    }

    private fun openAutostartSettings() {
        val candidates = listOf(
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity"
            ),
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.powercenter.PowerSettings"
            ),
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
            )
        )
        for (component in candidates) {
            try {
                startActivity(Intent().setComponent(component))
                return
            } catch (e: Exception) {
                // 换下一个候选
            }
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")
                )
            )
        } catch (e: Exception) {
            toast("请手动到 设置 → 应用管理 → 本应用，允许自启动")
        }
    }

    private fun fmt(value: BigDecimal): String =
        NumberFormat.getNumberInstance(Locale.US).apply {
            minimumFractionDigits = 2
            maximumFractionDigits = 2
        }.format(value)

    private fun toast(text: String) {
        Toast.makeText(this, text, Toast.LENGTH_LONG).show()
    }
}
EOF

# ------------------------------------------------------------------ 资源文件

cat > app/src/main/res/values/all.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">DeepSeek 余额</string>
    <string name="widget_title">DeepSeek 余额</string>
    <string name="widget_idle">正在初始化…</string>
    <string name="widget_description">在桌面显示 DeepSeek API 账户剩余金额</string>

    <string name="intro">填好 API Key 后，桌面小组件会定时自动查询余额。Key 只保存在本机。</string>
    <string name="label_key">API Key</string>
    <string name="hint_key">粘贴 sk- 开头的 Key</string>
    <string name="label_warn">预警阈值（黄色）</string>
    <string name="label_critical">危险阈值（红色）</string>
    <string name="btn_save">保存并查询</string>
    <string name="btn_refresh">立即刷新</string>
    <string name="btn_pin">添加桌面小组件</string>
    <string name="btn_battery">允许后台运行（关闭省电限制）</string>
    <string name="btn_autostart">打开自启动设置</string>
    <string name="label_status">状态</string>
    <string name="note">说明：小组件每 30 分钟自动刷新一次，点小组件右上角 ↻ 可立即刷新，点其他地方打开本页。\n安装来源：github.com（第三方构建，非官方）。</string>

    <color name="brand">#4D6BFE</color>
    <color name="ic_launcher_background">#1B2330</color>

    <style name="AppTheme" parent="Theme.Material3.DayNight.NoActionBar">
        <item name="colorPrimary">@color/brand</item>
    </style>
</resources>
EOF

cat > app/src/main/res/layout/widget_balance.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/widget_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="@drawable/widget_bg"
    android:orientation="vertical"
    android:padding="14dp">

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:gravity="center_vertical"
        android:orientation="horizontal">

        <TextView
            android:id="@+id/widget_dot"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="●"
            android:textColor="#8B95A7"
            android:textSize="10sp" />

        <TextView
            android:id="@+id/widget_title"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_marginStart="6dp"
            android:layout_weight="1"
            android:maxLines="1"
            android:ellipsize="end"
            android:text="@string/widget_title"
            android:textColor="#B9C2D0"
            android:textSize="12sp" />

        <TextView
            android:id="@+id/widget_refresh"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:paddingStart="10dp"
            android:paddingTop="2dp"
            android:paddingEnd="4dp"
            android:paddingBottom="6dp"
            android:text="↻"
            android:textColor="#B9C2D0"
            android:textSize="16sp" />
    </LinearLayout>

    <TextView
        android:id="@+id/widget_amount"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="2dp"
        android:ellipsize="end"
        android:maxLines="1"
        android:text="—"
        android:textColor="#E8ECF3"
        android:textSize="26sp"
        android:textStyle="bold" />

    <TextView
        android:id="@+id/widget_detail"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:ellipsize="end"
        android:maxLines="1"
        android:text="@string/widget_idle"
        android:textColor="#8B95A7"
        android:textSize="11sp" />

    <TextView
        android:id="@+id/widget_extra"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:ellipsize="end"
        android:maxLines="1"
        android:text=""
        android:textColor="#8B95A7"
        android:textSize="11sp" />
</LinearLayout>
EOF

cat > app/src/main/res/layout/activity_main.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<ScrollView xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:fillViewport="true">

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="vertical"
        android:padding="20dp">

        <TextView
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="@string/app_name"
            android:textSize="22sp"
            android:textStyle="bold" />

        <TextView
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="6dp"
            android:text="@string/intro"
            android:textSize="13sp" />

        <TextView
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_marginTop="20dp"
            android:text="@string/label_key"
            android:textSize="14sp"
            android:textStyle="bold" />

        <EditText
            android:id="@+id/input_key"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:hint="@string/hint_key"
            android:inputType="textVisiblePassword"
            android:maxLines="1"
            android:textSize="14sp" />

        <LinearLayout
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="12dp"
            android:orientation="horizontal">

            <LinearLayout
                android:layout_width="0dp"
                android:layout_height="wrap_content"
                android:layout_weight="1"
                android:orientation="vertical">

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="@string/label_warn"
                    android:textSize="12sp" />

                <EditText
                    android:id="@+id/input_warn"
                    android:layout_width="match_parent"
                    android:layout_height="wrap_content"
                    android:inputType="numberDecimal"
                    android:maxLines="1"
                    android:textSize="14sp" />
            </LinearLayout>

            <LinearLayout
                android:layout_width="0dp"
                android:layout_height="wrap_content"
                android:layout_marginStart="12dp"
                android:layout_weight="1"
                android:orientation="vertical">

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="@string/label_critical"
                    android:textSize="12sp" />

                <EditText
                    android:id="@+id/input_critical"
                    android:layout_width="match_parent"
                    android:layout_height="wrap_content"
                    android:inputType="numberDecimal"
                    android:maxLines="1"
                    android:textSize="14sp" />
            </LinearLayout>
        </LinearLayout>

        <Button
            android:id="@+id/btn_save"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="16dp"
            android:text="@string/btn_save" />

        <Button
            android:id="@+id/btn_refresh"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="8dp"
            android:text="@string/btn_refresh" />

        <TextView
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_marginTop="20dp"
            android:text="@string/label_status"
            android:textSize="14sp"
            android:textStyle="bold" />

        <TextView
            android:id="@+id/status"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="6dp"
            android:textSize="13sp" />

        <Button
            android:id="@+id/btn_pin"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="20dp"
            android:text="@string/btn_pin" />

        <Button
            android:id="@+id/btn_battery"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="8dp"
            android:text="@string/btn_battery" />

        <Button
            android:id="@+id/btn_autostart"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="8dp"
            android:text="@string/btn_autostart" />

        <TextView
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="24dp"
            android:text="@string/note"
            android:textSize="11sp" />
    </LinearLayout>
</ScrollView>
EOF

cat > app/src/main/res/xml/widget_info.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:description="@string/widget_description"
    android:initialLayout="@layout/widget_balance"
    android:minHeight="100dp"
    android:minWidth="180dp"
    android:previewLayout="@layout/widget_balance"
    android:resizeMode="horizontal|vertical"
    android:targetCellHeight="2"
    android:targetCellWidth="3"
    android:updatePeriodMillis="0"
    android:widgetCategory="home_screen" />
EOF

cat > app/src/main/res/drawable/widget_bg.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#F21A1F2A" />
    <corners android:radius="20dp" />
    <stroke
        android:width="1dp"
        android:color="#33FFFFFF" />
</shape>
EOF

cat > app/src/main/res/drawable/ic_launcher_foreground.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">

    <path
        android:pathData="M42,38 L54,57 L66,38"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeWidth="6" />
    <path
        android:pathData="M54,57 L54,74"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeWidth="6" />
    <path
        android:pathData="M40,60 L68,60"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeWidth="6" />
    <path
        android:pathData="M40,70 L68,70"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeWidth="6" />
</vector>
EOF

cat > app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
EOF

cp app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml \
   app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml

echo "工程已生成完成："
find . -path ./.git -prune -o -type f -print | sort
