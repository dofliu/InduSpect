# R8/ProGuard 額外規則
# Flutter engine 與各 plugin 的 keep 規則由 Flutter Gradle plugin 自動注入，
# 此處僅補上已知的缺類警告抑制。

# Flutter deferred components 會引用 Play Core；本專案未使用，抑制 R8 缺類錯誤
-dontwarn com.google.android.play.core.**

# 保留 model 類的行號資訊，讓 release crash log 可讀
-keepattributes SourceFile,LineNumberTable
