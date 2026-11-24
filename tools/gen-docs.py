#!/usr/bin/env python3
"""Generates the Textem user guides at docs/docs/ (served at /docs/).

Run from the repository root:  python3 -I tools/gen-docs.py
Every UI name below must match the app (Sources/scarcrux-textem/MainMenu.swift,
SettingsView.swift, StatusItemController.swift). Edit the content here, not the
generated HTML.
"""
import html, pathlib

SITE = "https://textem.scarcrux.com"
UPDATED = "2026-11-21"
OUT = pathlib.Path("docs/docs")

GROUPS = [
    ("start", "Start here", ["install", "sign-in"]),
    ("everyday", "Everyday use", ["notifications", "codes", "accounts-shortcuts"]),
    ("yours", "Make it yours", ["privacy-offline"]),
    ("help", "Help", ["troubleshooting"]),
]

def shot(name, alt, caption, narrow=False, dark=True):
    source = f'<source srcset="/media/{name}-dark.png" media="(prefers-color-scheme: dark)">' if dark else ""
    src = f"/media/{name}-light.png" if dark else f"/media/{name}.png"
    cls = "shot narrow" if narrow else "shot"
    return (f'<figure class="{cls}"><picture>{source}<img src="{src}" alt="{html.escape(alt)}" loading="eager"></picture>'
            f'<figcaption>{caption}</figcaption></figure>')

def k(*keys):
    return "".join(f"<kbd>{key}</kbd>" for key in keys)

