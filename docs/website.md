# Website maintenance

The website is plain HTML, CSS, and JavaScript in `web/`. It has no build step
or package dependencies. The existing Pages workflow publishes the contents
of `web/` as the site root: `https://adm1nsys.github.io/ServerMaster/`.
The source folder name does not add an extra `/web/` to the public URL.

## Downloads

Edit `web/data/releases.json`. The page fetches it at runtime and builds the
platform picker, current download, and release archive from that file.
It does not call GitHub's API in visitors' browsers.

For a new version:

1. Publish its GitHub Release and upload the compiled application and any
   source snapshot or checksum files.
2. Add a release object to the platform's `releases` array. Keep older entries.
3. Use the exact `browser_download_url` URLs of the uploaded assets.
   GitHub may normalize spaces in filenames to dots.
4. Set `currentRelease` to the new entry's `id`, and set the platform's
   `status` to `available` and `statusLabel` to `Available now`.
5. Update visible development/release wording in `web/index.html` if needed.
6. Commit the website when approved, then run **Actions → Deploy website →
   Run workflow**.

Each release includes its requirements, architecture, build identifier,
package format, version, and assets. Asset kinds are `application`, `source`,
and `checksums`. Multiple `application` assets are supported: use distinct
labels such as `Linux glibc · ARM64` and `Linux musl · x86_64`. Do not offer a
platform or architecture until its binary is actually uploaded.

Set `signed: false` for an unsigned application. Omit `sizeBytes` for releases
with several application archives; each download can have its own label.
Only HTTPS links on `github.com` are accepted by the catalog renderer.

An unreleased platform uses `status: "planned"`, `currentRelease: null`, and
`releases: []`. Its entry describes planned targets without offering a
nonexistent download. The future Intel-only legacy line can be added as a
separate platform entry when it is ready; the published 1.0 Universal release
already includes Intel.

Keep this catalog separate from `updates/maclastversion.txt`, which is read
by existing app installations. The text file is not a download catalog.

## Preview

From the repository root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory web
```

Open `http://127.0.0.1:4173/`. Opening the HTML as a `file://` URL cannot
reliably load JSON, so use a local HTTP server.

Screenshots can show active development work without promising a particular
version number or release date. The catalog offers only published builds and
shows the exact version being downloaded. The workflow comparisons illustrate
process differences, not measured speed or performance.

WebP copies are used for fast loading; the supplied PNG originals remain
unchanged. The gallery can open each optimized image in a new tab.

The simple 404 home link uses `/ServerMaster/` so that nested missing paths
return to the real project home. If moving to a custom domain or a differently
named repository, update that link.

## Documentation

Repository documentation remains in the top-level `docs/` folder. That folder
is not currently published by Pages. To publish a separate `/docs/` site later,
build or copy its public output into the Pages artifact alongside the website;
no root redirect is required.
