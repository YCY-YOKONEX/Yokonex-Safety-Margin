#!/usr/bin/env python3
from __future__ import annotations

import datetime
import pathlib
import shutil
import sys


def server_blocks(text: str):
    cursor = 0
    while True:
        start = text.find("server", cursor)
        if start < 0:
            return
        brace = text.find("{", start)
        if brace < 0:
            return
        if text[start:brace].strip() != "server":
            cursor = brace + 1
            continue
        depth = 0
        for index in range(brace, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    yield start, index + 1
                    cursor = index + 1
                    break
        else:
            raise RuntimeError("nginx.conf contains an unterminated server block")


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent
    config = pathlib.Path(
        sys.argv[1] if len(sys.argv) > 1 else "/opt/proxy-admin/nginx/nginx.conf"
    )
    text = config.read_text(encoding="utf-8")
    marker = "location = /dglab-v4"
    if marker in text:
        print("unchanged")
        return 0

    target = None
    for start, end in server_blocks(text):
        block = text[start:end]
        if "listen 8444 ssl" in block:
            target = (start, end)
            break
    if target is None:
        raise RuntimeError("TLS server block listening on 8444 was not found")

    snippet = (root / "nginx-location.conf").read_text(encoding="utf-8").strip()
    indented = "\n".join(
        f"        {line}" if line else "" for line in snippet.splitlines()
    )
    _, end = target
    closing = text.rfind("}", target[0], end)
    patched = text[:closing] + "\n\n" + indented + "\n" + text[closing:]

    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    backup = config.with_name(f"{config.name}.before-dglab-{stamp}")
    shutil.copy2(config, backup)
    # nginx.conf is bind-mounted as a single file on this server. Preserve its
    # inode so the running container sees the new contents before nginx -t.
    config.write_text(patched, encoding="utf-8")
    (root / ".last-nginx-backup").write_text(str(backup), encoding="utf-8")
    print(backup)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
