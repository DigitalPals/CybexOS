"""The password policy shared by fresh installation and credential changes."""
from .common import Failure

MIN_PASSWORD_LENGTH = 8


def validate_password(value):
    # Do not strip, normalize, truncate or require particular character classes.
    # Newlines cannot be represented safely by shadow's password-change input.
    if not isinstance(value, str) or len(value) < MIN_PASSWORD_LENGTH:
        raise Failure('Use at least 8 characters')
    try:
        size = len(value.encode('utf-8'))
    except UnicodeError:
        raise Failure('The password contains unsupported characters') from None
    if size > 4096 or any(c in value for c in ('\x00', '\n', '\r')):
        raise Failure('The password contains unsupported characters or is too long')
    return value
