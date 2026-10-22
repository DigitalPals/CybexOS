#!/usr/bin/env python3
"""Read a bounded event window from Evolution Data Server as JSON.

GNOME Online Accounts owns authentication and Evolution Data Server owns the
calendar cache.  This process never asks for, stores, or prints credentials;
it only returns the presentation fields used by the Quickshell calendar.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
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
# How long each source may wait for its backend to report "connected" before
# its cache is read.  A local calendar never reports it, so this is the floor
# of every request.  0 does not mean "no wait": EDS then waits without any
# timeout, which was measured hanging.
CONNECT_WAIT_SECONDS = 1
# Sources are read side by side, so a request costs its slowest calendar
# rather than the sum of every connect wait.
MAX_PARALLEL_SOURCES = 16

_emit_lock = threading.Lock()
_emitted = False
# Set once the calendar sources are being read, so the deadline can answer
# with what has arrived instead of blanking every event.
_results: Results | None = None


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


class Results:
    """Calendars and events read so far.

    Source threads add results as they finish and the deadline thread may
    report them at any moment, so every access holds the lock.
    """

    def __init__(self, start: int, end: int, header: dict[str, Any]) -> None:
        self.lock = threading.Lock()
        self.range_start = start
        self.range_end = end
        self.header = header
        self.calendars: list[dict[str, Any]] = []
        self.events: list[dict[str, Any]] = []
        self.source_errors: list[dict[str, str]] = []
        self.pending: dict[str, str] = {}

    def add_calendar(self, calendar: dict[str, Any]) -> None:
        with self.lock:
            self.calendars.append(calendar)
            self.pending[calendar["uid"]] = calendar["name"]

    def finish(
        self,
        source_uid: str,
        source_name: str,
        events: list[dict[str, Any]],
        error: Any = None,
    ) -> None:
        with self.lock:
            self.pending.pop(source_uid, None)
            self.events.extend(events)
            if error is not None:
                self.source_errors.append(
                    {
                        "calendar": source_name,
                        "message": text(error, "calendar could not be read", 200),
                    }
                )

    def payload(self, timed_out: bool = False) -> dict[str, Any]:
        with self.lock:
            events = sorted(
                self.events,
                key=lambda event: (event["startMs"], event["endMs"], event["summary"]),
            )
            calendars = sorted(
                self.calendars, key=lambda calendar: calendar["name"].casefold()
            )
            source_errors = list(self.source_errors)
            if timed_out:
                # A calendar that did not answer in time is reported like any
                # other unreadable source; the ones that did answer still show.
                source_errors.extend(
                    {"calendar": name, "message": "Calendar request timed out"}
                    for name in self.pending.values()
                )
        return {
            "available": True,
            "error": "",
            **self.header,
            "calendars": calendars,
            "events": events,
            "sourceErrors": source_errors,
            "rangeStartMs": self.range_start * 1000,
            "rangeEndMs": self.range_end * 1000,
        }


def _deadline_expired() -> None:
    # The main thread may be parked inside a GI call that never returns to
    # the interpreter, so a signal handler would not run.  PyGObject releases
    # the GIL around those calls; this thread answers and ends the process.
    results = _results
    if results is None:
        unavailable("Calendar request timed out")
    else:
        emit(results.payload(timed_out=True))
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
    global _results
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

    results = Results(
        start,
        end,
        {
            "goaError": goa_error,
            "googleAccounts": google_accounts,
            "googleCalendarAccounts": google_calendar_accounts,
        },
    )

    def read_source(
        source: Any,
        source_uid: str,
        source_name: str,
        source_color: str,
        is_google: bool,
    ) -> None:
        events: list[dict[str, Any]] = []
        seen_events: set[tuple[str, int, int]] = set()
        first_error: Any = None

        def add_instance(
            component: Any,
            instance_start: Any,
            instance_end: Any,
            _user_data: Any,
            _cancellable: Any,
        ) -> bool:
            nonlocal first_error
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
                identity = (event_uid, start_ms, end_ms)
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
                if first_error is None:
                    first_error = error
            return True

        try:
            client = ECal.Client.connect_sync(
                source, ECal.ClientSourceType.EVENTS, CONNECT_WAIT_SECONDS, None
            )
            if client is None:
                raise RuntimeError("calendar backend did not return a client")
            client.set_default_timezone(system_timezone)
            # EDS expands RRULE/RDATE recurrence, exclusions and detached
            # exceptions before invoking the callback.  Doing this here avoids
            # the subtly incorrect hand-written recurrence loops calendar
            # widgets often grow.
            client.generate_instances_sync(start, end, None, add_instance, None)
        except Exception as error:
            if first_error is None:
                first_error = error
        results.finish(source_uid, source_name, events, first_error)

    jobs: list[tuple[Any, str, str, str, bool]] = []
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
        results.add_calendar(
            {
                "uid": source_uid,
                "name": source_name,
                "color": source_color,
                "isGoogle": is_google,
            }
        )
        jobs.append((source, source_uid, source_name, source_color, is_google))

    # Each connect waits up to CONNECT_WAIT_SECONDS on its own backend, so
    # one slow or offline calendar no longer delays the others.  A source
    # still running at the deadline is reported as timed out by
    # _deadline_expired, together with every calendar that did answer.
    _results = results
    if jobs:
        with ThreadPoolExecutor(
            max_workers=min(MAX_PARALLEL_SOURCES, len(jobs)),
            thread_name_prefix="calendar-source",
        ) as pool:
            for job in jobs:
                pool.submit(read_source, *job)

    emit(results.payload())
    return 0


if __name__ == "__main__":
    deadline = arm_deadline(DEADLINE_SECONDS)
    status = main(sys.argv[1:])
    deadline.cancel()
    raise SystemExit(status)
