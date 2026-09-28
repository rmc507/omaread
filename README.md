# OmaRead

![OmaRead](preview.png)

An Omarchy shell plugin that speed-reads text one word at a time in a
centered, themed card. Point it at the clipboard, highlighted text, or a
copied webpage link.

Each word is placed so its focus letter (a little left of the middle, drawn
in the theme's accent color) always lands on the same column, marked by two
small ticks. Your eyes stay still; the words come to you.

## Use

Copy some text, or a link to an article, and press **`Super+Shift+T`**.
Press it again (or `Esc`) to close.

| Key | Action |
|---|---|
| `Space` / `Enter` / click | Pause / resume (restart when finished) |
| `←` `→` or `h` `l` | Previous / next sentence |
| `↑` `↓` or `k` `j` | Faster / slower |
| `Home` | Back to the start |
| `Esc` / `q` | Close |

In `auto` mode (the default) it reads the clipboard. A clipboard that holds
just a URL is fetched and reduced to the article text. When the clipboard is
empty it falls back to the highlighted (primary) selection.

## Install

```bash
omarchy plugin add https://github.com/rmc507/omaread.git --enable
```

Then add a keybinding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + T", "OmaRead", "omarchy-shell shell toggle io.github.rmc507.omaread '{}'")
```

### Dependencies

- `wl-clipboard` and `python3`, both of which ship with Omarchy.
- Optional: the [`defuddle`](https://github.com/kepano/defuddle) CLI. When it
  is on your `PATH`, webpages are cleaned with it; otherwise a built-in
  extractor keeps the page's `<article>`/`<main>` text.

The plugin only reads `~/.config/omarchy/shell.json`; it never writes to your
configuration. Webpages are downloaded as HTML and read as text, never run.
Only public http(s) addresses are fetched (links to localhost or your local
network are refused, including via redirects), proxy settings are ignored,
and downloads stop at 5 MB.

## Configure

Settings live on the plugin's entry in `~/.config/omarchy/shell.json` and
apply on save. All three are optional:

```jsonc
"plugins": [
  {
    "id": "io.github.rmc507.omaread",
    "wpm": 400,          // words per minute (60–1500)
    "source": "auto",    // auto | clipboard | selection
    "fontSize": 0        // word size in px; 0 follows the theme
  }
]
```

Reading pauses briefly at punctuation and paragraph ends, so the real pace
is a little under the set speed. Changes made with the arrow keys last until
the card is closed.

## Other ways to open it

The summon payload can override the source, so other bindings or scripts can
read something specific:

```bash
omarchy-shell shell toggle io.github.rmc507.omaread '{"source":"selection"}'
omarchy-shell shell toggle io.github.rmc507.omaread '{"url":"https://example.com/post"}'
omarchy-shell shell toggle io.github.rmc507.omaread '{"file":"~/Books/novel.epub"}'
omarchy-shell shell toggle io.github.rmc507.omaread '{"text":"Read this.","title":"Note","wpm":400}'
```

Files can be `.txt`, `.md`, `.html` or `.epub`. EPUBs are read in spine
order.

## How it works

- `SpeedReader.qml` is the overlay: the card, the word timer and the keys.
- `ReaderModel.js` holds the pure logic: config, tokenizing, focus letter,
  timing and sentence jumps.
- `bin/fetch-text` gets the text (clipboard, selection, URL or file) and
  prints `title`, a blank line, then the body. You can run it on its own:
  `bin/fetch-text url https://example.com`.

## Develop

```bash
node --test tests/*.test.js   # ReaderModel tests
omarchy plugin validate .
```

Saving a file reloads the plugin. If the open card still shows the old
version, run `omarchy restart shell`.

## Uninstall

```bash
omarchy plugin remove io.github.rmc507.omaread
```

Then delete the `SUPER + SHIFT + T` binding from `~/.config/hypr/bindings.lua`.

## License

MIT, see [LICENSE](LICENSE).
