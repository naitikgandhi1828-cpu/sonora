# Installing Sonora on an iPhone 13 from a Windows PC

**The one hard constraint:** Xcode runs only on macOS. There is no Windows
version and no workaround. But you don't need to *own* a Mac — GitHub will
lend you one for free to do the compiling, and everything after that happens
on your PC.

The plan:

```
Your PC ──push──▶ GitHub  ──builds on a rented Mac──▶  Sonora.ipa
                                                          │
                                                     download
                                                          ▼
Your PC ──AltServer──▶ iPhone 13  (signs with your free Apple ID)
```

Total cost: nothing. Time: about 45 minutes the first time, 2 minutes for
rebuilds after that.

---

## Before you start

**Check your iPhone runs iOS 17 or newer.** Settings → General → About →
iOS Version. An iPhone 13 supports up to iOS 26, so you're almost certainly
fine, but the app won't install on iOS 16 or older.

**Consider making a second Apple ID** just for this, at
[appleid.apple.com](https://appleid.apple.com). AltServer sends your
credentials straight to Apple and nowhere else, but a throwaway ID keeps
your sideloading completely separate from your real account. Either works.

---

## Part 1 — Get GitHub to build the app (~10 min)

The project already ships as a **prepared git repository with the first
commit made**, so you don't have to drag 35 files through a browser. You
just point GitHub Desktop at the folder and press Publish.

1. **Make a free GitHub account** at [github.com](https://github.com) if you
   don't already have one. Remember the username and password.

2. **Install [GitHub Desktop](https://desktop.github.com)** and sign in with
   that account (File → Options → Accounts → Sign in).

3. **Unzip `Sonora-iOS.zip`** somewhere sensible — `Documents\Sonora` is
   fine. Inside you'll find a folder named `Sonora` containing
   `Sonora.xcodeproj`, a `Sonora` source folder, `README.md` and a hidden
   `.git` folder. That whole folder is the repository.

4. **Add it to GitHub Desktop:** File → **Add local repository…** → browse to
   that `Sonora` folder → **Add repository**. It should recognise it
   immediately and show "1 commit" with nothing left to commit. If it
   complains the folder isn't a repository, you unzipped one level too deep
   or too shallow — pick the folder that directly contains `README.md`.

5. **Publish it:** click **Publish repository** at the top. Name it `sonora`.
   Untick "Keep this code private" if you want unlimited free build minutes
   (see the note at the bottom). Click **Publish repository**.

6. **Run the build:** open your repo on github.com → **Actions** tab → click
   **I understand my workflows, enable them** if prompted → choose
   **Build unsigned IPA** in the left sidebar → **Run workflow** → the green
   **Run workflow** button.

7. **Wait about 5 minutes.** The run goes green when it finishes. Click into
   it, scroll to **Artifacts** at the bottom, download **Sonora-ipa**.

8. **Unzip what you downloaded.** GitHub wraps artifacts in a zip, so you get
   `Sonora-ipa.zip` containing `Sonora.ipa`. That file is the app. Keep it
   somewhere you can find it.

> **If the build fails**, click the failed step and copy the red error text.
> That text is exactly what's needed to fix it — send it over and you'll get
> a corrected project back. A first-build failure is normal for a codebase
> this size and is usually a one-line fix.

## Part 2 — Set up AltStore on Windows (~20 min)

AltStore signs the app with your Apple ID on your own device, then keeps it
alive by re-signing it over Wi-Fi before it expires.

### Install the prerequisites, in this order

1. **iTunes — from Apple, not the Microsoft Store.** This matters. The Store
   version is sandboxed and AltServer cannot talk to it.
   [64-bit installer](https://www.apple.com/itunes/download/win64)

2. **iCloud — also from Apple, not the Store.**
   [Direct installer](https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe)

3. **AltServer:** download
   [altinstaller.zip](https://cdn.altstore.io/file/altstore/altinstaller.zip),
   extract it, run `Setup.exe`.

Reboot the PC once all three are installed.

### Install AltStore onto the phone

4. **Launch AltServer as administrator.** Search "AltServer" in the Windows
   taskbar, right-click → **Run as administrator**. It lives in the system
   tray (the ^ arrow near the clock).

5. **Plug the iPhone in with a cable** and unlock it. Tap **Trust** on the
   phone, and confirm on the PC if asked.

6. **Open iTunes**, sign in with your Apple ID, click the small phone icon,
   and tick **Sync with this iPhone over Wi-Fi**. This is what lets AltStore
   refresh itself later without a cable.

7. **Turn on Developer Mode** (required on iOS 16+):
   Settings → Privacy & Security → Developer Mode → on → restart the phone.

8. **Install AltStore:** click the AltServer tray icon → **Install AltStore**
   → pick your iPhone. Enter your Apple ID and password when prompted.

9. **Trust the certificate on the phone:**
   Settings → General → VPN & Device Management → tap your Apple ID →
   **Trust**. AltStore now opens from your home screen.

---

## Part 3 — Install Sonora (~5 min)

1. **Get `Sonora.ipa` onto the phone.** Easiest route: email it to yourself,
   or drop it in iCloud Drive / OneDrive / Google Drive and open that app on
   the phone. Save it to **Files**.

2. **Open AltStore** on the iPhone → **My Apps** tab → the **+** in the top
   left → browse to `Sonora.ipa` and tap it.

3. Wait for the install. Sonora appears on your home screen.

4. **First launch:** open Sonora, tap **+** → **Add Folder**, and pick a
   folder of music from Files (iCloud Drive, On My iPhone, or a USB-C drive).
   It'll index and you're playing.

> Note: AltStore automatically changes the bundle ID when it signs, so you
> do **not** need to edit `com.example.Sonora` on this route. That step only
> applies when building directly in Xcode.

---

## Keeping it alive

A free Apple ID signs apps for **7 days**. After that Sonora stops opening
until it's re-signed. You don't have to rebuild anything:

- **Automatic:** keep AltServer running on the PC and have both devices on
  the same Wi-Fi. AltStore refreshes in the background — opening AltStore
  every few days is enough to keep it topped up.
- **Manual:** open AltStore → **My Apps** → **Refresh All**.

Practical habit: launch AltStore once a week, or any time you notice Sonora
won't open. Refreshing takes a few seconds.

**Free-account limits worth knowing:**

- 3 sideloaded apps at a time (AltStore itself counts as one, so you get 2 more).
- 10 new app IDs per 7 days — re-installing repeatedly can hit this. Refreshing does not.
- If you go away for more than a week without Wi-Fi access to the PC, the app
  will expire and need a manual refresh on your return. Your music library
  index and settings survive — they're stored on the phone.

---

## If you'd rather skip GitHub

**Rent a Mac by the hour.** [MacinCloud](https://www.macincloud.com) and
[MacStadium](https://www.macstadium.com) rent real Macs remotely, roughly
$1–2/hour pay-as-you-go. One hour is plenty: install Xcode, open the project,
build, export the IPA, then carry on with Part 2 above. Slower to set up than
the GitHub route and it costs money, but it gives you a full Xcode you can
poke at if you want to change the code.

**Borrow a Mac for 30 minutes.** A friend's laptop works. Install Xcode, open
`Sonora.xcodeproj`, set Signing & Capabilities → your Apple ID + a unique
bundle ID like `com.yourname.sonora`, plug in your iPhone, press ⌘R. Done.
You'd need the Mac again each week though, which is why AltStore is the
better long-term answer.

---

## About GitHub build minutes

- **Public repo:** macOS builds are unlimited and free.
- **Private repo:** free accounts get 2,000 minutes/month, and macOS runners
  count 10× — so about 200 macOS minutes. A Sonora build takes ~5 minutes,
  giving you roughly 40 builds a month. Fine unless you're iterating hard.

You only need to rebuild when the *code* changes. Weekly re-signing is
AltStore's job and costs no build minutes at all.
