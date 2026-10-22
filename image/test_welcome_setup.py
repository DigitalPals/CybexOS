"""Welcome's setup probes must not outlive the window or run on early exits."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from PySide6.QtCore import QPointF, Qt
from PySide6.QtGui import QFont
from PySide6.QtQuick import QQuickItem
from PySide6.QtTest import QTest

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
loader = importlib.machinery.SourceFileLoader('welcome_setup', str(Path(__file__).parent / 'rootfs/usr/bin/cybexos-welcome'))
spec = importlib.util.spec_from_loader(loader.name, loader)
welcome = importlib.util.module_from_spec(spec)
loader.exec_module(welcome)


class LayoutWelcome(welcome.Welcome):
    def __init__(self, width, height):
        super().__init__()
        self.area = {"width": width, "height": height}
        self.live = False
        self._source = "unavailable"
        self._note = "Wallpaper service is unavailable. " * 6
        self._network_state = "offline"
        self._hardware_state = "failed"
        self._nvidia_state = "enroll"
        self._seed_state = "error"
        self._reconcile_state = "blocked"
        self.message = "Setup needs attention. " * 20

    @welcome.Slot(str, result="QVariantMap")
    def availableWorkArea(self, _name):
        return self.area

    @welcome.Slot()
    def loadWallpapers(self):
        pass

    @welcome.Slot()
    def refreshWallpapers(self):
        pass

    @welcome.Slot()
    def install(self):
        pass


class SetupLifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = welcome.QGuiApplication.instance() or welcome.QGuiApplication([])

    def test_constructor_performs_no_probes_before_autostart_or_singleton_checks(self):
        with patch.object(welcome.QProcess, 'start') as start:
            backend = welcome.Welcome()
            self.assertFalse(backend.setup_timer.isActive())
            self.assertFalse(backend.setup_timeout.isActive())
            start.assert_not_called()
        self.assertEqual(backend.network_process.processEnvironment().value('LC_ALL'), 'C')

    def test_missing_helper_has_error_state_without_reading_deleted_qprocess(self):
        backend = welcome.Welcome()
        backend.networkFailed(welcome.QProcess.FailedToStart)
        backend.reconcileFailed(welcome.QProcess.FailedToStart)
        self.assertEqual(backend.networkState, 'offline')
        self.assertEqual(backend.reconcileState, 'error')

    def test_live_session_cannot_launch_installed_repair_actions(self):
        backend = welcome.Welcome()
        backend.live = True
        with patch.object(welcome.QProcess, 'startDetached') as start:
            backend.retryApps()
            backend.retryHardware()
            backend.startSetup()
            start.assert_not_called()
            self.assertFalse(backend.setup_timer.isActive())

    def test_probe_timeout_is_bounded_and_shutdown_stops_timers(self):
        backend = welcome.Welcome()
        with patch.object(welcome.QProcess, 'state', return_value=welcome.QProcess.Running), \
             patch.object(welcome.QProcess, 'kill') as kill:
            backend.setupTimedOut()
            self.assertEqual(kill.call_count, 2)
        backend.setup_timer.start()
        backend.setup_timeout.start()
        backend.stopSetup()
        self.assertFalse(backend.setup_timer.isActive())
        self.assertFalse(backend.setup_timeout.isActive())


    def test_work_area_uses_the_requested_screen_not_the_virtual_desktop(self):
        first = Mock()
        first.name.return_value = "first"
        first.availableGeometry.return_value.width.return_value = 1920
        first.availableGeometry.return_value.height.return_value = 1040
        scaled = Mock()
        scaled.name.return_value = "scaled"
        scaled.availableGeometry.return_value.width.return_value = 640
        scaled.availableGeometry.return_value.height.return_value = 450
        backend = welcome.Welcome()
        with patch.object(welcome.QGuiApplication, 'screens', return_value=[first, scaled]), \
                patch.object(welcome.QGuiApplication, 'primaryScreen', return_value=first):
            self.assertEqual(backend.availableWorkArea('scaled'), {"width": 640, "height": 450})
            self.assertEqual(backend.availableWorkArea('gone'), {"width": 1920, "height": 1040})

    def test_small_logical_screens_wrap_scroll_reveal_focus_and_keep_escape(self):
        # Construct the actual window in Qt. Expanded error/enrollment copy and
        # larger inherited text exercise geometry, rather than source strings.
        for width, height, text_size, live, install_mode in (
                (640, 480, 16, False, False), (800, 450, 24, False, False),
                (480, 360, 24, True, True), (1280, 900, 16, False, False)):
            with self.subTest(width=width, height=height, text_size=text_size, live=live):
                backend = LayoutWelcome(width, height)
                backend.live = live
                backend.install_mode = install_mode
                engine = welcome.QQmlApplicationEngine()
                warnings = []
                engine.warnings.connect(lambda found: warnings.extend(w.toString() for w in found))
                engine.rootContext().setContextProperty('welcome', backend)
                engine.load(welcome.QUrl.fromLocalFile(str(welcome.QML)))
                self.assertTrue(engine.rootObjects(), warnings)
                window = engine.rootObjects()[0]
                font = QFont(window.property('font'))
                font.setPixelSize(text_size)
                window.setProperty('font', font)
                QTest.qWait(80)
                self.assertLessEqual(window.width(), width)
                self.assertLessEqual(window.height(), height)
                viewport = window.findChild(QQuickItem, 'welcomeViewport')
                primary = window.findChild(QQuickItem, 'welcomePrimaryAction')
                self.assertIsNotNone(viewport)
                self.assertIsNotNone(primary)
                if height < 500:
                    self.assertGreater(viewport.property('contentHeight'), viewport.height())
                viewport.setProperty('contentY', 0)
                primary.forceActiveFocus()
                QTest.qWait(40)
                point = primary.mapToItem(viewport, QPointF(0, 0))
                self.assertGreaterEqual(point.y(), 0)
                self.assertLessEqual(point.y() + primary.height(), viewport.height() + 1)
                self.assertGreaterEqual(point.x(), 0)
                self.assertLessEqual(point.x() + primary.width(), viewport.width() + 1)
                self.assertEqual(warnings, [])
                with patch.object(backend, 'markComplete') as complete:
                    QTest.keyClick(window, Qt.Key_Escape)
                    QTest.qWait(20)
                    if install_mode:
                        self.assertTrue(window.isVisible())
                        complete.assert_not_called()
                    else:
                        self.assertFalse(window.isVisible())
                        complete.assert_called_once_with()
                window.hide()
                backend.stopSetup()
                del primary, viewport, window, engine, backend


if __name__ == '__main__':
    unittest.main()
