import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material. Either provide `android/key.properties`
// (KEYSTORE_PATH, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD) or the matching
// environment variables; both files are git-ignored. When neither is present the
// release build falls back to the debug key so local builds keep working, but it
// is not publishable to Play in that state.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(propertyName: String, envName: String): String? =
    (keystoreProperties.getProperty(propertyName) ?: System.getenv(envName))?.takeIf { it.isNotBlank() }

val releaseStorePath = signingValue("KEYSTORE_PATH", "KEYSTORE_PATH")
val hasReleaseSigning = releaseStorePath != null

android {
    namespace = "com.tango.kyc.tango_kyc_verification"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
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
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "WARNING: no release keystore configured (android/key.properties or " +
                        "KEYSTORE_PATH). Falling back to the debug signing key; this build " +
                        "cannot be published to Google Play.",
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
