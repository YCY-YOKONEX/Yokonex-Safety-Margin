import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class AppColors {
  static const ink = Color(0xFFD5C7BA);
  static const paper = Color(0xFF070707);
  static const panel = Color(0xFF0E0E0F);
  static const border = Color(0xFF3B3032);
  static const region = Color(0xFFD5C7BA);
  static const cage = Color(0xFFA41424);
  static const green = Color(0xFFD5C7BA);
  static const cyan = Color(0xFFA41424);
  static const alert = Color(0xFFD64550);
  static const yellow = Color(0xFFC89C5D);
  static const muted = Color(0xFF8C8582);
  static const camera = Color(0xFF020202);
  static const wine = Color(0xFFA41424);
}

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.wine,
    onPrimary: AppColors.ink,
    secondary: AppColors.ink,
    onSecondary: AppColors.paper,
    error: AppColors.alert,
    surface: AppColors.paper,
    onSurface: AppColors.ink,
    onSurfaceVariant: AppColors.muted,
    outline: AppColors.border,
    surfaceContainer: AppColors.panel,
    surfaceContainerHighest: AppColors.panel,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.paper,
    fontFamily: 'sans-serif',
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w600,
        fontFamily: 'serif',
        letterSpacing: 0,
      ),
      titleLarge: TextStyle(
        fontSize: 21,
        fontWeight: FontWeight.w700,
        fontFamily: 'serif',
        letterSpacing: 0,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      bodyMedium: TextStyle(fontSize: 14, letterSpacing: 0),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      backgroundColor: AppColors.paper,
      foregroundColor: AppColors.ink,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: AppColors.ink,
        fontFamily: 'serif',
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AppColors.paper,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? AppColors.wine : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? AppColors.muted.withValues(alpha: .4)
              : AppColors.ink,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 50),
        backgroundColor: AppColors.wine,
        foregroundColor: AppColors.ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 50),
        foregroundColor: AppColors.ink,
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: AppColors.paper,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1),
  );
}
