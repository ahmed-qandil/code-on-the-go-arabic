package io.sentry

/**
 * No-op replacement for the Sentry SDK, which has been removed from this build
 * (crash reporting to GlitchTip is disabled). Call sites keep compiling; nothing
 * is ever captured or sent anywhere.
 */
object Sentry {
	@JvmStatic
	fun captureException(throwable: Throwable) {}

	@JvmStatic
	fun close() {}

	@JvmStatic
	fun withScope(callback: (IScope) -> Unit) {}
}

interface IScope {
	fun setTag(key: String, value: String)
}
