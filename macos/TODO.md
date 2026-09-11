# ServerMaster — TODO

Everything that is planned but not built yet, plus the honest limits of what
ships today. Format: `[ ]` not started, `[~]` partially there.

---

## Features to build

### [ ] Localization — German, French, Danish, Japanese

English is the source language: the strings are written in English directly in
the Swift code, so English needs no `.lproj` of its own. Four languages are
still missing, and no others are planned.

Scope: about 733 keys per language, roughly 2900 translations in total.

How it is wired:

| Piece | Path |
|---|---|
| Language registry | `ServerMaster/Core/AppLanguage.swift` |
| One file per language | `ServerMaster/<code>.lproj/Localizable.strings` |

The translation key is the English text from the code. To add a language:
append an entry to `AppLanguage.supported`, drop the `.strings` file in place,
and add the code to `knownRegions` in `project.pbxproj`.

### [x] Apache as an engine — done in 1.1

Two engines shipped: **Apache** for static sites and **PHP site (Apache +
PHP-FPM)** for a CMS. The reason to pick them over Nginx is `.htaccess`, and it
works — verified live, not assumed: a `RewriteRule` and a `Header` directive in
a site's own `.htaccess` both take effect.

**No installation is needed.** macOS ships Apache 2.4 in `/usr/sbin/httpd` and
every module required is already on disk; the generated config loads them
explicitly. Homebrew's `httpd` is used instead when it is present.

Three things that had to be got right, each found by running it:

- Without its own `DefaultRuntimeDir`, Apache creates the proxy mutex in
  `/var/run` and refuses to start without root.
- The `Mutex` directive does not accept a quoted path, so it cannot be used at
  all when the runtime folder lives under “Application Support”.
- `ErrorDocument 418` is rejected and fails the whole config — Apache has no
  entry for that status. It is filtered out; every other code we generate is
  accepted.

PHP version per profile works here too: Apache reuses the php-fpm sidecar
machinery that already existed for Nginx.

Verified against the real thing, not a synthetic site: Joomla 5 installed from
scratch, its own `htaccess.txt` renamed to `.htaccess` the way the Joomla docs
tell you to, and SEF rewriting switched on in `configuration.php`. A request for
`/component/users/` — an extensionless path with no file behind it — comes back
with `X-Powered-By: PHP/8.5.10`, so Joomla's own rewrite rules carried it to
`index.php`. That is exactly what Nginx cannot do without hand-translating the
rules.

### [~] Intel support — universal build in 1.1

The deployment target came down to macOS 14 Sonoma and `ARCHS` is now
`arm64 x86_64`, so the build is genuinely universal — verified with `lipo` on the
exported app. That it compiles at all is meaningful: the compiler checked API
availability against Sonoma, so nothing macOS 27-only is being used.

The x86_64 slice was exercised under Rosetta on this Mac: the settings and
decoding suite (48 checks) and the Apache suite (15 checks, including spawning
httpd and php-fpm and serving real HTTP) both pass as x86_64.

Keep this as `[~]` until there is a regular Intel validation checklist for each
public release.

### [~] Database work without the command line

Already there: browse tables, edit cells in place, add and delete rows, run raw
SQL, copy results as CSV, create and drop databases.

Still missing: schema editing through the UI — create and alter tables, add,
rename and drop columns, indexes and keys, import and export `.sql` dumps, and
manage users and privileges. Right now those still need a terminal.

### [x] Web database admin panel — done in 1.1

A button on the Database screen starts a web panel on a port of its own and
opens the browser — the thing MAMP had. Bound to `127.0.0.1` only: it is
unrestricted access to every database and must never be reachable from the
network.

Both panels are offered, chosen in Settings:

- **Adminer 6.0.1** is bundled with the app (one PHP file, 407 KB, dual
  Apache 2.0 / GPL 2, attribution in `Resources/adminer-LICENSE.txt`). Works
  instantly and offline.
- **phpMyAdmin** is installed through Homebrew and served from where brew put
  it, with our config alongside, so the installed tree is never modified. Its
  `auth_type = config` gives the true auto-login MAMP had.

Neither accepts the managed database's passwordless root account — verified
against Adminer 6, which refuses outright. So the panel gets its own account
with a password generated on every start. Root is untouched: a CMS already
installed with “no password” keeps working.

