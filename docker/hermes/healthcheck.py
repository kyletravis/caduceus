"""Require both the gateway API and the supervised dashboard to respond."""
import os
import sys
import urllib.error
import urllib.request


def main():
    checks = (
        ("Gateway API", "http://127.0.0.1:8642/v1/models",
         {"Authorization": f"Bearer {os.environ['API_SERVER_KEY']}"}),
        ("Dashboard", "http://127.0.0.1:9119/", {}),
    )
    for name, url, headers in checks:
        try:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=3):
                pass
        except (OSError, urllib.error.URLError) as error:
            print(f"{name} unavailable: {error}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
