import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase Cloud Messaging is wired only when a google-services.json is present.
// Without it the Com google-services plugin (which generates the required
// resources) is skipped entirely, so the app still builds and runs - it simply
// receives no push. This keeps a Firebase-less checkout buildable while making a
// Firebase-configured one fully functional. The file is git-ignored: it is
// per-project client configuration, not a secret, and is not committed.
val googleServicesFile = file("google-services.json")
val hasFirebase = googleServicesFile.exists()
if (hasFirebase) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.warn(
        "google-services.json is absent; Firebase Cloud Messaging is disabled. " +
            "Add mobile/android/app/google-services.json to enable push notifications.",
    )
}

// Release signing material. Provide `android/key.properties`
// (KEYSTORE_PATH, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD) or the matching
// environment variables. Both files are git-ignored. A release build never falls
// back to the debug key: without this material it fails, because a debug-signed
// artifact is rejected by Google Play and unsafe to distribute.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(propertyName: String, envName: String): String? =
    (keystoreProperties.getProperty(propertyName) ?: System.getenv(envName))?.takeIf { it.isNotBlank() }

val releaseStorePath = signingValue("KEYSTORE_PATH", "KEYSTORE_PATH")
val hasReleaseSigning = releaseStorePath != null

// The `release` block below is evaluated for every build, including debug, so a
// missing keystore must only fail the builds that actually produce a release
// artifact. Gradle is invoked with `assembleRelease` / `bundleRelease` by Flutter.
val releaseBuildRequested = gradle.startParameter.taskNames.any { it.contains("Release") }

android {
    namespace = "com.tango.kyc.tango_kyc_verification"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (it uses java.time on older
        // API levels); without it the release build fails to compile.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Package name published to Google Play and registered with Google
        // OAuth. Changing it invalidates the OAuth configuration.
        applicationId = "com.tango.kyc.tango_kyc_verification"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStorePath!!)
                storePassword = signingValue("KEYSTORE_PASSWORD", "KEYSTORE_PASSWORD")
                keyAlias = signingValue("KEY_ALIAS", "KEY_ALIAS")
                keyPassword = signingValue("KEY_PASSWORD", "KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            if (!hasReleaseSigning) {
                if (releaseBuildRequested) {
                    throw GradleException(
                        "Release signing is not configured. Create android/key.properties " +
                            "with KEYSTORE_PATH, KEYSTORE_PASSWORD, KEY_ALIAS and KEY_PASSWORD " +
                            "(see docs/DEPLOYMENT.md), or set the matching environment " +
                            "variables. A debug-signed release artifact is not publishable.",
                    )
                }
                logger.warn(
                    "WARNING: release signing is not configured; the release build type " +
                        "will fail if it is ever assembled.",
                )
            }
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // Unreachable for a release build: the check above throws first. A
                // debug build never assembles this variant, so this placeholder is
                // never used to sign a distributed artifact.
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // Backport of java.time.* for the notification plugin on older Android.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
