package com.itsaky.androidide.app

import android.os.Build
import android.provider.Settings
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.itsaky.androidide.BuildConfig
import com.itsaky.androidide.analytics.AttachedDevicesCollector
import com.itsaky.androidide.analytics.AttachedDevicesMetric
import com.itsaky.androidide.analytics.IAnalyticsManager
import com.itsaky.androidide.app.strictmode.StrictModeConfig
import com.itsaky.androidide.app.strictmode.StrictModeManager
import com.itsaky.androidide.events.AppEventsIndex
import com.itsaky.androidide.events.EditorEventsIndex
import com.itsaky.androidide.events.LspApiEventsIndex
import com.itsaky.androidide.events.LspJavaEventsIndex
import com.itsaky.androidide.events.ProjectsApiEventsIndex
import com.itsaky.androidide.handlers.CrashEventSubscriber
import com.itsaky.androidide.handlers.GlitchTipDiagnosticsContext
import com.itsaky.androidide.handlers.MetricsCrashAttachment
import com.itsaky.androidide.logging.provider.IdeLogRouter
import com.itsaky.androidide.preferences.internal.StatPreferences
import com.itsaky.androidide.preferences.internal.TelemetryConsent
import com.itsaky.androidide.syntax.colorschemes.SchemeAndroidIDE
import com.itsaky.androidide.ui.themes.IThemeManager
import com.itsaky.androidide.utils.Environment
import com.itsaky.androidide.utils.FeatureFlags
import com.itsaky.androidide.utils.MetricsScratch
import com.termux.shared.reflection.ReflectionUtils
import io.github.rosemoe.sora.widget.schemes.EditorColorScheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import moe.shizuku.manager.ShizukuSettings
import org.greenrobot.eventbus.EventBus
import org.koin.core.component.KoinComponent
import org.koin.core.component.inject
import org.slf4j.LoggerFactory
import org.slf4j.event.Level
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.system.exitProcess

/**
 * @author Akash Yadav
 */
internal object DeviceProtectedApplicationLoader :
	ApplicationLoader,
	DefaultLifecycleObserver,
	KoinComponent {
	private val logger = LoggerFactory.getLogger(DeviceProtectedApplicationLoader::class.java)

	private val crashEventSubscriber = CrashEventSubscriber()
	val analyticsManager: IAnalyticsManager by inject()

	private val telemetryInitialized = AtomicBoolean(false)

	private const val KEY_LEGACY_PRIVACY_DISCLOSURE_SHOWN = "privacy.disclosure.shown"

	override suspend fun load(app: IDEApplication) {
		logger.info("Loading device protected storage context components...")

		runCatching {
			Environment.init(app)
		}

		runCatching {
			// try to initialize feature flags
			// this may fail when running in direct boot mode, so we wrap this
			// in runCatching and ignore errors, if any
			FeatureFlags.initialize()
		}

		// Enable StrictMode for debug builds
		StrictModeManager.install(
			StrictModeConfig(
				enabled = BuildConfig.DEBUG && !FeatureFlags.isPardonEnabled,
				isReprieveEnabled = true,
			),
		)

		initTelemetryIfConsented(app)

		ShizukuSettings.initialize()

		EventBus
			.builder()
			.addIndex(AppEventsIndex())
			.addIndex(EditorEventsIndex())
			.addIndex(ProjectsApiEventsIndex())
			.addIndex(LspApiEventsIndex())
			.addIndex(LspJavaEventsIndex())
			.installDefaultEventBus(true)

		EventBus.getDefault().register(crashEventSubscriber)

		EditorColorScheme.setDefault(SchemeAndroidIDE.newInstance(null))

		ReflectionUtils.bypassHiddenAPIReflectionRestrictions()

		app.coroutineScope.launch(Dispatchers.IO) {
			IThemeManager.getInstance()
		}
	}

	suspend fun initTelemetryIfConsented(app: IDEApplication) {
		// Crash/usage telemetry (Sentry/GlitchTip, Firebase Analytics) has been removed
		// from this build; nothing to initialize.
	}

	fun handleUncaughtException(
		thread: Thread,
		exception: Throwable,
	) {
		// we can't write logs to files, nor we can show the crash handler
		// activity to the user. Just exit.

		IDEApplication.instance.uncaughtExceptionHandler?.uncaughtException(thread, exception)
		exitProcess(EXIT_CODE_CRASH)
	}

	override fun onStart(owner: LifecycleOwner) {
		super.onStart(owner)
		analyticsManager.startSession()
	}

	override fun onStop(owner: LifecycleOwner) {
		super.onStop(owner)
		analyticsManager.endSession()
	}
}
