DXSPIDER WEB ADMIN - OPERATIONAL OVERVIEW
=========================================

DXWeb Admin is the separate SYSOP administration web application. The
version declared by admin.pl, /admin-version.json and the supplied HTML
in this snapshot is 0.75.0. Its default HTTP port is 7381.

The administrative backend is dxweb-admin/admin.pl. It uses a local-only
DXSpider transport at 127.0.0.1 and DXS_PORT (default 27754). DXSpider
allocates its #WEB-n technical channel dynamically. Browser sessions
must authenticate as DXSpider users with SYSOP privilege 9 or higher.

The application exposes /healthz and /admin-version.json. The latter
reports the application version independently of the DXSpider Git build.
It also provides an asynchronous /update-status.json endpoint.

Its operation, registration, supervision, metrics, timeline and console
functions depend on the corresponding DXSpider backend capabilities.
The historical UI-V2-NOTES.txt references files from an older external
release package; this repository's installation guide is INSTALL.txt.

For installation, see INSTALL.txt. User Web is independent and optional.
