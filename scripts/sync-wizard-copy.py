#!/usr/bin/env python3
# 修 wizard 文案与实际入口的一致性（2026-10-18）
#
# 背景：2.9.0-3 起删除了桌面入口 wildwork.direct（「Wild Work 直连」），
# 但 install/upgrade 向导里仍在介绍这个图标 —— 用户装完按向导去找，找不到。
# 这是典型的「改了功能没同步文案」的适配性缺陷，且在安装向导里直接暴露给用户。
#
# 本脚本幂等：已改过则跳过。
import json
import sys

OLD_DIRECT_MARK = "Wild Work 直连"

NEW_ENTRIES = [
    "『Wild Work』主入口：走 fnOS 统一网关（/app/wildwork），局域网与飞牛远程（含自有域名反代）都能打开。",
    "登录兜底：登录弹窗里内置「粘贴回调地址」框（上游自带，覆盖 TraeWork / 千问 / CodeArts / "
    "Gemini / LobsterAI），浏览器跳到打不开的 127.0.0.1 页面时把地址整条粘回即可。",
    "日志：运行日志在应用数据目录的 app.log 与 wild-work.log，超过 10 MB 会自动轮转为 .1，不需要手工清理。",
    "数据：账号凭据保存在应用配置目录，升级/重装选「保留数据」不会丢失，无需重新登录。",
]


def patch(path: str) -> int:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    changed = 0
    for step in data:
        items = step.get("items") or []
        texts = [i.get("helpText", "") for i in items if isinstance(i, dict)]
        if not any(OLD_DIRECT_MARK in t for t in texts):
            continue
        # 保留非「桌面图标与访问方式」类的条目不动，整段替换成新文案
        step["items"] = [{"type": "tips", "helpText": t} for t in NEW_ENTRIES]
        changed += 1

    if changed:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print(f"{path}: 已同步 {changed} 处向导文案")
    else:
        print(f"{path}: 无需改动（已同步或未找到旧文案）")
    return changed


if __name__ == "__main__":
    total = sum(patch(p) for p in sys.argv[1:])
    sys.exit(0)
