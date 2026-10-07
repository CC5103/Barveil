#!/usr/bin/env python3
"""Apply the maintained zh-Hans/ja copy to Localizable.xcstrings.

Usage:
    python3 scripts/localize.py [extracted-keys.json]

The optional key list is produced from Xcode's ``*.stringsdata`` files. When
provided, the script also removes obsolete keys so old product copy does not
linger in the catalog.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Barveil/Resources/Localizable.xcstrings"
KEYS_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else None

TRANSLATIONS: dict[str, tuple[str, str]] = {
    "Automatic": ("自动", "自動"),
    "Behavior": ("行为", "動作"),
    "Advanced": ("高级", "詳細"),
    "Privacy": ("隐私", "プライバシー"),
    "Data": ("数据", "データ"),
    "Keyboard": ("键盘", "キーボード"),
    "Barveil control": ("Barveil 控制", "Barveil の制御"),
    "Language": ("语言", "言語"),
    "System Default": ("跟随系统", "システムに合わせる"),
    "Changes take effect immediately.": ("更改会立即生效。", "変更はすぐに反映されます。"),
    "Active": ("运行中", "有効"),
    "Off": ("已关闭", "オフ"),
    "Restore and Turn Off Automation": ("恢复设置并关闭自动控制", "設定を戻して自動制御をオフ"),
    "Diagnostics": ("诊断", "診断"),
    "System Recovery": ("系统恢复", "システムの復元"),
    "Current app": ("当前应用", "現在のアプリ"),
    "While Barveil is running, it uses a consistent visible baseline and temporarily hides the menu bar only during playback. Your original full-screen menu-bar setting is restored when Barveil is turned off or quit.": (
        "Barveil 运行期间会使用统一的可见基线，只在播放时临时隐藏菜单栏。关闭 Barveil 或退出后，会恢复你原来的全屏菜单栏设置。",
        "Barveil の実行中は一貫した表示ベースを使い、再生中だけメニューバーを一時的に隠します。Barveil をオフにするか終了すると、元のフルスクリーン用メニューバー設定に戻ります。",
    ),
    "Current setting": ("当前设置", "現在の設定"),
    "Current shortcut": ("当前快捷键", "現在のショートカット"),
    "Current system setting": ("当前系统设置", "現在のシステム設定"),
    "Control mode": ("控制模式", "制御モード"),
    "Shortcut": ("快捷键", "ショートカット"),
    "Exclude": ("排除", "除外"),
    "Done": ("完成", "完了"),
    "No action needed right now": ("目前无需操作", "現在必要な操作はありません"),
    "No Action Needed": ("无需操作", "操作は必要ありません"),
    "Get Started": ("开始使用", "使ってみる"),
    "Ready": ("已就绪", "準備完了"),
    "Only during playback": ("仅在播放时", "再生中のみ"),
    "Stays on this Mac": ("只留在这台 Mac", "この Mac の中だけ"),
    "Returns automatically": ("自动恢复", "自動的に戻る"),
    "No analytics": ("不进行分析", "解析なし"),
    "No network access": ("无网络访问", "ネットワークアクセスなし"),
    "Stored on this Mac": ("存储在本机", "この Mac に保存"),
    "Waiting for playback": ("等待播放", "再生待ち"),
    "Hidden until the app changes": ("切换应用前保持隐藏", "アプリを切り替えるまで非表示"),
    "Visible until the app changes": ("切换应用前保持显示", "アプリを切り替えるまで表示"),
    "Manual control": ("手动控制", "手動制御"),
    "This app is excluded": ("此应用已排除", "このアプリは除外されています"),
    "Restore Automatic": ("恢复自动控制", "自動制御に戻す"),
    "Turn On Automatic Control": ("开启自动控制", "自動制御をオンにする"),
    "Add Barveil & Open Settings": ("添加 Barveil 并打开设置", "Barveil を追加して設定を開く"),
    "Hide Menu Bar": ("隐藏菜单栏", "メニューバーを隠す"),
    "Show Menu Bar": ("显示菜单栏", "メニューバーを表示"),
    "Keep Hidden": ("保持隐藏", "隠したまま"),
    "When full screen is paused": ("全屏暂停时", "フルスクリーン一時停止時"),
    "Why this state?": ("为什么是这个状态？", "この状態の理由"),
    "Menu bar hidden": ("菜单栏已隐藏", "メニューバーを非表示中"),
    "Automatic control is off": ("自动控制已关闭", "自動制御はオフです"),
    "Hidden in full screen": ("全屏时隐藏", "フルスクリーンで非表示"),
    "Visible in full screen": ("全屏时显示", "フルスクリーンで表示"),
    "Exact browser detection needs permission": ("精确浏览器检测需要权限", "ブラウザの正確な検出には権限が必要です"),
    "Next, macOS may ask for Accessibility access. Barveil adds itself to the list; you only turn on the switch.": (
        "接下来，macOS 可能会请求辅助功能权限。Barveil 会自动加入列表，你只需打开开关。",
        "次に macOS がアクセシビリティ権限を求める場合があります。Barveil は自動で一覧に追加されるので、スイッチをオンにするだけです。",
    ),
    "The system switch for Barveil is on.": (
        "Barveil 的系统开关已打开。",
        "Barveil のシステムスイッチはオンです。",
    ),
    "Barveil will be added to Accessibility automatically. You only need to turn on its system switch.": (
        "Barveil 会自动加入辅助功能列表，你只需要打开它的系统开关。",
        "Barveil はアクセシビリティ一覧に自動で追加されます。システムのスイッチをオンにするだけです。",
    ),
    "Barveil registers itself; macOS only asks you to confirm the system switch.": (
        "Barveil 会自动注册，macOS 只会请你确认系统开关。",
        "Barveil は自動で登録されます。macOS ではシステムのスイッチを確認するだけです。",
    ),

    "Your Mac already hides it": ("你的 Mac 已经隐藏了菜单栏", "Mac はすでにメニューバーを隠しています"),
    "The system setting already applies to every full-screen window. Barveil preserves that choice.": (
        "该系统设置已经作用于所有全屏窗口，Barveil 会保留你的选择。",
        "このシステム設定はすでにすべてのフルスクリーンウインドウに適用されています。Barveil はその選択を尊重します。",
    ),
    "Turn it on to let Barveil manage the menu bar. Your current system setting is unchanged.": (
        "开启后由 Barveil 管理菜单栏；当前系统设置不会被改动。",
        "オンにすると Barveil がメニューバーを管理します。現在のシステム設定は変更されません。",
    ),
    "It will come back when playback pauses or the picture leaves full screen.": (
        "暂停播放或退出全屏后，它会自动回来。",
        "再生を一時停止するかフルスクリーンを終了すると、自動的に戻ります。",
    ),
    "The menu bar stays under your control while this app is in front.": (
        "此应用位于前台时，菜单栏由你掌控。",
        "このアプリが前面にある間、メニューバーは手動操作のままです。",
    ),
    "This manual choice stays put until the front app changes.": (
        "此手动选择会保持到前台 App 改变。",
        "この手動設定は前面のアプリが変わるまで保持されます。",
    ),
    "Automatic detection is off. Use the button below or your keyboard shortcut.": (
        "自动检测已关闭。请使用下方按钮或键盘快捷键。",
        "自動検出はオフです。下のボタンまたはキーボードショートカットを使います。",
    ),
    "The picture is full screen. The menu bar will step aside when playback begins.": (
        "画面已全屏。开始播放后，菜单栏会退场。",
        "画面はフルスクリーンです。再生が始まるとメニューバーが退きます。",
    ),
    "The menu bar is returning with the system transition.": (
        "菜单栏会随系统转场动画一起回来。",
        "メニューバーはシステムの切り替えアニメーションとともに戻ります。",
    ),
    "Start a full-screen video. Windowed playback and ordinary app windows are left alone.": (
        "开始播放全屏视频。窗口播放和普通应用窗口不会触发隐藏。",
        "フルスクリーン動画を再生してください。ウインドウ再生や通常のアプリウインドウには影響しません。",
    ),
    "macOS needs Accessibility access to tell a full-screen browser window apart from a full-screen video.": (
        "macOS 需要“辅助功能”权限，才能区分浏览器窗口全屏和视频全屏。",
        "macOS がブラウザのウインドウ全画面と動画のフルスクリーンを区別するには、アクセシビリティ権限が必要です。",
    ),
    "The system setting applies this behavior to every full-screen window. Barveil will not fight that choice.": (
        "该系统设置会作用于所有全屏窗口。Barveil 不会覆盖你的选择。",
        "このシステム設定はすべてのフルスクリーンウインドウに適用されます。Barveil はユーザーの選択を上書きしません。",
    ),
    "A quieter full screen": ("更安静的全屏体验", "もっと静かなフルスクリーン"),
    "Barveil gets the menu bar out of the way only while a video is playing full screen.": (
        "只有在视频全屏播放时，Barveil 才会让菜单栏暂时退场。",
        "Barveil は動画がフルスクリーンで再生されている間だけ、メニューバーを邪魔にならない位置へ退けます。",
    ),
    "Windowed video and ordinary full-screen windows are left alone.": (
        "窗口视频和普通全屏窗口不受影响。",
        "ウインドウ表示の動画や通常のフルスクリーンウインドウには影響しません。",
    ),
    "Pause playback or leave full screen and your menu bar comes back.": (
        "暂停播放或退出全屏后，菜单栏会自动回来。",
        "再生を一時停止するかフルスクリーンを終了すると、メニューバーが戻ります。",
    ),
    "No account, no analytics, and no network access.": (
        "无账号、无分析、无网络访问。",
        "アカウント不要、解析なし、ネットワークアクセスなし。",
    ),
    "Choose how Barveil reacts, and when it should start.": (
        "选择 Barveil 的响应方式与启动时机。",
        "Barveil の動作と起動タイミングを選択します。",
    ),
    "Hides the menu bar only when the front app is playing full-screen video. Windowed playback is left alone.": (
        "仅当前台 App 全屏播放视频时隐藏菜单栏；窗口播放不受影响。",
        "前面のアプリがフルスクリーン動画を再生しているときだけメニューバーを隠します。ウインドウ再生には影響しません。",
    ),
    "Turns automatic detection off. Use the menu-bar button or keyboard shortcut to hide and show the bar.": (
        "关闭自动检测。使用菜单栏按钮或键盘快捷键显示/隐藏菜单栏。",
        "自動検出をオフにします。メニューバーのボタンまたはキーボードショートカットで表示／非表示を切り替えます。",
    ),
    "Start quietly in the menu bar after you sign in.": (
        "登录后在菜单栏中安静启动。",
        "ログイン後、メニューバーで静かに起動します。",
    ),
    "Toggle the menu bar without opening this panel.": (
        "无需打开面板即可切换菜单栏。",
        "パネルを開かずにメニューバーを切り替えます。",
    ),
    "A manual toggle stays pinned until the front app changes. Automatic control then resumes.": (
        "手动操作会保持到前台 App 改变；随后自动控制会恢复。",
        "手動操作は前面のアプリが変わるまで固定され、その後は自動制御に戻ります。",
    ),
    "Keep automation away from apps where you prefer manual control.": (
        "将不希望自动控制的应用加入例外。",
        "自動制御を使いたくないアプリを除外します。",
    ),
    "Excluded Apps": ("排除的应用", "除外したアプリ"),
    "No excluded apps": ("没有排除的应用", "除外したアプリはありません"),
    "When an app is excluded, Barveil leaves the menu bar exactly as it is whenever that app is in front.": (
        "应用被排除后，只要它位于前台，Barveil 就不会改动菜单栏。",
        "アプリを除外すると、そのアプリが前面にある間は Barveil がメニューバーを変更しません。",
    ),
    "You can also exclude the current app directly from the Barveil panel.": (
        "也可以直接从 Barveil 面板排除当前应用。",
        "Barveil パネルから現在のアプリを直接除外することもできます。",
    ),
    "Barveil keeps its permissions narrow and its data on your Mac.": (
        "Barveil 仅申请必要的权限，数据只留在你的 Mac 上。",
        "Barveil は必要最小限の権限だけを使い、データは Mac の外へ出しません。",
    ),
    "Recommended for Safari, Chrome, and other browsers.": (
        "推荐用于 Safari、Chrome 等浏览器。",
        "Safari、Chrome などのブラウザに推奨します。",
    ),
    "Used only to distinguish a full-screen browser window from a video that fills the browser content area.": (
        "仅用于区分浏览器窗口全屏和内容区域中的视频全屏。",
        "ブラウザのウインドウ全画面と、内容領域を埋める動画の全画面を区別するためだけに使用します。",
    ),

    "The app bundle contains no networking entitlement.": (
        "App 包未包含网络权限。",
        "アプリバンドルにはネットワーク権限が含まれていません。",
    ),
    "Nothing is sent to a server or third party.": (
        "不会向服务器或第三方发送任何内容。",
        "サーバーや第三者には何も送信しません。",
    ),
    "Preferences and the short diagnostics log stay in local storage.": (
        "偏好设置和简短的诊断日志只保存在本机存储中。",
        "環境設定と短い診断ログは、この Mac のローカルストレージにのみ保存されます。",
    ),
    "Detection edge cases, system recovery, and diagnostics.": (
        "检测边界情况、系统恢复与诊断。",
        "検出の例外、システムの復元、診断。",
    ),
    "Treat unattributed audio as playback": ("将来源不明的音频视为播放", "帰属先不明の音声を再生中として扱う"),
    "May help with unusual players that route audio through another process.": (
        "可能有助于通过其他进程输出音频的播放器。",
        "別のプロセス経由で音声を出力する特殊なプレイヤーで役立つ場合があります。",
    ),
    "Leave this off unless a player is not detected. It can produce more false positives.": (
        "仅在播放器无法识别时开启；它可能增加误判。",
        "プレイヤーが検出されない場合だけオンにしてください。誤検出が増える可能性があります。",
    ),
    "Restore My System Setting": ("恢复我的系统设置", "自分のシステム設定に戻す"),
    "Barveil uses macOS’s own “Automatically hide and show the menu bar in full screen” setting while a video is playing, then restores your value.": (
        "视频播放时，Barveil 会使用 macOS 的“在全屏模式下自动隐藏并显示菜单栏”设置，随后恢复你的原值。",
        "動画の再生中だけ macOS の「フルスクリーンでメニューバーを自動的に隠す／表示する」設定を使い、あとで元の値に戻します。",
    ),
    "%lld recorded events": ("%lld 条记录", "%lld 件の記録"),
    "Detection details": ("检测详情", "検出の詳細"),
    "Nothing recorded yet.": ("暂无记录。", "まだ記録はありません。"),
    "The log is kept in memory, is limited to 30 events, and can be copied when you report a problem.": (
        "日志仅保存在内存中，最多 30 条，可在反馈问题时复制。",
        "ログはメモリ内に最大 30 件保存され、問題を報告するときにコピーできます。",
    ),
    "A small menu-bar utility that gets out of the way while you watch full-screen video.": (
        "观看全屏视频时自动让路的菜单栏小工具。",
        "フルスクリーン動画を見ている間、邪魔にならないメニューバーユーティリティ。",
    ),
    "Version information.": ("版本信息。", "バージョン情報。"),
    "Barveil does not collect data and does not require an account.": (
        "Barveil 不收集数据，也不要求账号。",
        "Barveil はデータを収集せず、アカウントも必要としません。",
    ),
    "Automatically hide the menu bar during full-screen playback.": (
        "全屏播放时自动隐藏菜单栏。",
        "フルスクリーン再生中はメニューバーを自動的に隠します。",
    ),
    "Couldn’t Update Settings": ("无法更新设置", "設定を更新できませんでした"),
    "Quit Barveil": ("退出 Barveil", "Barveil を終了"),
    "OK": ("好", "OK"),
    "Your current macOS menu-bar setting is preserved while automation is off.": (
        "自动控制关闭期间，会保留你当前的 macOS 菜单栏设置。",
        "自動制御がオフの間、現在の macOS メニューバー設定は保持されます。",
    ),
    "“Keep Hidden” leaves the menu bar out of the way until the full-screen picture closes. This choice has no effect in manual mode.": (
        "“保持隐藏”会让菜单栏一直退场，直到关闭全屏画面。手动模式下无效。",
        "「隠したまま」はフルスクリーン画面を閉じるまでメニューバーを退けたままにします。手動モードでは効果がありません。",
    ),
    "Barveil Settings": ("Barveil 设置", "Barveil 設定"),
    "About": ("关于", "情報"),
    "About Barveil": ("关于 Barveil", "Barveil について"),
    "Version %@": ("版本 %@", "バージョン %@"),
    "Links": ("链接", "リンク"),
    "GitHub": ("GitHub", "GitHub"),
    "Check for Updates": ("检查更新", "更新をチェック"),
    "Copied": ("已复制", "コピーしました"),
    "Restore System Setting?": ("恢复系统设置？", "システム設定を復元しますか？"),
    "This turns off automatic control and restores the menu-bar setting that was active before Barveil changed it.": (
        "这会关闭自动控制，并恢复 Barveil 更改前的菜单栏设置。",
        "自動制御をオフにし、Barveil が変更する前のメニューバー設定に戻します。",
    ),
}

def main() -> None:
    catalog = json.loads(CATALOG.read_text())
    old = catalog.get("strings", {})

    if KEYS_PATH:
        keys = json.loads(KEYS_PATH.read_text())
    else:
        keys = sorted(old, key=str.casefold)

    result: dict[str, object] = {}
    missing: list[str] = []

    for key in keys:
        if key == "Barveil":
            result[key] = {"extractionState": "manual"}
            continue

        translations: dict[str, object] = {}
        old_localizations = old.get(key, {}).get("localizations", {})

        for language, index in (("zh-Hans", 0), ("ja", 1)):
            value = None
            if key in TRANSLATIONS:
                value = TRANSLATIONS[key][index]
            else:
                value = old_localizations.get(language, {}).get("stringUnit", {}).get("value")
            if value:
                translations[language] = {
                    "stringUnit": {"state": "translated", "value": value},
                }

        if len(translations) != 2:
            missing.append(key)

        entry: dict[str, object] = {"extractionState": "manual"}
        if translations:
            entry["localizations"] = translations
        result[key] = entry

    if missing:
        print("Missing translations:")
        for key in missing:
            print(f"  - {key!r}")
        raise SystemExit(1)

    output = {
        "sourceLanguage": "en",
        "strings": dict(sorted(result.items(), key=lambda item: item[0].casefold())),
        "version": "1.0",
    }
    CATALOG.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
    print(f"Wrote {len(result)} localized keys to {CATALOG.relative_to(ROOT)}")

if __name__ == "__main__":
    main()
