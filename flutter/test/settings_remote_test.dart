import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusionplay_android_flutter/backend/native_app_controller.dart';
import 'package:fusionplay_android_flutter/main.dart';
import 'package:fusionplay_android_flutter/models/app_state.dart';
import 'package:fusionplay_android_flutter/ui/settings_view.dart';

void main() {
  testWidgets('audio calibration respects limits and can return to zero', (
    tester,
  ) async {
    final initial = FocusNode();
    addTearDown(initial.dispose);
    tester.view.physicalSize = const Size(600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final values = <int>[];
    Widget screen(int value) => MaterialApp(
      home: Scaffold(
        body: SettingsView(
          state: AppState(initialized: true, miPlayOutputAdvanceMs: value),
          initialFocusNode: initial,
          onClose: () {},
          onReceiverName: (_) {},
          onStartup: (_) {},
          onAutoWake: (_) {},
          onAdvancedEffects: (_) {},
          onMiPlay: (_) {},
          onMiPlayIdentity: (_) {},
          onAirPlay: (_) {},
          onDlna: (_) {},
          onExportLogs: () async {},
          onMiPlayOutputAdvance: values.add,
        ),
      ),
    );
    await tester.pumpWidget(screen(0));
    await tester.ensureVisible(find.text('+10'));
    await tester.tap(find.text('−10'));
    await tester.tap(find.text('+10'));
    await tester.pump();
    expect(values, [10]);
    await tester.pumpWidget(screen(500));
    await tester.ensureVisible(find.text('+10'));
    await tester.tap(find.text('+10'));
    await tester.tap(find.text('−10'));
    await tester.tap(find.text('归零'));
    await tester.pump();
    expect(values, [10, 490, 0]);
    final parsed = AppState.fromMap({'miPlayOutputAdvanceMs': 100});
    expect(parsed.copyWith(lastError: 'test').miPlayOutputAdvanceMs, 100);
  });

  testWidgets(
    'remote name editor cancellation preserves name and completion only edits draft',
    (tester) async {
      final initial = FocusNode();
      addTearDown(initial.dispose);
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? result;
      var opened = 0;
      final saved = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsView(
              state: const AppState(
                initialized: true,
                settings: AppSettings(receiverName: 'Original'),
              ),
              initialFocusNode: initial,
              onClose: () {},
              onReceiverName: saved.add,
              onStartup: (_) {},
              onAutoWake: (_) {},
              onAdvancedEffects: (_) {},
              onMiPlay: (_) {},
              onMiPlayIdentity: (_) {},
              onAirPlay: (_) {},
              onDlna: (_) {},
              onExportLogs: () async {},
              onEditReceiverName: (value, hint) async {
                opened++;
                return result;
              },
            ),
          ),
        ),
      );
      initial.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(opened, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Original',
      );
      expect(saved, isEmpty);
      result = 'New name';
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(opened, 2);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'New name',
      );
      expect(saved, isEmpty);
      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(saved, ['New name']);
    },
  );

  testWidgets(
    'native cast pause is separate from MiPlay and blocks duplicate operations',
    (tester) async {
      final initial = FocusNode();
      addTearDown(initial.dispose);
      tester.view.physicalSize = const Size(600, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final changes = <bool>[];
      var miPlayChanges = 0;
      Widget screen(bool busy) => MaterialApp(
        home: Scaffold(
          body: SettingsView(
            state: AppState(
              initialized: true,
              nativeCast: NativeCastState(supported: true, busy: busy),
            ),
            initialFocusNode: initial,
            onClose: () {},
            onReceiverName: (_) {},
            onStartup: (_) {},
            onAutoWake: (_) {},
            onAdvancedEffects: (_) {},
            onMiPlay: (_) {
              miPlayChanges++;
            },
            onMiPlayIdentity: (_) {},
            onAirPlay: (_) {},
            onDlna: (_) {},
            onExportLogs: () async {},
            onNativeCast: changes.add,
          ),
        ),
      );
      await tester.pumpWidget(screen(false));
      await tester.ensureVisible(find.text('暂停原生投屏'));
      await tester.tap(find.text('暂停原生投屏'));
      await tester.pump();
      expect(changes, [true]);
      expect(miPlayChanges, 0);
      await tester.ensureVisible(find.text('恢复原生投屏'));
      await tester.tap(find.text('恢复原生投屏'));
      await tester.pump();
      expect(changes, [true, false]);
      await tester.pumpWidget(screen(true));
      await tester.ensureVisible(find.text('暂停原生投屏'));
      await tester.tap(find.text('暂停原生投屏'));
      await tester.ensureVisible(find.text('恢复原生投屏'));
      await tester.tap(find.text('恢复原生投屏'));
      await tester.pump();
      expect(changes, [true, false]);
    },
  );

  testWidgets('menu toggles settings and remote back closes it', (
    tester,
  ) async {
    final controller = NativeAppController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: FusionPlayHome(
          controller: controller,
          state: const AppState(initialized: true),
        ),
      ),
    );
    await tester.pump();

    AnimatedPositioned panel() =>
        tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned));

    expect(panel().right, lessThan(0));
    expect(panel().duration, Duration.zero);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(panel().right, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(panel().right, lessThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(panel().right, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(panel().right, lessThan(0));
  });

  testWidgets('up from protocol switches focuses the receiver name field', (
    tester,
  ) async {
    final initial = FocusNode(debugLabel: 'settings-miplay-test');
    addTearDown(initial.dispose);
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: SettingsView(
            state: const AppState(initialized: true),
            initialFocusNode: initial,
            onClose: () {},
            onReceiverName: (_) {},
            onStartup: (_) {},
            onAutoWake: (_) {},
            onAdvancedEffects: (_) {},
            onMiPlay: (_) {},
            onMiPlayIdentity: (_) {},
            onAirPlay: (_) {},
            onDlna: (_) {},
            onExportLogs: () async {},
          ),
        ),
      ),
    );
    initial.requestFocus();
    await tester.pump();
    expect(initial.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.focusNode?.hasPrimaryFocus, isTrue);
  });

  testWidgets('日志导出入口与关于应用位于同一卡片并可触发', (tester) async {
    var exportCount = 0;
    final initial = FocusNode(debugLabel: 'settings-export-test');
    addTearDown(initial.dispose);
    tester.view.physicalSize = const Size(480, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: SettingsView(
            state: const AppState(initialized: true),
            initialFocusNode: initial,
            onClose: () {},
            onReceiverName: (_) {},
            onStartup: (_) {},
            onAutoWake: (_) {},
            onAdvancedEffects: (_) {},
            onMiPlay: (_) {},
            onMiPlayIdentity: (_) {},
            onAirPlay: (_) {},
            onDlna: (_) {},
            onExportLogs: () async => exportCount++,
          ),
        ),
      ),
    );

    expect(find.text('关于应用'), findsOneWidget);
    expect(find.text('导出日志'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('export-logs')));
    await tester.tap(find.byKey(const ValueKey('export-logs')));
    await tester.pump();

    expect(exportCount, 1);
  });

  testWidgets('select does not open settings while player control has focus', (
    tester,
  ) async {
    final controller = NativeAppController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: FusionPlayHome(
          controller: controller,
          state: const AppState(
            initialized: true,
            playback: PlaybackSnapshot(
              title: 'Track',
              protocol: 'AirPlay',
              durationMs: 180000,
              streamActive: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final playPause = FocusManager.instance.rootScope.descendants.singleWhere(
      (node) => node.debugLabel == 'player-play-pause',
    );
    playPause.requestFocus();
    await tester.pump();
    expect(playPause.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    final panel = tester.widget<AnimatedPositioned>(
      find.byType(AnimatedPositioned),
    );
    expect(panel.right, lessThan(0));
  });

  testWidgets('player focus follows settings progress and play pause space', (
    tester,
  ) async {
    final controller = NativeAppController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: FusionPlayHome(
          controller: controller,
          state: const AppState(
            initialized: true,
            playback: PlaybackSnapshot(
              title: 'Track',
              protocol: 'AirPlay',
              durationMs: 180000,
              streamActive: true,
            ),
            remoteControl: RemoteControlState(
              available: true,
              commands: {'play_pause', 'seek'},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final nodes = FocusManager.instance.rootScope.descendants;
    final progress = nodes.singleWhere(
      (node) => node.debugLabel == 'player-progress',
    );
    final playPause = nodes.singleWhere(
      (node) => node.debugLabel == 'player-play-pause',
    );
    final settings = nodes.singleWhere(
      (node) => node.debugLabel == 'settings-button',
    );

    progress.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(playPause.hasPrimaryFocus, isTrue);

    progress.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(settings.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(progress.hasPrimaryFocus, isTrue);

    final settingsRect = tester.getRect(find.byTooltip('设置'));
    expect(settingsRect.top, 14);
    expect(1200 - settingsRect.right, 14);
  });
}
