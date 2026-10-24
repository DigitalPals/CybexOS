#!/usr/bin/env python3
"""Native password dialog; credentials reach the authorized worker over stdin."""
import json
import os
import sys
from PySide6.QtCore import QProcess
from PySide6.QtWidgets import QApplication, QCheckBox, QDialog, QLabel, QLineEdit, QPushButton, QVBoxLayout

app = QApplication(sys.argv)
app.setApplicationName('Cybex OS Password')
class PasswordDialog(QDialog):
    def closeEvent(self, event):
        if process.state() != QProcess.NotRunning:
            event.ignore()
            return
        super().closeEvent(event)

    def reject(self):
        if process.state() == QProcess.NotRunning:
            super().reject()


dialog = PasswordDialog()
dialog.setWindowTitle('Change your Cybex OS password')
dialog.setMinimumWidth(440)
dialog.setStyleSheet('QDialog{background:#1a1b1e;color:#f3f2ec} QLabel,QCheckBox{color:#f3f2ec} QLineEdit{background:#242528;color:#f3f2ec;border:1px solid #525358;border-radius:7px;padding:12px} QPushButton{background:#60a5fa;color:#1a1b1e;border:0;border-radius:7px;padding:12px;font-weight:bold}')
layout = QVBoxLayout(dialog)
layout.setContentsMargins(28, 28, 28, 28)
layout.setSpacing(16)
title = QLabel('One password. Your desktop and disk.')
title.setWordWrap(True)
layout.addWidget(title)
current = QLineEdit()
current.setPlaceholderText('Current password')
current.setEchoMode(QLineEdit.Password)
current.setMaxLength(1024)
layout.addWidget(current)
new = QLineEdit()
new.setPlaceholderText('New password · at least 8 characters')
new.setEchoMode(QLineEdit.Password)
new.setMaxLength(1024)
layout.addWidget(new)
show = QCheckBox('Show passwords')
show.toggled.connect(lambda checked: [field.setEchoMode(QLineEdit.Normal if checked else QLineEdit.Password) for field in (current, new)])
layout.addWidget(show)
status = QLabel('Updates your login and the encrypted root disk together. Approve the system authorization prompt when asked.')
status.setWordWrap(True)
layout.addWidget(status)
button = QPushButton('Change password')
layout.addWidget(button)
process = QProcess(dialog)


def submit():
    if len(new.text()) < 8:
        status.setText('Use at least 8 characters.')
        return
    if not current.text():
        status.setText('Enter your current password.')
        return
    button.setEnabled(False)
    current.setEnabled(False)
    new.setEnabled(False)
    status.setText('Approve the system authorization prompt. Keep this window open until the password change finishes.')
    payload = json.dumps({'current': current.text(), 'new': new.text()}).encode()
    process.start('pkexec', [os.environ['CYBEXOS_PASSWORD_WORKER']])
    process.write(payload)
    process.closeWriteChannel()
    current.clear()
    new.clear()


def finished(_code, _status):
    try:
        result = json.loads(bytes(process.readAllStandardOutput()))
        status.setText(result.get('message') or result.get('error') or 'The password change did not complete.')
    except (ValueError, UnicodeError):
        status.setText('Authorization was cancelled or the password service could not start. No completed password change was reported.')
    process.readAllStandardError()
    button.setEnabled(True)
    current.setEnabled(True)
    new.setEnabled(True)


process.finished.connect(finished)
process.errorOccurred.connect(lambda _error: finished(127, QProcess.CrashExit))
button.clicked.connect(submit)
new.returnPressed.connect(submit)
dialog.show()
sys.exit(app.exec())