PAGES = {
"install": dict(
    title="Install Textem",
    lead="Download the signed app, move it to Applications, and allow notifications.",
    sections=[
    ("Before you start", """
<ul><li>A Mac with <strong>macOS 13 (Ventura) or later</strong>, Apple silicon or Intel.</li>
<li>An <strong>Android phone with Google Messages</strong>, signed in to a Google account.</li>
<li>Multiple Google accounts need macOS 14 or later; Textem Codes in AutoFill needs macOS 15 or later.</li></ul>
<p>Textem is a free, unofficial macOS wrapper for Google Messages for web. It shows Google's own web client in a Mac window and adds notifications, a Dock badge, shortcuts and more.</p>"""),
    ("Download and install", """
<ol><li><a href="https://github.com/Scarcrux/Textem/releases/latest/download/Textem.dmg">Download Textem.dmg</a>.</li>
<li>Open the disk image and drag <strong>Textem</strong> onto <strong>Applications</strong>.</li>
<li>Open Textem from Applications. It is signed with a Developer ID and notarized by Apple, so it opens without a security warning.</li></ol>"""),
    ("Allow notifications", """
<p>The first time Textem runs, macOS asks whether it may send notifications. Choose <strong>Allow</strong> so new texts show up as banners you can reply to. You can change this later in System Settings &gt; Notifications &gt; Textem.</p>"""),
    ("Keep it up to date", """
<p>While it is open, Textem checks for a new version once a day and asks before installing anything. To check now, choose <strong>Textem &gt; Check for Updates…</strong>. To turn the daily check off, open <strong>Textem &gt; Settings…</strong> (""" + k("⌘", ",") + """) and switch off <strong>Automatically check for updates</strong>.</p>"""),
    ],
    related=["sign-in", "notifications", "troubleshooting"]),

"sign-in": dict(
    title="Sign in and pair with your phone",
    lead="Connect Textem to Google Messages on your phone. You only do this once.",
    sections=[
    ("Don't use a passkey", """
<div class="callout warn"><p><strong>Passkeys can't work inside Textem.</strong> Apple only lets an app use passkeys for websites it owns, and Textem doesn't own google.com. When Google asks how to sign in, choose <strong>Enter your password</strong>, and pick a non-passkey second step.</p></div>"""),
    ("Pair", """
<p>Textem shows these steps the first time it opens. You can see them again any time with <strong>Help &gt; Sign-in Help…</strong>.</p>
""" + shot("onboarding", "Textem's sign-in guide with four pairing steps", "Textem's built-in sign-in guide.", narrow=True) + """
<ol><li>On your phone, open <strong>Google Messages</strong>, tap your <strong>account menu</strong> (top right), then <strong>Device pairing</strong>.</li>
<li>In Textem, sign in with the <strong>same Google account</strong> and choose <strong>Enter your password</strong>.</li>
<li>For the second step, choose a Google prompt ("Tap Yes"), an SMS or email code, or an authenticator app.</li>
<li>Your phone shows three emoji. Tap the one that matches what Textem shows.</li></ol>
<p>Textem then stays signed in across restarts.</p>"""),
    ("One computer at a time", """
<p>Google allows one active computer per account. If you open Messages for web in a browser or on another computer, that one becomes active and Textem disconnects. To switch back, press """ + k("⇧", "⌘", "R") + """ (<strong>View &gt; Reload from Origin</strong>).</p>"""),
    ],
    related=["install", "troubleshooting", "accounts-shortcuts"]),

"notifications": dict(
    title="Notifications and quick replies",
    lead="See new texts as notifications, reply without opening Textem, and control what a banner shows.",
    sections=[
    ("New-message notifications", """
<p>When a text arrives and Textem isn't the frontmost app, a notification shows the sender and the message. Click it to open that exact conversation. The Dock icon and the menu-bar icon show your unread count.</p>"""),
    ("Reply from the notification", """
<ol><li>Hover over the notification and click <strong>Reply</strong>.</li>
<li>Type your reply and press Return.</li></ol>
<p>Textem sends it to the conversation the notification came from, even if a different one is open. If Textem is locked, unlock it first. If Textem locks while a reply is sending, check its status after unlocking. When the status is unknown, check the conversation before resending.</p>"""),
    ("Mute or hide what banners show", """
<p>In <strong>Textem &gt; Settings…</strong>, under <strong>Notifications</strong>:</p>
<ul><li><strong>Mute notifications</strong> stops banners. The Dock badge still updates.</li>
<li><strong>Hide sender and message preview</strong> shows only "New message".</li></ul>
<p>Mute is also in the menu-bar icon's menu.</p>"""),
    ("Test that notifications work", """
<p>Choose <strong>Help &gt; Diagnostics &gt; Send Test Notification</strong>. If no banner appears, see <a href="/docs/troubleshooting/#no-notifications">No notifications</a>.</p>"""),
    ],
    related=["codes", "privacy-offline", "troubleshooting"]),

"codes": dict(
    title="Verification codes",
    lead="Copy a code from a text in one click, or pick it from AutoFill in Safari.",
    sections=[
    ("Copy Code on the notification", """
<p>When a text with a verification code arrives, its notification gets a <strong>Copy Code</strong> button. Click it, then paste where you need the code.</p>
<ul><li>A code can be copied for <strong>3 minutes</strong> after it arrives.</li>
<li>Codes stay in memory only, and are copied marked as private so clipboard managers that respect that don't save them.</li>
<li>To copy the most recent code at any time, choose <strong>Edit &gt; Copy Latest Code</strong> (""" + k("⇧", "⌘", "C") + """).</li>
<li>To turn the button off: <strong>Textem &gt; Settings…</strong> &gt; <strong>Verification Codes</strong> &gt; <strong>Copy Code button in notifications</strong>.</li></ul>
<p>Detection is cautious: it needs verification wording and exactly one 4–8 digit code, and ignores your own messages, promo codes, phone numbers and amounts. Notifications only offer newly received codes.</p>"""),
    ("Copy from a conversation or another app", """
<p>If the open conversation contains a detected verification code, choose <strong>Copy Code</strong> or use <strong>Show Message</strong> to find the original text. Check the age before using the code.</p>
<p>To copy a fresh code while you are in another app, turn on <strong>Global Copy Latest Code shortcut</strong> in <strong>Settings &gt; Verification Codes</strong>. Choose <strong>Change Shortcut…</strong>, press a letter or number with at least two modifiers including Command or Control, then click <strong>Save</strong>. The global shortcut uses codes received in the active Textem account in the last three minutes.</p>"""),
    ("Textem Codes in AutoFill <span class=\"badge\">Experimental · macOS 15+</span>", """
<p>Textem can also offer fresh codes in Safari's AutoFill, the way Apple's Messages app does. This is experimental and hasn't yet been confirmed showing up in every app.</p>
<ol><li>Open <strong>System Settings &gt; General &gt; AutoFill &amp; Passwords</strong> and turn on <strong>Textem Codes</strong>.</li>
<li>In <strong>Textem &gt; Settings…</strong> &gt; <strong>Verification Codes</strong>, turn on <strong>AutoFill verification codes (Experimental)</strong>.</li>
<li>When a site asks for a code, click the code field, open AutoFill and choose <strong>Textem Codes</strong>, then the code.</li></ol>
""" + shot("autofill-list", "The Textem Codes sheet listing two recent codes with Fill buttons", "Choosing a code from Textem Codes.", narrow=True) + """
<p>If the text ends in the form <code>@example.com #123456</code>, macOS can also suggest that code directly on example.com. Apple's own "From Messages" suggestions only read Apple's Messages and Mail apps, so Textem uses Apple's AutoFill provider system instead.</p>"""),
    ],
    related=["notifications", "privacy-offline", "troubleshooting"]),

"accounts-shortcuts": dict(
    title="Accounts, menu bar and shortcuts",
    lead="Use more than one Google account, run Textem from the menu bar, and learn the shortcuts.",
    sections=[
    ("Multiple Google accounts", """
<p>On macOS 14 or later, use the <strong>Accounts</strong> menu to <strong>Add Account…</strong>, switch between accounts, <strong>Rename Current Account…</strong> or <strong>Remove Current Account…</strong>. Each account keeps its own separate session, so you pair each one once.</p>"""),
    ("Menu bar and background", """
<p>The menu-bar icon shows your unread count. Its menu has <strong>Show Textem</strong>, your accounts, <strong>Settings…</strong>, and quick switches for <strong>Launch at Login</strong>, <strong>Menu Bar Only</strong>, <strong>Mute Notifications</strong> and <strong>Quit When Window Closed</strong>.</p>
<p>The same choices are in <strong>Textem &gt; Settings…</strong> under <strong>General</strong>: <strong>Launch at login</strong>, <strong>Start hidden</strong>, <strong>Menu bar only</strong> (hides the Dock icon) and <strong>Quit when the window is closed</strong>.</p>
""" + shot("settings", "Textem Settings with General, Updates, Notifications and Verification Codes", "Textem's Settings window.", narrow=True)),
    ("Keyboard shortcuts", """
<table class="keys"><thead><tr><th>Action</th><th>Shortcut</th></tr></thead><tbody>
<tr><td>Show or hide Textem from any app</td><td>""" + k("⌥", "⌘", "M") + """</td></tr>
<tr><td>New conversation</td><td>""" + k("⌘", "N") + """</td></tr>
<tr><td>Copy latest verification code</td><td>""" + k("⇧", "⌘", "C") + """</td></tr>
<tr><td>Find on page / next / previous</td><td>""" + k("⌘", "F") + " " + k("⌘", "G") + " " + k("⇧", "⌘", "G") + """</td></tr>
<tr><td>Zoom in / out / actual size</td><td>""" + k("⌘", "+") + " " + k("⌘", "−") + " " + k("⌘", "0") + """</td></tr>
<tr><td>Reload / reload from origin (reconnect)</td><td>""" + k("⌘", "R") + " " + k("⇧", "⌘", "R") + """</td></tr>
<tr><td>Settings</td><td>""" + k("⌘", ",") + """</td></tr>
</tbody></table>
<p><strong>Window &gt; Always on Top</strong> keeps Textem above other windows.</p>"""),
    ],
    related=["notifications", "privacy-offline", "install"]),

"privacy-offline": dict(
    title="Privacy options and Offline Mode",
    lead="Hide what's on screen, know what Textem connects to, and browse saved content offline.",
    sections=[
    ("Privacy options", """
<p>In <strong>Textem &gt; Settings…</strong>:</p>
<ul><li><strong>Privacy &gt; Blur message previews</strong>: previews and messages are blurred until you hover over them.</li>
<li><strong>Privacy &gt; Hide avatars</strong>: removes contact pictures.</li>
<li><strong>Notifications &gt; Hide sender and message preview</strong>: banners say only "New message".</li></ul>
<p>These change only what's shown on your Mac. Read receipts and what you send are unaffected.</p>"""),
    ("Lock the Textem window", """
<p>In <strong>Settings &gt; Privacy</strong>, turn on <strong>Require Touch ID or your Mac password to open Textem</strong>. Textem locks at launch and when your Mac sleeps or locks. You can also choose to lock immediately when you switch away, or after five minutes of inactivity in Textem.</p>
<p>Choose <strong>Lock Textem</strong> from the app menu or the Textem menu-bar icon to lock immediately. On return, Textem can prompt for Touch ID. Use <strong>Use Mac Password…</strong> if macOS requires your password. Notification previews are hidden while locked. The lock protects the Textem window; your session and saved files rely on your Mac login and FileVault.</p>"""),
    ("What Textem connects to", """
<p>Textem shows Google's own Messages for web and talks to Google. It adds no analytics, telemetry, accounts or relay servers, and your session is stored on your Mac. The only other connection is the daily update check to textem.scarcrux.com, which you can turn off in <strong>Settings &gt; Updates</strong>. To keep Google's sign-in working inside an app, Textem turns off WebKit's cross-site tracking prevention for its own Google session; this doesn't affect Safari.</p>"""),
    ("Offline Mode <span class=\"badge\">Experimental</span>", """
<p><strong>View &gt; Offline Mode</strong> pauses Google Messages and shows what Textem has saved on this Mac. Choose <strong>Go Online</strong> to return. The choice is remembered across restarts.</p>
<p>Today it shows phone history and pictures saved through Textem's developer Android companion; without the companion it's empty. Ordinary conversations aren't stored offline.</p>"""),
    ],
    related=["notifications", "codes", "troubleshooting"]),

"troubleshooting": dict(
    title="Troubleshooting and updating",
    lead="Fix the common problems, and what to expect when Textem updates.",
    sections=[
    ("“Can't reach Google Messages”", """
<p>If the page fails to load (offline, after sleep, a network blip), Textem retries on its own after 1, 2, 4, 8 and 16 seconds and shows the reason. Click <strong>Try Again</strong> or press """ + k("⇧", "⌘", "R") + """.</p>"""),
    ("The window is blank or the inbox never appears", """
<p>If the page loads but your conversations never appear, Textem reloads it once after about 40 seconds. If they still don't appear, it shows the <strong>Try Again</strong> screen. Quitting and reopening Textem also fixes it.</p>"""),
    ("“Trying to reach your phone”", """
<p>Google Messages on your phone needs to be on and connected. Opening the Messages app on your phone usually fixes it.</p>"""),
    ("A message says “View on your phone”", """
<p>Google sends some messages, usually business messages with rich cards, images or buttons, only to your phone. Google Messages for web never receives them, so Textem can't show them. Open them on your phone.</p>"""),
    ("Disconnected after using Messages in a browser", """
<p>Only one computer can be active per account. Press """ + k("⇧", "⌘", "R") + """ in Textem to make it the active one again.</p>"""),
    ("Sign-in verification fails", """
<p>You probably chose a passkey. Sign in again, choose <strong>Enter your password</strong>, and pick a non-passkey second step. See <a href="/docs/sign-in/">Sign in and pair</a>.</p>"""),
    ("No notifications", """
<ol><li>Check System Settings &gt; Notifications &gt; Textem allows alerts.</li>
<li>Check <strong>Mute notifications</strong> is off in Textem's Settings and in the menu-bar menu.</li>
<li>Notifications appear when Textem isn't the frontmost app.</li>
<li>Choose <strong>Help &gt; Diagnostics &gt; Send Test Notification</strong> to test delivery on its own.</li></ol>"""),
    ("Updating", """
<p>Textem checks for updates once a day while it's open and asks before installing. Choose <strong>Textem &gt; Check for Updates…</strong> to check now.</p>
<p><strong>Coming from 1.0b1?</strong> Textem's app identity changed in 1.0b2, so that one update has to be downloaded by hand. Your settings and Google sign-in carry over. Afterwards, Textem shows a short sheet, once, to turn notifications, Textem Codes and launch at login back on. You can open it again with <strong>Help &gt; After Updating…</strong>.</p>
""" + shot("after-updating", "Sheet listing notifications, Textem Codes, launch at login and phone companion with buttons", "The After Updating sheet.", narrow=True)),
    ],
    related=["sign-in", "notifications", "install"]),
}

