# Native Overleaf

This directory contains a native, non-Docker bring-up for the Overleaf monorepo.

## Bootstrap

From the repo root:

```bash
./native/bootstrap-overleaf.sh
```

Useful flags:

```bash
./native/bootstrap-overleaf.sh --port 9100 --public-url http://127.0.0.1:9100
./native/bootstrap-overleaf.sh --skip-apt
./native/bootstrap-overleaf.sh --write-only
```

The bootstrap script:

- installs the Ubuntu packages needed by the current native setup
- adds the MongoDB apt repository if needed
- runs the npm install steps used for the web service
- builds the web assets
- regenerates `native/overleaf.env`, `native/start-overleaf.sh`, and `native/stop-overleaf.sh`
- rewrites `native/INSTALL_LOG.md`

## Start and stop

```bash
./native/start-overleaf.sh
./native/stop-overleaf.sh
```

Default runtime topology:

- frontend nginx proxy: `9000`
- internal web service: `9001`
- real-time service: `3026`
- history-v1: `3100`

The frontend port is the only one that normally needs to be forwarded to a browser.