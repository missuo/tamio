# tamio.sh

Tamio's complete public website, served by Cloudflare Workers with static
assets. The site uses HTML, CSS, and browser JavaScript; there is no frontend
build step.

## Pages and behavior

- `/`: the responsive product page, download links, copyable setup commands,
  navigation, and an interactive app demonstration.
- `/download` and `/download/`: temporary redirects to the official
  [latest Tamio release](https://github.com/missuo/tamio/releases/latest).
- Unknown paths: the custom `public/404.html` page with HTTP status 404.
- `www.tamio.sh`: permanent redirects to `tamio.sh`, preserving the path and
  query string.
- Search and sharing: canonical URL, structured application data, social
  preview image, icons, `robots.txt`, and `sitemap.xml`.

The app demonstration runs in the browser with sample data. Its server views,
terminal output, agent approval, and activity history illustrate
the Mac app; they do not open SSH connections or make changes to real servers.
The actual SSH, SFTP, sync, and MCP functionality belongs to the native app.

The homepage and error page share an animated pixel garden. Animations pause
when reduced motion is enabled, the garden is offscreen, or the page is hidden. The
static artwork remains visible if JavaScript or the scene request fails.

## Preview and verify

Use a current Node.js LTS release and npm. From the repository root:

```sh
cd website
npm ci
npm run dev       # http://localhost:8787
```

Wrangler previews the Worker routes and static assets together, including the
download redirect and custom 404. A generic static server can display the UI,
but does not reproduce the Worker's redirects.

```sh
npm run check    # Local assets, anchors, JSON-LD, and JavaScript syntax
npm test         # Worker routing and cache stamping regression tests
npm run stamp    # Refresh stylesheet/script hashes without deploying
```

The tests use Node's built-in test runner and temporary directories, with no
additional packages or network requests. The checks do not replace a browser
review of mobile layout, keyboard navigation, and demo interactions.

## Files

- `public/index.html`, `styles.css`, `main.js`: page content, responsive styling,
  navigation, and setup interactions.
- `public/demo.js`, `demo.css`: the interactive app window, drawn in HTML and CSS.
  Keep its measurements and colors aligned with the app's design tokens in
  `Foundation/TamioDesign/Sources/TamioDesign/Tokens.swift`.
- `public/server-garden.svg`, `garden.css`, `garden.js`: the shared pixel
  artwork, CSS animation, and visibility and motion-preference controls.
- `public/404.html`: the error page; `public/_headers`: security and cache headers.
- `public/og.png`, app icons, `robots.txt`, `sitemap.xml`: search and sharing assets.
- `og/card.html`: the local social-card artwork. Run `bash og/render.sh` to
  regenerate `public/og.png` with Chrome, Python 3, and ImageMagick.
- `src/index.js`: canonical-host and download routing; `wrangler.jsonc`: hosting.
- `scripts/stamp.mjs`: portable SHA-256 cache stamping, also exposed by `stamp.sh`.

## Deploy

```sh
npm run check
npm test
npx wrangler login
npm run deploy
```

Deploying requires access to the Cloudflare account that holds the `tamio.sh`
zone. The existing deployment command stamps local CSS and JavaScript links in
every `public/*.html` file before running Wrangler. Stamping works on macOS and
Linux, preserves other query parameters, skips remote resources, and produces
the same files when run again without asset changes.

For another hosting provider, upload the contents of `public/` and reproduce the
canonical-host redirect, `/download` redirect, custom 404 response, and security
headers in that server's configuration. Never use a homepage fallback for
unknown paths. The app icon assets originate in `Resources/Tamio.icon`.
