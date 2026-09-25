"""System theme target: hyprland. Placeholder until the target is implemented.

Contract (see theme-apply.py):
  NAME: the report key.
  render(tokens) -> {file name: content}, files in the theme state directory.
    Must be deterministic; at least one file once implemented.
  reload(tokens, directory): make the running application pick the files up.
    Raise with a short, user-readable message on failure.
"""
NAME = 'hyprland'


def render(tokens):
    return {}


def reload(tokens, directory):
    pass
