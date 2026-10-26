# ServerMaster

ServerMaster is a local web server manager for macOS. A cross-platform Swift
command-line interface and native Windows interface are in development.

The repository is being rebuilt from verified release snapshots. Source code,
release history, build instructions, and downloadable applications will be
added in separate, reviewable steps.

## Repository layout

| Path | Purpose |
| --- | --- |
| `macos/` | Native macOS application, extensions, tests, and Xcode project |
| `linux/` | Linux integration files such as service and installation definitions |
| `windows/` | Native Windows interface and Visual Studio solution |
| `cli/` | One cross-platform Swift CLI codebase for macOS and Linux |
| `updates/` | Stable update manifests and legacy compatibility files |
| `web/` | Static project website published with GitHub Pages |
| `docs/` | Architecture, development, and release documentation |
| `scripts/` | Repository maintenance and release scripts |

## Releases

Source snapshots are identified by Git tags. Compiled applications and
checksums are published as assets on the GitHub Releases page; build artifacts
are not stored in the Git history.

## Printing & Publishing templates

The Windows version includes a **Printing & Publishing** template category for
print-shop and Web-to-Print workflows. These templates do the setup a small
printing company would otherwise do by hand: preparing runtimes, downloading
open-source software, creating a database and launching the site locally.

Available templates:

- **Web-to-Print Showcase** builds a ready print shop in one step: WordPress and
  WooCommerce in Ukrainian, print products with format, paper, run and finish
  options and prices, delivery, payment and sample orders. The profile starts and
  opens in the browser as soon as it is ready.
- **Web-to-Print Store** prepares WordPress with WooCommerce and Printcart
  Integration and one demo product, as a starting point for your own store.
- **Print Shop CRM** downloads PrintShopCRM, installs its npm dependencies,
  creates local SQLite data, seeds a demo shop and runs the Node.js server.

Getting started on Windows:

1. Open **New profile** and choose a template from **Printing & Publishing**.
2. Choose an empty project folder.
3. Use **Install missing software** if ServerMaster reports a missing runtime.
4. Create the profile. ServerMaster prepares the project, starts it and opens it.

Store admin credentials are saved in `servermaster-demo.md` in the project folder.
The internet is needed once, while a template is prepared; afterwards the projects
run offline. Third-party components keep their own licenses: PrintShopCRM is
AGPL-3.0-or-later, WordPress and WooCommerce are GPL software, and Printcart
Integration comes from the WordPress.org plugin directory; its online designer
works with a Printcart account.

## License

Original ServerMaster source code is available under the [MIT License](LICENSE).
Bundled third-party components retain their respective licenses.