def slug_id(title):
    import re
    plain = re.sub(r"<[^>]+>", "", html.unescape(title))
    return re.sub(r"[^a-z0-9]+", "-", plain.lower()).strip("-")

def nav(current):
    parts = ['<a class="all-guides" href="/docs/">Documentation home</a>']
    for _, name, slugs in GROUPS:
        items = "".join(
            f'<li><a href="/docs/{s}/"{" aria-current=\"page\"" if s == current else ""}>{html.escape(PAGES[s]["title"])}</a></li>'
            for s in slugs)
        parts.append(f"<h2>{name}</h2><ul>{items}</ul>")
    return "".join(parts)

def head(title, description, path):
    t = html.escape(title); d = html.escape(description)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t}</title>
<meta name="description" content="{d}">
<link rel="canonical" href="{SITE}{path}">
<meta property="og:title" content="{t}"><meta property="og:description" content="{d}">
<meta property="og:type" content="article"><meta property="og:url" content="{SITE}{path}">
<meta property="og:site_name" content="Textem"><meta property="og:image" content="{SITE}/og-image.png">
<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="/favicon.png" type="image/png"><link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="stylesheet" href="/topbar.css"><link rel="stylesheet" href="/docs/docs.css">
</head><body>
<a class="skip-link" href="#main-content">Skip to content</a>
<header class="site-topbar"><a class="tb-brand" href="/"><img src="/media/app-icon.png" width="28" height="28" alt="">Textem</a>
<nav aria-label="Site"><a href="/">Overview</a><a href="/docs/" aria-current="page">Documentation</a><a class="tb-github" href="https://github.com/Scarcrux/Textem">GitHub</a><a class="tb-download" href="https://github.com/Scarcrux/Textem/releases/latest/download/Textem.dmg">Download</a></nav></header>
"""

FOOT = f"""<footer><p>Textem documentation · Updated {UPDATED}</p>
<p>Unofficial. Not affiliated with, endorsed by, or sponsored by Google. “Google Messages” is a trademark of Google LLC.</p>
<a href="/docs/">Documentation</a> · <a href="/">Back to Textem</a> · <a href="https://github.com/Scarcrux/Textem">GitHub</a> · <a href="https://github.com/Scarcrux/Textem/issues">Report a problem</a> · © 2026 <a href="https://scarcrux.com">Scarcrux LLC</a></footer>"""

def page(slug):
    p = PAGES[slug]
    group = next((gid, name) for gid, name, slugs in GROUPS if slug in slugs)
    toc = "".join(f'<li><a href="#{slug_id(h)}">{h}</a></li>' for h, _ in p["sections"])
    body = "".join(f'<section id="{slug_id(h)}"><h2>{h}</h2>{c.strip()}</section>' for h, c in p["sections"])
    related = "".join(f'<li><a href="/docs/{r}/">{html.escape(PAGES[r]["title"])}</a></li>' for r in p["related"])
    return (head(f'{p["title"]} | Textem Documentation', p["lead"], f"/docs/{slug}/")
        + f'<div class="doc-layout"><aside class="sidebar"><nav aria-label="Documentation topics">{nav(slug)}</nav></aside>'
        + f'<div class="reading"><details class="mobile-nav"><summary>Browse the documentation</summary><nav aria-label="Documentation topics">{nav(slug)}</nav></details>'
        + f'<main id="main-content" tabindex="-1"><nav class="breadcrumbs" aria-label="Breadcrumb"><a href="/docs/">Documentation</a><span>/</span><a href="/docs/#{group[0]}">{group[1]}</a></nav>'
        + f'<article><h1>{html.escape(p["title"])}</h1><p class="lead">{html.escape(p["lead"])}</p>'
        + f'<nav class="contents" aria-label="On this page"><h2>On this page</h2><ul>{toc}</ul></nav>{body}'
        + f'<aside class="related"><h2>Related</h2><ul>{related}</ul></aside></article></main>'
        + FOOT + "</div></div>\n</body></html>\n")

def index():
    cards = []
    for gid, name, slugs in GROUPS:
        items = "".join(
            f'<a class="guide-card" href="/docs/{s}/"><h3>{html.escape(PAGES[s]["title"])}</h3><p>{html.escape(PAGES[s]["lead"])}</p></a>'
            for s in slugs)
        cards.append(f'<section class="category" id="{gid}"><h2>{name}</h2><div class="guide-grid">{items}</div></section>')
    return (head("Documentation | Textem", "Step-by-step documentation for Textem, the free macOS wrapper for Google Messages for web.", "/docs/")
        + f'<div class="doc-layout"><aside class="sidebar"><nav aria-label="Documentation topics">{nav(None)}</nav></aside>'
        + f'<div class="reading"><details class="mobile-nav"><summary>Browse the documentation</summary><nav aria-label="Documentation topics">{nav(None)}</nav></details>'
        + '<main id="main-content" tabindex="-1"><h1>Learn your way around.</h1>'
        + '<p class="lead">Install Textem, pair it with your phone, and get the most out of notifications, verification codes and shortcuts.</p>'
        + "".join(cards) + "</main>" + FOOT + "</div></div>\n</body></html>\n")

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "index.html").write_text(index(), encoding="utf-8")
    for slug in PAGES:
        (OUT / slug).mkdir(exist_ok=True)
        (OUT / slug / "index.html").write_text(page(slug), encoding="utf-8")
    print("wrote", 1 + len(PAGES), "pages to", OUT)
