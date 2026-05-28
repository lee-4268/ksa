import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Modern Minimal 공통 위젯 모음

/// 카드 컨테이너
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool withBorder;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.withBorder = false,
    this.onTap,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final br = borderRadius ?? BorderRadius.circular(12);
    final decoration = withBorder
        ? BoxDecoration(
            color: Colors.white,
            borderRadius: br,
            border: Border.all(color: AppColors.border),
          )
        : BoxDecoration(
            color: Colors.white,
            borderRadius: br,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 12,
                offset: const Offset(0, 2),
              ),
            ],
          );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: br,
        child: Container(
          padding: padding,
          decoration: decoration,
          child: child,
        ),
      );
    }

    return Container(
      padding: padding,
      decoration: decoration,
      child: child,
    );
  }
}

/// 상태 뱃지 (색상 자동 설정)
class AppBadge extends StatelessWidget {
  final String text;
  final Color color;
  final Color? backgroundColor;
  final double fontSize;

  const AppBadge({
    super.key,
    required this.text,
    required this.color,
    this.backgroundColor,
    this.fontSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 섹션 헤더
class AppSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const AppSectionHeader({
    super.key,
    required this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textMid,
              letterSpacing: 0.5,
            ),
          ),
          if (trailing != null) ...[
            const Spacer(),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 기본 버튼 (Primary)
class AppPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double? width;

  const AppPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 44,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : icon != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18),
                      const SizedBox(width: 6),
                      Text(label,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ],
                  )
                : Text(label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// 외곽선 버튼 (Outlined)
class AppOutlinedButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? foregroundColor;
  final Color? borderColor;

  const AppOutlinedButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.foregroundColor,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foregroundColor ?? AppColors.textDark;
    final bc = borderColor ?? AppColors.border;
    return SizedBox(
      height: 44,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: fg,
          elevation: 0,
          side: BorderSide(color: bc),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: icon != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: fg)),
                ],
              )
            : Text(label,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: fg)),
      ),
    );
  }
}

/// 구분선 (Divider 래퍼)
class AppDivider extends StatelessWidget {
  final double height;
  const AppDivider({super.key, this.height = 1});

  @override
  Widget build(BuildContext context) {
    return Divider(height: height, thickness: 1, color: AppColors.border);
  }
}

/// AppBar용 하단 테두리 PreferredSize
class AppBarBottomBorder extends StatelessWidget
    implements PreferredSizeWidget {
  const AppBarBottomBorder({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(1);

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, color: AppColors.border);
  }
}

/// 공통 AppBar 빌더
AppBar buildAppBar({
  required String title,
  List<Widget>? actions,
  Widget? leading,
  bool centerTitle = false,
  PreferredSizeWidget? bottom,
}) {
  return AppBar(
    backgroundColor: Colors.white,
    elevation: 0,
    surfaceTintColor: Colors.transparent,
    centerTitle: centerTitle,
    leading: leading,
    title: Text(
      title,
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: AppColors.textDark,
        letterSpacing: -0.2,
      ),
    ),
    actions: actions,
    iconTheme: const IconThemeData(color: AppColors.textDark),
    bottom: bottom ??
        const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.border),
        ),
  );
}

/// 빈 상태 표시
class AppEmptyState extends StatelessWidget {
  final String message;
  final IconData icon;
  final VoidCallback? onRetry;

  const AppEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: AppColors.border),
          const SizedBox(height: 12),
          Text(message,
              style: const TextStyle(
                  fontSize: 14, color: AppColors.textMid)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: onRetry,
              child: const Text('다시 시도'),
            ),
          ],
        ],
      ),
    );
  }
}

/// DataTable 스타일 헬퍼
class AppDataTableTheme {
  AppDataTableTheme._();

  static DataTableThemeData get theme => DataTableThemeData(
    headingRowColor: WidgetStateProperty.all(const Color(0xFFF9FAFB)),
    headingTextStyle: const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: AppColors.textDark,
    ),
    dataTextStyle: const TextStyle(
      fontSize: 13,
      color: AppColors.textDark,
    ),
    dividerThickness: 1,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.border),
    ),
  );
}
