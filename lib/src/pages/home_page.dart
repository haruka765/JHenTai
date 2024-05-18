import 'dart:async';

import 'package:clipboard/clipboard.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery_image_page_url.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/pages/gallery_image/gallery_image_page_logic.dart';
import 'package:jhentai/src/pages/layout/desktop/desktop_layout_page.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2.dart';
import 'package:jhentai/src/pages/layout/tablet_v2/tablet_layout_page_v2.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/log.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/utils/version_util.dart';
import 'package:jhentai/src/widget/will_pop_interceptor.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:retry/retry.dart';
import 'package:window_manager/window_manager.dart';

import '../mixin/window_widget_mixin.dart';
import '../mixin/login_required_logic_mixin.dart';
import '../model/jh_layout.dart';
import '../network/eh_request.dart';
import '../routes/routes.dart';
import '../service/storage_service.dart';
import '../setting/advanced_setting.dart';
import '../utils/eh_spider_parser.dart';
import '../utils/route_util.dart';
import '../utils/screen_size_util.dart';
import '../utils/snack_util.dart';
import '../utils/string_uril.dart';
import '../widget/app_manager.dart';
import '../widget/update_dialog.dart';

const int left = 1;
const int right = 2;
const int fullScreen = 3;
const int leftV2 = 4;
const int rightV2 = 5;

Routing leftRouting = Routing();
Routing rightRouting = Routing();

/// Core widget to decide which layout to be applied
class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with LoginRequiredMixin, WindowListener, WindowWidgetMixin {
  final StorageService storageService = Get.find();

  StreamSubscription? _intentDataStreamSubscription;
  String? _lastDetectedText;

  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    initToast(context);
    _initSharingIntent();
    _checkUpdate();
    _handleUrlInClipBoard();

