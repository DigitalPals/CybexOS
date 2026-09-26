"""Welcome's setup probes must not outlive the window or run on early exits."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
loader = importlib.machinery.SourceFileLoader('welcome_setup', str(Path(__file__).parent / 'rootfs/usr/bin/cybexos-welcome'))
spec = importlib.util.spec_from_loader(loader.name, loader)
welcome = importlib.util.module_from_spec(spec)
loader.exec_module(welcome)


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


if __name__ == '__main__':
    unittest.main()
