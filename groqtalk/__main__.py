"""Entry point: python -m groqtalk."""
from __future__ import annotations

import signal

from .config import log
from .app import GroqTalkApp


def main() -> None:
    """Launch GroqTalk with signal handling."""
    def _on_signal(signum: int, frame: object) -> None:
        log.warning(
            "[EXIT] received signal %d (%s)", signum, signal.Signals(signum).name,
        )

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGHUP, _on_signal)

    log.info("[MAIN] starting GroqTalkApp.run()")
    try:
        app = GroqTalkApp()
        app.run()
    except Exception:
        log.exception("[MAIN] app crashed")
    finally:
        log.warning("[MAIN] app exited")


if __name__ == "__main__":
    main()
