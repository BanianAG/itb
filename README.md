# ITB — Information Toolbench

**ITB** is a metadata modelling platform. You model entities, attributes and relations on
a canvas; a generation engine turns that model into artefacts — SQL, dbt projects,
documentation — from templates you can extend.

This repository is how you **run it**: three published images, wired by Docker Compose,
with a reverse proxy in front. No source code here.

---

## Before you start

- **The images are public.** No `docker login`, no account.
- **A licence file is required** — free of charge, self-service:
  <https://itb.banian.ch/license/>. The API verifies it at startup and exits
  without it, which from the outside is a container that stops with no useful log.
- **Exactly one account.** Not a recommendation: a second entry in `ITB_AUTH_USERS`
  makes the API refuse to start (`exit 27`), naming the reason in its log.

---

## Run it

```bash
cp /path/to/your/license.json ./license.json    # the one thing to fetch first
./itb.sh                                        # Windows without WSL: .\itb.ps1
```

`itb.sh` asks four things — version, e-mail, password, port — writes `.env`, creates
`./data`, checks the licence and starts the stack. Safe to run again: the second time it
only starts.

```bash
./itb.sh --check         # what is missing? changes nothing, starts nothing
./itb.sh --reconfigure   # answer the questions again (your .env is backed up)
./itb.sh --logs          # start, then follow the API log
```

### By hand

```bash
cp .env.example .env                   # fill in what it marks as required
cp /path/to/your/license.json ./license.json
mkdir -p data && sudo chown -R 65532:65532 data
docker compose up -d
```

| URL | What |
| --- | --- |
| <http://itb.localhost> | The modeller |
| <http://api.itb.localhost/user-docs/> | The user guide — see the note below |
| <http://api.itb.localhost/docs> | The API reference |
| <http://localhost:8080> | The proxy dashboard |

**The user guide is baked into the API image**, so it matches the version you run. It was
broken in images before `v0.1.2-2544`: built with a `baseUrl` of `/api/user-docs/`, it
loaded and then 404'd on every stylesheet — Docusaurus reported "did not load properly …
a wrong site baseUrl". If you see that, your API tag is older than `v0.1.2-2544`.

**Why the `chown`:** the API runs as uid **65532**, and a directory you create belongs to
you. Skip it and the API starts but cannot save. To avoid `sudo`, add `user: "0:0"` to the
`itb-api` service instead — that runs the container as root, which is why it is not the
default.

---

## Where your things are

```
data/
  users/<id>/model/               your model
  users/<id>/output/              what the generator produced
  users/<id>/connections/         stored connection settings
  marketplace/company/            packs you add for your organisation
  marketplace/community/          packs you want to share more widely
```

`<id>` is derived from your account name and stays the same across restarts. A pack
dropped into `marketplace/company/` is picked up **without a restart** — a pack is a
directory with a `config/config.json`; the in-app documentation describes the format.

```bash
docker compose down        # keeps ./data
docker compose down -v     # also keeps ./data — it is a directory, not a volume
```

Nothing here deletes your data. Removing `./data` is yours to do.

---

## Updating

```bash
# new tags in .env, then
docker compose pull && docker compose up -d
```

Your model and packs live in `./data` and are untouched by an image change.

---

## Documentation

- **Online:** <https://itb.banian.ch/docs/>
- **In the app:** <http://api.itb.localhost/user-docs/> — served by your own deployment, so
  it matches the version you run.

---

## What is in this repository

| File | Purpose |
| --- | --- |
| `itb.sh` / `itb.ps1` | Set up and run. Twins — same questions, same steps |
| `docker-compose.yml` | The three services: `itb-proxy`, `itb-api`, `itb-client` |
| `dynamic.yml` | The proxy's routing. Watched — edits apply without a restart |
| `.env.example` | Every setting. Copy to `.env` |
| `LICENSE` | The terms this software is provided under |

---

## When something does not come up

```bash
docker compose logs itb-api
```

The licence check logs every step and why it stopped, so start here.

| Symptom | Cause |
| --- | --- |
| Container exits immediately, no application log | No licence at `./license.json`, or expired |
| Container exits with "nobody could log in" | `ITB_AUTH_USERS` not set in `.env` |
| Container exits, log says "a public license runs exactly one" | `ITB_AUTH_USERS` lists more than one account |
| Runs, but nothing can be saved | `./data` not writable by uid 65532 — the `chown` above |
| Proxy ignores an edit to `dynamic.yml` | The single-file mount detached — `docker compose restart itb-proxy` |
| App loads, reports the API unavailable | `ITB_CORS_ALLOW_ORIGINS` does not match the URL you opened |

`./itb.sh --check` catches the first three and an *empty* `ITB_CORS_ALLOW_ORIGINS`,
without changing anything. A value that is set but wrong it cannot see — compare it
against the address in your browser's bar.

---

## License

Free of charge for private and commercial use, with no redistribution. See
[`LICENSE`](LICENSE) for the terms.
