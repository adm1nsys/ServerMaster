# ServerMaster for Windows

Open `ServerMaster.slnx` in Visual Studio, or build the WinUI application with:

```powershell
dotnet build src/ServerMaster.Windows/ServerMaster.csproj -p:Platform=x64
```

PHP profiles pin a branch (8.2, 8.3, 8.4 or 8.5). ServerMaster downloads the
latest patch for that branch from the official PHP Windows release manifest,
verifies SHA-256, and installs it under `ServerMaster\Runtime\php` in the
package's `ApplicationData.LocalFolder` (LocalState). Unpackaged builds use
`%APPDATA%\ServerMaster\Runtime\php`. Explicit physical paths avoid MSIX
AppData redirection hiding DLLs and installers from native child processes.
Profiles and settings stay in their existing location. PHP installations from
older packaged builds must be installed again through Dependencies; their old
files are left untouched.
Each profile launches its own selected executable. Required CMS extensions
are enabled and checked before an installation is reported ready. Removing
a PHP branch is blocked while a profile uses it. Visual C++ v14 Runtime is
downloaded directly from Microsoft and its Authenticode signature is verified.
The dependency screen shows installed and available versions, with update and
repair actions. PHP installation prepares the matching x64/x86 runtime first.
Windows may request administrator permission for the Microsoft installer.
Other system dependencies use Windows Package Manager; http-server uses npm.

The packaged WinUI app runs with the current user's permissions because Windows does
not allow an MSIX app with `requireAdministrator` activation. Operations that need
elevation should request UAC for that operation only.

The dependency screen and profile wizard share observable installation state.
Installer output is streamed, failures remain visible, and concurrent installer
processes are serialized. The wizard can install the missing components in order.

Diagnostics checks profile folders, free disk space, memory, the database,
launch configuration, required software, firewall and proxy settings, bind
availability for stopped profiles and HTTP responses for running profiles. Each
address can be traced step by step. Findings include next steps and can be copied
as a report. Checks do not start custom commands, install software or terminate
processes.

The Ports section lists listening TCP and UDP sockets with the owning process and
PID, filters by port, process or PID, opens HTTP listeners in the browser, and can
terminate a selected process after confirmation. Ports can also be reserved for a
project. Nothing is ever killed silently.

Run the headless regression checks (no system packages are installed):

```powershell
dotnet run --project tests/ServerMaster.SmokeTests
dotnet run --project tests/ServerMaster.SmokeTests -- --online
```

The online checks download PHP 8.2 and 8.3 into a unique temporary directory,
check extensions and installation progress, verify the Microsoft Visual C++
installer's signature and version without executing it, serve HTTP using both versions,
verify independent removal, and clean up. They need internet access and the
Microsoft Visual C++ Runtime.
Offline diagnostics tests cover occupied and available ports, missing folders,
invalid ports, HTTP 200/503 responses and exclusion of profile credentials from
the report.
Dependency regression checks also cover Cyrillic PowerShell/native output,
Python Store alias detection and incomplete PHP packages missing `php8.dll`.

Joomla profiles use a small managed PHP router to canonicalize explicit
`installation/index.php` (and other standard entry points) to directory URLs.
This avoids duplicated asset prefixes in Joomla's `cli-server` URI handling.
Redirects use HTTP 307 to preserve POST requests and keep query strings. Joomla
files and permissions are not modified. This is not a general SEF rewrite engine.
To test an existing, not-yet-installed Joomla package without installing its database:

```powershell
dotnet run --project tests/ServerMaster.SmokeTests -- --joomla-root "C:\Sites\Joomla" --php "C:\PHP\php.exe"
```

The test starts PHP on an ephemeral local port, checks installer CSS/JS responses,
redirect semantics and missing assets, then stops the test server.

## Printing & Publishing templates

The profile wizard includes a **Printing & Publishing** category for print-shop
and Web-to-Print workflows.

**Web-to-Print Showcase** builds a complete local print shop in one step and is
the quickest way to see the workflow. It downloads WordPress and WooCommerce in
Ukrainian, then fills the store in a single pass: print products (business cards,
flyers, posters, stickers) with format, paper, run and finish options and prices
per run, artwork requirements, delivery, payment and sample orders in different
production states. Only the project folder is asked for; the profile then starts
and opens in the browser. The store admin address and login are saved in
`servermaster-demo.md` in the project folder, shown at the top of **Files**.

**Web-to-Print Store** is the same WordPress, WooCommerce and Printcart
Integration setup with a single demo product, for building a store of your own.
It downloads WordPress, starts the managed MariaDB service, creates its own
database and user, writes `wp-config.php`, installs the plugins from
WordPress.org, completes the installation with WP-CLI and records the admin
credentials in `servermaster-demo.md`.

**Print Shop CRM** uses PrintShopCRM from
`https://github.com/ColeLundstrom/printshopcrm`. The template downloads the
source, creates `.env`, keeps SQLite data and uploads inside the project folder,
runs `npm install`, seeds demo data, and launches `server.mjs` through the Node
profile engine.

The internet is needed once, while a template is prepared; afterwards the
projects run offline. Printcart's online product designer works with a Printcart
account; the store itself runs fully locally.

## Port parity

The Windows app follows the macOS app screen by screen. Intentional differences:
dependencies install through WinGet or verified downloads, the terminal offers
CMD and PowerShell, and the macOS command-line tool, Safari extension and widgets
are not ported.

Files includes breadcrumbs, hidden/config groups, rename and dotfile actions,
Open with, file information, and a text editor with search, wrapping and dirty-close
protection. The editor supports UTF-8 and BOM-marked UTF-16, rejects binary/oversize
files, and refuses to overwrite external changes. File snapshots include hidden
files and empty directories and are published only after ZIP creation succeeds.
Linked files/folders cause a readable error rather than an incomplete snapshot.

Run the focused filesystem regression checks without installing dependencies:

```powershell
dotnet run --project tests/ServerMaster.SmokeTests -- --files-only
```

Focused core checks (no system installations):

```powershell
dotnet run --project tests/ServerMaster.SmokeTests -- --lifecycle-only
dotnet run --project tests/ServerMaster.SmokeTests -- --database-only
dotnet run --project tests/ServerMaster.SmokeTests -- --adminer-only
```

Lifecycle tests use Node.js if available and isolated temporary sites. Database
tests initialize a temporary MariaDB data directory and skip when port 3307 is
already occupied; existing databases and processes are not touched. Adminer tests
require an already installed PHP runtime and Adminer and do not download them.
Custom/extra arguments follow Windows command-line quoting (use double quotes
around paths containing spaces).