Both panels sign in by themselves. Adminer 6 dropped the `adminer_object()`
extension point older wrappers used, and its login form carries a CSRF token, so
credentials cannot simply be posted from a static page. The wrapper does what a
person does: loads the login page, takes the token out of it, submits the form.
Verified in a browser — it lands straight on the database list. The account and
password are still shown in the app as a fallback.

### [ ] Command line tool and its installer

A `servermaster` command for the terminal, so a profile can be started, stopped
and inspected without touching the window — useful in scripts, in a Makefile, or
over SSH.

Sketch of the surface: `servermaster start <profile>`, `stop`, `restart`,
`status`, `list`, `logs <profile>`, `ports`.

It needs an installer too, because a binary inside the `.app` bundle is not on
anyone's `PATH`. A button in Settings that symlinks the tool into
`/usr/local/bin` (with the system password prompt when that directory is not
writable), plus the matching uninstall. The Settings row should show whether the
tool is currently installed and which version it points at.

### [ ] Interface modes — Standard and Advanced

One setting that changes how much the app shows.

*Standard* is for someone who just needs a directory served on a port: pick a
folder, press Start. Ports, engines, config files and certificates stay out of
the way behind sensible defaults.

*Advanced* is what exists today: every engine option, config file editing,
sidecars, privileged ports, database tooling.

---

## Open issues

### [ ] Release builds are not signed for distribution

The app checks `updates/maclastversion.txt` for the latest macOS version and
links users to the project releases. Current public builds are unsigned and not
notarized, so macOS shows the normal first-launch warning for apps from an
unidentified developer.

Only an *Apple Development* certificate is installed. Distribution needs a
**Developer ID Application** certificate (Apple Developer Program, team
`88M5SYPGUR`), after which the release flow becomes:

```
xcodebuild archive -scheme ServerMaster -configuration Release \
    -destination 'generic/platform=macOS' -archivePath build/ServerMaster.xcarchive
xcodebuild -exportArchive -archivePath build/ServerMaster.xcarchive \
    -exportOptionsPlist ExportOptions.plist -exportPath build/export
xcrun notarytool submit build/export/ServerMaster.zip --keychain-profile AC --wait
xcrun stapler staple build/export/ServerMaster.app
```

with `method` set to `developer-id` in `ExportOptions.plist`.

### [ ] Manual release QA checklist

Keep a short manual pass before every release:

- Control: start, stop, restart, open URL, copy address, health check.
- Profiles: create, edit, duplicate, delete, import/export profile data.
- Console and Terminal: open logs, run a command, close tabs cleanly.
- Database: start the managed database, browse tables, open the web panel.
- Ports and Dependencies: refresh data and handle missing tools gracefully.
- Settings: update checks, language, PATH entries, database panel choice.
- Certificates and config editor: create, trust/export, edit and restore config.
- Shutdown window: stop every managed process and release reserved ports.

### [ ] Self-signed certificate is not marked as trusted

A deliberate choice, not a breakage. Checked on the user's machine: the
certificate is issued as `CN=localhost, O=ServerMaster` — so openssl, not
mkcert. HTTPS works and the encryption is real, but `security verify-cert`
returns `CSSMERR_TP_NOT_TRUSTED`, so the browser shows a warning that has to be
clicked through by hand.

Two ways to remove the warning, both requiring a password:

- **Certificates…** → *Trust in the system* for the current certificate, or
- switch to mkcert and install its local CA.

Either is fine, and so is leaving it as is.

### [ ] Make test fixtures self-contained

Move the integration-test scaffolding into the repository or generate it during
the tests:

- Joomla fixture downloads for Joomla 5 and 6.
- A local mock server for update-checker raw/API responses.
- Isolated MariaDB datadir and port for database tests.
- Cleanup for child processes left behind by interrupted test runs.

Fresh checkouts should be able to run the intended test target without private
scratchpad folders or a manually started helper server.

## Tool limitations — not app bugs

**http-server does not protect dotfiles.** Its `--no-dotfiles` flag only hides
them from the directory listing; a direct request for `/.env` still returns the
contents. Verified live. Only Nginx and Caddy actually deny access. The UI says
so plainly, so the checkbox does not create false confidence.

**Custom error pages work only on Nginx and Caddy.** http-server, Python and the
PHP built-in server cannot do it at all. The switch is disabled for them, with
the reason shown.

**Ports below 1024 require uid 0.** Being in the `admin` group is not enough —
it has to be root. Handled by launching through the system password prompt (see
*Administrator rights* in the profile). The password is typed into a macOS
window; the app never sees it.
