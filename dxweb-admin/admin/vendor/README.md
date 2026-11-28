# Vendored browser assets

These files are served locally by DXWeb Admin so the admin interface works on
nodes without outbound internet access and does not depend on a third-party
CDN at runtime.

| File | Package | Version | License |
|---|---|---|---|
| `echarts.min.js` | [echarts](https://www.npmjs.com/package/echarts) | 6.0.0 | Apache-2.0, see `LICENSE.echarts` |
| `xterm.js`, `xterm.css` | [@xterm/xterm](https://www.npmjs.com/package/@xterm/xterm) | 5.5.0 | MIT, see `LICENSE.xterm` |
| `addon-fit.js` | [@xterm/addon-fit](https://www.npmjs.com/package/@xterm/addon-fit) | 0.10.0 | MIT, see `LICENSE.xterm` |

Source files were downloaded from jsDelivr and the `sourceMappingURL`
comments were removed because the map files are not shipped.

To upgrade:

```sh
curl -fsSL -o echarts.min.js \
  https://cdn.jsdelivr.net/npm/echarts@6.0.0/dist/echarts.min.js
curl -fsSL -o xterm.js \
  https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js
curl -fsSL -o xterm.css \
  https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css
curl -fsSL -o addon-fit.js \
  https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.js
```

Then update the version references in `admin/index.html` and this table.
Check the new release notes before upgrading a major version.
