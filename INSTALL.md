# Installing Caduceus

This guide takes a fresh machine to a running Caduceus stack. Plan on about an hour, most of it spent waiting for the first image build.

## 1. Requirements

| Need | Notes |
|---|---|
| Docker with Compose v2 | Docker Desktop on macOS or Windows; Docker Engine plus the compose plugin on Linux. Check with `docker compose version`. |
| `git` and `openssl` | Used by `bin/setup`. |
| Memory | Give Docker at least 8 GB; 16 GB is comfortable. Pages that need the headless browser are the hungriest part. This excludes your models. |
| Disk | About 20 GB for images, plus room for the databases. |
| An OpenAI-compatible model server | See step 2. It can run on the same machine or elsewhere on your network. |

## 2. Prepare your models

Caduceus needs one model from your server:

| Setting in `.env` | Used for | What to pick |
|---|---|---|
| `CADUCEUS_AGENT_MODEL` | The agent's conversations and tool use | Your strongest model with reliable tool calling and a long context window |

Reading web pages needs no model. Memory needs no model from your server either. Its search uses its own embedding model,
`BAAI/bge-small-en-v1.5`, which runs on the CPU inside the `hermes` container
and is downloaded once from Hugging Face on the first start.

Example using [Ollama](https://ollama.com) (the default `CADUCEUS_LLM_BASE_URL` assumes Ollama on the same machine):

```bash
ollama pull <your-agent-model>
curl -s http://localhost:11434/v1/models     # use the exact name in .env
```

> **Linux only:** Containers reach the host through the Docker bridge, not loopback. Start Ollama with `OLLAMA_HOST=0.0.0.0` so they can connect, and firewall port 11434 from the rest of your network. Docker Desktop on macOS and Windows needs no change.

## 3. Get the code and run setup

```bash
git clone <this-repository-url> caduceus
cd caduceus
bin/setup
```

`bin/setup`:
- creates `.env` with generated secrets and prints your dashboard password;
- clones Hermes Agent into `vendor/` at the commit pinned in `versions.env`;
- applies `patches/`;
- writes Hermes's image version metadata from its verified Git tag and commit;
- installs a starter Hermes config at `data/hermes/config.yaml`.

It is safe to re-run.

## 4. Configure

Open `.env` and set at least:

- `CADUCEUS_LLM_BASE_URL`: your model server, as containers see it (`host.docker.internal` means "the host machine").
- `CADUCEUS_LLM_API_KEY`: leave `local` for servers that don't check keys.
- The two model names from step 2.

Matrix is optional and can be added later (see step 8).

Hermes's bundled `obsidian` skill reads and writes notes in the folder `OBSIDIAN_VAULT_DIR` names (default `data/obsidian`; quote paths with spaces). To sync it with your other devices, see step 9.

## 5. Build and start

```bash
docker compose build        # first build takes a while
docker compose up -d
```

The first start downloads the integration dependencies and can take several
minutes. The `hermes-init` service installs the Mnemosyne plugin from the Hermes plugin
catalog at the commit in `versions.env`, downloads Mnemosyne's embedding model,
and installs the bundled Iris plugin from `plugins/iris`. Hermes and the dashboard wait for that
step to finish successfully. Follow progress with:

```bash
docker compose logs -f hermes-init
```

The gateway and dashboard run as two supervised processes in one long-running
`hermes` container. The API remains on port 8642 and the dashboard on port 9119;
`docker compose logs -f hermes` shows both processes.

Dependencies live in the shared `hermes-dependencies` Docker volume. This keeps
Linux filenames and permissions intact on macOS and Windows. Conversations,
uploads and editable config still live in `data/hermes`.
The starter config disables public web-provider fallback so failures in your
local search or extraction service are visible.

If upgrading from the earlier two-container layout, stop the old dashboard
first so it releases its listener, then remove the retired container when
applying the new Compose file:

```bash
docker stop caduceus-hermes-dashboard
docker compose up -d --remove-orphans hermes
```

Your configuration, conversations, uploads and named volumes are preserved.

## 6. Verify the integrations

No manual plugin installation is needed. Run:

```bash
bin/check-integrations
```

This searches through SearXNG, reads a static page and a script-rendered page
through Iris, confirms Iris blocks a private address, and
checks Mnemosyne storage and cross-session recall in a throwaway database. It fails if a
configured integration fails; a public extraction fallback cannot hide a broken
local reader.

Mnemosyne keeps its SQLite database in the `hermes-mnemosyne-data` volume,
mounted at `/opt/data/mnemosyne`. Conversation turns and saved facts are stored
as they happen, and the starter config makes them recallable from every session
(`memory.mnemosyne.default_scope: global`). Recall matches by meaning, not only
by shared words (`MNEMOSYNE_POLYPHONIC_RECALL=1`). Every 10 turns Mnemosyne consolidates working
memory in the background into compact keyword digests, without calling a model.

## 7. Check that everything works

```bash
bin/status
```

Every line should say `ok`. Then talk to the agent through its API:

```bash
source .env
curl -s http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"Search the web for today'\''s top science story and summarize it with sources."}]}'
```

Or open the dashboard at <http://127.0.0.1:9119> and sign in with `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` from `.env`. The dashboard can run commands on the server, so keep it on localhost. For remote use, reach it through an SSH tunnel: `ssh -N -L 9119:localhost:9119 you@server`.

`docker compose exec hermes hermes doctor` gives a detailed self-check.

## 8. Connect Matrix (optional)

1. Create a dedicated account for the bot on your homeserver, for example `@caduceus:matrix.example.org`.
2. In `.env`, set:
   - `MATRIX_HOMESERVER`, `MATRIX_USER_ID` and `MATRIX_PASSWORD` (or `MATRIX_ACCESS_TOKEN`);
   - `MATRIX_ALLOWED_USERS`, the people allowed to talk to it;
   - for encrypted rooms, `MATRIX_E2EE_MODE`, a fixed `MATRIX_DEVICE_ID` (any stable name, e.g. `CADUCEUS_BOT`) and `MATRIX_RECOVERY_KEY` from the bot account's secure backup.
3. Run `docker compose up -d hermes`.
4. Invite the bot to a room or start a direct message.

In group rooms the bot answers only when @mentioned. To list rooms where it should answer every message, use `MATRIX_FREE_RESPONSE_ROOMS`, with room IDs that start with `!`.

> **Run only one copy of a bot account.** Two Caduceus instances, or a test copy, logged in with the same account create duplicate devices. That breaks encrypted sessions. Stop the old instance before starting a new one. To run several instances side by side (step 10), give each its own bot account.

## 9. Sync your Obsidian vault (optional)

The `obsidian-sync` service runs [Obsidian Headless](https://obsidian.md/help/sync/headless), the official command-line Sync client, against the vault folder. It needs an Obsidian Sync subscription. Until you set it up, it waits and does nothing.

1. Back up the vault folder if it already has notes.
2. Run `bin/obsidian-sync setup` and log in with your Obsidian account. Then pick the remote vault, or pass its name: `bin/obsidian-sync setup "AI Vault"`. End-to-end encrypted vaults ask for their password.
3. The first sync only downloads, so the remote copy replaces stale local files. Two-way sync then starts and uploads anything that exists only locally.

Check on it with `bin/obsidian-sync status` or `docker compose logs -f obsidian-sync`. The login and sync state live in the `obsidian-sync-config` volume.

> **Use one sync client per folder.** Don't also open this vault in the Obsidian desktop app with Sync turned on: two clients syncing the same folder cause conflicts.

## 10. Run more than one instance (optional)

Several people can each have their own Caduceus on one machine. Each instance
has its own conversations, memory, Matrix bot and vault. Use one checkout per
instance:

```bash
git clone <this-repository-url> ~/caduceus-dana
cd ~/caduceus-dana
bin/setup --instance dana
```

`--instance` sets `COMPOSE_PROJECT_NAME` in that checkout's `.env`. Docker
Compose scopes containers, volumes, networks and the built images
(`dana-hermes:local`, `dana-obsidian-sync:local`) by this name, so instances
never share state. Setup refuses a name that another checkout already uses.
When setup creates `.env`, it moves `API_SERVER_PORT`, `DASHBOARD_PORT` and
`SEARXNG_PORT` past any port already used by a listener or by another
container, including stopped ones, and prints the ports it chose. Then
configure, build and start the new checkout as in steps 4 and 5. Every
command, including `bin/status` and `bin/cleanup`, acts only on the instance
of the checkout it runs from.

Each instance needs:

- **Its own Matrix bot account** (step 8). Two instances logged in to the same
  account break encrypted sessions.
- **Its own vault folder and Obsidian Sync vault** (step 9). The default
  `OBSIDIAN_VAULT_DIR` is already inside each checkout. Sync shows the device as
  `Caduceus (dana)`.
- **About 8 GB more memory for Docker.** Each instance runs its own headless browser.

All instances can use the same model server. Concurrent conversations queue on
it unless it serves requests in parallel; for Ollama, set
`OLLAMA_NUM_PARALLEL`.

Run every checkout as the same host user: Docker Desktop runs one engine per
user account. That user can read every instance's data, so whoever administers
the machine can see every instance's conversations.

The dashboard stays bound to localhost. To use an instance from another
computer, open an SSH tunnel to that instance's `DASHBOARD_PORT`, for example:

```bash
ssh -N -L 9119:localhost:9129 you@server    # then open http://127.0.0.1:9119
```

Existing single-instance installs keep working unchanged. Without
`COMPOSE_PROJECT_NAME`, the instance is named `caduceus`, and it is the only
instance that can keep that name.

## Day-to-day operation

| Task | Command |
|---|---|
| Health check | `bin/status` |
| Follow logs | `docker compose logs -f hermes` (or any service name) |
| Restart the gateway and dashboard | `docker compose restart hermes` |
| Check search, page reading and memory | `bin/check-integrations` |
| Start (and show status) | `bin/start` (runs `docker compose up -d`) |
| Stop | `bin/stop` (keeps containers) or `bin/stop --down` (removes them; data is kept) |
| Apply `.env` changes | `docker compose up -d` |
| Hermes CLI | `docker compose exec hermes hermes --help` |

**Back up** these things together:
- `.env`
- `data/hermes/`
- `data/obsidian/`, if you use the default vault
- the Docker volumes listed by `docker volume ls --filter label=com.docker.compose.project=caduceus`

Replace `caduceus` with your `COMPOSE_PROJECT_NAME` if you set one (step 10);
volume names start with that name and an underscore. To back up a volume, stop
the stack first, then run for example:

```bash
docker run --rm -v caduceus_hermes-mnemosyne-data:/v -v "$PWD/backups:/b" alpine tar czf /b/mnemosyne-data.tgz -C /v .
```

**Upgrade** deliberately:
1. Change the refs and commits in `versions.env`, and the dated SearXNG image
   tag in `docker-compose.yml` when updating search.
2. Run `bin/setup`. It takes out the patches, including ones an earlier Caduceus release applied, moves `vendor/`, and re-applies the current patches. If a patch no longer applies, it stops and tells you.
3. Run `docker compose pull searxng`, then
   `docker compose build && docker compose up -d`.
4. Run `bin/status` and `bin/check-integrations`.

Back up first. Upstream releases sometimes change config formats or database schemas.

To move Mnemosyne to a new catalog pin, change `MNEMOSYNE_COMMIT` in
`versions.env` and run `docker compose up -d`. `hermes-init` reinstalls the
plugin at the new commit. Mnemosyne migrates its database on first open.

## Reset for a clean-install test

Preview the reset, including deletion of Hermes's host data:

```bash
bin/cleanup --dry-run --reset-data
```

After backing up anything you need, run:

```bash
bin/cleanup --reset-data
bin/setup
docker compose build --pull --no-cache
docker compose up -d
bin/status
bin/check-integrations
```

`bin/cleanup` lists its targets and asks you to type the Compose project name
before deleting them. Use `--yes` to skip that prompt in an automated test.
It removes the project's containers (including retired services), attached
anonymous volumes, all project-labeled named volumes and networks, the
project's own image tags (`caduceus-hermes` and `caduceus-obsidian-sync`, or
`<instance>-…` for another instance), and dangling images labeled for the
project. Other instances on the same machine are left alone. Images still required
by other containers are protected by Docker; cleanup stops if removal fails.

**This erases databases, learned memories, integration dependencies and Matrix
encryption state.** `--reset-data` also deletes the configured `HERMES_DATA_DIR`
(default `data/hermes`), including conversations, uploads, skills and edited
Hermes config. Omit `--reset-data` to keep that host directory. A fresh Matrix
login may require device verification or key recovery.

The repository `.env`, `vendor/` and starter `config/` remain available for
reinstallation. To test initial settings generation too, move `.env` to a safe
backup location before rerunning `bin/setup`, then configure the new `.env`.
Shared upstream images and Docker's build cache are retained; the build flags
above refresh base images and bypass cached build steps without pruning other
projects. The script uses this checkout's `docker-compose.yml` and resolves
`.env` and shell overrides through Compose. If you started the stack with
`docker compose -p NAME`, pass the same name to `bin/cleanup --project-name NAME`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Dashboard is unavailable or its supervised process keeps restarting | No login configured. Set `DASHBOARD_PASSWORD` in `.env`, then `docker compose up -d hermes`. Check `docker compose logs hermes` for the dashboard error. |
| Dashboard version shows `vunknown` | Run `bin/setup`, `docker compose build hermes`, then `docker compose up -d`. Setup writes release metadata into the image because Docker excludes Git history. |
| `hermes-init` exits with an error | Read `docker compose logs hermes-init`. Check outbound package-download access, fix the reported error, then run `docker compose up -d`. Runtime services wait for initialization to succeed. |
| `hermes-init` reports `Mnemosyne's local embedding model is unavailable` | The container could not download `BAAI/bge-small-en-v1.5` from Hugging Face. Allow outbound access to `huggingface.co`, then run `docker compose up -d`. The model is cached in the `hermes-mnemosyne-data` volume afterwards. |
| The agent saved something but a new conversation can't recall it | Your `data/hermes/config.yaml` predates the global default. Add `default_scope: global` under `memory.mnemosyne`, then `docker compose restart hermes`. Memories saved before the change stay in their original session. |
| `hermes-init` prints `Keeping user-managed Mnemosyne plugin` | A Mnemosyne plugin installed by hand is left alone. To let Caduceus manage it, run `docker compose run --rm hermes-init` after removing it with `docker compose exec hermes hermes plugins remove mnemosyne`. |
| Mnemosyne or Iris is inactive, or initialization reports `File exists` under `installs/.../terminfo` | Use the updated Compose file with the shared `hermes-dependencies` volume, then run `docker compose up -d --force-recreate hermes-init hermes`. The old bind-mounted dependency directory is retained beneath the new volume. |
| New dashboard chats stay on `reconnecting` | Check `docker compose logs hermes`. The current Compose file runs the gateway and dashboard together so chat can reach the gateway's private localhost listener. For an older two-container deployment, apply the migration command in step 5. |
| `bin/status` says Hermes API FAILED with HTTP 401 | A stale `API_SERVER_KEY` in the Hermes data directory overrides the project `.env` key. See the repair below. |
| `bin/status` says Models FAILED | The model server is down, or unreachable from Docker. On Linux, see the `OLLAMA_HOST` note in step 2. Some servers accept loopback connections only; containers reach the host as `host.docker.internal`, which must be allowed. |
| A page comes back as `Prove your humanity` or a similar challenge | The site blocks automated browsers. Iris does not solve CAPTCHAs. Use a different source for that page. |
| `hermes-init` prints `Keeping user-managed Iris plugin` | `data/hermes/plugins/web/iris` exists but was not installed by Caduceus. Remove it and run `docker compose up -d` to use the bundled copy. |
| `port is already allocated` on start | Another service or instance is using a port. Change `API_SERVER_PORT`, `DASHBOARD_PORT` or `SEARXNG_PORT` in `.env`. |
| `bin/setup` says the instance already exists in another checkout | Two checkouts would share one set of containers and volumes. Use a different name with `bin/setup --instance NAME` (step 10). |
| `Conflict. The container name "/caduceus-hermes" is already in use` | A checkout that predates multi-instance support still uses fixed container names. Update that checkout (`git pull`, then `docker compose up -d`) or give the new one a different instance name. |
| Matrix: bot can't read encrypted messages | Usually a second login created a new device. Make sure only one instance runs, `MATRIX_DEVICE_ID` is fixed, and `MATRIX_RECOVERY_KEY` is set. Restart `hermes`. |
| Files in `data/hermes` are owned by root | `HERMES_UID`/`HERMES_GID` don't match your user. Re-run `bin/setup` (it sets them), fix ownership with `sudo chown -R "$(id -u):$(id -g)" data`, then `docker compose up -d`. |

For the Hermes API 401 error, use the updated `docker-compose.yml`, which passes
`API_SERVER_KEY` to Hermes. Older configurations let a separate dashboard
container generate a different key in the shared data directory. Hermes loads
that saved key ahead of the one supplied by Compose.

From the repository root, remove only the saved key (keeping a backup), then
recreate Hermes so it uses the project `.env` key:

```bash
sed -i.bak '/^API_SERVER_KEY=/d' data/hermes/.env
docker compose up -d --no-deps --force-recreate hermes
bin/status
```

If you set `HERMES_DATA_DIR`, use that directory instead of `data/hermes`.

Hermes's built-in supervisor starts the dashboard alongside the gateway in the
same container. They share the private `127.0.0.1` chat endpoint directly, and
one `docker compose restart hermes` restarts both. The dashboard's published
host port stays bound to `127.0.0.1`.