    _listener = AppLifecycleListener(onResume: _handleUrlInClipBoard);
  }

  @override
  void dispose() {
    super.dispose();
    _intentDataStreamSubscription?.cancel();
    _listener.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return buildWindow(
      child: WillPopInterceptor(
        /// Use LayoutBuilder to listen to resize of window.
        child: LayoutBuilder(
          builder: (_, __) => Obx(
            () {
              if (StyleSetting.layout.value == LayoutMode.mobileV2 || StyleSetting.layout.value == LayoutMode.mobile) {
                StyleSetting.actualLayout = LayoutMode.mobileV2;
                return MobileLayoutPageV2();
              }

              /// Device width is under 600, degrade to mobileV2 layout.
              if (fullScreenWidth < 600) {
                StyleSetting.actualLayout = LayoutMode.mobileV2;
                untilRoute2BlankPage();
                return MobileLayoutPageV2();
              }

              if (StyleSetting.layout.value == LayoutMode.tabletV2 || StyleSetting.layout.value == LayoutMode.tablet) {
                StyleSetting.actualLayout = LayoutMode.tabletV2;
                return TabletLayoutPageV2();
              }

              StyleSetting.actualLayout = LayoutMode.desktop;
              return DesktopLayoutPage();
            },
          ),
        ),
      ),
    );
  }

  Future<void> _checkUpdate() async {
    if (AdvancedSetting.enableCheckUpdate.isFalse) {
      return;
    }

    String url = 'https://api.github.com/repos/jiangtian616/JHenTai/releases';
    String latestVersion;

    try {
      latestVersion = (await retry(
        () => EHRequest.get(url: url, parser: EHSpiderParser.githubReleasePage2LatestVersion),
        maxAttempts: 3,
      ))
          .trim()
          .split('+')[0];
    } on Exception catch (_) {
      Log.info('check update failed');
      return;
    }

    String? dismissVersion = storageService.read(UpdateDialog.dismissVersion);
    if (dismissVersion == latestVersion) {
      return;
    }

    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    String currentVersion = 'v${packageInfo.version}'.trim();
    Log.info('Latest version:[$latestVersion], current version: [$currentVersion]');

    if (compareVersion(currentVersion, latestVersion) >= 0) {
      return;
    }

    Get.engine.addPostFrameCallback((_) {
      Get.dialog(UpdateDialog(currentVersion: currentVersion, latestVersion: latestVersion));
    });
  }

  /// Listen to share or open urls/text coming from outside the app while the app is in the memory or is closed
  void _initSharingIntent() {
    if (!GetPlatform.isAndroid) {
      return;
    }

    ReceiveSharingIntent.getInitialText().then(
      (String? rawText) {
        if (isEmptyOrNull(rawText)) {
          return;
        }

        GalleryUrl? galleryUrl = GalleryUrl.tryParse(rawText!);
        if (galleryUrl != null) {
          toRoute(
            Routes.details,
            arguments: DetailsPageArgument(galleryUrl: galleryUrl),
            offAllBefore: false,
            preventDuplicates: false,
          );
          return;
        }

        GalleryImagePageUrl? galleryImagePageUrl = GalleryImagePageUrl.tryParse(rawText);
        if (galleryImagePageUrl != null) {
          toRoute(
            Routes.imagePage,
            arguments: GalleryImagePageArgument(galleryImagePageUrl: galleryImagePageUrl),
            offAllBefore: false,
          );
          return;
        }

        toast('Invalid jump link', isShort: false);
      },
    );

    _intentDataStreamSubscription = ReceiveSharingIntent.getTextStream().listen(
      (String url) {
        GalleryUrl? galleryUrl = GalleryUrl.tryParse(url);
        if (galleryUrl != null) {
          toRoute(
            Routes.details,
            arguments: DetailsPageArgument(galleryUrl: galleryUrl),
            offAllBefore: false,
            preventDuplicates: false,
          );
          return;
        }

        GalleryImagePageUrl? galleryImagePageUrl = GalleryImagePageUrl.tryParse(url);
        if (galleryImagePageUrl != null) {
          toRoute(
            Routes.imagePage,
            arguments: GalleryImagePageArgument(galleryImagePageUrl: galleryImagePageUrl),
            offAllBefore: false,
          );
          return;
        }
      },
      onError: (e) {
        Log.error('ReceiveSharingIntent Error!', e);
        Log.uploadError(e);
      },
    );
  }

  /// a gallery url exists in clipboard, show dialog to check whether enter detail page
  void _handleUrlInClipBoard() async {
    if (AdvancedSetting.enableCheckClipboard.isFalse) {
      return;
    }

    String rawText = await FlutterClipboard.paste();
    GalleryUrl? galleryUrl = GalleryUrl.tryParse(rawText);
    GalleryImagePageUrl? galleryImagePageUrl = GalleryImagePageUrl.tryParse(rawText);

    if (galleryUrl == null && galleryImagePageUrl == null) {
      return;
    }

    /// show snack only once
    if (rawText == _lastDetectedText) {
      return;
    }

    _lastDetectedText = rawText;
    if (galleryUrl != null) {
      snack(
        'galleryUrlDetected'.tr,
        '${'galleryUrlDetectedHint'.tr}: ${galleryUrl.url}',
        onPressed: () {
          if (!galleryUrl.isEH && !UserSetting.hasLoggedIn()) {
            showLoginToast();
            return;
          }
          toRoute(
            Routes.details,
            arguments: DetailsPageArgument(galleryUrl: galleryUrl),
            offAllBefore: false,
            preventDuplicates: false,
          );
        },
        longDuration: true,
      );
    } else if (galleryImagePageUrl != null) {
      snack(
        'galleryUrlDetected'.tr,
        '${'galleryUrlDetectedHint'.tr}: ${galleryImagePageUrl.url}',
        onPressed: () {
          if (!galleryImagePageUrl.isEH && !UserSetting.hasLoggedIn()) {
            showLoginToast();
            return;
          }
          toRoute(
            Routes.imagePage,
            arguments: GalleryImagePageArgument(galleryImagePageUrl: galleryImagePageUrl),
            offAllBefore: false,
          );
        },
        longDuration: true,
      );
    }
  }
}
