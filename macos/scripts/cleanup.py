#!/usr/bin/env python3
"""Remove only generated files and receiver state, retaining the Git checkout."""
import argparse
import pathlib
import shutil
import subprocess

GENERATED = ("artifacts", "build", "cache", "data", "logs", "tmp")


def cleanup(root, dry_run=True):
    root = pathlib.Path(root).resolve()
    marker = root / ".fusionplay-mac"
    if not marker.is_file() or marker.read_text().strip() != "fusionplay-mac-v1":
        raise RuntimeError("Missing installation marker; nothing was deleted")
    targets = [root / name for name in GENERATED]
    if not dry_run:
        for path in targets:
            if path.is_symlink():
                path.unlink()
            elif path.exists():
                shutil.rmtree(path)
    return targets


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[3]
    targets = cleanup(root)
    print("将清理以下生成目录，保留 source 中的源码和 Git 历史：")
    for target in targets:
        print(target)
    if not args.execute:
        print("仅预览，没有删除任何文件。")
        return
    if input("输入 DELETE 确认清理：").strip() != "DELETE":
        return
    # Quit only the installed application; diagnostics must be stopped separately.
    subprocess.run(["osascript", "-e", 'tell application id "tech.zrim.fusionplay.mac" to quit'], capture_output=True)
    result = subprocess.run(["ps", "-axo", "command="], check=True, capture_output=True, text=True)
    if any(str(root) in line and ("/FusionPlayMac" in line or "/fusionplay-diagnostic" in line) for line in result.stdout.splitlines()):
        raise RuntimeError("接收器仍在退出或诊断程序仍在运行，请关闭后重试；未删除文件。")
    cleanup(root, dry_run=False)
    print("已清理程序、配置、身份、日志和专用缓存。源码与共享工具保留。")


if __name__ == "__main__":
    main()
