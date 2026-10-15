"""The new-owner setup window, offscreen: pages, rules, language and answers.

The window is driven as a person would with a keyboard (fields, Continue,
Back) while a list stands in for the root service's pipe. Every message it
sends must pass the root service's own parser.
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import unittest

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
os.environ.setdefault('QT_QUICK_BACKEND', 'software')
LIBEXEC = Path(__file__).parent / 'rootfs/usr/libexec'


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


gui = load('cybexos_new_owner_gui', LIBEXEC / 'cybexos-new-owner-gui')
owner = load('cybexos_new_owner_for_window', LIBEXEC / 'cybexos-new-owner')
from PySide6.QtCore import Q_ARG, QEvent, QMetaObject, QObject, Qt  # noqa: E402
from PySide6.QtGui import QKeyEvent  # noqa: E402

PASSWORD = 'new owner password'


def init(encrypted=True, **changes):
    message = {'type': 'init', 'version': 1, 'encrypted': encrypted, 'keyboard': 'us', 'locale': 'en_US.UTF-8',
               'timezone': 'Europe/Amsterdam', 'focus': '',
               'keyboards': [{'id': 'us', 'label': 'English (US)'}, {'id': 'nl', 'label': 'Dutch'},
                             {'id': 'us (dvorak)', 'label': 'English (Dvorak)'}],
               'locales': ['en_US.UTF-8', 'nl_NL.UTF-8', 'de_DE.UTF-8'],
               'timezones': ['America/New_York', 'Europe/Amsterdam', 'UTC'], 'taken': ['root', 'taken']}
    message.update(changes)
    return message


class Window(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = gui.QGuiApplication.instance() or gui.QGuiApplication([])
        gui.QQuickStyle.setStyle('Basic')

    def open(self, **changes):
        self.sent = []
        self.setup = gui.Setup(init(**changes), self.sent.append)
        self.engine = gui.QQmlApplicationEngine()
        self.warnings = []
        self.engine.warnings.connect(lambda found: self.warnings.extend(item.toString() for item in found))
        self.engine.rootContext().setContextProperty('setup', self.setup)
        self.engine.load(gui.QUrl.fromLocalFile(str(gui.QML)))
        self.assertTrue(self.engine.rootObjects(), 'the window failed to load')
        self.window = self.engine.rootObjects()[0]
        self.addCleanup(self.close)
        self.settle()
        return self.window

    def close(self):
        if getattr(self, 'window', None) is None:
            return
        self.window.close()
        self.settle()
        self.window = self.engine = None

    def settle(self):
        for _ in range(3):
            self.app.processEvents()

    def find(self, name):
        item = self.window.findChild(QObject, name)
        self.assertIsNotNone(item, name)
        return item

    def call(self, function):
        QMetaObject.invokeMethod(self.window, function)
        self.settle()

    def type_into(self, name, text):
        self.find(name).setProperty('text', text)
        self.settle()

    def text(self, name):
        return self.find(name).property('text')

    def fill_account(self, username='alice', password=PASSWORD, confirm=PASSWORD, startup='temporary handover 1'):
        self.type_into('fullName', 'Alice Example')
        if username is not None:
            self.type_into('username', username)
        self.type_into('password', password)
        self.type_into('confirm', confirm)
        if self.setup.encrypted:
            self.type_into('startup', startup)


class PageTests(Window):
    def test_window_loads_cleanly_and_asks_for_the_disk_passphrase_only_when_encrypted(self):
        for encrypted in (True, False):
            self.open(encrypted=encrypted)
            self.assertEqual(self.warnings, [], f'QML warnings with encrypted={encrypted}')
            self.assertEqual(self.window.property('page'), 0)
            self.call('next')
            self.assertEqual(self.window.property('page'), 1)
            self.assertEqual(self.find('startup').property('visible'), encrypted)
            self.assertEqual(self.setup.stages, ['account', 'desktop', 'disk', 'finish'] if encrypted
                             else ['account', 'desktop', 'finish'])
            self.close()

    def test_the_language_switches_the_windows_own_text_live(self):
        self.open()
        self.assertEqual(self.text('heading'), 'Welcome.')
        self.assertEqual(self.text('primaryButton'), 'Continue')
        QMetaObject.invokeMethod(self.find('languageList'), 'chosen', Q_ARG(str, 'nl_NL.UTF-8'))
        self.settle()
        self.assertEqual((self.setup.locale, self.setup.language), ('nl_NL.UTF-8', 'nl'))
        self.assertEqual(self.text('heading'), 'Welkom.')
        self.assertEqual(self.text('primaryButton'), 'Doorgaan')
        self.assertEqual(self.window.property('title'), 'CybexOS instellen')
        self.setup.locale = 'de_DE.UTF-8'
        self.settle()
        self.assertEqual(self.text('heading'), 'Welcome.', 'other languages read English')
        self.setup.locale = 'xx_XX.UTF-8'
        self.assertEqual(self.setup.locale, 'de_DE.UTF-8', 'only listed locales are accepted')

    def test_every_line_of_copy_has_a_dutch_translation(self):
        self.open()
        dutch = self.window.property('dutch').toVariant()
        source = gui.QML.read_text()
        start = source.index('readonly property var dutch')
        source = source[:start] + source[source.index('})', start):]
        copy = {literal for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', source)
                if re.match(r'[A-Z] ?[a-z]', literal) and literal not in ('Figtree', 'Cybex', 'Input')}
        self.assertGreater(len(copy), 40)
        self.assertEqual(sorted(copy - set(dutch)), [], 'copy without a Dutch translation')
        self.assertEqual(sorted(set(dutch) - copy), [], 'translations nothing uses')
        problems = self.window.property('problems').toVariant()
        self.assertTrue(set(owner.PROBLEMS).issubset(problems), 'every code the service sends has text')

    def test_after_a_layout_restart_the_test_field_has_focus(self):
        self.open(focus='keyboard-test')
        self.assertTrue(self.find('keyboardTest').property('focus'))


class AccountTests(Window):
    def test_account_rules_match_the_service_and_the_username_follows_the_name(self):
        self.open()
        self.call('next')
        self.type_into('fullName', 'Jörg Smit')
        self.assertEqual(self.text('username'), 'jorg')
        # Continue shows every problem and stays on the page.
        self.type_into('password', 'short')
        self.call('next')
        self.assertEqual(self.window.property('page'), 1)
        self.assertEqual(self.find('password').property('problem'), 'Use a password of 12–512 characters.')
        self.assertEqual(self.find('startup').property('problem'), 'Type the passphrase you used at startup.')
        self.type_into('password', PASSWORD)
        self.type_into('confirm', PASSWORD + 'x')
        self.assertEqual(self.find('password').property('problem'), '')
        self.assertEqual(self.find('confirm').property('problem'), 'The passwords do not match.')
        for name, problem in (('taken', 'That name is already in use.'), ('sddm', 'That name is reserved for the system.'),
                              ('Alice', 'Use lowercase letters, numbers, dashes or underscores, starting with a letter.'),
                              ('', 'Choose a username.')):
            self.type_into('username', name)
            self.assertEqual(self.find('username').property('problem'), problem, name)
        self.type_into('fullName', 'Alice: Example')
        self.assertEqual(self.find('fullName').property('problem'), 'Use at most 128 characters, without colons.')
        self.fill_account()
        self.call('next')
        self.assertEqual(self.window.property('page'), 2)
        self.call('back')
        self.assertEqual(self.window.property('page'), 1)

    def test_an_edited_username_is_kept(self):
        self.open(encrypted=False)
        self.call('next')
        username = self.find('username')
        username.setProperty('text', 'ali')
        QMetaObject.invokeMethod(username, 'edited')
        self.settle()
        self.assertTrue(self.window.property('usernameEdited'))
        self.type_into('fullName', 'Bob Example')
        self.assertEqual(self.text('username'), 'ali')


class AnswerTests(Window):
    def reach_timezone(self, **account):
        self.call('next')
        self.fill_account(**account)
        self.call('next')
        self.assertEqual(self.window.property('page'), 2)

    def test_the_answers_are_exactly_what_the_service_accepts(self):
        self.open()
        self.reach_timezone()
        QMetaObject.invokeMethod(self.find('timezoneList'), 'chosen', Q_ARG(str, 'America/New_York'))
        self.settle()
        self.assertEqual(self.text('primaryButton'), 'Set up')
        self.call('next')
        self.assertEqual(self.window.property('page'), 3)
        self.assertEqual(self.setup.state, 'working')
        submitted = self.sent[-1]
        self.assertEqual(owner.parse_message(json.dumps(submitted).encode()), submitted)
        self.assertEqual(submitted, {'type': 'submit', 'locale': 'en_US.UTF-8', 'timezone': 'America/New_York',
                                     'full_name': 'Alice Example', 'username': 'alice', 'password': PASSWORD,
                                     'confirm': PASSWORD, 'startup': 'temporary handover 1'})
        # A plain disk never sends a passphrase.
        self.close()
        self.open(encrypted=False)
        self.reach_timezone()
        self.call('next')
        self.assertEqual(self.sent[-1]['startup'], '')
        self.assertEqual(owner.parse_message(json.dumps(self.sent[-1]).encode())['timezone'], 'Europe/Amsterdam')

    def test_service_answers_lead_the_finishing_page(self):
        self.open()
        self.reach_timezone()
        self.call('next')
        self.setup.receive({'type': 'progress', 'stage': 'desktop'})
        self.settle()
        self.assertEqual((self.setup.state, self.setup.stage), ('working', 'desktop'))
        self.assertFalse(self.find('primaryButton').property('visible'), 'nothing to press while working')
        # A wrong passphrase: back to the account page, said at the field.
        self.setup.receive({'type': 'error', 'field': 'startup', 'code': 'startup-wrong'})
        self.settle()
        self.assertEqual(self.window.property('page'), 1)
        self.assertEqual(self.find('startup').property('problem'), 'That passphrase does not unlock this disk.')
        self.assertTrue(self.find('startupInput').property('focus'))
        self.call('next')
        self.call('next')
        self.setup.receive({'type': 'error', 'field': '', 'code': 'failed', 'detail': 'Key slot 2 could not be removed.'})
        self.settle()
        self.assertEqual(self.text('heading'), 'Setup did not finish.')
        self.assertIn('Key slot 2 could not be removed.', self.text('failure'))
        self.assertEqual(self.text('primaryButton'), 'Try again')
        submissions = len([item for item in self.sent if item['type'] == 'submit'])
        self.call('next')
        self.assertEqual(len([item for item in self.sent if item['type'] == 'submit']), submissions + 1)
        self.setup.receive({'type': 'done'})
        self.settle()
        self.assertEqual(self.text('heading'), 'Ready.')
        self.assertEqual(self.text('primaryButton'), 'Restart now')
        self.call('next')
        self.assertEqual(self.sent[-1], {'type': 'restart'})

    def test_a_new_layout_waits_for_the_service_then_the_window_closes(self):
        self.open()
        closed = []
        self.setup.finished.connect(lambda: closed.append(True))
        QMetaObject.invokeMethod(self.find('keyboardList'), 'chosen', Q_ARG(str, 'us (dvorak)'))
        self.settle()
        self.assertEqual(owner.parse_message(json.dumps(self.sent[-1]).encode()),
                         {'type': 'keyboard', 'keyboard': 'us (dvorak)', 'locale': 'en_US.UTF-8'})
        self.assertEqual(self.setup.state, 'switching')
        self.assertFalse(self.find('primaryButton').property('enabled'))
        self.setup.chooseKeyboard('nl')
        self.assertEqual(len(self.sent), 1, 'one change at a time')
        self.setup.receive({'type': 'error', 'field': 'keyboard', 'code': 'boot-keymap'})
        self.settle()
        self.assertEqual(self.setup.state, 'idle')
        self.assertIn('unlock screen', self.text('keyboardProblem'))
        self.setup.chooseKeyboard('nl')
        self.setup.receive({'type': 'restart'})
        self.assertEqual(closed, [True])


class ChannelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = gui.QGuiApplication.instance() or gui.QGuiApplication([])

    def read(self, data, limit=gui.MAX_INIT):
        chunks = [data[index:index + 7] for index in range(0, len(data), 7)]
        return gui.read_init(0, limit, 1, lambda *args: (args[0], [], []),
                             lambda fd, size: chunks.pop(0) if chunks else b'')

    def test_only_a_complete_init_message_opens_the_window(self):
        line = json.dumps(init()).encode() + b'\n'
        message, rest = self.read(line + b'{"type": "progress"')
        # Whatever arrived with it is handed on to the channel.
        self.assertEqual(message['type'], 'init')
        self.assertTrue(rest and b'{"type": "progress"'.startswith(rest))
        for broken in (b'', b'not json\n', json.dumps({**init(), 'version': 2}).encode() + b'\n',
                       json.dumps({**init(), 'encrypted': 'yes'}).encode() + b'\n',
                       json.dumps({**init(), 'keyboards': ['us']}).encode() + b'\n', line[:-1]):
            self.assertIsNone(self.read(broken), broken[:30])
        self.assertIsNone(self.read(line, limit=16), 'oversized')
        self.assertIsNone(gui.read_init(0, timeout=0, wait=lambda *args: ([], [], [])), 'silence')

    def test_the_channel_delivers_whole_lines_and_ignores_garbage(self):
        reader, writer = os.pipe()
        out_reader, out_writer = os.pipe()
        try:
            channel = gui.Channel(reader, out_writer)
            received = []
            channel.on_message = received.append
            os.write(writer, b'{"type": "progress", "stage": "acc')
            channel.readable()
            os.write(writer, b'ount"}\nnot json\n[1]\n{"type": "done"}\n')
            channel.readable()
            self.assertEqual(received, [{'type': 'progress', 'stage': 'account'}, {'type': 'done'}])
            channel.send({'type': 'ready'})
            self.assertEqual(os.read(out_reader, 100), b'{"type":"ready"}\n')
            closed = []
            channel.on_closed = lambda: closed.append(True)
            os.close(writer)
            writer = None
            channel.readable()
            self.assertEqual(closed, [True])
        finally:
            for fd in (reader, out_reader, out_writer, writer):
                if fd is not None:
                    os.close(fd)

    def test_ready_and_the_first_key_press_are_reported_once(self):
        sent = []
        setup = gui.Setup(init(), sent.append)
        setup.noteReady()
        setup.noteReady()
        activity = gui.Activity(setup.noteActive)
        release = QKeyEvent(QEvent.Type.KeyRelease, Qt.Key.Key_A, Qt.KeyboardModifier.NoModifier, 'a')
        press = QKeyEvent(QEvent.Type.KeyPress, Qt.Key.Key_A, Qt.KeyboardModifier.NoModifier, 'a')
        for event in (release, press, press):
            self.assertFalse(activity.eventFilter(None, event))
        self.assertEqual(sent, [{'type': 'ready'}, {'type': 'active'}])

    def test_labels_name_languages_in_their_own_words(self):
        entries = {entry['id']: entry for entry in gui.locale_entries(
            ['en_US.UTF-8', 'nl_BE.UTF-8', 'nl_NL.UTF-8', 'sr_RS.UTF-8@latin', 'ca_ES.UTF-8@valencia'])}
        self.assertEqual(entries['en_US.UTF-8']['label'], 'English (United States)')
        self.assertEqual(entries['nl_BE.UTF-8']['label'], 'Nederlands (België)')
        self.assertEqual(entries['nl_NL.UTF-8']['detail'], 'Dutch (Netherlands)')
        self.assertEqual(entries['sr_RS.UTF-8@latin']['label'], 'Srpski (Srbija)')
        self.assertTrue(entries['ca_ES.UTF-8@valencia']['label'].endswith('· valencia'))
        self.assertIn('dutch', entries['nl_NL.UTF-8']['search'])
        zones = gui.timezone_entries(['America/Argentina/Buenos_Aires', 'UTC'])
        self.assertEqual(zones[0], {'id': 'America/Argentina/Buenos_Aires', 'label': 'Buenos Aires',
                                    'detail': 'America / Argentina',
                                    'search': 'america/argentina/buenos_aires buenos aires america / argentina'})
        self.assertEqual((zones[1]['label'], zones[1]['detail']), ('UTC', ''))


if __name__ == '__main__':
    unittest.main()
