# Flutter and Android framework integration.
-keep class io.flutter.** { *; }
-keep class androidx.media.** { *; }

# audio_service / just_audio_background.
-keep class com.ryanheise.** { *; }
-keep class com.google.android.exoplayer2.** { *; }
-keep class androidx.media3.** { *; }

# Keep plugin classes and constructors discovered by Flutter/plugin registries.
-keep class com.ryanheise.just_audio.** { *; }
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio_background.** { *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
