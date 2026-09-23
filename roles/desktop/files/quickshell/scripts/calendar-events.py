#!/usr/bin/env python3
"""Read a bounded event window from Evolution Data Server as JSON.

GNOME Online Accounts owns authentication and Evolution Data Server owns the
calendar cache.  This process never asks for, stores, or prints credentials;
it only returns the presentation fields used by the Quickshell calendar.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
from typing import Any


MAX_RANGE_SECONDS = 370 * 24 * 60 * 60
DEFAULT_COLOR = "#62a0ea"
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$")
# The whole request, not each call: SourceRegistry/Goa new_sync can block for
# tens of seconds when their D-Bus services are slow to activate, and every
# calendar source adds its own connect timeout.  The shell's poll must always
# receive an answer, so past this point the process reports "timed out".
DEADLINE_SECONDS = 15.0

_emit_lock = threading.Lock()
_emitted = False


def emit(payload: dict[str, Any]) -> None:
    global _emitted
    with _emit_lock:
        if _emitted:
            return
        _emitted = True
        json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
        sys.stdout.flush()


def unavailable(message: str) -> int:
    emit(
        {
            "available": False,
            "error": message,
            "googleAccounts": 0,
            "googleCalendarAccounts": 0,
            "calendars": [],
            "events": [],
            "sourceErrors": [],
        }
    )
    return 0


def _deadline_expired() -> None:
    # The main thread may be parked inside a GI call that never returns to
    # the interpreter, so a signal handler would not run.  PyGObject releases
    # the GIL around those calls; this thread answers and ends the process.
    unavailable("Calendar request timed out")
    os._exit(0)


def arm_deadline(seconds: float) -> threading.Timer:
    timer = threading.Timer(seconds, _deadline_expired)
    timer.daemon = True
    timer.start()
    return timer


def parse_range(arguments: list[str]) -> tuple[int, int]:
    if len(arguments) != 2:
        raise ValueError("expected a start and end Unix timestamp")
    start, end = (int(value) for value in arguments)
    if start < 0 or end <= start:
        raise ValueError("the event window is not valid")
    if end - start > MAX_RANGE_SECONDS:
        raise ValueError("the event window is larger than 370 days")
    return start, end


def text(value: Any, fallback: str = "", limit: int = 500) -> str:
    cleaned = str(value or fallback).replace("\x00", "").strip()
    return cleaned[:limit]


def main(arguments: list[str]) -> int:
    try:
        start, end = parse_range(arguments)
    except (TypeError, ValueError) as error:
        return unavailable(f"calendar-events.py: {error}")

    try:
        import gi

        gi.require_version("EDataServer", "1.2")
        gi.require_version("ECal", "2.0")
        gi.require_version("ICalGLib", "3.0")
        gi.require_version("Goa", "1.0")
        from gi.repository import ECal, EDataServer, Goa, ICalGLib
    except (ImportError, ValueError) as error:
        return unavailable(
            "GNOME calendar support is not installed "
            f"({text(error, 'missing Python GI bindings', 160)})"
        )

    google_accounts = 0
    google_calendar_accounts = 0
    google_account_ids: set[str] = set()
    goa_error = ""
    try:
        goa_client = Goa.Client.new_sync(None)
        for account_object in goa_client.get_accounts():
            account = account_object.get_account()
            if text(account.get_provider_type()).lower() != "google":
                continue
            google_accounts += 1
            google_account_ids.add(text(account.get_id()))
            if not account.get_calendar_disabled():
                google_calendar_accounts += 1
    except Exception as error:  # GOA status must not hide otherwise usable EDS data.
        goa_error = text(error, "GNOME Online Accounts could not be read", 200)

    try:
        registry = EDataServer.SourceRegistry.new_sync(None)
        system_timezone = ECal.util_get_system_timezone()
        if system_timezone is None:
            system_timezone = ICalGLib.Timezone.get_utc_timezone()
    except Exception as error:
        return unavailable(
            "Evolution Data Server could not be opened "
            f"({text(error, 'source registry unavailable', 160)})"
        )

    def source_is_google(source: Any, calendar_extension: Any) -> bool:
        backend = text(calendar_extension.get_backend_name()).lower()
        if backend == "google":
            return True

        current = source
        visited: set[str] = set()
        while current is not None:
            uid = text(current.get_uid())
            if uid in visited:
                break
            visited.add(uid)

            if current.has_extension(EDataServer.SOURCE_EXTENSION_GOA):
                goa = current.get_extension(EDataServer.SOURCE_EXTENSION_GOA)
                account_id = text(goa.get_account_id())
                if account_id in google_account_ids:
                    return True
            if current.has_extension(EDataServer.SOURCE_EXTENSION_COLLECTION):
                collection = current.get_extension(
                    EDataServer.SOURCE_EXTENSION_COLLECTION
                )
                if text(collection.get_backend_name()).lower() == "google":
                    return True

            parent_uid = text(current.get_parent())
            current = registry.ref_source(parent_uid) if parent_uid else None
        return False

    def timestamp_ms(value: Any) -> int | None:
        if value is None or value.is_null_time():
            return None
        # libical's `as_timet_with_zone()` interprets floating values in the
        # supplied zone.  Values carrying a TZID (including UTC) must use their
        # own zone instead, otherwise 10:00Z becomes 10:00 local time.
        zone = value.get_timezone() or system_timezone
        return int(value.as_timet_with_zone(zone)) * 1000

    events: list[dict[str, Any]] = []
    calendars: list[dict[str, Any]] = []
    source_errors: list[dict[str, str]] = []
    failed_sources: set[str] = set()
    seen_events: set[tuple[str, str, int, int]] = set()

    def record_source_error(source_uid: str, source_name: str, error: Any) -> None:
        if source_uid in failed_sources:
            return
        failed_sources.add(source_uid)
        source_errors.append(
            {
                "calendar": source_name,
                "message": text(error, "calendar could not be read", 200),
            }
        )

    sources = registry.list_sources(EDataServer.SOURCE_EXTENSION_CALENDAR)
    for source in sources:
        if not source.get_enabled():
            continue
        extension = source.get_extension(EDataServer.SOURCE_EXTENSION_CALENDAR)
        # This is the same visibility flag GNOME Calendar and Evolution use.
        if not extension.get_selected():
            continue

        source_uid = text(source.get_uid())
        source_name = text(source.get_display_name(), "Calendar", 160)
        source_color = text(extension.get_color(), DEFAULT_COLOR, 16)
        if not COLOR_RE.fullmatch(source_color):
            source_color = DEFAULT_COLOR
        is_google = source_is_google(source, extension)
        calendars.append(
            {
                "uid": source_uid,
                "name": source_name,
                "color": source_color,
                "isGoogle": is_google,
            }
        )

        try:
            client = ECal.Client.connect_sync(
                source, ECal.ClientSourceType.EVENTS, 3, None
            )
            if client is None:
                raise RuntimeError("calendar backend did not return a client")
            client.set_default_timezone(system_timezone)

            def add_instance(
                component: Any,
                instance_start: Any,
                instance_end: Any,
                _user_data: Any,
                _cancellable: Any,
            ) -> bool:
                try:
                    status = component.get_status()
                    if status in (
                        ICalGLib.PropertyStatus.CANCELLED,
                        ICalGLib.PropertyStatus.DELETED,
                    ):
                        return True

                    start_ms = timestamp_ms(instance_start)
                    end_ms = timestamp_ms(instance_end)
                    if start_ms is None:
                        return True
                    all_day = bool(instance_start.is_date())
                    if end_ms is None or end_ms <= start_ms:
                        end_ms = start_ms + (86_400_000 if all_day else 3_600_000)

                    event_uid = text(component.get_uid(), "", 300)
                    identity = (source_uid, event_uid, start_ms, end_ms)
                    if identity in seen_events:
                        return True
                    seen_events.add(identity)
                    events.append(
                        {
                            "id": f"{source_uid}:{event_uid}:{start_ms}",
                            "uid": event_uid,
                            "calendarUid": source_uid,
                            "calendar": source_name,
                            "color": source_color,
                            "isGoogle": is_google,
                            "summary": text(
                                component.get_summary(), "(Untitled event)", 500
                            ),
                            "location": text(component.get_location(), "", 500),
                            "startMs": start_ms,
                            "endMs": end_ms,
                            "allDay": all_day,
                        }
                    )
                except Exception as error:
                    record_source_error(source_uid, source_name, error)
                return True

            # EDS expands RRULE/RDATE recurrence, exclusions and detached
            # exceptions before invoking the callback.  Doing this here avoids
            # the subtly incorrect hand-written recurrence loops calendar
            # widgets often grow.
            client.generate_instances_sync(start, end, None, add_instance, None)
        except Exception as error:
            record_source_error(source_uid, source_name, error)

    events.sort(key=lambda event: (event["startMs"], event["endMs"], event["summary"]))
    calendars.sort(key=lambda calendar: calendar["name"].casefold())
    emit(
        {
            "available": True,
            "error": "",
            "goaError": goa_error,
            "googleAccounts": google_accounts,
            "googleCalendarAccounts": google_calendar_accounts,
            "calendars": calendars,
            "events": events,
            "sourceErrors": source_errors,
            "rangeStartMs": start * 1000,
            "rangeEndMs": end * 1000,
        }
    )
    return 0


if __name__ == "__main__":
    deadline = arm_deadline(DEADLINE_SECONDS)
    status = main(sys.argv[1:])
    deadline.cancel()
    raise SystemExit(status)
