"""Serve only the self-contained local showcase directory."""

from __future__ import annotations

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import webbrowser
from urllib.parse import unquote, urlsplit


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--page", choices=('viewer.html', 'angular_viewer.html'), default='viewer.html')
    parser.add_argument("--output", type=Path, help="Explicit preview cache directory")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    root = repo / 'user_app' / 'car_showcase'
    output = args.output or repo / 'sample' / 'car_showcase' / 'output'
    if not (output / "manifest.json").exists():
        parser.error("missing output/manifest.json; run python -m car_showcase.build first")
    class ShowcaseHandler(SimpleHTTPRequestHandler):
        def translate_path(self, path: str) -> str:
            path = unquote(urlsplit(path).path)
            if path.startswith('/output/'):
                base, relative = output, path[len('/output/'):]
            else:
                base, relative = root, path.lstrip('/') or 'viewer.html'
            target = (base / relative).resolve()
            if not target.is_relative_to(base.resolve()):
                return str(root / '__not_found__')
            return str(target)

        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(root), **kw)

        def guess_type(self, path: str) -> str:
            if path.endswith(".m3mesh"):
                return "application/x-mid360-mesh"
            return super().guess_type(path)

    server = ThreadingHTTPServer((args.host, args.port), ShowcaseHandler)
    url = f"http://{args.host}:{args.port}/{args.page}"
    print(url, flush=True)
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
