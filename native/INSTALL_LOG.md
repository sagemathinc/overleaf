# Native Overleaf Install Log

Date: 2026-04-27
Status: success
Repo root: `/home/user/overleaf`

## Options

- Frontend port: `9000`
- Internal web port: `9001`
- Public URL: `http://127.0.0.1:9000`
- Apt stage: `skipped`
- npm install stage: `skipped`
- Web build stage: `skipped`

## Tooling

- Node.js: `v24.15.0`
- npm: `11.12.1`
- Repo npm engine: `11.11.0`

## System packages

```text
build-essential
postgresql
redis-server
mongodb-org
mongodb-mongosh
nginx
libmagic-dev
imagemagick
optipng
qpdf
jq
parallel
pkg-config
python-is-python3
python3-pygments
inkscape
poppler-utils
latexmk
texlive-latex-recommended
texlive-latex-extra
texlive-fonts-recommended
texlive-pictures
texlive-plain-generic
texlive-xetex
texlive-luatex
texlive-bibtex-extra
texlive-extra-utils
texlive-lang-english
biber
```

## MongoDB apt repository

```text
deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse
```

## Generated files

- `native/overleaf.env`
- `native/start-overleaf.sh`
- `native/stop-overleaf.sh`

## Runtime topology

- Front proxy: `nginx` on `9000`
- Web backend: `9001`
- Real-time: `3026`, exposed through `/socket.io`
- CLSI file server: `8080`
- history-v1: `3100`

## Build commands

```bash
CYPRESS_INSTALL_BINARY=0 npm install --omit=dev
CYPRESS_INSTALL_BINARY=0 npm install --include=dev -w services/web
npm run lezer-latex:generate -w services/web
make -C services/web create_module_Makefiles
npm run precompile-pug -w services/web
OVERLEAF_CONFIG=/home/user/overleaf/services/web/config/settings.webpack.js npm run webpack:production -w services/web
```

## Usage

```bash
cd /home/user/overleaf
./native/start-overleaf.sh
./native/stop-overleaf.sh
```
