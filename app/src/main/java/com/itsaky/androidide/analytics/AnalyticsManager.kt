package com.itsaky.androidide.analytics

import com.itsaky.androidide.analytics.gradle.BuildCompletedMetric
import com.itsaky.androidide.analytics.gradle.BuildStartedMetric
import com.itsaky.androidide.analytics.gradle.StrategySelectedMetric

interface IAnalyticsManager {
	fun initialize()

	fun trackAppOpen()

	fun startSession()

	fun endSession()

	fun trackProjectOpened(projectPath: String)

	fun trackFeatureUsed(featureName: String)

	fun trackError(
		errorType: String,
		errorMessage: String,
	)

	fun setUserProperty(
		key: String,
		value: String,
	)

	fun trackScreenView(screenName: String)

	fun trackBuildRun(metric: BuildStartedMetric) = trackMetric(metric)

	fun trackGradleStrategySelected(metric: StrategySelectedMetric) = trackMetric(metric)

	fun trackBuildCompleted(metric: BuildCompletedMetric) = trackMetric(metric)

	fun trackDeepLink(metric: DeepLinkMetric) = trackMetric(metric)

	fun trackMetric(metric: Metric)
}

class AnalyticsManager : IAnalyticsManager {
	// Telemetry has been removed from this build: every method is a no-op so callers
	// keep working without the Firebase Analytics SDK.

	override fun initialize() {}

	override fun trackAppOpen() {}

	override fun startSession() {}

	override fun endSession() {}

	override fun trackProjectOpened(projectPath: String) {}

	override fun trackFeatureUsed(featureName: String) {}

	override fun trackError(
		errorType: String,
		errorMessage: String,
	) {}

	override fun setUserProperty(
		key: String,
		value: String,
	) {}

	override fun trackScreenView(screenName: String) {}

	override fun trackMetric(metric: Metric) {}
}
